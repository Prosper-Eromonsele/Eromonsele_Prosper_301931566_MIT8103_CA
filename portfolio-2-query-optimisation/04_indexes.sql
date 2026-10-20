-- =====================================================================
-- TC.Solutions - indexes chosen from the "before" execution plans (Portfolio 2)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
-- PostgreSQL indexes primary keys and UNIQUE columns by itself, but NOT
-- foreign-key columns. These four cover the slow paths found in E1-E5.
-- =====================================================================
SET search_path TO tcs;
\timing on

DROP INDEX IF EXISTS idx_ledger_wallet_time, idx_ledger_txn,
                     idx_txn_merchant_pay_day, idx_txn_sender_transfers;

-- E1 statement: find one wallet's entries for a date range, already in date order
CREATE INDEX idx_ledger_wallet_time ON ledger_entries (wallet_id, created_at);

-- E5 posting: the balanced-ledger trigger (and the FK to transactions) look up by txn_id
CREATE INDEX idx_ledger_txn ON ledger_entries (txn_id);

-- E2 settlement: partial index, only successful merchant payments (about 20% of rows)
CREATE INDEX idx_txn_merchant_pay_day ON transactions (created_at)
    WHERE txn_type = 'MERCHANT_PAYMENT' AND status = 'SUCCESS';

-- E3 real-time velocity: one sender's successful transfers by time
CREATE INDEX idx_txn_sender_transfers ON transactions (initiated_by, created_at)
    WHERE txn_type = 'TRANSFER' AND status = 'SUCCESS';

ANALYZE ledger_entries;
ANALYZE transactions;

SELECT indexrelname AS index_name, relname AS table_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE indexrelname LIKE 'idx\_%' ORDER BY 2, 1;
