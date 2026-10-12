-- ══════════════════════════════════════════════════════════════════════════════
-- 062 — the risk profile a tenant DECLARES about itself at onboarding
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Backs PATCH /api/tenant/settings/risk-profile and the identity step of the
-- onboarding wizard, which until now collected an organisation profile
-- (organizationName, workspaceId, adminEmail, environment, description) and
-- threw every field away — it never reached wizard_state, let alone a column.
--
-- ── What these five columns are, and why they are these five ────────────────
--
-- They are the subset of `OrgRiskPosture` (tools/riskctl/internal/model/
-- model.go) that an institution can honestly state about ITSELF on day one:
--
--   risk/org/acme.yaml field          column here
--   ────────────────────────────────  ──────────────────────────
--   metadata.sector                   sector
--   metadata.jurisdiction             jurisdiction
--   currency                          reporting_currency
--   appetite.tolerance                risk_appetite_tolerance
--   risk_load                         risk_load
--
-- Deliberately NOT here: the per-scenario `magnitude` triples. Those are the
-- institution's half of the pricing split (acme.yaml:3-6 — the policy pack owns
-- loss event FREQUENCY, the institution owns loss MAGNITUDE), and every one of
-- them carries MANDATORY `provenance` prose because an unsourced number is not
-- reviewable. A wizard cannot elicit a calibrated triple with a defensible
-- anchor class from someone clicking through onboarding, and a fabricated
-- triple is strictly worse than no triple: it would price agent risk in pounds
-- that nobody can argue with because nobody wrote down where they came from.
-- Magnitudes stay in reviewed, version-controlled YAML.
--
-- ── Typed columns on tenant_settings, not EAV and not wizard_state ──────────
--
-- Three doctrines in this schema already decided the shape:
--
--   * 020_user_preferences.sql:40-44 — "a preference worth storing is worth
--     declaring". Not a key/value EAV table: typed columns can carry a CHECK,
--     a shared TEXT `value` column never can.
--   * 006_onboarding.sql:14-24 — org configuration does NOT belong on
--     tenant_onboarding. wizard_state churns on every step change; this is
--     stable org configuration and belongs on the stable row.
--   * 005_tenant_scan_preferences.sql — the exact precedent for adding a
--     declared field to tenant_settings via an onboarding step.
--
-- ── EVERY COLUMN IS NULLABLE, WITH NO DEFAULT. That is load-bearing ─────────
--
-- A tenant that declines to declare must stay valid, and must stay
-- INDISTINGUISHABLE FROM ONE THAT HAS NOT BEEN ASKED. There is deliberately no
-- `DEFAULT 0.10` for risk_load and no `DEFAULT 'GBP'` for reporting_currency,
-- even though those are the values the engine uses today, because a default
-- here would be a posture the tenant never stated — and the moment it is a
-- column with a value, something downstream will price with it. NULL means
-- "undeclared", the engine falls back to its own documented constant, and no
-- existing figure moves unless a tenant opts in.
--
-- The jurisdiction semantics follow from the same reasoning and are NOT
-- invented here: `Scenario.AppliesTo` (model.go:153-163) excludes a scoped
-- scenario when the institution states no jurisdiction, rather than assuming
-- it applies. Silence must never read as a match. So NULL here scopes NOTHING,
-- which is why '*' is spellable — declaring global operation is an affirmative
-- act and is not the same as saying nothing.
--
-- ── Why the currency CHECK is a shape check, and what it is NOT ─────────────
--
-- `^[A-Z]{3}$` is a FLOOR, not the real validation. The binding constraint is
-- the FX rate table (risk/fx/rates.yaml): a currency with no rate renders every
-- figure as Unavailable. The closed set lives in the handler as
-- SUPPORTED_DISPLAY_CURRENCIES, which tests/test_user_currency_renderable.py
-- holds equal to SUPPORTED_CURRENCIES in currency.ts. Both layers exist on
-- purpose:
--
--   * the handler's closed set stops a renderable-but-unpriceable code (XXX is
--     a real ISO assignment meaning "no currency"; XAU is gold);
--   * this CHECK binds EVERY writer, including a migration, a fixture or a
--     psql session that never passes through the handler.
--
-- The failure this prevents is not a 500. Intl.NumberFormat RENDERS an
-- unrecognised code instead of throwing, so an unvalidated code arrives on
-- screen looking like real money (020_user_preferences.sql makes the same
-- point about display_currency).
--
-- ── Why `< 'Infinity'` and not just `>= 0` ──────────────────────────────────
--
-- PostgreSQL sorts NaN ABOVE every other value, so `'NaN'::float8 >= 0` is TRUE
-- and `'NaN'::numeric > 0` is TRUE. A naive non-negativity check therefore
-- admits NaN, which then propagates through `tvar * (1 + risk_load)` and yields
-- a carried figure that passes every structural check and is not a number
-- anyone can use — the same trap LoadOrgRiskPosture guards with
-- math.IsNaN/IsInf at the YAML boundary. `< 'Infinity'` is what rejects it,
-- because NaN compares as greater than Infinity, and it excludes +Inf in the
-- same breath. Verified against postgres:16 rather than reasoned about.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + guarded constraint creation, the same
-- shape as 005.

BEGIN;

ALTER TABLE IF EXISTS public.tenant_settings
    ADD COLUMN IF NOT EXISTS sector                  TEXT,
    ADD COLUMN IF NOT EXISTS jurisdiction            TEXT,
    ADD COLUMN IF NOT EXISTS reporting_currency      TEXT,
    ADD COLUMN IF NOT EXISTS risk_appetite_tolerance NUMERIC(20, 2),
    ADD COLUMN IF NOT EXISTS risk_load               DOUBLE PRECISION;

DO $body$ BEGIN
  IF to_regclass('public.tenant_settings') IS NULL THEN
    RETURN;
  END IF;

  -- An ISO-4217-shaped code, or nothing. See the header for why this is a floor
  -- and not the whole validation.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_reporting_currency_shape'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_reporting_currency_shape
      CHECK (reporting_currency IS NULL OR reporting_currency ~ '^[A-Z]{3}$');
  END IF;

  -- Finite and non-negative. Zero is a coherent posture: carry the tail with no
  -- load on top.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_risk_load_finite_non_negative'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_risk_load_finite_non_negative
      CHECK (
        risk_load IS NULL
        OR (risk_load >= 0 AND risk_load < 'Infinity'::double precision)
      );
  END IF;

  -- Strictly positive when stated: without a tolerance band a number cannot
  -- become a verdict (model.go, appetite.tolerance).
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_risk_appetite_tolerance_positive'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_risk_appetite_tolerance_positive
      CHECK (
        risk_appetite_tolerance IS NULL
        OR (risk_appetite_tolerance > 0 AND risk_appetite_tolerance < 'Infinity'::numeric)
      );
  END IF;

  -- A blank string must not be storable as though it were a declaration. A
  -- whitespace-only jurisdiction trims to empty, which AppliesTo treats as "no
  -- jurisdiction stated" — so it would behave as NULL while reading as declared.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_sector_non_blank'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_sector_non_blank
      CHECK (sector IS NULL OR btrim(sector) <> '');
  END IF;

  -- Canonical form, so 'uk' and 'UK' cannot both exist. AppliesTo compares
  -- case-insensitively and trimmed, so storing both buys nothing and makes two
  -- rows that differ only by case — a data trap, not a feature (model.go:147).
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tenant_settings_jurisdiction_canonical'
  ) THEN
    ALTER TABLE public.tenant_settings
      ADD CONSTRAINT tenant_settings_jurisdiction_canonical
      CHECK (
        jurisdiction IS NULL
        OR (btrim(jurisdiction) <> '' AND jurisdiction = upper(btrim(jurisdiction)))
      );
  END IF;
END $body$;

COMMIT;
