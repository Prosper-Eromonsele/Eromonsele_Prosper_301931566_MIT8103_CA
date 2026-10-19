-- =====================================================================
-- TC.Solutions Fintech - core relational schema (PostgreSQL 16)
-- MIT 8103 CA, Portfolio 1 - Prosper Eromonsele (301931566)
-- =====================================================================
DROP SCHEMA IF EXISTS tcs CASCADE;
CREATE SCHEMA tcs;
SET search_path TO tcs;

-- ---------- reference tables ----------------------------------------
CREATE TABLE kyc_tiers (
    tier              SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 3),
    description       VARCHAR(60)    NOT NULL,
    single_txn_limit  NUMERIC(18,2)  NOT NULL CHECK (single_txn_limit > 0),
    daily_limit       NUMERIC(18,2)  NOT NULL CHECK (daily_limit >= single_txn_limit),
    max_balance       NUMERIC(18,2)           -- NULL = no cap
);

CREATE TABLE banks (
    bank_code   VARCHAR(6)   PRIMARY KEY,
    bank_name   VARCHAR(80)  NOT NULL UNIQUE
);

CREATE TABLE staff (
    staff_id    SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(120) NOT NULL UNIQUE,
    role        VARCHAR(20)  NOT NULL
                CHECK (role IN ('SUPPORT','COMPLIANCE','FINANCE','ADMIN'))
);

-- ---------- customers and identity ----------------------------------
CREATE TABLE customers (
    customer_id    BIGSERIAL    PRIMARY KEY,
    first_name     VARCHAR(50)  NOT NULL,
    last_name      VARCHAR(50)  NOT NULL,
    phone          VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    email          VARCHAR(120) UNIQUE,
    date_of_birth  DATE         NOT NULL CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years'),
    state_of_residence VARCHAR(30) NOT NULL,
    kyc_tier       SMALLINT     NOT NULL DEFAULT 1 REFERENCES kyc_tiers(tier),
    bvn_hash       CHAR(64)     UNIQUE,   -- SHA-256 of BVN, never the raw number
    nin_hash       CHAR(64)     UNIQUE,   -- SHA-256 of NIN
    status         VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- Tier 2 and above require a verified BVN
    CONSTRAINT chk_bvn_for_tier CHECK (kyc_tier = 1 OR bvn_hash IS NOT NULL)
);

CREATE TABLE devices (
    device_id          BIGSERIAL   PRIMARY KEY,
    device_fingerprint VARCHAR(64) NOT NULL UNIQUE,
    os                 VARCHAR(20) NOT NULL CHECK (os IN ('ANDROID','IOS','WEB','USSD')),
    first_seen         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- many-to-many: a customer can use many devices, a device can be shared
CREATE TABLE customer_devices (
    customer_id  BIGINT      NOT NULL REFERENCES customers(customer_id),
    device_id    BIGINT      NOT NULL REFERENCES devices(device_id),
    first_used   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, device_id),
    CHECK (last_used >= first_used)
);

-- ---------- wallets (customer, merchant, agent and system) ----------
CREATE TABLE wallets (
    wallet_id    BIGSERIAL     PRIMARY KEY,
    wallet_type  VARCHAR(20)   NOT NULL
                 CHECK (wallet_type IN ('CUSTOMER','MERCHANT','AGENT_FLOAT','SYSTEM')),
    customer_id  BIGINT        REFERENCES customers(customer_id),
    currency     CHAR(3)       NOT NULL DEFAULT 'NGN' CHECK (currency IN ('NGN','GHS')),
    balance      NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    status       VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE'
                 CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    opened_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- only customer wallets point at a customer
    CONSTRAINT chk_wallet_owner CHECK ((wallet_type = 'CUSTOMER') = (customer_id IS NOT NULL)),
    CONSTRAINT uq_customer_currency UNIQUE (customer_id, currency)
);

CREATE TABLE merchants (
    merchant_id          BIGSERIAL    PRIMARY KEY,
    business_name        VARCHAR(120) NOT NULL,
    cac_rc_number        VARCHAR(12)  NOT NULL UNIQUE,
    category             VARCHAR(40)  NOT NULL,
    settlement_wallet_id BIGINT       NOT NULL UNIQUE REFERENCES wallets(wallet_id),
    api_key_hash         CHAR(64)     NOT NULL,
    status               VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                         CHECK (status IN ('ACTIVE','SUSPENDED')),
    onboarded_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE agents (
    agent_id         BIGSERIAL    PRIMARY KEY,
    agent_code       VARCHAR(10)  NOT NULL UNIQUE,
    full_name        VARCHAR(100) NOT NULL,
    phone            VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    lga              VARCHAR(40)  NOT NULL,
    state            VARCHAR(30)  NOT NULL,
    float_wallet_id  BIGINT       NOT NULL UNIQUE REFERENCES wallets(wallet_id),
    status           VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE','SUSPENDED'))
);

CREATE TABLE beneficiaries (
    beneficiary_id  BIGSERIAL   PRIMARY KEY,
    customer_id     BIGINT      NOT NULL REFERENCES customers(customer_id),
    bank_code       VARCHAR(6)  NOT NULL REFERENCES banks(bank_code),
    account_number  CHAR(10)    NOT NULL CHECK (account_number ~ '^[0-9]{10}$'),  -- NUBAN
    account_name    VARCHAR(100) NOT NULL,
    nickname        VARCHAR(40),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (customer_id, bank_code, account_number)
);

-- ---------- money movement: transaction header + double-entry ledger --
CREATE TABLE transactions (
    txn_id              BIGSERIAL     PRIMARY KEY,
    reference           VARCHAR(30)   NOT NULL UNIQUE,   -- idempotency / NIP session reference
    txn_type            VARCHAR(20)   NOT NULL
                        CHECK (txn_type IN ('TRANSFER','EXTERNAL_TRANSFER','DEPOSIT',
                                            'WITHDRAWAL','MERCHANT_PAYMENT','REVERSAL','FEE')),
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED')),
    amount              NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    currency            CHAR(3)       NOT NULL DEFAULT 'NGN' CHECK (currency IN ('NGN','GHS')),
    channel             VARCHAR(6)    NOT NULL CHECK (channel IN ('APP','USSD','POS','API','WEB')),
    initiated_by        BIGINT        REFERENCES customers(customer_id),
    device_id           BIGINT        REFERENCES devices(device_id),
    beneficiary_id      BIGINT        REFERENCES beneficiaries(beneficiary_id),
    merchant_id         BIGINT        REFERENCES merchants(merchant_id),
    agent_id            BIGINT        REFERENCES agents(agent_id),
    reversal_of_txn_id  BIGINT        UNIQUE REFERENCES transactions(txn_id),
    narration           VARCHAR(140),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT chk_reversal_link CHECK ((txn_type = 'REVERSAL') = (reversal_of_txn_id IS NOT NULL)),
    CONSTRAINT chk_external_has_beneficiary
        CHECK (txn_type <> 'EXTERNAL_TRANSFER' OR beneficiary_id IS NOT NULL)
);

CREATE TABLE ledger_entries (
    entry_id       BIGSERIAL     PRIMARY KEY,
    txn_id         BIGINT        NOT NULL REFERENCES transactions(txn_id),
    wallet_id      BIGINT        NOT NULL REFERENCES wallets(wallet_id),
    direction      CHAR(2)       NOT NULL CHECK (direction IN ('DR','CR')),
    amount         NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    balance_after  NUMERIC(18,2) NOT NULL CHECK (balance_after >= 0),
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Business rule: in every transaction, total debits = total credits.
-- Checked at COMMIT (deferred), because the two legs are inserted one after another.
CREATE FUNCTION check_ledger_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE dr NUMERIC; cr NUMERIC;
BEGIN
    SELECT COALESCE(SUM(amount) FILTER (WHERE direction='DR'),0),
           COALESCE(SUM(amount) FILTER (WHERE direction='CR'),0)
      INTO dr, cr
      FROM ledger_entries WHERE txn_id = NEW.txn_id;
    IF dr <> cr THEN
        RAISE EXCEPTION 'Ledger for txn % is unbalanced (DR % / CR %)', NEW.txn_id, dr, cr;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_ledger_balanced
    AFTER INSERT OR UPDATE ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_ledger_balanced();

-- ---------- security operations -------------------------------------
CREATE TABLE fraud_alerts (
    alert_id     BIGSERIAL   PRIMARY KEY,
    customer_id  BIGINT      NOT NULL REFERENCES customers(customer_id),
    txn_id       BIGINT      REFERENCES transactions(txn_id),
    rule_code    VARCHAR(30) NOT NULL
                 CHECK (rule_code IN ('VELOCITY','SHARED_DEVICE','NEW_DEVICE_HIGH_VALUE',
                                      'TIER_LIMIT_BREACH','MULE_PATTERN')),
    risk_score   SMALLINT    NOT NULL CHECK (risk_score BETWEEN 0 AND 100),
    status       VARCHAR(25) NOT NULL DEFAULT 'OPEN'
                 CHECK (status IN ('OPEN','INVESTIGATING','CLOSED_FALSE_POSITIVE','CLOSED_CONFIRMED')),
    assigned_to  INT         REFERENCES staff(staff_id),
    raised_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    audit_id    BIGSERIAL   PRIMARY KEY,
    staff_id    INT         NOT NULL REFERENCES staff(staff_id),
    action      VARCHAR(30) NOT NULL,
    table_name  VARCHAR(40) NOT NULL,
    record_id   BIGINT      NOT NULL,
    old_value   JSONB,
    new_value   JSONB,
    logged_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
