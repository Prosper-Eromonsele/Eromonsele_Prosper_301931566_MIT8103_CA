-- =====================================================================
-- Run on the PRIMARY: who is replicating from me, and how far behind are they?
-- =====================================================================
\x on
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS bytes_behind,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
\x off
