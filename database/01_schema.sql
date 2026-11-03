CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;

-- BRONZE
CREATE TABLE IF NOT EXISTS raw_tenders (
    raw_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_run_id BIGINT,
    payload JSONB NOT NULL,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    external_id TEXT GENERATED ALWAYS AS (payload->>'tender_id') STORED,
    CONSTRAINT uq_raw_external UNIQUE (source_run_id, external_id)
);
CREATE INDEX IF NOT EXISTS idx_raw_payload_gin ON raw_tenders USING gin (payload jsonb_path_ops);

-- ETL LOGGING
CREATE TABLE IF NOT EXISTS etl_runs (
    run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pipeline_name TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ,
    status VARCHAR(10) NOT NULL DEFAULT 'running' CHECK (status IN ('running','success','failed','partial')),
    rows_extracted INTEGER NOT NULL DEFAULT 0,
    rows_rejected INTEGER NOT NULL DEFAULT 0,
    rows_loaded INTEGER NOT NULL DEFAULT 0,
    error_message TEXT,
    duration_sec INTEGER GENERATED ALWAYS AS (EXTRACT(EPOCH FROM (finished_at - started_at))::int) STORED
);

-- SILVER
CREATE TABLE IF NOT EXISTS stg_tenders (
    stg_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_run_id BIGINT REFERENCES etl_runs(run_id),
    tender_ext_id TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    customer_inn VARCHAR(12) NOT NULL CHECK (customer_inn ~ '^[0-9]{10}$|^[0-9]{12}$'),
    customer_name TEXT NOT NULL,
    amount NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
    currency CHAR(3) NOT NULL DEFAULT 'RUB',
    okpd2_code VARCHAR(20),
    region TEXT,
    published_at TIMESTAMPTZ,
    deadline_at TIMESTAMPTZ,
    status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','cancelled','archived')),
    dedup_hash BYTEA GENERATED ALWAYS AS (md5(tender_ext_id || '|' || title)) STORED,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_stg_dedup ON stg_tenders (dedup_hash);

-- GOLD
CREATE TABLE IF NOT EXISTS mart_tenders (
    tender_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tender_ext_id TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    description TEXT,
    summary_ai TEXT,
    complexity_ai SMALLINT CHECK (complexity_ai BETWEEN 1 AND 5),
    customer_inn VARCHAR(12) NOT NULL,
    customer_name TEXT NOT NULL,
    amount NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
    okpd2_code VARCHAR(20),
    industry VARCHAR(60),
    region TEXT,
    published_at TIMESTAMPTZ NOT NULL,
    deadline_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by_run BIGINT REFERENCES etl_runs(run_id)
);
CREATE INDEX IF NOT EXISTS idx_mart_title_trgm ON mart_tenders USING gin (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_mart_status_deadline ON mart_tenders (status, deadline_at DESC);
CREATE INDEX IF NOT EXISTS idx_mart_amount ON mart_tenders (amount);
CREATE INDEX IF NOT EXISTS idx_mart_region ON mart_tenders (region);

-- USERS & FAVORITES
CREATE TABLE IF NOT EXISTS users (
    user_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name TEXT NOT NULL CHECK (full_name ~ '^\S+(\s\S+){1,2}$'),
    email CITEXT NOT NULL UNIQUE,
    organization TEXT,
    field_of_interest VARCHAR(60),
    password_hash TEXT NOT NULL,
    fcm_token TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS favorites (
    user_id BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    tender_id BIGINT NOT NULL REFERENCES mart_tenders(tender_id) ON DELETE CASCADE,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, tender_id)
);

CREATE TABLE IF NOT EXISTS user_tenders (
    user_id BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    tender_id BIGINT NOT NULL REFERENCES mart_tenders(tender_id) ON DELETE CASCADE,
    matched_by VARCHAR(20) NOT NULL DEFAULT 'industry',
    linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, tender_id)
);