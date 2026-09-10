-- Migration: 036_agent_claims.sql
-- Table public.agent_claims for persisting operator agent claims and tenant ownership associations.
-- Supports SLON-P2-3 dual-agent claim workflow.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_claims (
    claim_id               TEXT        PRIMARY KEY,
    tenant_id              TEXT        NOT NULL,
    agent_id               UUID        NOT NULL REFERENCES public.agent_registry(id) ON DELETE CASCADE,
    pod_name               TEXT        NOT NULL,
    namespace              TEXT        NOT NULL,
    spiffe_id              TEXT        NOT NULL,
    harness                TEXT        NOT NULL DEFAULT 'claude-code',
    model                  TEXT        NOT NULL DEFAULT 'claude-3-5-sonnet',
    status                 TEXT        NOT NULL DEFAULT 'granted'
                                       CHECK (status IN ('granted', 'denied', 'pending-review')),
    allocated_token_budget INTEGER     NOT NULL DEFAULT 100000 CHECK (allocated_token_budget > 0),
    authoritative_pod_uid  TEXT,
    claimed_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at            TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_agent_claims_tenant
    ON public.agent_claims (tenant_id, claimed_at DESC);

CREATE INDEX IF NOT EXISTS idx_agent_claims_agent_id
    ON public.agent_claims (agent_id);

CREATE INDEX IF NOT EXISTS idx_agent_claims_pod_name
    ON public.agent_claims (pod_name);

CREATE INDEX IF NOT EXISTS idx_agent_claims_status
    ON public.agent_claims (status);

COMMIT;
