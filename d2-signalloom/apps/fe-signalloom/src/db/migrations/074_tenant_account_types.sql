-- 074 — tenant_account_types: the account type applied to each tenant
--
-- An account type (EAP View, EAP Full, Full) is a named, exact feature-flag set
-- (feature_flags.FEATURE_PRESETS). PUT /api/v1/admin/features with a preset
-- writes the flags into tenant_feature_flags (057) AND records the type here.
--
-- `customised` is TRUE when a later manual toggle left the tenant's effective
-- flags different from the recorded type's set; the Feature Flags page then
-- shows "Custom, based on <type>" instead of claiming the type. It is
-- re-derived after every flag mutation, so toggling back clears it.
--
-- Design: docs/signalloom/feature-flag-account-types.md
BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_account_types (
    tenant_id    VARCHAR(128) PRIMARY KEY,
    account_type VARCHAR(64)  NOT NULL,
    customised   BOOLEAN      NOT NULL DEFAULT FALSE,
    updated_by   VARCHAR(256),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMIT;
