-- ══════════════════════════════════════════════════════════════════════════════
-- 012 — admit the operational event types
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Four actions that change state, or the cluster, and left no durable record:
--
--   demo.reset_requested       POST /api/demo/reset — the most destructive
--                              control in the product. It preempts and cancels
--                              whatever privileged phase is running, then runs
--                              the teardown. Its only history lived in a
--                              per-process dict that dies with the pod, while
--                              GET /api/demo/status describes that dict as the
--                              run history of a cluster-mutating control plane:
--                              which privileged phase was driven, by whom, when.
--                              That is a description of an audit trail kept in
--                              memory.
--
--   demo.phase_run             POST /api/demo/runs — a superadmin driving a
--                              privileged phase against the cluster. Recorded
--                              from what the runner observed (which step, which
--                              principal, exit status), never from what a
--                              browser asserted afterwards.
--
--   compliance.scan_completed  POST /api/compliance/policy/scan — refreshes
--                              agent_compliance_results. A compliance verdict
--                              changing with nothing recording that it did is
--                              the gap this product exists to close.
--
--   support.requested          POST /api/support — persists a request carrying
--                              the caller identity from their token. The row is
--                              evidence; that it was created was not.
--
-- Lengths against the VARCHAR(30) ceiling, longest first:
--   compliance.scan_completed  25
--   demo.reset_requested       20
--   support.requested          17
--   demo.phase_run             14
--
-- Same guarded drop-and-recreate shape as 006, 007, 009, 010 and 011:
-- event_type is a CHECK constraint rather than an enum, so widening means
-- recreating it, and the guard keys on a value unique to this migration so
-- re-running is a no-op.
--
-- This file enumerates EVERY permitted type, not just the new ones. 011 records
-- why in detail: whichever migration runs LAST wins outright, so a partial list
-- here would silently drop the eleven types 011 admitted and every one of those
-- writes would begin raising CheckViolationError — rolling back the mutation it
-- shares a transaction with and returning 500, invisibly, until someone presses
-- the button.
--
-- CONSTRAINT_MIGRATION in tests/test_audit_event_types.py now points here.
--
-- NB: no quote characters in these comments. test_audit_event_types.py parses
-- quoted literals out of this file, so a quoted event name in prose would be
-- captured as if it were part of the vocabulary.

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
         )) NOT LIKE '%demo.reset_requested%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%demo.reset_requested%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log(). Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list — and which now reads every
        -- module that calls _audit_log, not only api_compat.py.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
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
        -- New in this migration.
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'support.requested',
        -- Live undotted vocabulary. 011 described the whole undotted block as
        -- emitted by no call site; that was true of the rest of it but not of
        -- these two, which onboarding.py has written since 006 and which have
        -- rows in the deployed database. The guard could not see them because
        -- it read only api_compat.py.
        'onboarding_completed',
        'onboarding_skipped',
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
        'discovery_enroll_requested'
      ));
  END IF;
END $body$;

COMMIT;
