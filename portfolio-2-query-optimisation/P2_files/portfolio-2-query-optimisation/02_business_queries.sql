-- =====================================================================
-- TC.Solutions - business queries (Portfolio 2)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
-- Each query answers a question one of the case-study users actually asks.
-- =====================================================================
SET search_path TO tcs;
\timing on

-- the customer and merchant used as examples below
SELECT customer_id AS cust FROM customers ORDER BY customer_id OFFSET 1002 LIMIT 1 \gset
SELECT wallet_id AS cust_wallet FROM wallets WHERE customer_id = :cust \gset
\echo 'Example customer:' :cust ' wallet:' :cust_wallet

-- ---------------------------------------------------------------------
\echo '=== Q1. Customer account statement for September 2026 (customer support) ==='
-- Every debit and credit on one wallet, with the running balance after each one.
SELECT le.created_at::date                                   AS value_date,
       t.reference,
       t.txn_type,
       t.narration,
       CASE WHEN le.direction = 'DR' THEN le.amount END       AS debit,
       CASE WHEN le.direction = 'CR' THEN le.amount END       AS credit,
       le.balance_after
FROM wallets w
JOIN ledger_entries le ON le.wallet_id = w.wallet_id
JOIN transactions  t  ON t.txn_id     = le.txn_id
WHERE w.customer_id = :cust
  AND le.created_at >= '2026-09-01' AND le.created_at < '2026-10-01'
ORDER BY le.created_at, le.entry_id;

-- ---------------------------------------------------------------------
\echo '=== Q2. Reconciliation: wallets whose stored balance disagrees with the ledger (finance) ==='
-- wallets.balance is kept for speed (see Portfolio 1). This proves it still matches
-- the double-entry ledger. Expected result: 0 rows.
-- The SYSTEM wallet is left out: it is reconciled against the partner bank statement.
SELECT w.wallet_id, w.wallet_type, w.balance AS stored_balance,
       COALESCE(SUM(CASE WHEN le.direction = 'CR' THEN le.amount ELSE -le.amount END), 0) AS ledger_balance
FROM wallets w
LEFT JOIN ledger_entries le ON le.wallet_id = w.wallet_id
WHERE w.wallet_type <> 'SYSTEM'
GROUP BY w.wallet_id
HAVING w.balance <> COALESCE(SUM(CASE WHEN le.direction = 'CR' THEN le.amount ELSE -le.amount END), 0);

\echo '=== Q2b. Same check after a simulated bug changes one balance without a ledger entry ==='
BEGIN;
UPDATE wallets SET balance = balance + 5000 WHERE wallet_id = :cust_wallet;   -- the "bug"
SELECT w.wallet_id, w.wallet_type, w.balance AS stored_balance,
       COALESCE(SUM(CASE WHEN le.direction = 'CR' THEN le.amount ELSE -le.amount END), 0) AS ledger_balance
FROM wallets w
LEFT JOIN ledger_entries le ON le.wallet_id = w.wallet_id
WHERE w.wallet_type <> 'SYSTEM'
GROUP BY w.wallet_id
HAVING w.balance <> COALESCE(SUM(CASE WHEN le.direction = 'CR' THEN le.amount ELSE -le.amount END), 0);
ROLLBACK;                                                                       -- undo the "bug"

-- ---------------------------------------------------------------------
\echo '=== Q3. Merchant settlement for 15 September 2026, top 10 merchants (finance) ==='
-- Fee is an illustrative 1.5% per payment, capped at N2,000.
SELECT m.merchant_id,
       m.business_name,
       count(*)                                         AS payments,
       sum(t.amount)                                    AS gross,
       sum(LEAST(round(t.amount * 0.015, 2), 2000))     AS fees,
       sum(t.amount) - sum(LEAST(round(t.amount * 0.015, 2), 2000)) AS net_to_settle
FROM transactions t
JOIN merchants m ON m.merchant_id = t.merchant_id
WHERE t.txn_type = 'MERCHANT_PAYMENT' AND t.status = 'SUCCESS'
  AND t.created_at >= '2026-09-15' AND t.created_at < '2026-09-16'
GROUP BY m.merchant_id, m.business_name
ORDER BY gross DESC
LIMIT 10;

-- ---------------------------------------------------------------------
\echo '=== Q4. Velocity rule: accounts with 10 or more transfers inside any 60 minutes, October 2026 (fraud team) ==='
WITH w AS (
  SELECT initiated_by, created_at, amount,
         count(*)    OVER last_hour AS txns_in_last_hour,
         sum(amount) OVER last_hour AS value_in_last_hour
  FROM transactions
  WHERE txn_type = 'TRANSFER' AND status = 'SUCCESS'
    AND created_at >= '2026-10-01'
  WINDOW last_hour AS (PARTITION BY initiated_by ORDER BY created_at
                       RANGE BETWEEN INTERVAL '60 minutes' PRECEDING AND CURRENT ROW)
)
SELECT w.initiated_by AS customer_id,
       c.first_name || ' ' || c.last_name AS customer,
       c.kyc_tier,
       max(txns_in_last_hour)  AS peak_transfers_in_1h,
       max(value_in_last_hour) AS peak_value_in_1h,
       round(avg(amount))      AS avg_amount
FROM w JOIN customers c ON c.customer_id = w.initiated_by
GROUP BY w.initiated_by, c.first_name, c.last_name, c.kyc_tier
HAVING max(txns_in_last_hour) >= 10
ORDER BY peak_transfers_in_1h DESC;

\echo '=== Q4b. Real-time version: transfers by one customer in the last 60 minutes before a new transfer ==='
SELECT initiated_by AS cust FROM transactions
WHERE txn_type = 'TRANSFER' AND narration = 'Transfer' AND created_at::date = '2026-10-10' LIMIT 1 \gset
SELECT count(*) AS transfers_last_hour, sum(amount) AS value_last_hour
FROM transactions
WHERE initiated_by = :cust AND txn_type = 'TRANSFER' AND status = 'SUCCESS'
  AND created_at >  TIMESTAMPTZ '2026-10-10 02:00+01' - INTERVAL '60 minutes'
  AND created_at <= TIMESTAMPTZ '2026-10-10 02:00+01';

-- ---------------------------------------------------------------------
\echo '=== Q5. One device used by several customers (fraud team, KYC) ==='
SELECT d.device_fingerprint, d.os,
       count(*) AS customers_on_device,
       string_agg(c.first_name || ' ' || c.last_name, ', ' ORDER BY c.customer_id) AS customers
FROM customer_devices cd
JOIN devices   d ON d.device_id   = cd.device_id
JOIN customers c ON c.customer_id = cd.customer_id
GROUP BY d.device_id, d.device_fingerprint, d.os
HAVING count(*) >= 3
ORDER BY customers_on_device DESC;

-- ---------------------------------------------------------------------
\echo '=== Q6. Customers whose money out in one day went over their KYC tier daily limit (compliance) ==='
SELECT t.initiated_by AS customer_id, c.kyc_tier, k.daily_limit,
       t.created_at::date AS day,
       count(*)      AS outgoing_txns,
       sum(t.amount) AS total_out
FROM transactions t
JOIN customers c ON c.customer_id = t.initiated_by
JOIN kyc_tiers k ON k.tier = c.kyc_tier
WHERE t.status = 'SUCCESS'
  AND t.txn_type IN ('TRANSFER','EXTERNAL_TRANSFER','MERCHANT_PAYMENT','WITHDRAWAL')
GROUP BY t.initiated_by, c.kyc_tier, k.daily_limit, t.created_at::date
HAVING sum(t.amount) > k.daily_limit
ORDER BY sum(t.amount) - k.daily_limit DESC
LIMIT 15;

\echo '=== Q6b. How many breaches per tier ==='
SELECT kyc_tier, count(*) AS customer_days_over_limit FROM (
  SELECT c.kyc_tier
  FROM transactions t
  JOIN customers c ON c.customer_id = t.initiated_by
  JOIN kyc_tiers k ON k.tier = c.kyc_tier
  WHERE t.status = 'SUCCESS'
    AND t.txn_type IN ('TRANSFER','EXTERNAL_TRANSFER','MERCHANT_PAYMENT','WITHDRAWAL')
  GROUP BY t.initiated_by, c.kyc_tier, k.daily_limit, t.created_at::date
  HAVING sum(t.amount) > k.daily_limit) x
GROUP BY kyc_tier ORDER BY kyc_tier;
