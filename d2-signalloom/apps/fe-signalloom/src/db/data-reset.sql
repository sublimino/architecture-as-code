-- data-reset.sql
-- Truncates all governance tables and resets sequences.
-- Idempotent: TRUNCATE IF EXISTS pattern via DO blocks.
--
-- Usage:
--   psql $CONN -f data-reset.sql                       # reset all tables
--   psql $CONN -v focus=agents -f data-reset.sql       # reset agent tables only
--
-- Focus values: agents, compliance, audit, nhi, settings, users, all (default)

BEGIN;

DO $$
DECLARE
    v_focus TEXT := COALESCE(current_setting('app.data_reset_focus', true), 'all');
    v_append_only BOOLEAN;
BEGIN
    -- ── Lift the append-only guard on audit_events ───────────────────────────
    -- Migration 030 installs an ALWAYS trigger that refuses UPDATE, DELETE and
    -- TRUNCATE on public.audit_events, so that a compromised or careless
    -- application cannot rewrite its own history. This script is the one
    -- sanctioned destructive caller, and it lifts the guard explicitly rather
    -- than the trigger carrying a bypass condition that an attacker could also
    -- satisfy.
    --
    -- The disable has to wrap the WHOLE body, not just the 'audit' focus.
    -- audit_events.agent_id carries an FK to agent_registry, so the 'agents'
    -- focus reaches it too: `TRUNCATE public.agent_registry CASCADE` cascades
    -- into audit_events and fires the trigger just the same. Guarding only the
    -- obvious branch would leave `SERVICE=agents` broken.
    --
    -- The guard is restored before COMMIT below. Everything here is one
    -- transaction, so an error on any TRUNCATE rolls the DISABLE back with it
    -- and the table is never left unguarded.
    --
    -- The existence check keeps this working against a database provisioned
    -- before 030 (the bootstrap only runs on an empty data directory), where
    -- ALTER TABLE ... DISABLE TRIGGER on a missing trigger would abort.
    SELECT EXISTS (
        SELECT 1
          FROM pg_trigger trg
          JOIN pg_class rel ON rel.oid = trg.tgrelid
          JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
         WHERE nsp.nspname = 'public'
           AND rel.relname = 'audit_events'
           AND trg.tgname  = 'audit_events_append_only'
    ) INTO v_append_only;

    IF v_append_only THEN
        ALTER TABLE public.audit_events DISABLE TRIGGER audit_events_append_only;
    END IF;

    -- ── Agents + dependent tables ────────────────────────────────────────────
    IF v_focus IN ('all', 'agents') THEN
        TRUNCATE public.agent_compliance_results CASCADE;
        TRUNCATE public.lifecycle_transitions CASCADE;
        TRUNCATE public.agent_violations CASCADE;
        TRUNCATE public.agent_registry CASCADE;
        RAISE NOTICE 'reset: agent tables truncated';
    END IF;

    -- ── Users + roles (after agents — agent_registry.owner_id FK) ───────────
    IF v_focus IN ('all', 'users') THEN
        TRUNCATE public.user_roles CASCADE;
        TRUNCATE public.platform_users CASCADE;
        RAISE NOTICE 'reset: user tables truncated';
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

    -- ── Restore the append-only guard ────────────────────────────────────────
    -- ENABLE ALWAYS, not a bare ENABLE: 030 installs it as ALWAYS so that
    -- session_replication_role = 'replica' cannot skip it, and re-enabling it
    -- as ORIGIN would silently downgrade the control every time someone reset
    -- the demo.
    IF v_append_only THEN
        ALTER TABLE public.audit_events ENABLE ALWAYS TRIGGER audit_events_append_only;
    END IF;
END $$;

COMMIT;
