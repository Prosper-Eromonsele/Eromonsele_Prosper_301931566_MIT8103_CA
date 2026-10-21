-- =====================================================================
-- Run on the REPLICA straight after 04: is the new transfer already here?
-- =====================================================================
SELECT txn_id, reference, amount, narration, created_at,
       clock_timestamp() AS read_on_replica_at,
       now() - pg_last_xact_replay_timestamp() AS replay_delay
FROM tcs.transactions
WHERE narration = 'P5 replication test'
ORDER BY txn_id DESC LIMIT 3;
