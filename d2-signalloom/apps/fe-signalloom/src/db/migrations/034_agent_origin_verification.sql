-- Migration: 034_agent_origin_verification.sql
-- Establishes authenticated origin verification tracking for agent workloads.
-- Supports Live Authenticated Origin Verification (SFAGENTS-P3-4) under RFC 9110.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_origin_verifications (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL,
    agent_id            UUID        REFERENCES public.agent_registry(id) ON DELETE CASCADE,
    origin_type         TEXT        NOT NULL DEFAULT 'unknown',
    auth_method         TEXT        NOT NULL DEFAULT 'none',
    issuer              TEXT,
    subject             TEXT,
    status              TEXT        NOT NULL DEFAULT 'unverified'
                                    CHECK (status IN ('verified', 'unverified', 'failed', 'unsupported')),
    verified            BOOLEAN     NOT NULL DEFAULT false,
    proxy_path          TEXT,
    metadata            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    verified_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_origin_verifications_tenant
    ON public.agent_origin_verifications (tenant_id);
CREATE INDEX IF NOT EXISTS idx_agent_origin_verifications_agent_id
    ON public.agent_origin_verifications (agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_origin_verifications_status
    ON public.agent_origin_verifications (status);

COMMIT;
