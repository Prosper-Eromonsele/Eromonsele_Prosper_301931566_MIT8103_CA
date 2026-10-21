-- =====================================================================
-- TC.Solutions - export the fraud-relevant data from PostgreSQL to CSV
-- for the Neo4j graph (Portfolio 4)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
-- Runs inside the PostgreSQL container; files land in portfolio-4-nosql/import,
-- which the Neo4j container sees as its /import folder.
-- Window: 1-15 October 2026 (the period the fraud team is investigating).
-- =====================================================================
SET search_path TO tcs;
\timing on

\echo 'customers.csv'
\copy (SELECT customer_id, first_name || ' ' || last_name AS name, kyc_tier, state_of_residence AS state FROM customers ORDER BY customer_id) TO '/work/portfolio-4-nosql/import/customers.csv' WITH (FORMAT csv, HEADER)

\echo 'devices.csv'
\copy (SELECT device_id, device_fingerprint AS fingerprint, os FROM devices ORDER BY device_id) TO '/work/portfolio-4-nosql/import/devices.csv' WITH (FORMAT csv, HEADER)

\echo 'uses.csv  (customer -> device)'
\copy (SELECT customer_id, device_id, to_char(first_used AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS first_used FROM customer_devices ORDER BY 1, 2) TO '/work/portfolio-4-nosql/import/uses.csv' WITH (FORMAT csv, HEADER)

\echo 'transfers.csv  (customer -> customer, successful wallet transfers, 1-15 Oct)'
\copy (SELECT t.txn_id, t.initiated_by AS from_customer, w.customer_id AS to_customer, t.amount, to_char(t.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS at FROM transactions t JOIN ledger_entries le ON le.txn_id = t.txn_id AND le.direction = 'CR' JOIN wallets w ON w.wallet_id = le.wallet_id AND w.wallet_type = 'CUSTOMER' WHERE t.txn_type = 'TRANSFER' AND t.status = 'SUCCESS' AND t.created_at >= '2026-10-01' AND t.created_at < '2026-10-16' ORDER BY t.txn_id) TO '/work/portfolio-4-nosql/import/transfers.csv' WITH (FORMAT csv, HEADER)

\echo 'bank_accounts.csv  (external accounts paid in the window)'
\copy (SELECT DISTINCT b.bank_code || '-' || b.account_number AS key, b.bank_code, bk.bank_name, b.account_number, b.account_name FROM transactions t JOIN beneficiaries b ON b.beneficiary_id = t.beneficiary_id JOIN banks bk ON bk.bank_code = b.bank_code WHERE t.txn_type = 'EXTERNAL_TRANSFER' AND t.status = 'SUCCESS' AND t.created_at >= '2026-10-01' AND t.created_at < '2026-10-16' ORDER BY 1) TO '/work/portfolio-4-nosql/import/bank_accounts.csv' WITH (FORMAT csv, HEADER)

\echo 'payouts.csv  (customer -> external bank account)'
\copy (SELECT t.txn_id, t.initiated_by AS customer_id, b.bank_code || '-' || b.account_number AS account_key, t.amount, to_char(t.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS at FROM transactions t JOIN beneficiaries b ON b.beneficiary_id = t.beneficiary_id WHERE t.txn_type = 'EXTERNAL_TRANSFER' AND t.status = 'SUCCESS' AND t.created_at >= '2026-10-01' AND t.created_at < '2026-10-16' ORDER BY t.txn_id) TO '/work/portfolio-4-nosql/import/payouts.csv' WITH (FORMAT csv, HEADER)

\echo 'Done. Row counts:'
SELECT 'customers' AS file, count(*) FROM customers
UNION ALL SELECT 'devices', count(*) FROM devices
UNION ALL SELECT 'uses', count(*) FROM customer_devices
UNION ALL SELECT 'transfers', count(*) FROM transactions WHERE txn_type = 'TRANSFER' AND status = 'SUCCESS' AND created_at >= '2026-10-01' AND created_at < '2026-10-16'
UNION ALL SELECT 'payouts', count(*) FROM transactions WHERE txn_type = 'EXTERNAL_TRANSFER' AND status = 'SUCCESS' AND created_at >= '2026-10-01' AND created_at < '2026-10-16';
