-- ══════════════════════════════════════════════════════════════════════════════
-- 010 — admit 'agent.stunned'
-- ══════════════════════════════════════════════════════════════════════════════
--
-- POST /api/agents/{id}/stun records the operator isolating a non-compliant
-- agent. The SuperCred proxy performs the cluster-side action (relabel the pod,
-- revoke the OpenBao lease) and holds no database; without this endpoint the
-- most consequential action in the demo left no durable record at all — the
-- agent changed state and the Audit Trail showed nothing.
--
-- 007 moved the constraint to the code's dotted vocabulary and
-- tests/test_audit_event_types.py derives its expectations from the AST of
-- api_compat.py, so adding the call site without widening the constraint fails
-- that test rather than 500ing at runtime. This is that widening.
--
-- 'agent.stunned' is 13 characters; audit_events.event_type is VARCHAR(30).
--
-- Same guarded drop-and-recreate shape as 006, 007 and 009: event_type is a
-- CHECK constraint rather than an enum, so widening means recreating it, and
-- the guard keys on a value unique to this migration so re-running is a no-op.
--
-- CONSTRAINT_MIGRATION in tests/test_audit_event_types.py now points here.

BEGIN;

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
         )) NOT LIKE '%agent.stunned%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.stunned%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() in api_compat.py. Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.stunned',
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
        -- Retained from 004, 006 and 007. No call site emits these, but
        -- dropping them would break any environment holding rows that use them.
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

COMMIT;
