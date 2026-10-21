-- =====================================================================
-- TC.Solutions - the transfer as one safe database transaction (Portfolio 3)
-- MIT 8103 CA - Prosper Eromonsele (301931566)
--
-- transfer() does every step of a wallet transfer inside the caller's
-- transaction. If any step fails it raises an error, and the whole
-- transaction is rolled back: no half transfers.
-- =====================================================================
SET search_path TO tcs;

CREATE OR REPLACE FUNCTION transfer(
    p_from       BIGINT,
    p_to         BIGINT,
    p_amount     NUMERIC,
    p_narration  VARCHAR DEFAULT NULL,
    p_channel    VARCHAR DEFAULT 'APP',
    p_txn_type   VARCHAR DEFAULT 'TRANSFER'
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_from   wallets%ROWTYPE;
    v_to     wallets%ROWTYPE;
    v_tier   kyc_tiers%ROWTYPE;
    v_today  NUMERIC;
    v_txn    BIGINT;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than zero';
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'Sender and receiver wallet are the same';
    END IF;

    -- 1. Lock BOTH wallet rows, always in wallet_id order.
    --    FOR UPDATE makes any other transfer touching these wallets wait.
    --    Locking in a fixed order means two opposite transfers (A->B and
    --    B->A) can never hold one lock each and wait for each other (deadlock).
    PERFORM 1 FROM wallets WHERE wallet_id IN (p_from, p_to)
            ORDER BY wallet_id FOR UPDATE;

    SELECT * INTO v_from FROM wallets WHERE wallet_id = p_from;
    SELECT * INTO v_to   FROM wallets WHERE wallet_id = p_to;

    IF v_from.wallet_id IS NULL OR v_to.wallet_id IS NULL THEN
        RAISE EXCEPTION 'Wallet not found';
    END IF;
    IF v_from.status <> 'ACTIVE' OR v_to.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Wallet is frozen or closed';
    END IF;
    IF v_from.currency <> v_to.currency THEN
        RAISE EXCEPTION 'Currency mismatch (% to %)', v_from.currency, v_to.currency;
    END IF;

    -- 2. KYC tier limits for customer wallets. Portfolio 2 (Q6) showed
    --    these limits were not being enforced; here they are.
    IF v_from.customer_id IS NOT NULL THEN
        SELECT k.* INTO v_tier
        FROM customers c JOIN kyc_tiers k ON k.tier = c.kyc_tier
        WHERE c.customer_id = v_from.customer_id;

        IF p_amount > v_tier.single_txn_limit THEN
            RAISE EXCEPTION 'Amount % is above the Tier % single transaction limit of %',
                p_amount, v_tier.tier, v_tier.single_txn_limit;
        END IF;

        SELECT COALESCE(sum(amount), 0) INTO v_today
        FROM transactions
        WHERE initiated_by = v_from.customer_id AND status = 'SUCCESS'
          AND txn_type IN ('TRANSFER','EXTERNAL_TRANSFER','MERCHANT_PAYMENT','WITHDRAWAL')
          AND created_at >= date_trunc('day', now());

        IF v_today + p_amount > v_tier.daily_limit THEN
            RAISE EXCEPTION 'Daily limit reached: % already sent today, Tier % limit is %',
                v_today, v_tier.tier, v_tier.daily_limit;
        END IF;
    END IF;

    -- 3. Enough money? Checked AFTER the lock, so nobody can spend it in between.
    IF v_from.balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, amount %', v_from.balance, p_amount;
    END IF;

    -- 4. Post it: header, two ledger legs, two balance updates.
    INSERT INTO transactions (reference, txn_type, status, amount, channel, initiated_by, narration)
    VALUES ('TCS-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'),
            p_txn_type, 'SUCCESS', p_amount, p_channel, v_from.customer_id, p_narration)
    RETURNING txn_id INTO v_txn;

    INSERT INTO ledger_entries (txn_id, wallet_id, direction, amount, balance_after) VALUES
        (v_txn, p_from, 'DR', p_amount, v_from.balance - p_amount),
        (v_txn, p_to,   'CR', p_amount, v_to.balance   + p_amount);

    UPDATE wallets SET balance = balance - p_amount WHERE wallet_id = p_from;
    UPDATE wallets SET balance = balance + p_amount WHERE wallet_id = p_to;

    RETURN v_txn;
END $$;

\echo 'transfer() created'
