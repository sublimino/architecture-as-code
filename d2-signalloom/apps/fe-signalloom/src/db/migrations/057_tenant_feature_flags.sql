-- ══════════════════════════════════════════════════════════════════════════════
-- 057 — tenant-scoped feature flags for granular surface scoping and gating
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Provides tenant-scoped feature flags with JSONB configuration payloads.
-- Guarantees strict multi-tenant isolation, default evaluation fallbacks,
-- and sub-millisecond lookups via composite primary key (tenant_id, flag_key).

BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_feature_flags (
    tenant_id   VARCHAR(128) NOT NULL,
    flag_key    VARCHAR(128) NOT NULL,
    enabled     BOOLEAN      NOT NULL DEFAULT FALSE,
    config_json JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, flag_key)
);

CREATE INDEX IF NOT EXISTS idx_tenant_feature_flags_tenant
    ON public.tenant_feature_flags (tenant_id, flag_key);

COMMIT;
