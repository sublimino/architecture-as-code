-- 038 — attributable AgentMaxxing operator identities
--
-- Migration 008 remains the platform-user directory baseline. This forward-only
-- extension binds a directory row to one immutable OIDC issuer/subject pair,
-- preserves removed identities, and gives audit rows stable identity snapshots.
-- Existing users are deliberately not guessed or backfilled.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS uq_platform_users_id_tenant
    ON public.platform_users (id, tenant_id);

CREATE TABLE IF NOT EXISTS public.operator_identities (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    platform_user_id    UUID        NOT NULL,
    tenant_id           TEXT        NOT NULL,
    issuer              TEXT        NOT NULL CHECK (btrim(issuer) <> ''),
    subject             TEXT        NOT NULL CHECK (btrim(subject) <> ''),
    identity_kind       TEXT        NOT NULL DEFAULT 'individual'
                                    CHECK (identity_kind = 'individual'),
    status              TEXT        NOT NULL DEFAULT 'active'
                                    CHECK (status IN ('active', 'removed')),
    removed_at          TIMESTAMPTZ,
    removed_by_user_id  UUID,
    removal_reason      TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_operator_identity_user UNIQUE (platform_user_id),
    CONSTRAINT uq_operator_identity_subject UNIQUE (issuer, subject),
    CONSTRAINT fk_operator_identity_user_tenant
        FOREIGN KEY (platform_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_operator_identity_remover_tenant
        FOREIGN KEY (removed_by_user_id, tenant_id)
        REFERENCES public.platform_users (id, tenant_id)
        ON DELETE RESTRICT,
    CONSTRAINT operator_identities_removal_check CHECK (
        (
            status = 'active'
            AND removed_at IS NULL
            AND removed_by_user_id IS NULL
            AND removal_reason IS NULL
        )
        OR
        (
            status = 'removed'
            AND removed_at IS NOT NULL
            AND removed_by_user_id IS NOT NULL
            AND removal_reason IS NOT NULL
            AND btrim(removal_reason) <> ''
        )
    )
);

CREATE INDEX IF NOT EXISTS idx_operator_identities_tenant_status
    ON public.operator_identities (tenant_id, status);

DROP TRIGGER IF EXISTS set_operator_identities_updated_at
    ON public.operator_identities;
CREATE TRIGGER set_operator_identities_updated_at
    BEFORE UPDATE ON public.operator_identities
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.audit_events
    ADD COLUMN IF NOT EXISTS actor_user_id UUID,
    ADD COLUMN IF NOT EXISTS actor_issuer TEXT,
    ADD COLUMN IF NOT EXISTS actor_subject TEXT;

DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.audit_events'::regclass
       AND conname = 'audit_events_actor_user_tenant_fkey'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_actor_user_tenant_fkey
      FOREIGN KEY (actor_user_id, tenant_id)
      REFERENCES public.platform_users (id, tenant_id) ON DELETE RESTRICT;
  END IF;
END $body$;

CREATE INDEX IF NOT EXISTS idx_audit_events_actor_user
    ON public.audit_events (tenant_id, actor_user_id, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_audit_events_actor_identity
    ON public.audit_events (tenant_id, actor_issuer, actor_subject, timestamp DESC)
    WHERE actor_issuer IS NOT NULL AND actor_subject IS NOT NULL;

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
         )) NOT LIKE '%operator.created%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%operator.created%'
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
