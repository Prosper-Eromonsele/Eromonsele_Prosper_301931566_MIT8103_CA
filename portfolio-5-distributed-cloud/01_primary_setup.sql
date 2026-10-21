-- =====================================================================
-- TC.Solutions - prepare the PRIMARY for streaming replication (Portfolio 5)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
-- Run on the primary (tcs-postgres) once.
-- =====================================================================

-- a login that may only stream WAL; it cannot read or change table data
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'repl_lab_2026';   -- lab-only password
  END IF;
END $$;

-- keep recent WAL so a replica that falls behind can catch up
ALTER SYSTEM SET wal_keep_size = '512MB';
SELECT pg_reload_conf();
SELECT pg_sleep(1);

-- settings that make replication possible (PostgreSQL 16 defaults)
SELECT name, setting FROM pg_settings
WHERE name IN ('wal_level', 'max_wal_senders', 'wal_keep_size', 'synchronous_commit', 'synchronous_standby_names')
ORDER BY name;

SELECT rolname, rolreplication, rolcanlogin FROM pg_roles WHERE rolname = 'replicator';
