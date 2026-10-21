-- =====================================================================
-- Run on the PRIMARY: switch to SYNCHRONOUS replication.
-- From now on COMMIT waits until the replica has the change.
-- =====================================================================
ALTER SYSTEM SET synchronous_standby_names = 'tcs_replica';
SELECT pg_reload_conf();
SELECT pg_sleep(1);
SELECT application_name, state, sync_state FROM pg_stat_replication;
