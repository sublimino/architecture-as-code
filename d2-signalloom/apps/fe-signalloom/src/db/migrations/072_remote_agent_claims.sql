-- 072 — remote_agents.claimed_agent_id: a remote provider agent claimed into the tenant
--
-- POST /api/v1/connectors/{provider_id}/remote-agents/{external_id}/claim
-- (routers/connectors.py) creates or links an agent_registry record carrying the
-- provider provenance (provider_id, connector_id, external_id, kind, model in
-- agent_registry.config->'remote_agent') and records the link here, so Discovery
-- and the remote environment page can show "Claimed" and link to the agent.
--
-- The sync's upsert never writes these columns, so a re-listing keeps the link.
-- Deleting the registry agent clears the link (ON DELETE SET NULL) and the remote
-- agent becomes claimable again; deleting the connector cascades the row away.
BEGIN;

ALTER TABLE public.remote_agents
    ADD COLUMN IF NOT EXISTS claimed_agent_id UUID
        REFERENCES public.agent_registry (id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

COMMIT;
