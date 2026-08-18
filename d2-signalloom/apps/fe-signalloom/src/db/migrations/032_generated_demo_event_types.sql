-- ══════════════════════════════════════════════════════════════════════════════
-- 032 — admit the event types the multi-demo router GENERATES
-- ══════════════════════════════════════════════════════════════════════════════
--
-- WHAT BROKE
-- ----------
-- POST /api/demo/signalfusion/runs returned 500 on the Signal Fusion demo's
-- first phase, in front of an audience:
--
--   asyncpg.exceptions.CheckViolationError: new row for relation "audit_events"
--     violates check constraint "audit_events_event_type_check"
--   DETAIL: ... demo.signalfusion.phase_run ...
--
-- demo_runner.py has two paths into _record_privileged_invocation(). The
-- original SuperCred route passes a LITERAL:
--
--   _record_privileged_invocation(principal, "demo.phase_run", ...)
--
-- and the generic router factory _build_demo_router() INTERPOLATES:
--
--   _record_privileged_invocation(principal, f"demo.{config.demo_type}.phase_run", ...)
--   _record_privileged_invocation(principal, f"demo.{config.demo_type}.reset_requested", ...)
--
-- 'demo.phase_run' has been permitted since 012, which is why the SuperCred
-- demo kept working and why this looked like a Signal Fusion problem rather
-- than a refactor that shipped without its migration. The generalisation
-- changed the event type from a fixed string into a family of generated ones,
-- and the constraint's enumeration never followed.
--
--
-- THE SECOND DEFECT, WHICH THE CONSTRAINT ALONE DOES NOT FIX
-- -----------------------------------------------------------
-- audit_events.event_type has been VARCHAR(30) since 004. The generated names:
--
--   demo.supercred.phase_run             24
--   demo.signalfusion.phase_run          27   <- the reported 500
--   demo.supercred.reset_requested       30   <- exactly at the ceiling
--   demo.signalfusion.reset_requested    33   <- OVER IT
--
-- So widening only the CHECK constraint fixes the Run button and leaves the
-- Reset button failing — with StringDataRightTruncation instead of
-- CheckViolationError. Same 500, same endpoint, completely different error,
-- discovered only by whoever pressed Reset next. This migration therefore
-- widens the column as well, and tests/test_audit_event_types.py grew
-- test_every_emitted_event_type_fits_the_column so length is checked by
-- machine from here on.
--
-- 012 did that length check by hand, in a comment: "Lengths against the
-- VARCHAR(30) ceiling, longest first". That was correct when the vocabulary was
-- a hand-written list of short names. It stopped being checkable the moment the
-- emitter became an f-string, and a comment cannot notice that it has been
-- outgrown.
--
-- VARCHAR(30) -> TEXT rather than a bigger number. The CHECK constraint is an
-- exact allowlist, so it — not the column width — is what actually bounds this
-- value; a length cap on top of an allowlist constrains nothing the allowlist
-- does not already constrain, and contributes only a second, less legible way
-- for the same insert to fail. varchar -> text is binary-coercible, so this is
-- a catalogue change with no table rewrite and no scan.
--
--
-- WHY ENUMERATE RATHER THAN MATCH A PATTERN
-- ------------------------------------------
-- The obvious alternative is to stop enumerating and admit the family:
--
--   CHECK (event_type ~ '^demo\.[a-z_]+\.(phase_run|reset_requested)$' OR ...)
--
-- That never breaks again, and it was rejected. Three reasons, in order of
-- weight:
--
--   1. It converts the constraint from an allowlist into a shape check exactly
--      where the vocabulary is generated, which is exactly where a typo is most
--      likely and least visible. `demo.signalfsion.phase_run` satisfies that
--      regex. Under the enumeration it is a loud failure; under the pattern it
--      is a permanent, silent second vocabulary in the audit trail, and audit
--      rows are not editable (030) so it could not be cleaned up afterwards.
--   2. The constraint is READ as a source of truth, not merely enforced.
--      tests/test_audit_event_types.py parses this list, and
--      tests/test_dashboard_audit_vocabulary.py compares the dashboard's filter
--      options against it — a filter <select> cannot be built from a regex.
--      "What event types can this system record?" is a question a bank asks,
--      and `pg_get_constraintdef` currently answers it exactly. A pattern
--      answers a weaker question: "what shapes are not refused".
--   3. It contradicts this table's established posture. 030's whole argument is
--      that changing audit history should require "a deliberate, greppable,
--      reviewable DDL statement instead of happening by accident". Widening the
--      vocabulary is the same class of act, and deserves the same ceremony.
--
-- The cost of enumerating is one migration per new demo type. That cost is only
-- acceptable because it is now IMPOSSIBLE TO FORGET: test_audit_event_types.py
-- derives the demo types from the DemoConfig(demo_type=...) constructions,
-- expands the f-string templates over them, and fails if the result is not
-- permitted here. Registering a third demo turns that test red at commit time
-- rather than 500ing at runtime. Enumeration without that guard would just be
-- this bug on a timer, which is what it was.
--
-- The emitter deliberately keeps its f-string. Making it validate against a
-- shared constant was considered and rejected: it moves the failure from the
-- database to the application without removing it, and a runtime check that
-- fires in the same place at the same moment is not an improvement over a
-- constraint. The single source of truth is DemoConfig, and the test is what
-- binds it to this file.
--
--
-- SCOPE: all four combinations, not the one that broke. _build_demo_router() is
-- a factory over DEMO_CONFIGS, so the types it can generate are the full cross
-- product of the demo types with the two verbs. Only signalfusion is wired
-- through it today (supercred still uses the legacy literal route), but
-- `_build_demo_router(DEMO_CONFIGS["supercred"])` is a one-line change, and a
-- superset costs nothing while a subset is silent until someone presses the
-- button — 011 and 021 both record that lesson.
--
-- Same guarded drop-and-recreate shape as 006, 007, 009, 010, 011, 012 and 021:
-- event_type is a CHECK constraint rather than an enum, so widening means
-- recreating it, and the guard keys on a value unique to this migration so
-- re-running is a no-op.
--
-- This file enumerates EVERY permitted type, not just the new ones, for the
-- reason 011 records in detail: whichever migration runs LAST wins outright, so
-- a partial list here would silently drop everything 021 admitted.
--
-- 030 makes audit_events append-only via a BEFORE UPDATE/DELETE/TRUNCATE
-- trigger. Both statements below are DDL, which does not fire DML triggers —
-- 030's own comments verify precisely this drop-and-recreate against the live
-- cluster with the trigger installed. No rows are rewritten here, so the guard
-- neither needs nor gets an exemption.
--
-- CONSTRAINT_MIGRATION in tests/test_audit_event_types.py now points here.

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. Widen the column so the longest generated name can be stored at all
-- ──────────────────────────────────────────────────────────────────────────────
-- Guarded so a re-run is a catalogue read rather than a needless ACCESS
-- EXCLUSIVE lock on a table the demo is actively writing to.

DO $body$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'audit_events'
       AND column_name  = 'event_type'
       AND character_maximum_length IS NOT NULL
  ) THEN
    ALTER TABLE public.audit_events
      ALTER COLUMN event_type TYPE TEXT;
  END IF;
END $body$;

COMMENT ON COLUMN public.audit_events.event_type IS
  'Audit vocabulary. Bounded by audit_events_event_type_check, not by a length '
  'limit: the CHECK is an exact allowlist, so a width cap would add only a '
  'second failure mode. Widened from VARCHAR(30) by migration 032, where '
  'demo.signalfusion.reset_requested (33 chars) did not fit.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 2. Admit the generated demo event types
-- ──────────────────────────────────────────────────────────────────────────────

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
         )) NOT LIKE '%demo.signalfusion.phase_run%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%demo.signalfusion.phase_run%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() and _record_memory_audit() in api_compat.py.
        -- Keep in step with tests/test_audit_event_types.py, which derives its
        -- expectations from the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        -- ── The legacy fixed-string demo route ─────────────────────────────
        -- demo_runner.start_demo_run()/reset(), the original SuperCred pair.
        -- Still emitted: those routes pass literals and are unchanged.
        'demo.phase_run',
        'demo.reset_requested',
        -- ── Generated by _build_demo_router() ──────────────────────────────
        -- f"demo.{config.demo_type}.{phase_run|reset_requested}" over every
        -- DemoConfig. NOT hand-maintained in any meaningful sense: adding a
        -- DemoConfig without extending this list fails
        -- test_every_emitted_event_type_is_permitted, which derives the demo
        -- types from the constructor calls and expands the templates itself.
        --
        -- The supercred pair is not reachable today — that demo still uses
        -- the legacy literal routes above — but the factory can produce it
        -- from one line of wiring, and a subset here is silent until someone
        -- presses the button.
        --
        -- NB: no apostrophes in these comments. _permitted_event_types() pairs
        -- single quotes to read this list, so one apostrophe in prose shifts
        -- every pair after it and silently truncates the parsed vocabulary.
        -- 011 carries the same warning; this migration re-learned it.
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        -- ───────────────────────────────────────────────────────────────────
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
        -- Retained from 004, 006, 007 and 011. No call site emits these, but
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
