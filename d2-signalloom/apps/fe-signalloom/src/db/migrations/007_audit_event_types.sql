-- ══════════════════════════════════════════════════════════════════════════════
-- 007 — admit the event types the application actually writes
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Every call site of _audit_log() in api_compat.py writes a dotted event type
-- ('agent.created', 'tenant.frameworks_updated', ...). The CHECK constraint on
-- audit_events.event_type allowed only an undotted vocabulary
-- ('enrollment', 'state_transition', ...) that no call site uses. The two sets
-- were completely disjoint, so EVERY audit insert raised
--
--     CheckViolationError: new row for relation "audit_events"
--     violates check constraint "audit_events_event_type_check"
--
-- The mutation and its audit insert are separate autocommit statements, so the
-- business write landed and the request then returned 500. Symptoms included
-- PATCH /api/tenant/settings/preferences and PATCH /api/tenant/settings/frameworks
-- both failing while persisting their changes. audit_events held zero rows on a
-- cluster that had been running for days: the audit trail had never recorded a
-- single event.
--
-- 004 created the constraint and 006 widened it by two values, but both used the
-- undotted vocabulary, so neither closed the gap.
--
-- The dotted form is the application's convention — all thirteen call sites use
-- it — so the constraint moves to the code rather than the code to the
-- constraint. The undotted values are retained: they cost nothing, other
-- environments may hold rows that use them, and 006 is still expected to be
-- idempotent against a database that has already seen it.
--
-- tests/test_audit_event_types.py parses every event_type literal out of
-- api_compat.py and fails if one is absent here, so the two cannot drift again.
--
-- Same guarded-DO-block shape as 006: event_type is a CHECK constraint rather
-- than an enum, so widening means dropping and recreating, and the guard keys on
-- a value unique to this migration so re-running is a no-op.

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

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%tenant.preferences_updated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%tenant.preferences_updated%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() in api_compat.py. Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'violation.acknowledged',
        -- Retained from 004 and 006. No call site emits these, but dropping
        -- them would break any environment holding rows that use them.
        'enrollment',
        'state_transition',
        'violation_detected',
        'compliance_check',
        'token_issued',
        'token_refused',
        'tenant_created',
        'user_provisioned',
        'directory_connected',
        'discovery_enroll_requested',
        'onboarding_completed',
        'onboarding_skipped'
      ));
  END IF;
END $body$;
