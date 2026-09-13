-- 040 — host enrollment tokens with single-use consumption flags and timestamps
--
-- Implements AMXO-P3-1:
-- 1. Dedicated host enrollment tokens with single-use consumption flags and timestamps.
-- 2. Extended external agent registration credentials state (enrolled key ID, public key, nonce).
-- 3. Atomic token lookup indexes and audit event types.

BEGIN;

CREATE TABLE IF NOT EXISTS public.host_enrollment_tokens (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   TEXT        NOT NULL CHECK (btrim(tenant_id) <> ''),
    agent_id                    TEXT        NOT NULL CHECK (btrim(agent_id) <> ''),
    host_id                     TEXT        NOT NULL CHECK (btrim(host_id) <> ''),
    token_hash                  TEXT        NOT NULL CHECK (btrim(token_hash) <> ''),
    created_by_subject          TEXT        NOT NULL CHECK (btrim(created_by_subject) <> ''),
    created_by_issuer           TEXT        NOT NULL CHECK (btrim(created_by_issuer) <> ''),
    expires_at                  TIMESTAMPTZ NOT NULL,
    consumed_at                 TIMESTAMPTZ,
    consumed_by_host_id         TEXT,
    consumed_by_key_id          TEXT,
    consumed_by_public_key      TEXT,
    consumed_by_client_nonce    TEXT,
    status                      TEXT        NOT NULL DEFAULT 'pending'
                                            CHECK (status IN ('pending', 'consumed', 'expired', 'revoked')),
    metadata                    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_host_enrollment_tokens_hash UNIQUE (token_hash),
    CONSTRAINT fk_host_enrollment_token_agent
        FOREIGN KEY (agent_id)
        REFERENCES public.external_agent_registrations (agent_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_host_enrollment_tokens_tenant_status
    ON public.host_enrollment_tokens (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_host_enrollment_tokens_agent
    ON public.host_enrollment_tokens (tenant_id, agent_id);

CREATE INDEX IF NOT EXISTS idx_host_enrollment_tokens_hash
    ON public.host_enrollment_tokens (token_hash);

-- Extend external_agent_registrations table with enrolled credential columns
ALTER TABLE public.external_agent_registrations
    ADD COLUMN IF NOT EXISTS enrolled_key_id TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_public_key TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_client_nonce TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_credential_reference TEXT,
    ADD COLUMN IF NOT EXISTS enrolled_credential_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS token_consumed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_token_hash
    ON public.external_agent_registrations (enrollment_token_hash)
    WHERE enrollment_token_hash IS NOT NULL;

DROP TRIGGER IF EXISTS set_host_enrollment_tokens_updated_at
    ON public.host_enrollment_tokens;
CREATE TRIGGER set_host_enrollment_tokens_updated_at
    BEFORE UPDATE ON public.host_enrollment_tokens
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Extend audit event types for host enrollment
DO $body$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT con.conname INTO constraint_name
    FROM pg_constraint con
   WHERE con.conrelid = 'public.audit_events'::regclass
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%event_type%'
   LIMIT 1;

  IF constraint_name IS NOT NULL
     AND pg_get_constraintdef((
           SELECT con.oid FROM pg_constraint con
            WHERE con.conrelid = 'public.audit_events'::regclass
              AND con.conname = constraint_name
          )) NOT LIKE '%external_agent.token_issued%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%external_agent.token_issued%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stunned',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'external_agent.registered',
        'external_agent.claim_rejected',
        'external_agent.status_updated',
        'external_agent.revoked',
        'external_agent.claimed',
        'external_agent.token_issued',
        'external_agent.enrolled',
        'support.requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'nhi.dismissed',
        'nhi.enrolled',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'user.currency_updated',
        'violation.acknowledged',
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
