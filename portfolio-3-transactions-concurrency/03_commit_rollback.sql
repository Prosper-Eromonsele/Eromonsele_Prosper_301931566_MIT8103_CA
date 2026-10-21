-- =====================================================================
-- TC.Solutions - COMMIT, ROLLBACK and SAVEPOINT (Portfolio 3, part 1)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
-- One window. Run 02_demo_accounts.sql first.
-- Some statements below are SUPPOSED to fail; read the ERROR lines.
-- =====================================================================
\i /work/portfolio-3-transactions-concurrency/session_start.sql
\set ON_ERROR_STOP off

\echo ''
\echo '=== Starting balances ==='
SELECT * FROM v_demo_wallets ORDER BY wallet_id;

\echo ''
\echo '=== A. COMMIT: Bola sends Kunle N2,500 ==='
BEGIN;
SELECT transfer(:bola, :kunle, 2500, 'Rent contribution') AS txn_id;
COMMIT;
SELECT * FROM v_demo_wallets ORDER BY wallet_id;

\echo ''
\echo '=== B1. ROLLBACK by choice: Bola starts sending Ada N1,000, then cancels ==='
BEGIN;
SELECT transfer(:bola, :ada, 1000, 'Cancelled by customer') AS txn_id;
\echo '--- inside the transaction, the money has moved:'
SELECT * FROM v_demo_wallets ORDER BY wallet_id;
ROLLBACK;
\echo '--- after ROLLBACK, nothing happened:'
SELECT * FROM v_demo_wallets ORDER BY wallet_id;

\echo ''
\echo '=== B2. Automatic rollback: Ada (balance 0) tries to send N3,000 ==='
BEGIN;
SELECT transfer(:ada, :bola, 3000, 'No money') AS txn_id;
\echo '--- after an error, PostgreSQL refuses everything else in this transaction:'
SELECT 1 AS anything;
ROLLBACK;

\echo ''
\echo '=== B3. Atomicity: a half-done transfer written by hand ==='
\echo '--- header and debit leg are written, then the balance update breaks CHECK (balance >= 0)'
BEGIN;
INSERT INTO transactions (reference, txn_type, status, amount, channel, initiated_by, narration)
VALUES ('TCS-P3-HALFDONE', 'TRANSFER', 'SUCCESS', 50000, 'APP',
        (SELECT customer_id FROM wallets WHERE wallet_id = :kunle), 'Half-done transfer');
INSERT INTO ledger_entries (txn_id, wallet_id, direction, amount, balance_after)
VALUES (currval('transactions_txn_id_seq'), :kunle, 'DR', 50000, 0);
UPDATE wallets SET balance = balance - 50000 WHERE wallet_id = :kunle;
ROLLBACK;
\echo '--- the header and the debit leg written before the error are gone too:'
SELECT count(*) AS rows_with_that_reference FROM transactions WHERE reference = 'TCS-P3-HALFDONE';

\echo ''
\echo '=== B4. SAVEPOINT: a batch of three transfers where the middle one fails ==='
BEGIN;
SELECT transfer(:bola, :kunle, 500, 'Batch item 1') AS txn_id;
SAVEPOINT before_item_2;
SELECT transfer(:ada, :kunle, 5000, 'Batch item 2') AS txn_id;
ROLLBACK TO SAVEPOINT before_item_2;
SELECT transfer(:bola, :ada, 300, 'Batch item 3') AS txn_id;
COMMIT;
\echo '--- items 1 and 3 committed, item 2 was skipped:'
SELECT * FROM v_demo_wallets ORDER BY wallet_id;

\echo ''
\echo '=== B5. KYC limit: Bola (Tier 2, single limit N100,000) tries to send N150,000 ==='
SELECT transfer(:bola, :kunle, 150000, 'Too big') AS txn_id;

\echo ''
\echo '=== Final balances (all must say OK) ==='
SELECT * FROM v_demo_wallets ORDER BY wallet_id;
