-- =====================================================================
-- TC.Solutions - execution plans (Portfolio 2)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
--
-- Run this file TWICE: once BEFORE 04_indexes.sql and once AFTER it,
-- and compare the plans and the "Execution Time" lines.
-- =====================================================================
SET search_path TO tcs;
\timing on

SELECT customer_id AS cust FROM customers ORDER BY customer_id OFFSET 1002 LIMIT 1 \gset
SELECT wallet_id AS w_from FROM wallets WHERE customer_id = :cust \gset
SELECT wallet_id AS w_to FROM wallets WHERE customer_id = :cust + 1 \gset
SELECT initiated_by AS fast_cust FROM transactions
WHERE txn_type = 'TRANSFER' AND narration = 'Transfer' AND created_at::date = '2026-10-10' LIMIT 1 \gset

SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE indexrelname LIKE 'idx\_%' ORDER BY 1;

-- ---------------------------------------------------------------------
\echo '=== E1. Q1 customer statement (one wallet, one month) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT le.created_at::date, t.reference, t.txn_type, t.narration,
       CASE WHEN le.direction = 'DR' THEN le.amount END,
       CASE WHEN le.direction = 'CR' THEN le.amount END,
       le.balance_after
FROM wallets w
JOIN ledger_entries le ON le.wallet_id = w.wallet_id
JOIN transactions  t  ON t.txn_id     = le.txn_id
WHERE w.customer_id = :cust
  AND le.created_at >= '2026-09-01' AND le.created_at < '2026-10-01'
ORDER BY le.created_at, le.entry_id;

-- ---------------------------------------------------------------------
\echo '=== E2. Q3 merchant settlement for one day ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.merchant_id, m.business_name, count(*), sum(t.amount),
       sum(LEAST(round(t.amount * 0.015, 2), 2000))
FROM transactions t
JOIN merchants m ON m.merchant_id = t.merchant_id
WHERE t.txn_type = 'MERCHANT_PAYMENT' AND t.status = 'SUCCESS'
  AND t.created_at >= '2026-09-15' AND t.created_at < '2026-09-16'
GROUP BY m.merchant_id, m.business_name
ORDER BY 4 DESC
LIMIT 10;

-- ---------------------------------------------------------------------
\echo '=== E3. Q4b real-time velocity check for ONE customer (runs before every transfer) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(amount)
FROM transactions
WHERE initiated_by = :fast_cust AND txn_type = 'TRANSFER' AND status = 'SUCCESS'
  AND created_at >  TIMESTAMPTZ '2026-10-10 02:00+01' - INTERVAL '60 minutes'
  AND created_at <= TIMESTAMPTZ '2026-10-10 02:00+01';

-- ---------------------------------------------------------------------
\echo '=== E4. Q4 batch velocity report for the whole of October ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT initiated_by, max(c)
FROM (SELECT initiated_by,
             count(*) OVER (PARTITION BY initiated_by ORDER BY created_at
                            RANGE BETWEEN INTERVAL '60 minutes' PRECEDING AND CURRENT ROW) AS c
      FROM transactions
      WHERE txn_type = 'TRANSFER' AND status = 'SUCCESS' AND created_at >= '2026-10-01') x
GROUP BY initiated_by
HAVING max(c) >= 10;

-- ---------------------------------------------------------------------
\echo '=== E5. Posting one N100 transfer. Watch the time on COMMIT: ==='
\echo '=== the balanced-ledger trigger runs at COMMIT and looks up ledger_entries by txn_id ==='
BEGIN;
INSERT INTO transactions (reference, txn_type, status, amount, channel, initiated_by, narration)
VALUES ('TCS-P2-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'),
        'TRANSFER', 'SUCCESS', 100, 'APP', :cust, 'P2 timing test');
INSERT INTO ledger_entries (txn_id, wallet_id, direction, amount, balance_after)
SELECT currval('transactions_txn_id_seq'), wallet_id, 'DR', 100, balance - 100 FROM wallets WHERE wallet_id = :w_from;
INSERT INTO ledger_entries (txn_id, wallet_id, direction, amount, balance_after)
SELECT currval('transactions_txn_id_seq'), wallet_id, 'CR', 100, balance + 100 FROM wallets WHERE wallet_id = :w_to;
UPDATE wallets SET balance = balance - 100 WHERE wallet_id = :w_from;
UPDATE wallets SET balance = balance + 100 WHERE wallet_id = :w_to;
COMMIT;
