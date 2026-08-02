-- ══════════════════════════════════════════════════════════════════════════════
-- 009 — admit the lifecycle states the application actually writes
-- ══════════════════════════════════════════════════════════════════════════════
--
-- agent_registry.lifecycle_state carried a CHECK constraint permitting only
--
--     enrolled | active | suspended | revoked
--
-- while api_compat.py writes 'registered' on every create (POST /api/agents
-- hardcodes it in the INSERT and _make_agent uses it for the fixture path), and
-- POST /api/agents/{id}/transition writes whatever to_state the caller sends.
-- So creating an agent against a real database raised
--
--     CheckViolationError: new row for relation "agent_registry"
--     violates check constraint "agent_registry_lifecycle_state_check"
--
-- and every lifecycle transition out of the four permitted states did the same.
-- Neither was visible until the tier-2 integration suite first ran: the tier-1
-- fixture store is a dict, and a dict enforces no constraints.
--
-- Same reasoning as 007, which widened audit_events.event_type: where the
-- schema's vocabulary and the application's have drifted, the application is
-- the product surface and the constraint moves to the code. The added values
-- are not invented — 'registered' is what the create path writes, and
-- 'decommissioned' is already in agent_registry.status's own CHECK, so the two
-- columns on the same table disagreed about whether the state exists.
--
-- The four original values are retained: deployed databases hold rows using
-- them, and data-mock.sql seeds 'enrolled' and 'active'.
--
-- NOTE: TransitionRequest.to_state is a bare `str` with no validation, so an
-- unrecognised state still reaches this constraint and surfaces as a 500 rather
-- than a 400. Widening the constraint does not fix that; constraining to_state
-- to this vocabulary in the request model is the fix, and is deliberately left
-- out of this change.
--
-- Guarded DO block in the shape 006 and 007 use: a CHECK constraint is not an
-- enum, so widening means drop-and-recreate, and the guard keys on a value
-- unique to this migration so re-running is a no-op.

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
     AND rel.relname = 'agent_registry'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%lifecycle_state%'
   LIMIT 1;

  -- Already widened by this migration? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'agent_registry' AND con.conname = constraint_name
         )) NOT LIKE '%registered%'
  THEN
    EXECUTE format('ALTER TABLE public.agent_registry DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'agent_registry'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%registered%'
  ) THEN
    ALTER TABLE public.agent_registry
      ADD CONSTRAINT agent_registry_lifecycle_state_check
      CHECK (lifecycle_state IN (
        -- Original vocabulary from 004.
        'enrolled',
        'active',
        'suspended',
        'revoked',
        -- Written by POST /api/agents and _make_agent().
        'registered',
        -- Already permitted by agent_registry.status; the end of the lifecycle.
        'decommissioned'
      ));
  END IF;
END $body$;

COMMIT;
