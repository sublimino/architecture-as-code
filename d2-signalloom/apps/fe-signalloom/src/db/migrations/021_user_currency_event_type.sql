-- ══════════════════════════════════════════════════════════════════════════════
-- 021 — admit 'user.currency_updated'
-- ══════════════════════════════════════════════════════════════════════════════
--
-- PATCH /api/user/preferences records a user changing the currency every risk
-- figure on every screen is displayed in. A settings change a regulated
-- customer cannot see the history of is a gap, and this one changes what the
-- numbers in a board pack read as.
--
-- The detail carries {from, to, email} so the trail answers who changed it and
-- what it used to be, without a join against a table that only ever holds the
-- current value.
--
-- 'user.currency_updated' is 21 characters; audit_events.event_type is
-- VARCHAR(30).
--
-- ── The union, and why this file is dangerous ───────────────────────────────
--
-- event_type is a CHECK constraint rather than an enum, so widening it means
-- DROPPING AND RECREATING it with the ENTIRE vocabulary enumerated. The last
-- such migration to run wins outright: any type it omits is rejected from then
-- on, and because the audit insert shares a transaction with the mutation it
-- records, the rejection rolls back the business write and returns 500. Nothing
-- fails at migration time or at API startup — it fails the first time a user
-- presses the button.
--
-- 011 carries a long comment about exactly this: 010 and 011 were authored in
-- parallel, each enumerating a vocabulary that omitted the other's new type,
-- and renumbering alone did not fix it because ordering does not merge lists.
--
-- This file was written under the same conditions. Migrations 012-019 are
-- reserved for concurrent audit-coverage work that this author could not read.
-- If any of them adds an event type, IT MUST BE ADDED TO THE LIST BELOW — this
-- file runs last and its list is the one that survives. The reviewer merging
-- these branches owns that check; the test named below is what catches it.
--
-- tests/test_audit_event_types.py derives its expectations from the AST of
-- api_compat.py and compares them against CONSTRAINT_MIGRATION, which this
-- change repoints at this file. A type emitted by a call site and missing here
-- fails that test rather than 500ing in production — which is the whole reason
-- the test parses the source instead of trusting a hand-maintained list.
--
-- NB: no quote characters in this prose. test_audit_event_types.py parses
-- quoted literals out of this file, so a quoted event name in a comment is
-- captured as if it were part of the vocabulary.
--
-- Same guarded drop-and-recreate shape as 006, 007, 009 and 011: the guard keys
-- on a value unique to this migration so re-running is a no-op.

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
         )) NOT LIKE '%user.currency_updated%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%user.currency_updated%'
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
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        -- New in this migration. Per-user, deliberately not tenant-scoped: the
        -- tenant type above already exists and conflating the two would make a
        -- personal display choice look like a tenant-wide policy change.
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
