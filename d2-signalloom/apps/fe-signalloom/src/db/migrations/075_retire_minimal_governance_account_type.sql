-- 075 — retire the "Minimal Governance" preset
--
-- "minimal_governance" was never an account type (EAP View, EAP Full, Full):
-- it was a non-account-type "bundle" preset in feature_flags.FEATURE_PRESETS,
-- listed with kind="bundle" on GET /api/v1/admin/features/presets. The
-- principal decided to retire it entirely -- removed from the contract file,
-- FEATURE_PRESETS, the dashboard constants, the acceptance-test harness, and
-- every test that referenced it.
--
-- Any tenant that had it applied is still recorded in public.tenant_account_types
-- (migration 074) with account_type = 'minimal_governance'. That id no longer
-- resolves to anything, so describe_account_type() would report such a tenant
-- "Unassigned" even though its flags still reflect the old preset -- losing
-- the fact that a type was ever applied. This migration remaps those rows to
-- the nearest supported account type instead of just deleting the fact.
--
-- "Nearest" by flag-set Hamming distance over the 23 registered flags:
--   eap_view: 4 differ   (compliance, page_discovery, page_policies, page_audit)
--   eap_full: 9 differ
--   full:    19 differ
-- eap_view is nearest by a wide margin, so remapped tenants go there.
--
-- The tenant's actual flags in tenant_feature_flags (057) are NOT touched by
-- this migration -- only the recorded type label. Since minimal_governance's
-- flags differ from eap_view's in 4 places, the remapped row is marked
-- customised = TRUE, so the Feature Flags page shows "Custom, based on
-- EAP View (read-only)" rather than falsely claiming an exact match.
--
-- Idempotent: re-running finds no row with account_type = 'minimal_governance'
-- left to update (they are all 'eap_view' by then) and is a no-op.
--
-- Design: docs/signalloom/feature-flag-account-types.md
BEGIN;

UPDATE public.tenant_account_types
SET account_type = 'eap_view',
    customised = TRUE,
    updated_at = NOW()
WHERE account_type = 'minimal_governance';

COMMIT;
