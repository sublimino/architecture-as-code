-- Rollback: 006_tenant_isolation_rls_rollback.sql
-- Card: SLDP-P2-2 / SLDP-P2-GOV
--
-- Reverses 006_tenant_isolation_rls.sql.
-- Disables row-level security, drops tenant policies, removes tenant-scoped triggers,
-- drops tenant-leading indexes, removes tenant_id columns, and cleans up accessors
-- and the backfill report table.
--
-- SECURITY NOTE: Rolling back removes database-enforced multi-tenant isolation,
-- returning identity tables to shared unconfined state. This should only be used
-- in incident-response or disaster-recovery procedures.

-- 1. Drop referential integrity existence oracle triggers and function
DROP TRIGGER IF EXISTS trg_delegations_tenant_scoped_actor ON delegations;
DROP TRIGGER IF EXISTS trg_aliases_tenant_scoped_actor ON aliases;
DROP FUNCTION IF EXISTS check_tenant_scoped_actor_reference();

-- 2. Drop RLS policies
DROP POLICY IF EXISTS tenant_isolation_actors ON actors;
DROP POLICY IF EXISTS tenant_isolation_aliases ON aliases;
DROP POLICY IF EXISTS tenant_isolation_delegations ON delegations;
DROP POLICY IF EXISTS maintenance_cross_tenant_actors ON actors;
DROP POLICY IF EXISTS maintenance_cross_tenant_aliases ON aliases;
DROP POLICY IF EXISTS maintenance_cross_tenant_delegations ON delegations;
DROP POLICY IF EXISTS maintenance_backfill_report ON identity_tenant_backfill_report;

-- 3. Disable and unforce row-level security
ALTER TABLE actors NO FORCE ROW LEVEL SECURITY;
ALTER TABLE actors DISABLE ROW LEVEL SECURITY;
ALTER TABLE aliases NO FORCE ROW LEVEL SECURITY;
ALTER TABLE aliases DISABLE ROW LEVEL SECURITY;
ALTER TABLE delegations NO FORCE ROW LEVEL SECURITY;
ALTER TABLE delegations DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS identity_tenant_backfill_report NO FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS identity_tenant_backfill_report DISABLE ROW LEVEL SECURITY;

-- 4. Drop tenant-leading composite indexes
DROP INDEX IF EXISTS idx_actors_tenant_actor;
DROP INDEX IF EXISTS idx_aliases_tenant_actor_temporal;
DROP INDEX IF EXISTS idx_aliases_tenant_value_temporal;
DROP INDEX IF EXISTS idx_aliases_tenant_hash_temporal;
DROP INDEX IF EXISTS idx_delegations_tenant_delegate_temporal;
DROP INDEX IF EXISTS idx_delegations_tenant_principal_temporal;

-- 5. Drop column defaults and tenant_id columns
ALTER TABLE actors ALTER COLUMN tenant_id DROP DEFAULT;
ALTER TABLE aliases ALTER COLUMN tenant_id DROP DEFAULT;
ALTER TABLE delegations ALTER COLUMN tenant_id DROP DEFAULT;

ALTER TABLE actors DROP COLUMN IF EXISTS tenant_id;
ALTER TABLE aliases DROP COLUMN IF EXISTS tenant_id;
ALTER TABLE delegations DROP COLUMN IF EXISTS tenant_id;

-- 6. Drop backfill report and helper functions
DROP TABLE IF EXISTS identity_tenant_backfill_report;
DROP FUNCTION IF EXISTS identity_quarantine_tenant();
DROP FUNCTION IF EXISTS app_maintenance_reason();
DROP FUNCTION IF EXISTS app_current_tenant();
