-- ══════════════════════════════════════════════════════════════════════════════
-- 058 — platform_users superadmin flag and partial index
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Adds is_superadmin boolean column to public.platform_users defaulting to FALSE.
-- Adds partial index on platform_users(email) WHERE is_superadmin = TRUE for fast
-- privileged account lookup without scanning ordinary user records.

BEGIN;

ALTER TABLE public.platform_users
    ADD COLUMN IF NOT EXISTS is_superadmin BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_platform_users_superadmin
    ON public.platform_users (email)
    WHERE is_superadmin = TRUE;

COMMIT;
