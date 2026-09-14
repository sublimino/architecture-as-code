-- Migration: 006_tenant_isolation_rls.sql
-- Card: SLDP-P2-2 -- Tenant column and enforced row-level security on the identity graph.
-- Sequence 006 is reserved for this card by SLDP-P2-PRE section 3.2; 005 belongs to SLDP-P2-1.
--
-- Purpose: turn tenant isolation from an application-layer convention into a database-enforced
-- property. Before this migration the identity graph had no tenant column at all and the
-- repository issued seventeen SQL statements with no tenant predicate, so any caller that reached
-- the database read every tenant's actors, aliases and delegations.
--
-- Design note, and the reason this file changes no Go query text:
--   tenant_id carries a column DEFAULT sourced from the transaction-local GUC app.current_tenant.
--   Every pre-existing INSERT therefore keeps working byte-for-byte while acquiring the caller's
--   tenant, and the read side acquires its predicate from the row-level security policy rather
--   than from a rewritten WHERE clause. The two consequences that matter:
--     * a caller with no claim gets a NOT NULL violation on write and zero rows on read -- the
--       control fails closed, using a constraint that already existed;
--     * a correctly-scoped caller sees exactly the rows it saw before, which is what makes the
--       "no silent narrowing" assertion provable rather than hoped for.
--
-- Ordering note: every data-modifying step runs BEFORE row-level security is enabled. FORCE ROW
-- LEVEL SECURITY binds the table owner too, so enabling it first would make the backfill itself
-- subject to a policy whose claim is not set during a migration.

-- ---------------------------------------------------------------------------
-- 1. Claim accessors.
--
-- nullif(..., '') is not cosmetic. RESET ALL restores a custom GUC to the EMPTY STRING, not to
-- NULL (measured on PostgreSQL 16.14). Without the nullif, a connection that had been reset would
-- match every row whose tenant_id happened to be '', and a policy comparing against '' is a
-- policy that can be satisfied. Mapping empty to NULL makes "no claim" unsatisfiable, because
-- `tenant_id = NULL` is NULL and a policy predicate that is not TRUE denies.
--
-- These are STABLE and deliberately NOT SECURITY DEFINER: a SECURITY DEFINER accessor inside a
-- policy would execute with the definer's rights and is a standard RLS escalation route.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app_current_tenant() RETURNS text
    LANGUAGE sql
    STABLE
AS $$ SELECT nullif(current_setting('app.current_tenant', true), '') $$;

COMMENT ON FUNCTION app_current_tenant() IS
    'SLDP-P2-2: the tenant claim for the current transaction, or NULL when unset. Empty string maps to NULL so a RESET connection cannot match rows.';

CREATE OR REPLACE FUNCTION app_maintenance_reason() RETURNS text
    LANGUAGE sql
    STABLE
AS $$ SELECT nullif(current_setting('app.maintenance_reason', true), '') $$;

COMMENT ON FUNCTION app_maintenance_reason() IS
    'SLDP-P2-2: the declared reason for a cross-tenant maintenance session, or NULL when unset.';

-- The quarantine tenant. Rows that predate this migration cannot have their tenant determined --
-- there was no column to determine it from -- so they are assigned a reserved identifier that no
-- principal binding maps to, rather than to a live tenant. Assigning indeterminate rows to a real
-- tenant merges two estates invisibly and is not reversible, because the original attribution is
-- gone the moment it is overwritten.
CREATE OR REPLACE FUNCTION identity_quarantine_tenant() RETURNS text
    LANGUAGE sql
    IMMUTABLE
AS $$ SELECT '__unattributed__'::text $$;

COMMENT ON FUNCTION identity_quarantine_tenant() IS
    'SLDP-P2-2: reserved tenant identifier for rows that predate tenant attribution. No principal binding may map to it.';

-- ---------------------------------------------------------------------------
-- 2. Backfill report.
--
-- One row per pre-existing identity row whose tenant could not be determined, naming the row and
-- the reason. This exists so that "how many rows were quarantined, and which" is answerable after
-- the fact rather than inferred from a log line that has since rotated.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS identity_tenant_backfill_report (
    id              BIGSERIAL PRIMARY KEY,
    table_name      VARCHAR(64)  NOT NULL,
    row_key         VARCHAR(512) NOT NULL,
    assigned_tenant VARCHAR(255) NOT NULL,
    reason          TEXT         NOT NULL,
    backfilled_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_identity_backfill_row UNIQUE (table_name, row_key)
);

COMMENT ON TABLE identity_tenant_backfill_report IS
    'SLDP-P2-2: per-row record of identity rows quarantined during the tenant_id backfill.';

-- ---------------------------------------------------------------------------
-- 3. tenant_id column, backfill, default, NOT NULL -- four steps, in this order.
--
-- It cannot be one statement. ADD COLUMN ... NOT NULL DEFAULT app_current_tenant() evaluates the
-- default once, at migration time, when no claim is set; the default is STABLE so PostgreSQL takes
-- the fast path and writes that single value to every existing row. That value is NULL, and the
-- statement dies on its own NOT NULL constraint.
-- ---------------------------------------------------------------------------

ALTER TABLE actors      ADD COLUMN IF NOT EXISTS tenant_id VARCHAR(255);
ALTER TABLE aliases     ADD COLUMN IF NOT EXISTS tenant_id VARCHAR(255);
ALTER TABLE delegations ADD COLUMN IF NOT EXISTS tenant_id VARCHAR(255);

-- Report before backfilling: after the UPDATE there is no way to tell which rows were affected.
-- ON CONFLICT DO NOTHING keeps a re-run from duplicating entries; the WHERE tenant_id IS NULL
-- predicate means a second run finds nothing to report anyway.
INSERT INTO identity_tenant_backfill_report (table_name, row_key, assigned_tenant, reason)
SELECT 'actors', a.actor_id, identity_quarantine_tenant(),
       'row predates 006_tenant_isolation_rls.sql; no tenant column existed at insert time, and no other column in actors carries tenant attribution'
FROM actors a
WHERE a.tenant_id IS NULL
ON CONFLICT (table_name, row_key) DO NOTHING;

INSERT INTO identity_tenant_backfill_report (table_name, row_key, assigned_tenant, reason)
SELECT 'aliases', al.id::text, identity_quarantine_tenant(),
       'row predates 006_tenant_isolation_rls.sql; tenant is not derivable from actor_id because actors was itself unattributed'
FROM aliases al
WHERE al.tenant_id IS NULL
ON CONFLICT (table_name, row_key) DO NOTHING;

INSERT INTO identity_tenant_backfill_report (table_name, row_key, assigned_tenant, reason)
SELECT 'delegations', d.id::text, identity_quarantine_tenant(),
       'row predates 006_tenant_isolation_rls.sql; tenant is not derivable from delegate_actor_id or principal_actor_id because actors was itself unattributed'
FROM delegations d
WHERE d.tenant_id IS NULL
ON CONFLICT (table_name, row_key) DO NOTHING;

UPDATE actors      SET tenant_id = identity_quarantine_tenant() WHERE tenant_id IS NULL;
UPDATE aliases     SET tenant_id = identity_quarantine_tenant() WHERE tenant_id IS NULL;
UPDATE delegations SET tenant_id = identity_quarantine_tenant() WHERE tenant_id IS NULL;

ALTER TABLE actors      ALTER COLUMN tenant_id SET DEFAULT app_current_tenant();
ALTER TABLE aliases     ALTER COLUMN tenant_id SET DEFAULT app_current_tenant();
ALTER TABLE delegations ALTER COLUMN tenant_id SET DEFAULT app_current_tenant();

ALTER TABLE actors      ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE aliases     ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE delegations ALTER COLUMN tenant_id SET NOT NULL;

COMMENT ON COLUMN actors.tenant_id IS
    'SLDP-P2-2: owning tenant. Defaulted from app.current_tenant so an unclaimed write fails NOT NULL rather than landing unattributed.';
COMMENT ON COLUMN aliases.tenant_id IS
    'SLDP-P2-2: owning tenant. Defaulted from app.current_tenant so an unclaimed write fails NOT NULL rather than landing unattributed.';
COMMENT ON COLUMN delegations.tenant_id IS
    'SLDP-P2-2: owning tenant. Defaulted from app.current_tenant so an unclaimed write fails NOT NULL rather than landing unattributed.';

-- ---------------------------------------------------------------------------
-- 4. Tenant-leading composite indexes.
--
-- Row-level security adds `tenant_id = app_current_tenant()` to the front of every lookup on the
-- three hottest access paths in the identity graph. An index that does not lead with tenant_id
-- leaves that predicate as a filter applied after the scan. These mirror the existing temporal
-- indexes from 001 and 002 with tenant_id prepended.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_actors_tenant_actor
    ON actors (tenant_id, actor_id, created_at);

CREATE INDEX IF NOT EXISTS idx_aliases_tenant_actor_temporal
    ON aliases (tenant_id, actor_id, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_aliases_tenant_value_temporal
    ON aliases (tenant_id, alias_value, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_aliases_tenant_hash_temporal
    ON aliases (tenant_id, alias_value_hash, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_delegations_tenant_delegate_temporal
    ON delegations (tenant_id, delegate_actor_id, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_delegations_tenant_principal_temporal
    ON delegations (tenant_id, principal_actor_id, valid_from, valid_to);

-- ---------------------------------------------------------------------------
-- 5. Roles.
--
-- signal_identity_app is created by 001. What 001 does not do is pin the two attributes that
-- silently defeat every policy below: BYPASSRLS makes the policies decorative, and SUPERUSER
-- ignores them outright. Both are asserted here and again at runtime by
-- identity.AssertTenantIsolationPosture, because a migration proves what was set once and the
-- runtime assertion proves what is true now.
--
-- LOGIN is deliberately NOT granted. Which role the application authenticates as, and with what
-- credential, is deployment configuration; a migration that hands out a login is a migration that
-- creates a credential nobody rotates.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'signal_identity_app') THEN
        CREATE ROLE signal_identity_app;
    END IF;
    ALTER ROLE signal_identity_app NOSUPERUSER NOBYPASSRLS;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE WARNING 'SLDP-P2-2: cannot pin signal_identity_app attributes; verify NOBYPASSRLS out of band';
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'signal_identity_maintenance') THEN
        CREATE ROLE signal_identity_maintenance;
    END IF;
    ALTER ROLE signal_identity_maintenance NOSUPERUSER NOBYPASSRLS;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE WARNING 'SLDP-P2-2: cannot pin signal_identity_maintenance attributes; verify NOBYPASSRLS out of band';
END
$$;

DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE actors, aliases, delegations TO signal_identity_maintenance;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO signal_identity_maintenance;
    -- The backfill report names quarantined rows. The application role has no business reading it;
    -- the maintenance role does, because resolving quarantine is maintenance work.
    GRANT SELECT ON TABLE identity_tenant_backfill_report TO signal_identity_maintenance;
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        RAISE WARNING 'SLDP-P2-2: maintenance grants incomplete';
END
$$;

-- ---------------------------------------------------------------------------
-- 6. Row-level security. Last, for the ordering reason at the top of this file.
--
-- ENABLE turns policies on for everyone except the table owner; FORCE extends them to the owner.
-- Neither binds a SUPERUSER or a role with BYPASSRLS, which is why section 5 pins those attributes
-- and why any test that proves isolation must connect as a non-superuser, non-owner role. A test
-- run as postgres would observe every row and prove nothing.
--
-- There is no CREATE POLICY IF NOT EXISTS, so each policy is dropped first to stay idempotent.
-- ---------------------------------------------------------------------------

ALTER TABLE actors      ENABLE ROW LEVEL SECURITY;
ALTER TABLE actors      FORCE  ROW LEVEL SECURITY;
ALTER TABLE aliases     ENABLE ROW LEVEL SECURITY;
ALTER TABLE aliases     FORCE  ROW LEVEL SECURITY;
ALTER TABLE delegations ENABLE ROW LEVEL SECURITY;
ALTER TABLE delegations FORCE  ROW LEVEL SECURITY;

ALTER TABLE identity_tenant_backfill_report ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity_tenant_backfill_report FORCE  ROW LEVEL SECURITY;

-- Tenant isolation. USING governs what is readable and what an UPDATE may target; WITH CHECK
-- governs what may be written. Both are required: USING alone permits a caller to insert rows
-- tagged with another tenant that it then cannot see, which is a write-side leak.
--
-- The `<> identity_quarantine_tenant()` half closes a hole that the Go layer alone did not.
-- NewTenantClaim refuses to construct a claim naming the quarantine tenant, but the database has no
-- way to know a claim came from NewTenantClaim: anything that can reach set_config -- an injected
-- statement, a psql session, a future code path -- can set app.current_tenant to '__unattributed__'
-- and read every row the backfill quarantined. Excluding it in the policy makes the quarantine
-- reachable only through the maintenance policy below, which requires a different role AND a
-- declared reason.
DROP POLICY IF EXISTS tenant_isolation_actors ON actors;
CREATE POLICY tenant_isolation_actors ON actors
    USING (tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant())
    WITH CHECK (tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant());

DROP POLICY IF EXISTS tenant_isolation_aliases ON aliases;
CREATE POLICY tenant_isolation_aliases ON aliases
    USING (tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant())
    WITH CHECK (tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant());

DROP POLICY IF EXISTS tenant_isolation_delegations ON delegations;
CREATE POLICY tenant_isolation_delegations ON delegations
    USING (tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant())
    WITH CHECK (tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant());

-- The maintenance path.
--
-- Some operations legitimately cross tenants: resolving the quarantine above, investigating a
-- reported leak, honouring a regulator's request. An unscoped superuser session would do all of
-- those and would also reintroduce the hole this migration closes, under a different name. So the
-- crossing is made explicit on two axes at once -- it requires a DISTINCT ROLE, and that role must
-- declare a reason transaction-locally before it sees anything. A maintenance session that forgets
-- to declare a reason reads zero rows, exactly like an unclaimed application session.
--
-- Scoped TO signal_identity_maintenance rather than to PUBLIC: a permissive policy is ORed with
-- the tenant policy, so a PUBLIC-scoped version of this would hand every application session a
-- cross-tenant read the moment anything set the reason GUC.
DROP POLICY IF EXISTS maintenance_cross_tenant_actors ON actors;
CREATE POLICY maintenance_cross_tenant_actors ON actors
    TO signal_identity_maintenance
    USING (app_maintenance_reason() IS NOT NULL)
    WITH CHECK (app_maintenance_reason() IS NOT NULL);

DROP POLICY IF EXISTS maintenance_cross_tenant_aliases ON aliases;
CREATE POLICY maintenance_cross_tenant_aliases ON aliases
    TO signal_identity_maintenance
    USING (app_maintenance_reason() IS NOT NULL)
    WITH CHECK (app_maintenance_reason() IS NOT NULL);

DROP POLICY IF EXISTS maintenance_cross_tenant_delegations ON delegations;
CREATE POLICY maintenance_cross_tenant_delegations ON delegations
    TO signal_identity_maintenance
    USING (app_maintenance_reason() IS NOT NULL)
    WITH CHECK (app_maintenance_reason() IS NOT NULL);

DROP POLICY IF EXISTS maintenance_backfill_report ON identity_tenant_backfill_report;
CREATE POLICY maintenance_backfill_report ON identity_tenant_backfill_report
    TO signal_identity_maintenance
    USING (app_maintenance_reason() IS NOT NULL);

-- Deliberately absent: any policy on the three identity tables scoped TO PUBLIC, and any policy
-- whose predicate is a constant. Both would make the tables readable without a claim, which is the
-- state this migration exists to end.

-- ---------------------------------------------------------------------------
-- 7. Closing the referential-integrity existence oracle.
--
-- Row-level security does not constrain foreign-key checks. PostgreSQL runs referential integrity
-- as the table owner with row security bypassed, by design -- otherwise a policy could silently
-- break a constraint. The consequence here was measured on PostgreSQL 16.14 rather than inferred:
--
--   as signal_identity_app, claim = 't-b'
--   INSERT INTO delegations (..., principal_actor_id = 'p', ...)   -- 'p' belongs to tenant A
--     -> SUCCEEDS
--   INSERT INTO delegations (..., principal_actor_id = 'does-not-exist-anywhere', ...)
--     -> ERROR: violates foreign key constraint "delegations_principal_actor_id_fkey"
--
-- Two distinguishable outcomes for "another tenant has this actor_id" versus "nobody does", from a
-- session that can read neither. That is an enumeration oracle over the whole estate's actor
-- identifiers, and aliases.actor_id has the same shape.
--
-- The structural fix is a composite key -- actors (tenant_id, actor_id) -- so that the foreign key
-- is itself tenant-scoped. That is a breaking change to every foreign key and every query in
-- repository.go and is explicitly out of scope for this card, which is why it is handed to
-- SLDP-P2-GOV rather than attempted here.
--
-- What IS in scope is making the two outcomes indistinguishable. A BEFORE ROW trigger runs before
-- the referential-integrity check, and its subquery IS subject to row-level security, so it sees
-- only the caller's own tenant. Both cases therefore produce the same message with the same
-- SQLSTATE, and a cross-tenant reference is refused outright rather than quietly created.
--
-- Note this is strictly narrower than an isolation policy: it constrains what may be WRITTEN. It
-- does not, and cannot, stop the planner or a constraint from knowing the other tenant's row is
-- there. Do not read it as a substitute for the composite key.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_tenant_scoped_actor_reference() RETURNS TRIGGER AS $$
DECLARE
    missing_actor TEXT;
BEGIN
    IF TG_TABLE_NAME = 'aliases' THEN
        IF NOT EXISTS (SELECT 1 FROM actors WHERE actor_id = NEW.actor_id) THEN
            missing_actor := NEW.actor_id;
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM actors WHERE actor_id = NEW.delegate_actor_id) THEN
            missing_actor := NEW.delegate_actor_id;
        ELSIF NOT EXISTS (SELECT 1 FROM actors WHERE actor_id = NEW.principal_actor_id) THEN
            missing_actor := NEW.principal_actor_id;
        END IF;
    END IF;

    IF missing_actor IS NOT NULL THEN
        -- The wording must not distinguish "owned by another tenant" from "does not exist". That
        -- indistinguishability is the entire control; a more helpful message reopens the oracle.
        RAISE EXCEPTION 'referenced actor % does not exist', missing_actor
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_aliases_tenant_scoped_actor ON aliases;
CREATE TRIGGER trg_aliases_tenant_scoped_actor
    BEFORE INSERT OR UPDATE ON aliases
    FOR EACH ROW
    EXECUTE FUNCTION check_tenant_scoped_actor_reference();

DROP TRIGGER IF EXISTS trg_delegations_tenant_scoped_actor ON delegations;
CREATE TRIGGER trg_delegations_tenant_scoped_actor
    BEFORE INSERT OR UPDATE ON delegations
    FOR EACH ROW
    EXECUTE FUNCTION check_tenant_scoped_actor_reference();
