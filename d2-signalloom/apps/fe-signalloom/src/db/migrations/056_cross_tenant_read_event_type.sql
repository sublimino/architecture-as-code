-- 056 — admit 'audit.cross_tenant_read'
--
-- A superadmin keeps its cross-tenant view for the pilot (Andy, 2026-10-06),
-- but every read whose response discloses another tenant's data now writes
-- one audit event naming it (cross_tenant_audit.audit_cross_tenant_read,
-- called from the signal_fusion/signal_policy/invites/cadvisor_poller
-- read routes that can act for every tenant). Replaces
-- audit_events_event_type_check with 055's vocabulary plus this type, on
-- 055's own pattern.
BEGIN;

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
          )) NOT LIKE '%audit.cross_tenant_read%'
  THEN
    EXECUTE format('ALTER TABLE public.audit_events DROP CONSTRAINT %I', constraint_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint con
     WHERE con.conrelid = 'public.audit_events'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%audit.cross_tenant_read%'
  ) THEN
    ALTER TABLE public.audit_events
      ADD CONSTRAINT audit_events_event_type_check
      CHECK (event_type IN (
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
        'tenant_created',
        'token_issued',
        'token_refused',
        'user.currency_updated',
        'user_provisioned',
        'violation.acknowledged',
        'violation_detected'
      ));
  END IF;
END $body$;

COMMIT;
