-- W22 — purge remote_agent_snapshots rows that carry values 163b1b60c invented.
--
-- NOT a migration: nothing applies this automatically. An operator runs it
-- once per estate, after reading the preview, e.g.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f purge-w22-fabricated-remote-agent-snapshots.sql
--
-- Why. Between 163b1b60c (2026-10-16) and the W21 fix, the remote agent
-- adapters filled user_metadata and metrics with hardcoded values whenever the
-- provider sent none. Those snapshots are still served by
-- GET /connectors/{provider}/remote-agents/{id}/history as if a provider had
-- reported them. raw_hash covers user_metadata and metrics, so the fabricated
-- rows never share a primary key with an honest observation: deleting them
-- removes no real version of any agent.
--
-- Matched ONLY on the exact invented values (never on workspace_id, which may
-- legitimately come from the connector credentials):
--   user_metadata.owner      = 'Andrew Martin (User)'
--   user_metadata.org_id     = '1f9b3065-9e10-42e5-b2ac-e8f37a186b88'
--   metrics.input_tokens     = 12450
--
-- Idempotent: a second run matches and deletes nothing. remote_agents (the
-- current-state table) is only counted, never changed: the next sync rewrites
-- it from the provider, and the W22 investigation found it already honest.

\echo 'remote_agent_snapshots carrying fabricated values (to be deleted):'
SELECT tenant_id, connector_id, external_id, raw_hash, observed_at
  FROM public.remote_agent_snapshots
 WHERE user_metadata->>'owner' = 'Andrew Martin (User)'
    OR user_metadata->>'org_id' = '1f9b3065-9e10-42e5-b2ac-e8f37a186b88'
    OR metrics->>'input_tokens' = '12450'
 ORDER BY tenant_id, connector_id, external_id, observed_at DESC;

\echo 'remote_agents (current state) carrying fabricated values (report only, expected 0):'
SELECT count(*) AS fabricated_current_rows
  FROM public.remote_agents
 WHERE user_metadata->>'owner' = 'Andrew Martin (User)'
    OR user_metadata->>'org_id' = '1f9b3065-9e10-42e5-b2ac-e8f37a186b88'
    OR metrics->>'input_tokens' = '12450';

BEGIN;

DELETE FROM public.remote_agent_snapshots
 WHERE user_metadata->>'owner' = 'Andrew Martin (User)'
    OR user_metadata->>'org_id' = '1f9b3065-9e10-42e5-b2ac-e8f37a186b88'
    OR metrics->>'input_tokens' = '12450';

\echo 'remaining fabricated snapshots after delete (must be 0):'
SELECT count(*) AS remaining
  FROM public.remote_agent_snapshots
 WHERE user_metadata->>'owner' = 'Andrew Martin (User)'
    OR user_metadata->>'org_id' = '1f9b3065-9e10-42e5-b2ac-e8f37a186b88'
    OR metrics->>'input_tokens' = '12450';

COMMIT;
