-- Each statement below SHOULD FAIL. The error message is the evidence that the constraint works.
SET search_path TO tcs;
\set ON_ERROR_STOP off
\echo '--- 1. negative balance (CHECK balance >= 0)'
UPDATE wallets SET balance = -100 WHERE wallet_id = 3;
\echo '--- 2. Tier 2 customer without BVN (chk_bvn_for_tier)'
INSERT INTO customers (first_name,last_name,phone,date_of_birth,state_of_residence,kyc_tier)
VALUES ('Test','User','+2348000000001','1995-01-01','Oyo',2);
\echo '--- 3. under-18 customer'
INSERT INTO customers (first_name,last_name,phone,date_of_birth,state_of_residence)
VALUES ('Young','User','+2348000000002','2015-01-01','Oyo');
\echo '--- 4. invalid phone format'
INSERT INTO customers (first_name,last_name,phone,date_of_birth,state_of_residence)
VALUES ('Bad','Phone','08031234567','1990-01-01','Lagos');
\echo '--- 5. beneficiary with unknown bank (foreign key)'
INSERT INTO beneficiaries (customer_id,bank_code,account_number,account_name) VALUES (1,'999','0123456789','X');
\echo '--- 6. unbalanced ledger (deferred constraint trigger, fails at COMMIT)'
BEGIN;
INSERT INTO transactions (reference,txn_type,status,amount,channel,initiated_by)
VALUES ('TCS-TEST-UNBAL','TRANSFER','SUCCESS',1000,'APP',1);
INSERT INTO ledger_entries (txn_id,wallet_id,direction,amount,balance_after)
VALUES (currval('transactions_txn_id_seq'),1,'DR',1000,234000);
COMMIT;
\echo '--- 7. duplicate transaction reference (idempotency)'
INSERT INTO transactions (reference,txn_type,status,amount,channel,initiated_by)
VALUES ('TCS-20261020-0001','TRANSFER','SUCCESS',10,'APP',1);
