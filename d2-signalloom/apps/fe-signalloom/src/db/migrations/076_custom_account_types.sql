-- 076 — custom account types, superadmin-defined
--
-- A custom account type is a named, explicit feature-flag set a superadmin
-- can create, rename and delete (api/admin_account_types.py), on top of the
-- three built-in account types (EAP View, EAP Full, Full; migration 074) and
-- the now-retired "minimal_governance" bundle (075). It is persisted here and
-- tenant-assignable exactly like a built-in: PUT /api/v1/admin/features
-- accepts its id as `preset`, and it is listed alongside the built-ins by
-- GET /api/v1/admin/features/presets (kind="custom").
--
-- `flags` is a full JSONB flag map, same shape as tenant_feature_flags' values
-- but keyed by flag within a single row rather than one row per flag, because
-- a custom account type is one unit: feature_flags.CustomAccountTypeRepository
-- validates it sets exactly the registered flag keys before insert.
--
-- `id` is the primary key and doubles as the preset id applied to tenants, so
-- it is validated (lowercase, digits, underscores; starts with a letter) and
-- checked against RESERVED_ACCOUNT_TYPE_IDS (every built-in id, every
-- deprecated alias, and 'minimal_governance') before insert -- a custom type
-- can never collide with or shadow a built-in one.
--
-- Built-in account types are not rows in this table: they live in
-- feature_flags.FEATURE_PRESETS, a Python constant, which is exactly why they
-- "cannot be deleted or edited" -- there is no row here to delete or edit.
--
-- Design: docs/signalloom/feature-flag-account-types.md
BEGIN;

CREATE TABLE IF NOT EXISTS public.custom_account_types (
    id          VARCHAR(64)  PRIMARY KEY,
    name        VARCHAR(256) NOT NULL,
    flags       JSONB        NOT NULL,
    created_by  VARCHAR(256),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_by  VARCHAR(256),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────────────────────
-- Admit the 'account_type.created' / 'account_type.renamed' /
-- 'account_type.deleted' audit event types
-- ──────────────────────────────────────────────────────────────────────────────
-- Same guarded drop-and-recreate shape as 063/067/069: the new types are their
-- own sentinel, so re-running is a no-op and a database already carrying them
-- is left alone. 069 is the migration that last recreated this constraint (070
-- through 075 touch neither audit_events nor its CHECK); this one replaces it
-- with the 069 vocabulary plus the three new types.

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
         )) NOT LIKE '%account_type.created%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%account_type.created%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
        'account_type.created',
        'account_type.deleted',
        'account_type.renamed',
        'afm.cluster_import_requested',
        'actor.promote_requested',
        'agent.claimed',
        'agent.created',
        'agent.credential_issued',
        'agent.credential_revoked',
        'agent.stun_failed',
        'agent.stun_simulated',
        'agent.stunned',
        'agent.transition_failed',
        'agent.transitioned',
        'api_key.created',
        'api_key.rotated',
        'audit.cross_tenant_read',
        'compliance.reassess_requested',
        'compliance.scan_completed',
        'compliance_check',
        'connector.scan_requested',
        'consent.accepted',
        'cookie.preferences_updated',
        'demo.distancelatency.phase_run',
        'demo.distancelatency.reset_requested',
        'demo.phase_run',
        'demo.reset_requested',
        'demo.signalfusion.phase_run',
        'demo.signalfusion.reset_requested',
        'demo.supercred.phase_run',
        'demo.supercred.reset_requested',
        'directory_connected',
        'discovery_enroll_requested',
        'eap_environment.lease_extended',
        'eap_environment.provisioned',
        'eap_environment.reaping_triggered',
        'eap_environment.registered',
        'eap_environment.teardown_requested',
        'eap_environment.ttl_extended',
        'eap_environment.webhook_triggered',
        'eap_scenario.executed',
        'eap_tenant.isolation_provisioned',
        'eap_tenant.isolation_torn_down',
        'enrollment',
        'external_agent.claim_rejected',
        'external_agent.claimed',
        'external_agent.enrolled',
        'external_agent.registered',
        'external_agent.revoked',
        'external_agent.status_updated',
        'external_agent.token_issued',
        'feature_flags.updated',
        'fleet.recover_requested',
        'fleet.resume_requested',
        'invite.created',
        'invite.redeemed',
        'nhi.dismissed',
        'nhi.enrolled',
        'onboarding_completed',
        'onboarding_skipped',
        'operator.created',
        'operator.removed',
        'operator.sign_in_denied',
        'operator.sign_in_succeeded',
        'policy.bundle_submitted',
        'policy.rollback_requested',
        'rbac.scan_requested',
        'state_transition',
        'support.requested',
        'tenant.frameworks_updated',
        'tenant.preferences_updated',
        'tenant.risk_profile_updated',
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user.deleted',
        'user.invited',
        'user.role_updated',
        'user.status_updated',
        'user.updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
