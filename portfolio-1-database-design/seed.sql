-- Small hand-made sample data to prove the schema works (Portfolio 1).
SET search_path TO tcs;

-- Tier limits are illustrative values modelled on CBN's three-tier KYC idea
INSERT INTO kyc_tiers VALUES
 (1,'Basic - phone and name only',      50000,   50000,   300000),
 (2,'BVN verified',                    100000,  200000,   500000),
 (3,'Full KYC (BVN, NIN, address)',   5000000, 5000000,      NULL);

INSERT INTO banks VALUES
 ('044','Access Bank'),('058','Guaranty Trust Bank'),('011','First Bank of Nigeria'),
 ('033','United Bank for Africa'),('057','Zenith Bank');

INSERT INTO staff (full_name,email,role) VALUES
 ('Ngozi Okeke','ngozi.okeke@tcsolutions.ng','COMPLIANCE'),
 ('Tunde Bakare','tunde.bakare@tcsolutions.ng','SUPPORT'),
 ('Halima Sani','halima.sani@tcsolutions.ng','FINANCE');

INSERT INTO customers (first_name,last_name,phone,email,date_of_birth,state_of_residence,kyc_tier,bvn_hash) VALUES
 ('Chinedu','Okafor','+2348031234567','chinedu@example.com','1990-04-12','Lagos',3, encode(sha256('22123456789'::bytea),'hex')),
 ('Aisha','Bello','+2348059876543',NULL,'1998-09-30','Kano',2, encode(sha256('22987654321'::bytea),'hex')),
 ('Emeka','Nwosu','+2349061112233','emeka@example.com','2001-01-05','Abia',1, NULL);

INSERT INTO wallets (wallet_type,customer_id,balance) VALUES
 ('CUSTOMER',1,250000),('CUSTOMER',2,40000),('CUSTOMER',3,5000),
 ('MERCHANT',NULL,0),('AGENT_FLOAT',NULL,500000),('SYSTEM',NULL,10000000);

INSERT INTO merchants (business_name,cac_rc_number,category,settlement_wallet_id,api_key_hash) VALUES
 ('Mama Put Online','RC1234567','Food delivery',4, encode(sha256('demo-key'::bytea),'hex'));
INSERT INTO agents (agent_code,full_name,phone,lga,state,float_wallet_id) VALUES
 ('AG-ABA-001','Uche Eze','+2348101234567','Aba South','Abia',5);

INSERT INTO devices (device_fingerprint,os) VALUES ('fp-a1b2c3','ANDROID'),('fp-d4e5f6','IOS');
INSERT INTO customer_devices (customer_id,device_id) VALUES (1,1),(2,2),(3,1);  -- device 1 shared

INSERT INTO beneficiaries (customer_id,bank_code,account_number,account_name,nickname) VALUES
 (1,'058','0123456789','Okafor Ifeoma','Sister');

-- One balanced internal transfer: Chinedu -> Aisha, N15,000
BEGIN;
INSERT INTO transactions (reference,txn_type,status,amount,channel,initiated_by,device_id,narration)
VALUES ('TCS-20261020-0001','TRANSFER','SUCCESS',15000,'APP',1,1,'Rent contribution');
INSERT INTO ledger_entries (txn_id,wallet_id,direction,amount,balance_after) VALUES
 (currval('transactions_txn_id_seq'),1,'DR',15000,235000),
 (currval('transactions_txn_id_seq'),2,'CR',15000, 55000);
UPDATE wallets SET balance = balance - 15000 WHERE wallet_id = 1;
UPDATE wallets SET balance = balance + 15000 WHERE wallet_id = 2;
COMMIT;
