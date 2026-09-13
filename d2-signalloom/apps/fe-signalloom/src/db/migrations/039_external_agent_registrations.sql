-- 039 — tenant-bound external Linux agent registrations and claim controls
--
-- Adds durable registration metadata for external Linux agents (host OS,
-- runtime profile, enrollment status, allocated budget, registration provenance).
-- Ensures global agent_id uniqueness to reject cross-tenant and duplicate claims,
-- with foreign keys to tenant-scoped platform users and comprehensive audit types.

BEGIN;

CREATE TABLE IF NOT EXISTS public.external_agent_registrations (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id                    TEXT        NOT NULL CHECK (btrim(agent_id) <> ''),
    tenant_id                   TEXT        NOT NULL CHECK (btrim(tenant_id) <> ''),
    host_id                     TEXT        NOT NULL CHECK (btrim(host_id) <> ''),
    host_os                     TEXT        NOT NULL DEFAULT 'linux'
                                            CHECK (host_os IN ('linux', 'ubuntu-24.04', 'debian-12', 'rhel-9', 'fedora-40', 'arch')),
    runtime_profile             TEXT        NOT NULL DEFAULT 'nono-0.73.0-standard'
                                            CHECK (btrim(runtime_profile) <> ''),
    enrollment_status           TEXT        NOT NULL DEFAULT 'pending'
                                            CHECK (enrollment_status IN ('pending', 'enrolled', 'revoked', 'failed')),
    registered_by_user_id       UUID,
    registered_by_subject       TEXT        NOT NULL CHECK (btrim(registered_by_subject) <> ''),
    registered_by_issuer        TEXT        NOT NULL CHECK (btrim(registered_by_issuer) <> ''),
    allocated_token_budget      INTEGER     NOT NULL DEFAULT 100000 CHECK (allocated_token_budget > 0),
    spiffe_id_pattern           TEXT,
    enrollment_token_hash       TEXT,
    enrollment_token_expires_at TIMESTAMPTZ,
    enrolled_at                 TIMESTAMPTZ,
    revoked_at                  TIMESTAMPTZ,
    revocation_reason           TEXT,
    metadata                    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_external_agent_registrations_agent_id UNIQUE (agent_id),
    CONSTRAINT fk_external_agent_registered_by_user
        FOREIGN KEY (registered_by_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_tenant_status
    ON public.external_agent_registrations (tenant_id, enrollment_status);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_tenant_created
    ON public.external_agent_registrations (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_external_agent_registrations_host
    ON public.external_agent_registrations (tenant_id, host_id);

DROP TRIGGER IF EXISTS set_external_agent_registrations_updated_at
    ON public.external_agent_registrations;
CREATE TRIGGER set_external_agent_registrations_updated_at
    BEFORE UPDATE ON public.external_agent_registrations
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Extend audit event types for external agent lifecycle
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
         )) NOT LIKE '%external_agent.registered%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%external_agent.registered%'
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
