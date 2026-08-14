-- ══════════════════════════════════════════════════════════════════════════════
-- 020 — per-user display currency
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Every risk figure in the dashboard is denominated in GBP at source, and the
-- product default is to SHOW them in USD. Which currency a given user sees is
-- therefore a stored preference, not a formatting detail, and conversion is on
-- the critical path from the first render.
--
-- ── Why a column on platform_users, and not a user_preferences table ─────────
--
-- The alternative considered was a key/value `user_preferences` table keyed on
-- (user_id, key). A column wins here on three counts:
--
--   1. The default survives without application help. `ADD COLUMN ... NOT NULL
--      DEFAULT 'USD'` gives every row that already exists — every user created
--      before this migration ran — the documented default as a matter of DDL.
--      A side table has no row for those users at all, so the default becomes a
--      COALESCE that every read site has to remember. One forgotten COALESCE is
--      a NULL currency reaching a formatter, and Intl does not reject unknown
--      codes: it renders them, so the failure surfaces as a plausible-looking
--      figure rather than an error.
--
--   2. The value can be constrained. A CHECK keeps a non-ISO-4217 string out of
--      the column entirely. In a key/value table the value column is TEXT for
--      every key at once and can hold anything.
--
--   3. It matches what this schema already does. 005_tenant_scan_preferences
--      added preference columns straight onto tenant_settings rather than
--      introducing a preferences table, and platform_users already carries
--      inline CHECK constraints for `role` and `status`.
--
-- A side table earns its keep when preferences are numerous, sparse, or added
-- without schema changes. One preference is none of those, and the simplicity
-- gate says start with the column. Should a dozen more arrive, moving them is a
-- migration — which is exactly the cost this defers rather than pays up front.
--
-- ── Scope ───────────────────────────────────────────────────────────────────
-- PER-USER, deliberately. tenant_settings already holds tenant-wide scan
-- preferences (005) and there is separate tenant preference machinery around
-- `tenant.preferences_updated`. Two people looking at the same fleet can want
-- different display currencies, and one of them changing it must not move the
-- other's numbers. Conflating the two would make that impossible.
--
-- 'USD' must agree with DEFAULT_CURRENCY in
-- dashboard-signalloom/src/money/currency.ts and with the demo-mode fixture in
-- api/fakeData.ts. All three say USD; if one moves they all move, or a user
-- sees one currency while the audit trail records another.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + guarded constraint creation, the same
-- shape as 005.

BEGIN;

ALTER TABLE IF EXISTS public.platform_users
    ADD COLUMN IF NOT EXISTS display_currency VARCHAR(3) NOT NULL DEFAULT 'USD';

DO $body$ BEGIN
  IF to_regclass('public.platform_users') IS NULL THEN
    RETURN;
  END IF;

  -- ISO 4217 alphabetic codes are exactly three uppercase letters. The
  -- constraint is on the SHAPE rather than an enumeration of codes: widening a
  -- list of supported currencies is a frontend concern, and a migration to add
  -- 'CHF' to a database CHECK would be pure ceremony. What must never land is a
  -- lowercase code, an empty string, or a stray symbol.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'platform_users_display_currency_iso4217'
  ) THEN
    ALTER TABLE public.platform_users
      ADD CONSTRAINT platform_users_display_currency_iso4217
      CHECK (display_currency ~ '^[A-Z]{3}$');
  END IF;
END $body$;

COMMIT;
