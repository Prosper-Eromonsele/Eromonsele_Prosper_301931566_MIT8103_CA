-- Run at the start of every psql window:  \i /work/portfolio-3-transactions-concurrency/session_start.sql
SET search_path TO tcs;
SELECT w.wallet_id AS bola  FROM wallets w JOIN customers c USING (customer_id) WHERE c.phone = '+2348099000001' \gset
SELECT w.wallet_id AS kunle FROM wallets w JOIN customers c USING (customer_id) WHERE c.phone = '+2348099000002' \gset
SELECT w.wallet_id AS ada   FROM wallets w JOIN customers c USING (customer_id) WHERE c.phone = '+2348099000003' \gset
\echo 'Wallets  bola =' :bola '  kunle =' :kunle '  ada =' :ada
