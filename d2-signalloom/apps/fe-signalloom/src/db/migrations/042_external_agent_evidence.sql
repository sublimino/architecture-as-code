-- Migration: 042_external_agent_evidence.sql
-- Storage and tenant-scoped projections for external agent evidence (AMXO-P5-3).
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.external_agent_evidence (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           TEXT        NOT NULL,
    agent_id            TEXT        NOT NULL,
    session_id          TEXT        NOT NULL,
    evidence_type       TEXT        NOT NULL,
    source              TEXT        NOT NULL DEFAULT 'agentmaxxing-host-sensor',
    observed_at         TIMESTAMPTZ NOT NULL,
    attributable_actor  TEXT        NOT NULL,
    spiffe_id           TEXT        NOT NULL,
    landlock_abi        INTEGER     NOT NULL DEFAULT 0,
    git_oid             TEXT,
    attributes          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    hash_chain_digest   TEXT        NOT NULL,
    verified            BOOLEAN     NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_external_agent_evidence_tenant_agent
    ON public.external_agent_evidence (tenant_id, agent_id, observed_at DESC);

CREATE INDEX IF NOT EXISTS idx_external_agent_evidence_session
    ON public.external_agent_evidence (tenant_id, session_id);

CREATE INDEX IF NOT EXISTS idx_external_agent_evidence_type
    ON public.external_agent_evidence (tenant_id, evidence_type);

COMMIT;
