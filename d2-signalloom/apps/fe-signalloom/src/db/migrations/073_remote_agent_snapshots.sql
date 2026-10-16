-- 073 — remote_agent_snapshots: content-addressed versioned snapshots for remote agents
--
-- Stores versioned immutable snapshots of remote agents, sessions, and environments.
-- Deduplication is enforced by PRIMARY KEY (tenant_id, connector_id, external_id, raw_hash).
BEGIN;

ALTER TABLE public.remote_agents
    DROP CONSTRAINT IF EXISTS remote_agents_kind_check;

ALTER TABLE public.remote_agents
    ADD CONSTRAINT remote_agents_kind_check
    CHECK (kind IN ('agent', 'session', 'assistant', 'workflow', 'environment'));

ALTER TABLE public.remote_agents
    ADD COLUMN IF NOT EXISTS raw_hash TEXT,
    ADD COLUMN IF NOT EXISTS system_prompt TEXT,
    ADD COLUMN IF NOT EXISTS environment_config JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS user_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS metrics JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.remote_agent_snapshots (
    tenant_id            TEXT         NOT NULL,
    connector_id         TEXT         NOT NULL,
    external_id          TEXT         NOT NULL,
    raw_hash             TEXT         NOT NULL,
    kind                 TEXT         NOT NULL
                                      CHECK (kind IN ('agent', 'session', 'assistant', 'workflow', 'environment')),
    name                 TEXT,
    model                TEXT,
    status               TEXT,
    version              TEXT,
    system_prompt        TEXT,
    tools                JSONB        NOT NULL DEFAULT '[]'::jsonb,
    environment_config   JSONB        NOT NULL DEFAULT '{}'::jsonb,
    user_metadata        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    metrics              JSONB        NOT NULL DEFAULT '{}'::jsonb,
    raw                  JSONB        NOT NULL DEFAULT '{}'::jsonb,
    observed_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, connector_id, external_id, raw_hash),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES public.tenant_connectors (tenant_id, connector_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS remote_agent_snapshots_lookup_idx
    ON public.remote_agent_snapshots (tenant_id, connector_id, external_id, observed_at DESC);

COMMIT;
