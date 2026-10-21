-- =====================================================================
-- Run on the PRIMARY: a burst of writes (about 3 million rows, ~150 MB of WAL)
-- in a scratch schema, to make the replica fall behind for a moment.
-- Watch the lag from another window with 02_primary_status.sql.
-- =====================================================================
\timing on
CREATE SCHEMA IF NOT EXISTS lab;
DROP TABLE IF EXISTS lab.lag_test;
CREATE TABLE lab.lag_test AS
SELECT g AS id, md5(g::text) AS payload, now() AS created_at
FROM generate_series(1, 3000000) AS g;
SELECT pg_size_pretty(pg_total_relation_size('lab.lag_test')) AS table_size;
