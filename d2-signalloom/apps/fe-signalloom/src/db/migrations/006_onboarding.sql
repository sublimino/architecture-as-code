-- ══════════════════════════════════════════════════════════════════════════════
-- 005 — onboarding state
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Backs GET/POST /api/onboarding/{status,skip,complete} and GET/PUT
-- /api/onboarding/state. Until this existed the dashboard ran its onboarding
-- client in MOCK_MODE, where "Skip for now" wrote a module-level variable that
-- died on reload — so the wizard could never be dismissed and every protected
-- route bounced back to /onboarding.
--
-- Shape: one row per tenant, holding a terminal status with its date plus the
-- wizard's resumable in-progress state.
--
-- Why a dedicated table rather than columns on tenant_settings (which already
-- carries consent_accepted_at, the closest precedent):
--
--   1. wizard_state churns on every step change. On tenant_settings each write
--      would fire trg_tenant_settings_updated_at and bump the updated_at of a
--      row that holds stable org configuration.
--   2. tenant_settings is 1:1 with tenant by UNIQUE constraint. If onboarding
--      later needs to be per-user, this table takes a user_email column and a
--      composite unique; tenant_settings could not without a redesign.
--   3. The onboarding state machine is legible in one place instead of being
--      inferred from three nullable columns on a grab-bag row.
--
-- History is NOT kept here. Completion and skip both append to audit_events, so
-- "skipped in March, completed in June" is answerable without this table
-- carrying an event log it would otherwise duplicate.
--
-- Multi-tenancy note: tenant_id is NOT NULL with NO DEFAULT, deliberately
-- diverging from the `DEFAULT 'tenant-demo'` used by the 004 tables. A default
-- means an INSERT that forgets the tenant silently lands in the demo tenant
-- instead of failing; on a shared-schema multi-tenant database that is a
-- cross-tenant write, not a convenience. The FK to tenant_settings gives this
-- table the referential integrity and tenant-deletion semantics the rest of the
-- schema currently lacks.

CREATE TABLE IF NOT EXISTS public.tenant_onboarding (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL UNIQUE
                                REFERENCES public.tenant_settings(tenant_id)
                                ON DELETE CASCADE,
    status          TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending', 'completed', 'skipped')),
    completed_at    TIMESTAMPTZ,
    skipped_at      TIMESTAMPTZ,
    wizard_state    JSONB       NOT NULL DEFAULT '{}'::jsonb
                                CHECK (jsonb_typeof(wizard_state) = 'object'),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- A terminal status must carry its date, and a date must not appear without
    -- the status that explains it. Without these the table can express
    -- "completed, but we don't know when", which is exactly the ambiguity the
    -- status column was added to remove.
    CONSTRAINT tenant_onboarding_completed_has_date
        CHECK (status <> 'completed' OR completed_at IS NOT NULL),
    CONSTRAINT tenant_onboarding_skipped_has_date
        CHECK (status <> 'skipped'   OR skipped_at   IS NOT NULL),
    CONSTRAINT tenant_onboarding_pending_has_no_date
        CHECK (status <> 'pending'   OR (completed_at IS NULL AND skipped_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_tenant_onboarding_status
    ON public.tenant_onboarding (status);

DO $body$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_tenant_onboarding_updated_at') THEN
    CREATE TRIGGER trg_tenant_onboarding_updated_at
      BEFORE UPDATE ON public.tenant_onboarding
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $body$;

-- ──────────────────────────────────────────────────────────────────────────────
-- audit_events: admit the two onboarding transitions
-- ──────────────────────────────────────────────────────────────────────────────
-- audit_events.event_type is a CHECK constraint, not an enum, so widening it
-- means dropping and recreating the constraint. Done as a guarded block so the
-- migration stays idempotent and so a database that already has the wider
-- constraint is left alone.

DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
   WHERE nsp.nspname = 'public'
     AND rel.relname = 'audit_events'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%onboarding_completed%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%onboarding_completed%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'enrollment', 'state_transition', 'violation_detected',
        'compliance_check', 'token_issued', 'token_refused',
        'tenant_created', 'user_provisioned', 'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed', 'onboarding_skipped'
      ));
  END IF;
END $body$;
