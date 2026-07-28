-- data-reset.sql
-- Truncates all governance tables and resets sequences.
-- Idempotent: TRUNCATE IF EXISTS pattern via DO blocks.
--
-- Usage:
--   psql $CONN -f data-reset.sql                       # reset all tables
--   psql $CONN -v focus=agents -f data-reset.sql       # reset agent tables only
--
-- Focus values: agents, compliance, audit, nhi, settings, all (default)

BEGIN;

DO $$
DECLARE
    v_focus TEXT := COALESCE(current_setting('app.data_reset_focus', true), 'all');
BEGIN
    -- ── Agents + dependent tables ────────────────────────────────────────────
    IF v_focus IN ('all', 'agents') THEN
        TRUNCATE public.agent_compliance_results CASCADE;
        TRUNCATE public.lifecycle_transitions CASCADE;
        TRUNCATE public.agent_violations CASCADE;
        TRUNCATE public.agent_registry CASCADE;
        RAISE NOTICE 'reset: agent tables truncated';
    END IF;

    -- ── Compliance / Frameworks ──────────────────────────────────────────────
    IF v_focus IN ('all', 'compliance') THEN
        TRUNCATE public.agent_compliance_results CASCADE;
        TRUNCATE public.governance_controls CASCADE;
        TRUNCATE public.governance_frameworks CASCADE;
        RAISE NOTICE 'reset: compliance tables truncated';
    END IF;

    -- ── Audit events ─────────────────────────────────────────────────────────
    IF v_focus IN ('all', 'audit') THEN
        TRUNCATE public.audit_events CASCADE;
        RAISE NOTICE 'reset: audit_events truncated';
    END IF;

    -- ── NHI ──────────────────────────────────────────────────────────────────
    IF v_focus IN ('all', 'nhi') THEN
        TRUNCATE public.nhi_discovered_accounts CASCADE;
        TRUNCATE public.nhi_scans CASCADE;
        RAISE NOTICE 'reset: NHI tables truncated';
    END IF;

    -- ── Settings / Consent / API keys / Support ──────────────────────────────
    IF v_focus IN ('all', 'settings') THEN
        TRUNCATE public.consent_events CASCADE;
        TRUNCATE public.tenant_api_keys CASCADE;
        TRUNCATE public.support_requests CASCADE;
        TRUNCATE public.tenant_settings CASCADE;
        RAISE NOTICE 'reset: settings/consent/api-key/support tables truncated';
    END IF;
END $$;

COMMIT;
