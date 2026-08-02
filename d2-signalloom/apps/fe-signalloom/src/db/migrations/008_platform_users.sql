-- Migration: 008_platform_users
-- Adds platform user management tables and links agent ownership.
--
-- Tables created (2):
--   1. platform_users  — tenant-scoped user directory
--   2. user_roles      — future RBAC expansion (roles × scopes)
--
-- Columns added (1):
--   agent_registry.owner_id — FK to platform_users for ownership reconciliation
--
-- Design notes:
--   - "platform_users" avoids collision with pg_catalog.pg_user
--   - role column uses a simple CHECK constraint (admin/editor/viewer)
--   - user_roles table is schema-only foundation for row-level access;
--     no RLS policies are created here (single-tenant demo)
--   - agent_registry.owner (TEXT) is preserved for display; owner_id is
--     the relational link for permission checks
--   - Library-agnostic: works with PostgreSQL RLS, CASL, Casbin, or Cerbos

BEGIN;

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. platform_users
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.platform_users (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT        NOT NULL DEFAULT 'tenant-demo',
    email           TEXT        NOT NULL,
    display_name    TEXT        NOT NULL,
    role            TEXT        NOT NULL DEFAULT 'viewer'
                                CHECK (role IN ('admin', 'editor', 'viewer')),
    status          TEXT        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'invited', 'suspended', 'deactivated')),
    avatar_url      TEXT,
    department      TEXT,
    title           TEXT,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_platform_users_tenant_email UNIQUE (tenant_id, email)
);

CREATE INDEX IF NOT EXISTS idx_platform_users_tenant
    ON public.platform_users (tenant_id);

CREATE INDEX IF NOT EXISTS idx_platform_users_email
    ON public.platform_users (email);

CREATE TRIGGER set_platform_users_updated_at
    BEFORE UPDATE ON public.platform_users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. user_roles (RBAC foundation — not enforced in demo)
-- ══════════════════════════════════════════════════════════════════════════════
-- Designed for future row-level access control:
--   scope = 'tenant' → tenant-wide role
--   scope = 'team'   → team-scoped role (scope_id = team name)
--   scope = 'agent'  → per-agent permission (scope_id = agent UUID)
--
-- No RLS policies reference this table yet. When enforcement lands:
--   SET app.current_user_id = '<uuid>';
--   RLS policy: WHERE agent_registry.owner_id = current_setting('app.current_user_id')::uuid
--               OR EXISTS (SELECT 1 FROM user_roles WHERE ...)

CREATE TABLE IF NOT EXISTS public.user_roles (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES public.platform_users(id) ON DELETE CASCADE,
    tenant_id   TEXT        NOT NULL DEFAULT 'tenant-demo',
    role        TEXT        NOT NULL CHECK (role IN ('admin', 'editor', 'viewer')),
    scope       TEXT        NOT NULL DEFAULT 'tenant'
                            CHECK (scope IN ('tenant', 'team', 'agent')),
    scope_id    TEXT,
    granted_by  UUID        REFERENCES public.platform_users(id),
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_roles_assignment UNIQUE (user_id, tenant_id, role, scope, scope_id)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_user
    ON public.user_roles (user_id);

CREATE INDEX IF NOT EXISTS idx_user_roles_scope
    ON public.user_roles (tenant_id, scope, scope_id);

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Add owner_id FK to agent_registry
-- ══════════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'agent_registry'
          AND column_name = 'owner_id'
    ) THEN
        ALTER TABLE public.agent_registry
            ADD COLUMN owner_id UUID REFERENCES public.platform_users(id);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_registry_owner_id
    ON public.agent_registry (owner_id);

COMMIT;
