-- 078 — connector credentials move to OpenBao KV v2 (SA-TODO-003)
--
-- Connector credentials now live in OpenBao at
-- kv/data/signalloom/tenants/<tenant>/connectors/<connector>
-- (connector_secret_store.py). This table keeps only the reference:
-- credentials_ref is that path, credentials_version the KV v2 version written.
--
-- credentials_ciphertext (070) is no longer written. Existing sealed rows are
-- moved by scripts/migrate-connector-creds-to-openbao.py, which sets the
-- reference and nulls the ciphertext; until then such a row answers 503 and is
-- never decrypted by the portal. The CHECK makes "both" impossible, so a code
-- path that wrote a ciphertext next to a reference would fail here.
BEGIN;

ALTER TABLE public.tenant_connectors
    ADD COLUMN IF NOT EXISTS credentials_ref TEXT
        CHECK (credentials_ref LIKE 'signalloom/tenants/%/connectors/%'),
    ADD COLUMN IF NOT EXISTS credentials_version INTEGER
        CHECK (credentials_version > 0);

ALTER TABLE public.tenant_connectors
    DROP CONSTRAINT IF EXISTS tenant_connectors_credentials_one_store;

ALTER TABLE public.tenant_connectors
    ADD CONSTRAINT tenant_connectors_credentials_one_store
    CHECK (credentials_ref IS NULL OR credentials_ciphertext IS NULL);

COMMIT;
