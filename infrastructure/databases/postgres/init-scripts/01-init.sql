-- PostgreSQL init: bankobs_identity DB + identity_vault schema + seed.
-- Runs once via /docker-entrypoint-initdb.d (postgres image).

\set ON_ERROR_STOP on

-- ── DB and roles ────────────────────────────────────────────────────────────
CREATE DATABASE bankobs_retail   OWNER bankobs;
CREATE DATABASE bankobs_loan     OWNER bankobs;
CREATE DATABASE bankobs_license  OWNER bankobs;

\connect bankobs_identity bankobs

-- ── Schemas ─────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS bankobs_identity AUTHORIZATION bankobs;
CREATE SCHEMA IF NOT EXISTS identity_vault   AUTHORIZATION bankobs;

SET search_path TO bankobs_identity;

-- ── Identity tables ─────────────────────────────────────────────────────────
CREATE TABLE customer_profiles (
  profile_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   VARCHAR(20) NOT NULL UNIQUE,
  kyc_status    VARCHAR(20) DEFAULT 'PENDING',
  kyc_level     INT DEFAULT 0,
  verified_at   TIMESTAMP,
  documents     JSONB DEFAULT '{}',
  created_at    TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_profiles_status ON customer_profiles(kyc_status);
CREATE INDEX idx_profiles_level  ON customer_profiles(kyc_level);

CREATE TABLE kyc_documents (
  doc_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id         VARCHAR(20) NOT NULL,
  doc_type            VARCHAR(20) NOT NULL,
  doc_number_masked   VARCHAR(20),
  verification_status VARCHAR(20) DEFAULT 'PENDING',
  verified_at         TIMESTAMP,
  uploaded_at         TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_docs_customer ON kyc_documents(customer_id);
CREATE INDEX idx_docs_type     ON kyc_documents(doc_type, verification_status);

CREATE TABLE onboarding_sessions (
  session_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   VARCHAR(20),
  step          VARCHAR(50),
  status        VARCHAR(20) DEFAULT 'IN_PROGRESS',
  started_at    TIMESTAMP DEFAULT NOW(),
  completed_at  TIMESTAMP
);
CREATE INDEX idx_sessions_customer ON onboarding_sessions(customer_id);

CREATE TABLE consent_records (
  consent_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   VARCHAR(20) NOT NULL,
  consent_type  VARCHAR(50) NOT NULL,
  granted_at    TIMESTAMP DEFAULT NOW(),
  expires_at    TIMESTAMP,
  revoked_at    TIMESTAMP
);
CREATE INDEX idx_consents_customer ON consent_records(customer_id);

-- ── identity_vault.pii_records ──────────────────────────────────────────────
SET search_path TO identity_vault;

CREATE TABLE pii_records (
  token          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  encrypted_data BYTEA NOT NULL,
  pii_type       VARCHAR(20) NOT NULL,    -- AADHAAR, PAN, MOBILE, EMAIL, NAME, ADDRESS
  created_at     TIMESTAMP DEFAULT NOW(),
  accessed_at    TIMESTAMP,
  access_count   INT DEFAULT 0
);
CREATE INDEX idx_vault_type ON pii_records(pii_type);
CREATE INDEX idx_vault_accessed ON pii_records(accessed_at);

-- ── Seed customer profiles (matches Oracle CUSTOMERS) ──────────────────────
SET search_path TO bankobs_identity;

INSERT INTO customer_profiles (customer_id, kyc_status, kyc_level, verified_at)
SELECT
  'CUST-' || LPAD(g::TEXT, 8, '0'),
  CASE WHEN g % 100 = 0 THEN 'REJECTED'
       WHEN g % 50  = 0 THEN 'PENDING'
       ELSE 'VERIFIED' END,
  CASE WHEN g % 50  = 0 THEN 1
       WHEN g % 10  = 0 THEN 2
       ELSE 3 END,
  CASE WHEN g % 50 = 0 THEN NULL ELSE NOW() - (g * INTERVAL '1 hour') END
FROM generate_series(1, 5000) AS g;

-- ── Seed kyc_documents (mix of PAN + AADHAAR) ──────────────────────────────
INSERT INTO kyc_documents (customer_id, doc_type, doc_number_masked, verification_status, verified_at)
SELECT
  'CUST-' || LPAD(g::TEXT, 8, '0'),
  CASE WHEN g % 2 = 0 THEN 'PAN' ELSE 'AADHAAR' END,
  CASE WHEN g % 2 = 0 THEN 'XXXXX' || LPAD((g % 9999)::TEXT, 4, '0') || 'K'
                     ELSE 'XXXX-XXXX-' || LPAD((g % 9999)::TEXT, 4, '0') END,
  CASE WHEN g % 50 = 0 THEN 'PENDING' ELSE 'VERIFIED' END,
  CASE WHEN g % 50 = 0 THEN NULL ELSE NOW() - (g * INTERVAL '2 hour') END
FROM generate_series(1, 8000) AS g;

GRANT ALL ON ALL TABLES IN SCHEMA bankobs_identity TO bankobs;
GRANT ALL ON ALL TABLES IN SCHEMA identity_vault   TO bankobs;

-- ── Retail DB ───────────────────────────────────────────────────────────────
\connect bankobs_retail bankobs

CREATE TABLE credit_cards (
  card_id       VARCHAR(20) PRIMARY KEY,
  customer_id   VARCHAR(20) NOT NULL,
  card_number_masked VARCHAR(20),
  credit_limit  NUMERIC(12,2),
  current_balance NUMERIC(12,2) DEFAULT 0,
  status        VARCHAR(20) DEFAULT 'ACTIVE',
  issued_at     TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_cards_customer ON credit_cards(customer_id);

CREATE TABLE fixed_deposits (
  fd_id         VARCHAR(20) PRIMARY KEY,
  customer_id   VARCHAR(20) NOT NULL,
  principal     NUMERIC(12,2) NOT NULL,
  interest_rate NUMERIC(5,2) NOT NULL,
  tenure_months INT NOT NULL,
  status        VARCHAR(20) DEFAULT 'ACTIVE',
  opened_at     TIMESTAMP DEFAULT NOW(),
  matures_at    TIMESTAMP
);
CREATE INDEX idx_fd_customer ON fixed_deposits(customer_id);

CREATE TABLE recurring_deposits (
  rd_id         VARCHAR(20) PRIMARY KEY,
  customer_id   VARCHAR(20) NOT NULL,
  monthly_amount NUMERIC(12,2) NOT NULL,
  interest_rate NUMERIC(5,2) NOT NULL,
  tenure_months INT NOT NULL,
  status        VARCHAR(20) DEFAULT 'ACTIVE',
  opened_at     TIMESTAMP DEFAULT NOW()
);

-- ── Loan DB ─────────────────────────────────────────────────────────────────
\connect bankobs_loan bankobs

CREATE TABLE loans (
  loan_id        VARCHAR(20) PRIMARY KEY,
  customer_id    VARCHAR(20) NOT NULL,
  principal      NUMERIC(14,2) NOT NULL,
  outstanding    NUMERIC(14,2) NOT NULL,
  interest_rate  NUMERIC(5,2)  NOT NULL,
  tenure_months  INT NOT NULL,
  emi_amount     NUMERIC(12,2),
  status         VARCHAR(20) DEFAULT 'ACTIVE',
  disbursed_at   TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_loans_customer ON loans(customer_id);
CREATE INDEX idx_loans_status   ON loans(status);

-- ── License portal DB ──────────────────────────────────────────────────────
\connect bankobs_license bankobs

CREATE TABLE licenses (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email          VARCHAR(255) NOT NULL,
  tier           VARCHAR(20)  NOT NULL,
  created_at     TIMESTAMP DEFAULT NOW(),
  expires_at     TIMESTAMP NOT NULL,
  revoked_at     TIMESTAMP,
  hw_fingerprint VARCHAR(128),
  watermark_id   VARCHAR(64),
  jwt_jti        VARCHAR(64) UNIQUE
);
CREATE INDEX idx_licenses_email ON licenses(email);
CREATE INDEX idx_licenses_hw    ON licenses(hw_fingerprint);

CREATE TABLE activations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  license_id    UUID REFERENCES licenses(id),
  activated_at  TIMESTAMP DEFAULT NOW(),
  hw_fingerprint VARCHAR(128) NOT NULL,
  ip_address    INET
);

CREATE TABLE heartbeats (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  license_id   UUID REFERENCES licenses(id),
  last_seen    TIMESTAMP DEFAULT NOW(),
  ip_address   INET
);
CREATE INDEX idx_hb_license ON heartbeats(license_id, last_seen DESC);
