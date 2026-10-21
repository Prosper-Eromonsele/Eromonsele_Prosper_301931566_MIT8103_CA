-- =====================================================================
-- Run on the PRIMARY: post one transfer and print the exact time it committed.
-- Then read it on the replica (05_read_after_write.sql).
-- =====================================================================
\i /work/portfolio-3-transactions-concurrency/session_start.sql
SELECT transfer(:bola, :kunle, 500, 'P5 replication test') AS txn_id \gset
SELECT :txn_id AS txn_id, reference, amount, clock_timestamp() AS committed_on_primary_at
FROM tcs.transactions WHERE txn_id = :txn_id;
