-- ══════════════════════════════════════════════════════════════════════════════
-- 010 — persist agent credentials so revoke is real rather than theatrical
-- ══════════════════════════════════════════════════════════════════════════════
--
-- The dashboard already ships a Revoke Credential button, and the frontend now
-- calls POST /api/agents/{id}/credentials/revoke. The backend had no such
-- route, so the button 404'd outright. Worse, POST /api/agents/{id}/credentials
-- minted a demo token, wrote only an audit row, and persisted nothing about the
-- credential itself. Any later revoke count would therefore have been made up.
--
-- This migration fixes both halves of that defect:
--
--   1. add public.agent_credentials so issue can persist a revocable row and
--      revoke can count only what it actually changed, and
--   2. widen audit_events.event_type so the new
--      'agent.credential_revoked' audit row does not fail its CHECK and roll
--      the whole revoke back.
--
-- Only the token SHA-256 is stored. The dashboard never keeps a credential id
-- and the token is show-once, so revoke is intentionally all-or-nothing per
-- agent: revoke every active credential for that tenant+agent pair, without
-- retaining a plaintext secret the system never needs again.

BEGIN;

CREATE TABLE IF NOT EXISTS public.agent_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id TEXT NOT NULL,
  agent_id UUID NOT NULL REFERENCES public.agent_registry(id) ON DELETE CASCADE,
  token_sha256 TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  revoked_by TEXT
);

CREATE INDEX IF NOT EXISTS idx_agent_credentials_active
  ON public.agent_credentials (tenant_id, agent_id)
  WHERE revoked_at IS NULL;

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

  -- Already widened for revocation? Leave it alone.
  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
             JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'audit_events' AND con.conname = constraint_name
         )) NOT LIKE '%agent.credential_revoked%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'audit_events'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%agent.credential_revoked%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        -- Written by _audit_log() in api_compat.py. Keep in step with
        -- tests/test_audit_event_types.py, which derives its expectations from
        -- the source rather than from this list.
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
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
        -- Retained legacy values from 004, 006, and 007.
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
