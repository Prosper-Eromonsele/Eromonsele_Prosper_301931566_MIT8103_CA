-- =====================================================================
-- TC.Solutions - three demo customers for Portfolio 3 (re-runnable)
-- Bola N10,000, Kunle N5,000, Ada N0. Run it again to reset their
-- balances before each demo (the wallet numbers stay the same).
-- LAB RESET ONLY: it deletes the demo wallets' history. In production
-- nothing in the ledger is ever deleted; mistakes are fixed by reversals.
-- =====================================================================
SET search_path TO tcs;

DO $$
DECLARE w BIGINT[]; t BIGINT[];
BEGIN
    SELECT array_agg(w2.wallet_id) INTO w
    FROM wallets w2 JOIN customers c ON c.customer_id = w2.customer_id
    WHERE c.phone IN ('+2348099000001','+2348099000002','+2348099000003');
    IF w IS NULL THEN RETURN; END IF;

    SELECT array_agg(DISTINCT txn_id) INTO t FROM ledger_entries WHERE wallet_id = ANY (w);

    -- give the system wallet back what it paid out to fund the demo wallets
    UPDATE wallets s
    SET balance = s.balance + COALESCE((SELECT sum(CASE WHEN direction = 'DR' THEN amount ELSE -amount END)
                                        FROM ledger_entries le
                                        WHERE le.txn_id = ANY (t) AND le.wallet_id = s.wallet_id), 0)
    WHERE s.wallet_type = 'SYSTEM';

    DELETE FROM ledger_entries WHERE txn_id = ANY (t);
    DELETE FROM transactions   WHERE txn_id = ANY (t);
    UPDATE wallets SET balance = 0, status = 'ACTIVE' WHERE wallet_id = ANY (w);
END $$;

INSERT INTO customers (first_name, last_name, phone, date_of_birth, state_of_residence, kyc_tier, bvn_hash) VALUES
 ('Bola',  'Adewale', '+2348099000001', '1994-03-14', 'Lagos', 2, encode(sha256('DEMO-BVN-1'::bytea), 'hex')),
 ('Kunle', 'Ojo',     '+2348099000002', '1989-11-02', 'Oyo',   2, encode(sha256('DEMO-BVN-2'::bytea), 'hex')),
 ('Ada',   'Eze',     '+2348099000003', '1999-07-21', 'Enugu', 2, encode(sha256('DEMO-BVN-3'::bytea), 'hex'))
ON CONFLICT (phone) DO NOTHING;

INSERT INTO wallets (wallet_type, customer_id)
SELECT 'CUSTOMER', c.customer_id FROM customers c
WHERE c.phone LIKE '+234809900000_'
  AND NOT EXISTS (SELECT 1 FROM wallets w WHERE w.customer_id = c.customer_id);

-- fund them properly, through the ledger, from the system settlement wallet
SELECT transfer((SELECT wallet_id FROM wallets WHERE wallet_type = 'SYSTEM'),
                w.wallet_id, x.amt, 'Demo funding', 'WEB', 'DEPOSIT')
FROM (VALUES ('+2348099000001', 10000), ('+2348099000002', 5000)) AS x(phone, amt)
JOIN customers c ON c.phone = x.phone
JOIN wallets w ON w.customer_id = c.customer_id;

-- one view to watch the three wallets: stored balance next to the ledger total
CREATE OR REPLACE VIEW v_demo_wallets AS
SELECT c.first_name AS customer, w.wallet_id, w.balance AS stored_balance,
       COALESCE((SELECT sum(CASE WHEN direction = 'CR' THEN amount ELSE -amount END)
                 FROM ledger_entries le WHERE le.wallet_id = w.wallet_id), 0) AS ledger_balance,
       CASE WHEN w.balance = COALESCE((SELECT sum(CASE WHEN direction = 'CR' THEN amount ELSE -amount END)
                 FROM ledger_entries le WHERE le.wallet_id = w.wallet_id), 0)
            THEN 'OK' ELSE 'MISMATCH' END AS reconciles
FROM wallets w JOIN customers c ON c.customer_id = w.customer_id
WHERE c.phone LIKE '+234809900000_';

SELECT * FROM v_demo_wallets ORDER BY wallet_id;
