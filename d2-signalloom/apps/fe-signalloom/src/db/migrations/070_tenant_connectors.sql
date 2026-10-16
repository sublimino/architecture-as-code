-- 070 — tenant_connectors: connectors, sealed credentials and last scan, per tenant
--
-- Before this, a live deployment kept every tenant's connectors, their
-- credentials and their scan results in fe-signalloom process memory
-- (routers/connectors.py). A pod restart forgot all of it: a tenant that had
-- configured and tested Anthropic Claude saw "Not configured" after the next
-- deploy. It also handed every live tenant five demo connectors marked
-- "connected" with invented timestamps.
--
-- One row per (tenant, provider); connector_id is unique within the tenant.
-- Every query filters on tenant_id.
--
-- credentials_ciphertext is never plaintext: it is
-- connector_credentials.seal_credentials output, AES-256-GCM in the
-- `vault:v1:` wire format, with the tenant and connector as associated data so
-- a ciphertext moved to another row does not decrypt. The key is mounted from
-- Secret fe-signalloom-connector-credential-key, never stored here.
--
-- Timestamps are observations: last_tested_at and last_scan_at are written only
-- when a test or a fully successful scan happened; NULL means it has not.
BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_connectors (
    tenant_id              TEXT         NOT NULL,
    connector_id           TEXT         NOT NULL,
    provider_id            TEXT         NOT NULL,
    display_name           TEXT,
    status                 TEXT         NOT NULL
                                        CHECK (status IN ('connected', 'disconnected', 'error')),
    credential_expires_at  TIMESTAMPTZ,
    last_tested_at         TIMESTAMPTZ,
    last_scan_at           TIMESTAMPTZ,
    last_scan_status       TEXT         CHECK (last_scan_status IN ('success', 'warning', 'error')),
    last_scan_error        TEXT,
    last_scan_result       JSONB,
    metadata               JSONB        NOT NULL DEFAULT '{}'::jsonb,
    credentials_ciphertext TEXT         CHECK (credentials_ciphertext LIKE 'vault:v1:%'),
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, connector_id),
    UNIQUE (tenant_id, provider_id)
);

COMMIT;
