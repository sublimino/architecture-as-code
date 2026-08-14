-- ══════════════════════════════════════════════════════════════════════════════
-- 020 — per-user preferences, and the first of them: display currency
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Every risk figure in the product is GBP at source and shown in the user's
-- chosen currency, defaulting to USD. That makes the preference part of what a
-- number on screen MEANS, so it has to be stored, not inferred.
--
-- ── Why a table, and not a column on platform_users ─────────────────────────
--
-- This is the FIRST per-user setting SignalLoom has ever had. platform_users
-- holds role, status, department and title — directory identity, nothing a user
-- chooses — and there is no existing preference storage to extend. So this
-- migration is not following a precedent, it is setting one, and it is written
-- for the settings that come after it rather than for this one alone.
--
-- A column on platform_users is cheaper today. It was the first design, and it
-- was reversed for three reasons:
--
--   1. The cheap-today argument was weaker than it looked. The case FOR a
--      column was that `NOT NULL DEFAULT 'USD'` makes the default a matter of
--      DDL, with no application fallback to forget. That turns out not to hold
--      here: a caller authenticated against this tenant may legitimately have
--      NO platform_users row at all — the directory is populated separately —
--      so the handler needs an application-level default for the missing-row
--      case regardless. Having paid that cost either way, the column buys much
--      less than it appeared to.
--
--   2. Cohesion. platform_users is the user DIRECTORY. Display preferences are
--      not directory data, and a column per preference grows a wide table that
--      mixes who someone is with how they like their screen. There are already
--      three browser-local per-user preferences in the dashboard (theme,
--      sidebar collapsed, load times) that will each want a home here, so
--      "the next one" is not hypothetical.
--
--   3. There is an exact structural precedent, and it is not platform_users.
--      tenant_settings (004) is a typed, scoped settings table for the TENANT.
--      This is its per-user twin: same shape, same idea, different scope.
--
-- Note what this is NOT: a generic key/value EAV table. Columns are typed and
-- constrained, so display_currency can carry a CHECK — which a TEXT `value`
-- column shared by every setting could never do. Each new preference is a
-- column here, which is a migration, which is the point: a preference worth
-- storing is worth declaring.
--
-- ── Keyed on the token identity, not on directory membership ────────────────
--
-- (tenant_id, user_email) rather than a foreign key to platform_users(id).
-- A user who can authenticate can hold a preference, whether or not anyone has
-- added them to the directory. An FK would make "your setting did not save
-- because you are absent from a table you have never heard of" a real
-- behaviour, and it is not a defensible one.
--
-- user_email holds Principal.actor — the email claim when Dex issues one, the
-- subject when it does not. Same convention as tenant_api_keys.revealed_by_email.
--
-- ── Scope ───────────────────────────────────────────────────────────────────
--
-- PER-USER, deliberately. Two people looking at the same fleet can want
-- different display currencies, and one of them changing it must not move the
-- other's board pack. The failure mode is not hypothetical: patch_cookie_
-- preferences currently stores a per-user cookie choice tenant-scoped, so one
-- user's preference silently overwrites everyone else's. That is what happens
-- when a user-scoped setting is bolted onto tenant-scoped storage, and this
-- table exists so the next one does not have to be.
--
-- 'USD' must agree with DEFAULT_DISPLAY_CURRENCY in api_compat.py,
-- DEFAULT_CURRENCY in dashboard-signalloom/src/money/currency.ts, and the demo
-- fixture in dashboard-signalloom/src/api/fakeData.ts. If one moves they all
-- move, or a user sees one currency while the audit trail records another.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + guarded trigger creation, the same
-- shape as 008.

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_preferences (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         TEXT        NOT NULL DEFAULT 'tenant-demo',
    -- Principal.actor: the email claim, or the subject when the token carries
    -- no email. Named for the common case, like revealed_by_email.
    user_email        TEXT        NOT NULL,

    -- ISO 4217 alphabetic codes are exactly three uppercase letters. The
    -- constraint is on the SHAPE rather than an enumeration of codes: which
    -- currencies the UI offers is a frontend concern, and a migration to add
    -- CHF to a database list would be ceremony. What must never land is a
    -- lowercase code, an empty string, or a stray symbol — Intl does not
    -- reject unknown currency codes, it RENDERS them, so a bad value that
    -- reaches storage reaches the screen looking like real money.
    display_currency  VARCHAR(3)  NOT NULL DEFAULT 'USD'
                                  CHECK (display_currency ~ '^[A-Z]{3}$'),

    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_preferences_tenant_email UNIQUE (tenant_id, user_email)
);

CREATE INDEX IF NOT EXISTS idx_user_preferences_tenant
    ON public.user_preferences (tenant_id);

DROP TRIGGER IF EXISTS set_user_preferences_updated_at ON public.user_preferences;
CREATE TRIGGER set_user_preferences_updated_at
    BEFORE UPDATE ON public.user_preferences
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMIT;
