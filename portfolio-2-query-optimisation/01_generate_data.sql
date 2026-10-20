-- =====================================================================
-- TC.Solutions - synthetic data for Portfolio 2 (PostgreSQL 16)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
--
-- Run on a FRESH database: schema.sql -> seed.sql -> this file.
-- Builds about 40,000 customers, 1,200 merchants, 350 agents and
-- roughly 300,000 transactions (about 600,000 ledger entries), all fake.
-- setseed() makes the "random" data the same every time it is run.
-- =====================================================================
\set ON_ERROR_STOP on
\timing on
SET search_path TO tcs;

DO $$ BEGIN
  IF (SELECT count(*) FROM customers) > 3 THEN
    RAISE EXCEPTION 'Data already generated. Run schema.sql and seed.sql again first.';
  END IF;
END $$;

BEGIN;
SELECT setseed(0.2026);

-- ---------- 1. customers (39,997 new + 3 from seed = 40,000) ----------
INSERT INTO customers (first_name, last_name, phone, email, date_of_birth,
                       state_of_residence, kyc_tier, bvn_hash, nin_hash, created_at)
SELECT fn, ln,
       '+234' || pfx || lpad(i::text, 7, '0'),
       CASE WHEN r_mail < 0.6 THEN lower(fn) || '.' || lower(ln) || i || '@example.com' END,
       DATE '1960-01-01' + (r_dob * 15000)::int,
       st, tier,
       CASE WHEN tier >= 2 THEN encode(sha256(('BVN' || i)::bytea), 'hex') END,
       CASE WHEN tier = 3  THEN encode(sha256(('NIN' || i)::bytea), 'hex') END,
       TIMESTAMPTZ '2025-01-01' + r_join * INTERVAL '540 days'
FROM (
  SELECT i,
    (ARRAY['Chinedu','Ngozi','Emeka','Aisha','Tunde','Funmilayo','Ibrahim','Halima','Oluwaseun','Chiamaka',
           'Musa','Zainab','Adebayo','Yetunde','Ikechukwu','Amaka','Usman','Hauwa','Segun','Bolanle',
           'Nnamdi','Ifeoma','Abubakar','Fatima','Kelechi','Blessing','Emmanuel','Grace','Uche','Temitope',
           'Sani','Rukayat','Obinna','Adaeze','Babatunde','Kemi','Yakubu','Maryam','Chidi','Esther'])[1 + floor(random()*40)::int] AS fn,
    (ARRAY['Okafor','Bello','Nwosu','Adeyemi','Ibrahim','Okonkwo','Abubakar','Eze','Ogunleye','Mohammed',
           'Obi','Adebayo','Usman','Nnaji','Oladipo','Yusuf','Chukwu','Balogun','Danjuma','Ekwueme',
           'Afolabi','Garba','Onyeka','Salami','Akande','Lawal','Umeh','Ojo','Aliyu','Igwe'])[1 + floor(random()*30)::int] AS ln,
    (ARRAY['803','806','813','816','703','706','810','814','903','906','701','708',
           '802','808','812','902','905','907','809','817','818','909'])[1 + floor(random()*22)::int] AS pfx,
    (ARRAY['Lagos','Lagos','Lagos','Lagos','Lagos','Lagos','Lagos','Lagos','FCT','FCT','FCT',
           'Kano','Kano','Kano','Rivers','Rivers','Oyo','Oyo','Abia','Abia','Anambra','Anambra',
           'Ogun','Ogun','Enugu','Kaduna','Edo','Delta','Plateau','Kwara','Imo'])[1 + floor(random()*31)::int] AS st,
    CASE WHEN r_tier < 0.45 THEN 1 WHEN r_tier < 0.85 THEN 2 ELSE 3 END AS tier,
    random() AS r_mail, random() AS r_dob, random() AS r_join
  FROM (SELECT i, random() AS r_tier FROM generate_series(1, 39997) AS i) g
) s;

-- helper: generated customers numbered 1..39997 (rk)
CREATE TEMP TABLE cust AS
SELECT customer_id, kyc_tier, row_number() OVER (ORDER BY customer_id)::int AS rk
FROM customers WHERE customer_id > 3;

-- ---------- 2. wallets for every generated customer ------------------
INSERT INTO wallets (wallet_type, customer_id, balance, opened_at)
SELECT 'CUSTOMER', c.customer_id, 0, cu.created_at
FROM cust c JOIN customers cu USING (customer_id);

ALTER TABLE cust ADD COLUMN wallet_id BIGINT;
UPDATE cust c SET wallet_id = w.wallet_id FROM wallets w WHERE w.customer_id = c.customer_id;

-- ---------- 3. merchants (1,199 new) and agents (349 new) ------------
WITH w AS (
  INSERT INTO wallets (wallet_type) SELECT 'MERCHANT' FROM generate_series(1, 1199)
  RETURNING wallet_id
), n AS (SELECT wallet_id, row_number() OVER (ORDER BY wallet_id) AS rn FROM w)
INSERT INTO merchants (business_name, cac_rc_number, category, settlement_wallet_id, api_key_hash)
SELECT (ARRAY['Mama','Iya','Oga','Naija','Eko','Abuja','Kano','Royal','Golden','Zuma'])[1 + floor(random()*10)::int]
       || ' ' ||
       (ARRAY['Kitchen','Stores','Pharmacy','Electronics','Fashion','Supermarket','Gadgets','Bakery','Logistics','Hub'])[1 + floor(random()*10)::int]
       || ' ' || rn,
       'RC' || (2000000 + rn),
       (ARRAY['Food delivery','Retail','Health','Electronics','Fashion','Groceries','Transport','Bills'])[1 + floor(random()*8)::int],
       wallet_id,
       encode(sha256(('merchant-key-' || rn)::bytea), 'hex')
FROM n;

WITH w AS (
  INSERT INTO wallets (wallet_type) SELECT 'AGENT_FLOAT' FROM generate_series(1, 349)
  RETURNING wallet_id
), n AS (SELECT wallet_id, row_number() OVER (ORDER BY wallet_id) AS rn, floor(random()*14)::int + 1 AS loc FROM w)
INSERT INTO agents (agent_code, full_name, phone, lga, state, float_wallet_id)
SELECT 'AG-' || lpad((rn + 1)::text, 5, '0'),
       'Agent ' || (rn + 1),
       '+2349150' || lpad(rn::text, 6, '0'),
       (ARRAY['Ikeja','Alimosho','Surulere','Aba North','Aba South','Nassarawa','Fagge','Ibadan North',
              'Obio/Akpor','Port Harcourt','Abuja Municipal','Enugu North','Onitsha North','Oredo'])[loc],
       (ARRAY['Lagos','Lagos','Lagos','Abia','Abia','Kano','Kano','Oyo',
              'Rivers','Rivers','FCT','Enugu','Anambra','Edo'])[loc],
       wallet_id
FROM n;

CREATE TEMP TABLE merch AS SELECT merchant_id, settlement_wallet_id AS wallet_id,
       row_number() OVER (ORDER BY merchant_id)::int AS rk FROM merchants;
CREATE TEMP TABLE agt AS SELECT agent_id, float_wallet_id AS wallet_id,
       row_number() OVER (ORDER BY agent_id)::int AS rk FROM agents;

-- ---------- 4. devices: one per customer, 15% have a second one ------
INSERT INTO devices (device_fingerprint, os, first_seen)
SELECT 'fp-' || md5('dev-' || c.customer_id),
       CASE WHEN r < 0.70 THEN 'ANDROID' WHEN r < 0.85 THEN 'IOS' WHEN r < 0.90 THEN 'WEB' ELSE 'USSD' END,
       TIMESTAMPTZ '2025-01-01' + random() * INTERVAL '540 days'
FROM (SELECT customer_id, random() AS r FROM cust) c;

INSERT INTO customer_devices (customer_id, device_id, first_used, last_used)
SELECT c.customer_id, d.device_id, d.first_seen, d.first_seen + INTERVAL '30 days'
FROM cust c JOIN devices d ON d.device_fingerprint = 'fp-' || md5('dev-' || c.customer_id);

INSERT INTO devices (device_fingerprint, os, first_seen)
SELECT 'fp-' || md5('dev2-' || customer_id), 'ANDROID', TIMESTAMPTZ '2026-03-01'
FROM cust WHERE random() < 0.15;
INSERT INTO customer_devices (customer_id, device_id, first_used, last_used)
SELECT c.customer_id, d.device_id, d.first_seen, d.first_seen + INTERVAL '60 days'
FROM cust c JOIN devices d ON d.device_fingerprint = 'fp-' || md5('dev2-' || c.customer_id);

-- Planted pattern for Q5 and Portfolio 4: three phones each shared by 8 accounts
INSERT INTO devices (device_fingerprint, os, first_seen) VALUES
 ('fp-ring-01','ANDROID','2026-09-20'),('fp-ring-02','ANDROID','2026-09-22'),('fp-ring-03','IOS','2026-09-25');
INSERT INTO customer_devices (customer_id, device_id, first_used, last_used)
SELECT c.customer_id, d.device_id, d.first_seen, d.first_seen + INTERVAL '10 days'
FROM cust c
JOIN devices d ON d.device_fingerprint = CASE WHEN c.rk BETWEEN 301 AND 308 THEN 'fp-ring-01'
                                              WHEN c.rk BETWEEN 311 AND 318 THEN 'fp-ring-02'
                                              WHEN c.rk BETWEEN 321 AND 328 THEN 'fp-ring-03' END;

ALTER TABLE cust ADD COLUMN device_id BIGINT;
UPDATE cust c SET device_id = d.device_id FROM devices d
WHERE d.device_fingerprint = 'fp-' || md5('dev-' || c.customer_id);

-- ---------- 5. beneficiaries (external bank accounts) for 15,000 customers
INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name, created_at)
SELECT c.customer_id,
       (ARRAY['044','058','011','033','057'])[1 + floor(random()*5)::int],
       lpad((floor(random() * 9999999999))::bigint::text, 10, '0'),
       'Beneficiary of ' || c.customer_id,
       TIMESTAMPTZ '2026-06-01'
FROM cust c WHERE c.rk <= 15000;

-- ---------- 6. staging table: every money movement before posting ----
CREATE TEMP TABLE stage (
  txn_id BIGINT DEFAULT nextval('transactions_txn_id_seq'),
  txn_type VARCHAR(20), status VARCHAR(10) DEFAULT 'SUCCESS', amount NUMERIC(18,2),
  channel VARCHAR(6), initiated_by BIGINT, device_id BIGINT, beneficiary_id BIGINT,
  merchant_id BIGINT, agent_id BIGINT, reversal_of BIGINT, narration VARCHAR(140),
  created_at TIMESTAMPTZ, dr_wallet BIGINT, cr_wallet BIGINT, is_opening BOOLEAN DEFAULT false);

-- 6a. opening balances for the seed wallets (history behind seed.sql balances)
INSERT INTO stage (txn_type, amount, channel, initiated_by, narration, created_at, dr_wallet, cr_wallet)
VALUES ('DEPOSIT',250000,'APP',1,'Opening balance (migration)','2026-07-01 08:00+01',6,1),
       ('DEPOSIT', 40000,'APP',2,'Opening balance (migration)','2026-07-01 08:00+01',6,2),
       ('DEPOSIT',  5000,'APP',3,'Opening balance (migration)','2026-07-01 08:00+01',6,3),
       ('DEPOSIT',500000,'WEB',NULL,'Agent float funding','2026-07-01 08:00+01',6,5);

-- 6b. float funding for the new agents
INSERT INTO stage (txn_type, amount, channel, agent_id, narration, created_at, dr_wallet, cr_wallet, is_opening)
SELECT 'DEPOSIT', 2000000, 'WEB', agent_id, 'Agent float funding', TIMESTAMPTZ '2026-07-01 09:00+01', 6, wallet_id, true
FROM agt WHERE agent_id > 1;

-- 6c. first wallet funding for every generated customer (July 2026)
INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, narration, created_at, dr_wallet, cr_wallet, is_opening)
SELECT 'DEPOSIT',
       round((CASE WHEN kyc_tier = 1 THEN 150000 + random()*100000 ELSE 150000 + random()*350000 END) / 100) * 100,
       'APP', customer_id, device_id, 'Wallet funding (card)',
       TIMESTAMPTZ '2026-07-01 10:00+01' + random() * INTERVAL '30 days', 6, wallet_id, true
FROM cust;

-- 6d. 150,000 customer-to-customer transfers, Aug to mid-Oct 2026
INSERT INTO stage (txn_type, status, amount, channel, initiated_by, device_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'TRANSFER',
       CASE WHEN g.r_fail < 0.03 THEN 'FAILED' ELSE 'SUCCESS' END,
       round(500 + g.r_amt * g.r_amt * 19500),
       CASE WHEN g.r_ch < 0.75 THEN 'APP' WHEN g.r_ch < 0.90 THEN 'USSD' ELSE 'WEB' END,
       s.customer_id, s.device_id,
       (ARRAY['Food stuff','Rent contribution','Transport','School fees','Family support','Ajo contribution','Thank you'])[1 + floor(g.r_nar*7)::int],
       TIMESTAMPTZ '2026-08-01 00:00+01' + g.r_time * INTERVAL '75 days',
       s.wallet_id, r.wallet_id
FROM (SELECT 1 + floor(random()*39997)::int AS s_rk, 1 + floor(random()*39997)::int AS r_rk,
             random() AS r_amt, random() AS r_ch, random() AS r_fail, random() AS r_time, random() AS r_nar
      FROM generate_series(1, 150000)) g
JOIN cust s ON s.rk = g.s_rk
JOIN cust r ON r.rk = CASE WHEN g.r_rk = g.s_rk THEN (g.r_rk % 39997) + 1 ELSE g.r_rk END;

-- 6e. 60,000 merchant payments
INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, merchant_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'MERCHANT_PAYMENT', round(1000 + g.r_amt * g.r_amt * 29000),
       CASE WHEN g.r_ch < 0.5 THEN 'APP' ELSE 'WEB' END,
       s.customer_id, s.device_id, m.merchant_id, 'Payment to merchant',
       TIMESTAMPTZ '2026-08-01 00:00+01' + g.r_time * INTERVAL '75 days',
       s.wallet_id, m.wallet_id
FROM (SELECT 1 + floor(random()*39997)::int AS s_rk, 1 + floor(random()*1200)::int AS m_rk,
             random() AS r_amt, random() AS r_ch, random() AS r_time
      FROM generate_series(1, 60000)) g
JOIN cust s ON s.rk = g.s_rk
JOIN merch m ON m.rk = g.m_rk
WHERE m.merchant_id > 1;          -- the seed merchant is left untouched

-- 6f. 20,000 transfers out to other Nigerian banks (money leaves via the system settlement wallet)
INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, beneficiary_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'EXTERNAL_TRANSFER', round(2000 + g.r_amt * g.r_amt * 48000), 'APP',
       c.customer_id, c.device_id, b.beneficiary_id, 'Transfer to bank account',
       TIMESTAMPTZ '2026-08-01 00:00+01' + g.r_time * INTERVAL '75 days',
       c.wallet_id, 6
FROM (SELECT 1 + floor(random()*15000)::int AS rk, random() AS r_amt, random() AS r_time
      FROM generate_series(1, 20000)) g
JOIN cust c ON c.rk = g.rk
JOIN beneficiaries b ON b.customer_id = c.customer_id;

-- 6g. 15,000 agent cash-ins (customer gives cash, agent float pays the wallet)
--     and 15,000 agent cash-outs (wallet pays agent float, agent gives cash)
INSERT INTO stage (txn_type, amount, channel, initiated_by, agent_id, narration, created_at, dr_wallet, cr_wallet)
SELECT CASE WHEN g.k <= 15000 THEN 'DEPOSIT' ELSE 'WITHDRAWAL' END,
       round((1000 + g.r_amt * 19000) / 100) * 100, 'POS',
       c.customer_id, a.agent_id,
       CASE WHEN g.k <= 15000 THEN 'Cash-in at agent' ELSE 'Cash-out at agent' END,
       TIMESTAMPTZ '2026-08-01 00:00+01' + g.r_time * INTERVAL '75 days',
       CASE WHEN g.k <= 15000 THEN a.wallet_id ELSE c.wallet_id END,
       CASE WHEN g.k <= 15000 THEN c.wallet_id ELSE a.wallet_id END
FROM (SELECT k, 1 + floor(random()*39997)::int AS c_rk, 2 + floor(random()*349)::int AS a_rk,
             random() AS r_amt, random() AS r_time
      FROM generate_series(1, 30000) AS k) g
JOIN cust c ON c.rk = g.c_rk
JOIN agt a ON a.rk = g.a_rk;

-- 6h. planted pattern (Q4): 5 accounts each make 18 transfers just under N10,000 within 50 minutes
INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'TRANSFER', 9500 + floor(random()*400), 'APP', s.customer_id, s.device_id, 'Transfer',
       TIMESTAMPTZ '2026-10-10 01:00+01' + (n * INTERVAL '170 seconds'),
       s.wallet_id, r.wallet_id
FROM cust s
CROSS JOIN generate_series(1, 18) AS n
JOIN cust r ON r.rk = 20000 + n
WHERE s.rk BETWEEN 201 AND 205;

-- 6i. planted pattern (Portfolio 4): 10 victims pay one account, which passes the money
--     down a chain of 4 more accounts within an hour, and the last one sends it to a bank
INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'TRANSFER', 9800, 'APP', v.customer_id, v.device_id, 'Investment deposit',
       TIMESTAMPTZ '2026-10-11 18:00+01' + (v.rk - 501) * INTERVAL '25 minutes', v.wallet_id, m.wallet_id
FROM cust v JOIN cust m ON m.rk = 401 WHERE v.rk BETWEEN 501 AND 510;

INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'TRANSFER', 95000 - (a.rk - 401) * 500, 'APP', a.customer_id, a.device_id, 'Business',
       TIMESTAMPTZ '2026-10-12 02:00+01' + (a.rk - 401) * INTERVAL '12 minutes', a.wallet_id, b.wallet_id
FROM cust a JOIN cust b ON b.rk = a.rk + 1 WHERE a.rk BETWEEN 401 AND 404;

INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name, created_at)
SELECT customer_id, '033', '0987654321', 'Unknown Ventures', TIMESTAMPTZ '2026-10-12 02:30+01'
FROM cust WHERE rk = 405;
INSERT INTO stage (txn_type, amount, channel, initiated_by, device_id, beneficiary_id, narration, created_at, dr_wallet, cr_wallet)
SELECT 'EXTERNAL_TRANSFER', 93000, 'APP', c.customer_id, c.device_id, b.beneficiary_id, 'Withdrawal',
       TIMESTAMPTZ '2026-10-12 02:55+01', c.wallet_id, 6
FROM cust c JOIN beneficiaries b ON b.customer_id = c.customer_id AND b.account_number = '0987654321'
WHERE c.rk = 405;

-- 6j. 300 bank transfers that failed at the other bank are reversed 30 minutes later
INSERT INTO stage (txn_type, amount, channel, initiated_by, reversal_of, narration, created_at, dr_wallet, cr_wallet)
SELECT 'REVERSAL', amount, channel, initiated_by, txn_id, 'Reversal: beneficiary bank timeout',
       created_at + INTERVAL '30 minutes', cr_wallet, dr_wallet
FROM (SELECT * FROM stage WHERE txn_type = 'EXTERNAL_TRANSFER' AND status = 'SUCCESS'
      AND narration = 'Transfer to bank account' ORDER BY txn_id LIMIT 300) x;
UPDATE stage SET status = 'REVERSED' WHERE txn_id IN (SELECT reversal_of FROM stage WHERE reversal_of IS NOT NULL);

-- ---------- 7. make sure no wallet ever goes below zero ----------------
-- If a wallet's running balance would dip below zero at any point, its first
-- funding deposit is raised by that amount (opening deposit is always earliest).
WITH mv AS (
  SELECT wallet, created_at, txn_id, signed FROM (
    SELECT dr_wallet AS wallet, created_at, txn_id, -amount AS signed FROM stage WHERE status <> 'FAILED'
    UNION ALL
    SELECT cr_wallet, created_at, txn_id, amount FROM stage WHERE status <> 'FAILED') u
  WHERE wallet <> 6
), run AS (
  SELECT wallet, SUM(signed) OVER (PARTITION BY wallet ORDER BY created_at, txn_id) AS bal FROM mv
), short AS (
  SELECT wallet, -MIN(bal) AS gap FROM run GROUP BY wallet HAVING MIN(bal) < 0
)
UPDATE stage s SET amount = s.amount + ceil((short.gap + 500) / 100) * 100
FROM short WHERE s.cr_wallet = short.wallet AND s.is_opening;

-- ---------- 8. post everything: transactions, then ledger legs ---------
INSERT INTO transactions (txn_id, reference, txn_type, status, amount, channel, initiated_by, device_id,
                          beneficiary_id, merchant_id, agent_id, reversal_of_txn_id, narration, created_at)
SELECT txn_id, 'TCS-' || to_char(created_at, 'YYYYMMDD') || '-' || lpad(txn_id::text, 7, '0'),
       txn_type, status, amount, channel, initiated_by, device_id, beneficiary_id, merchant_id,
       agent_id, reversal_of, narration, created_at
FROM stage ORDER BY created_at, txn_id;

-- The balanced-ledger trigger checks one row at a time. For a bulk load of
-- ~600,000 rows it is switched off, and the same rule is checked once, in bulk, below.
ALTER TABLE ledger_entries DISABLE TRIGGER trg_ledger_balanced;

INSERT INTO ledger_entries (txn_id, wallet_id, direction, amount, balance_after, created_at)
SELECT txn_id, wallet, dir, amount,
       CASE WHEN wallet = 6 THEN 100000000000 ELSE 0 END
       + SUM(CASE WHEN dir = 'CR' THEN amount ELSE -amount END)
         OVER (PARTITION BY wallet ORDER BY created_at, txn_id),
       created_at
FROM (SELECT txn_id, dr_wallet AS wallet, 'DR' AS dir, amount, created_at FROM stage WHERE status <> 'FAILED'
      UNION ALL
      SELECT txn_id, cr_wallet, 'CR', amount, created_at FROM stage WHERE status <> 'FAILED') legs
ORDER BY created_at, txn_id, dir DESC;

ALTER TABLE ledger_entries ENABLE TRIGGER trg_ledger_balanced;

-- Bulk check of the double-entry rule: this must return 0
SELECT count(*) AS unbalanced_transactions FROM (
  SELECT txn_id FROM ledger_entries GROUP BY txn_id
  HAVING SUM(amount) FILTER (WHERE direction='DR') <> SUM(amount) FILTER (WHERE direction='CR')) x;

-- ---------- 9. wallet balances = sum of their ledger entries ----------
-- The SYSTEM wallet stands for TC.Solutions' settlement account at its partner
-- bank; it starts from an assumed N100bn so card funding never takes it below zero.
UPDATE wallets w
SET balance = CASE WHEN w.wallet_type = 'SYSTEM' THEN 100000000000 ELSE 0 END + l.net
FROM (SELECT wallet_id, SUM(CASE WHEN direction='CR' THEN amount ELSE -amount END) AS net
      FROM ledger_entries GROUP BY wallet_id) l
WHERE w.wallet_id = l.wallet_id;

COMMIT;

ANALYZE;

-- ---------- 10. what was built --------------------------------------
SELECT 'customers' AS table_name, count(*) AS rows FROM customers
UNION ALL SELECT 'wallets', count(*) FROM wallets
UNION ALL SELECT 'merchants', count(*) FROM merchants
UNION ALL SELECT 'agents', count(*) FROM agents
UNION ALL SELECT 'devices', count(*) FROM devices
UNION ALL SELECT 'beneficiaries', count(*) FROM beneficiaries
UNION ALL SELECT 'transactions', count(*) FROM transactions
UNION ALL SELECT 'ledger_entries', count(*) FROM ledger_entries;

SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
