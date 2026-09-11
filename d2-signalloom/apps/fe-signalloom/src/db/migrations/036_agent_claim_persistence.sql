-- Durable, tenant-scoped agent claim lifecycle and concurrency constraints.
BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_claims (
    claim_id                   TEXT        PRIMARY KEY,
    tenant_id                  TEXT        NOT NULL,
    agent_id                   UUID        NOT NULL REFERENCES public.agent_registry(id) ON DELETE CASCADE,
    pod_name                   TEXT        NOT NULL,
    namespace                  TEXT        NOT NULL,
    spiffe_id                  TEXT        NOT NULL,
    harness                    TEXT        NOT NULL,
    model                      TEXT        NOT NULL,
    status                     TEXT        NOT NULL CHECK (status IN ('granted', 'denied', 'pending-review')),
    allocated_token_budget     INTEGER     NOT NULL CHECK (allocated_token_budget > 0),
    authoritative_pod_uid      TEXT,
    claimed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at                TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_agent_claims_tenant
    ON public.agent_claims (tenant_id, claimed_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_claims_active_tenant_agent
    ON public.agent_claims (tenant_id, agent_id)
    WHERE status = 'granted' AND released_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_claims_active_authoritative_pod_uid
    ON public.agent_claims (authoritative_pod_uid)
    WHERE authoritative_pod_uid IS NOT NULL
      AND status = 'granted'
      AND released_at IS NULL;

COMMIT;
