-- =====================================================================
-- Run on the REPLICA (tcs-replica, port 5433)
-- =====================================================================
SET search_path TO tcs;
\timing on

\echo '=== R1. Am I a replica? (t = yes, read-only standby) ==='
SELECT pg_is_in_recovery() AS i_am_a_replica;

\echo '=== R2. Where am I streaming from? ==='
SELECT status, sender_host, sender_port, slot_name, latest_end_time
FROM pg_stat_wal_receiver;

\echo '=== R3. How old is the last change I replayed? ==='
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;

\echo '=== R4. The data is all here (same counts as the primary) ==='
SELECT (SELECT count(*) FROM customers)      AS customers,
       (SELECT count(*) FROM transactions)   AS transactions,
       (SELECT count(*) FROM ledger_entries) AS ledger_entries;

\echo '=== R5. Writes are refused on a replica ==='
UPDATE wallets SET balance = balance + 1 WHERE wallet_id = 1;

\echo '=== R6. The heavy finance report (Portfolio 2, Q2 reconciliation) runs here instead of on the primary ==='
SELECT count(*) AS wallets_not_matching_ledger FROM (
  SELECT w.wallet_id
  FROM wallets w LEFT JOIN ledger_entries le ON le.wallet_id = w.wallet_id
  WHERE w.wallet_type <> 'SYSTEM'
  GROUP BY w.wallet_id
  HAVING w.balance <> COALESCE(SUM(CASE WHEN le.direction = 'CR' THEN le.amount ELSE -le.amount END), 0)) x;
