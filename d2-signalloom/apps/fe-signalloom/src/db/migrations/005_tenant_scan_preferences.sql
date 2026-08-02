-- Migration: 005_tenant_scan_preferences
-- Adds the scan-preference columns the onboarding wizard's "Set your scan
-- preferences" step writes via PATCH /api/tenant/settings/preferences.
--
-- Defaults mirror the dashboard's DEFAULT_PREFERENCES
-- (dashboard-signalloom/src/pages/OnboardingWizard.tsx): 24-hour cadence,
-- no alert email, alert threshold of 1.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + guarded constraint creation.

BEGIN;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS preferred_scan_cadence_hours INTEGER NOT NULL DEFAULT 24;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS alert_email TEXT;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS alert_threshold INTEGER NOT NULL DEFAULT 1;

DO $body$ BEGIN
  IF to_regclass('public.tenant_settings') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_scan_cadence_positive'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_scan_cadence_positive
      CHECK (preferred_scan_cadence_hours > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_alert_threshold_positive'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_alert_threshold_positive
      CHECK (alert_threshold > 0);
  END IF;
END $body$;

COMMIT;
