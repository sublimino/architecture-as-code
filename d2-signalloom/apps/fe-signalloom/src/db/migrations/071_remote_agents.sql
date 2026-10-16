-- 071 — remote_agents and remote_agent_sync_state: the remote agentic runtime, per tenant connector
--
-- A connector to a managed agent platform (Anthropic Managed Agents, the
-- OpenAI Agents API) is continuously synchronised by remote_agent_sync.py:
-- a full paginated listing every CONNECTOR_SYNC_INTERVAL_SECONDS, an SSE
-- event stream for Anthropic sessions that are running, and an optional
-- signed webhook. This table is what that sync observed, so the platform
-- reflects the remote state rather than a demo fixture.
--
-- One row per (tenant, connector, external_id). Every query filters on
-- tenant_id. Nothing is deleted silently: an item that disappears from a
-- complete listing gets gone_at, and gets it cleared if it comes back.
--
-- Columns carry only what the provider reported: status is the provider's own
-- word ('running', 'idle', 'terminated', 'archived' for an archived agent),
-- never a translation; NULL means the provider did not say. raw is a whitelisted
-- subset of the provider's object (ids, names, model, status, timestamps); it
-- never holds credentials, prompts, tool definitions or MCP URLs.
--
-- first_seen_at / last_seen_at / last_changed_at / gone_at are this platform's
-- observation times. external_updated_at is the provider's own timestamp.
BEGIN;

CREATE TABLE IF NOT EXISTS public.remote_agents (
    tenant_id            TEXT         NOT NULL,
    connector_id         TEXT         NOT NULL,
    provider_id          TEXT         NOT NULL,
    external_id          TEXT         NOT NULL,
    kind                 TEXT         NOT NULL
                                      CHECK (kind IN ('agent', 'session', 'assistant', 'workflow')),
    name                 TEXT,
    model                TEXT,
    status               TEXT,
    version              TEXT,
    external_updated_at  TIMESTAMPTZ,
    first_seen_at        TIMESTAMPTZ  NOT NULL,
    last_seen_at         TIMESTAMPTZ  NOT NULL,
    last_changed_at      TIMESTAMPTZ  NOT NULL,
    gone_at              TIMESTAMPTZ,
    raw                  JSONB        NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (tenant_id, connector_id, external_id),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES public.tenant_connectors (tenant_id, connector_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS remote_agents_tenant_live_idx
    ON public.remote_agents (tenant_id, connector_id) WHERE gone_at IS NULL;

-- Per-connector sync bookkeeping, shown to the tenant and shared by replicas:
-- a replica that takes the advisory lock and finds next_poll_at in the future
-- leaves the poll to whoever set it.
CREATE TABLE IF NOT EXISTS public.remote_agent_sync_state (
    tenant_id             TEXT         NOT NULL,
    connector_id          TEXT         NOT NULL,
    provider_id           TEXT         NOT NULL,
    mode                  TEXT         NOT NULL
                                       CHECK (mode IN ('poll', 'poll+stream', 'backoff')),
    last_poll_at          TIMESTAMPTZ,
    last_success_at       TIMESTAMPTZ,
    last_error            TEXT,
    next_poll_at          TIMESTAMPTZ,
    consecutive_failures  INTEGER      NOT NULL DEFAULT 0,
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, connector_id),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES public.tenant_connectors (tenant_id, connector_id) ON DELETE CASCADE
);

COMMIT;
