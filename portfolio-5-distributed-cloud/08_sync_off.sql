-- =====================================================================
-- Run on the PRIMARY: back to ASYNCHRONOUS replication (the default).
-- Any COMMIT that was stuck waiting for the replica completes straight away.
-- =====================================================================
ALTER SYSTEM RESET synchronous_standby_names;
SELECT pg_reload_conf();
SELECT pg_sleep(1);
SELECT application_name, state, sync_state FROM pg_stat_replication;
