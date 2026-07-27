-- Migration: 003_platform_backends
-- Local-only platform connector records used by the deterministic demo adapters.

BEGIN;

CREATE TABLE IF NOT EXISTS public.platform_backends (
    identifier VARCHAR NOT NULL,
    tenant_id VARCHAR NOT NULL,
    display_name VARCHAR NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, identifier)
);

INSERT INTO public.platform_backends (identifier, tenant_id, display_name)
VALUES ('platform-demo', 'tenant-demo', 'Demo Platform')
ON CONFLICT (tenant_id, identifier) DO UPDATE
SET display_name = EXCLUDED.display_name;

COMMIT;
