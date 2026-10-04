-- 053 — self-service invites and a server-side subject-to-tenant binding
--
-- Until now the only way a Dex subject reached a tenant was the
-- API_SUBJECT_TENANTS environment variable of the fe-signalloom Deployment: a
-- new pilot user was a Dex config edit plus a subject-map edit plus a rollout.
-- These two tables give the portal a data path for the second edit.
--
-- invites: one row per invitation a superadmin issued. Only the sha256 of the
-- one-time token is stored; the token itself is shown once in the response to
-- POST /api/v1/invites and never again. A row is spent when redeemed_at is set
-- and dead when expires_at has passed.
--
-- subject_tenants: the binding authenticated_principal consults BEFORE the
-- environment map. The column is named `tenant`, not `tenant_id`, on purpose:
-- tests/test_tenant_isolation.py derives its tenant-owned table set from
-- `tenant_id` columns and requires every statement against such a table to be
-- bound to the caller's tenant. Neither table is reachable by tenant: a subject
-- lookup is keyed by subject, an invite by its token hash, and the superadmin
-- who lists or creates invites is acting across tenants by design. Access is
-- gated by require_superadmin (create, list) and by the verified token subject
-- (redeem), never by a tenant predicate.

BEGIN;

CREATE TABLE IF NOT EXISTS public.invites (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash      TEXT        NOT NULL UNIQUE CHECK (btrim(token_hash) <> ''),
    email           TEXT        NOT NULL CHECK (btrim(email) <> ''),
    tenant          TEXT        NOT NULL CHECK (btrim(tenant) <> ''),
    created_by      TEXT        NOT NULL CHECK (btrim(created_by) <> ''),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    redeemed_by     TEXT,
    redeemed_at     TIMESTAMPTZ,
    CONSTRAINT invites_redeemed_together CHECK (
        (redeemed_by IS NULL AND redeemed_at IS NULL)
        OR (redeemed_by IS NOT NULL AND redeemed_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS invites_tenant_created_at_idx
    ON public.invites (tenant, created_at DESC);

CREATE TABLE IF NOT EXISTS public.subject_tenants (
    subject         TEXT        PRIMARY KEY CHECK (btrim(subject) <> ''),
    tenant          TEXT        NOT NULL CHECK (btrim(tenant) <> ''),
    bound_via       TEXT        NOT NULL CHECK (bound_via IN ('invite', 'operator')),
    bound_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
