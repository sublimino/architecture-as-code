-- 077 — tenant_feature_flag_versions: one write version per tenant's flag set
--
-- Every flag mutation through the admin API (PUT /api/v1/admin/features and
-- PUT /api/v1/admin/features/{flag_key}) runs as one transaction that starts
-- by upserting this tenant's row:
--
--   INSERT ... VALUES ($1, 1) ON CONFLICT (tenant_id)
--     DO UPDATE SET version = version + 1 RETURNING version
--
-- That statement does two jobs.
--
-- * It serialises the tenant's flag mutations. The upsert takes the row lock
--   (or, for a tenant's first write, the unique-index entry) and holds it until
--   commit, so a second mutation for the same tenant waits at its first
--   statement. Other tenants are unaffected. The flag row write, the account
--   type re-derivation (074's `customised`, recomputed from the committed flag
--   set) and the audit event therefore commit together, from one consistent
--   view; before this, three autocommit statements let a toggle write back a
--   `customised` or `account_type` read before a concurrent change landed.
--
-- * It numbers the result. The returned version is strictly increasing per
--   tenant in commit order, and the API returns it with the flag state it
--   produced, so the Feature Flags page can drop a reply older than the one it
--   already shows (replies to concurrent requests arrive in any order).
--
-- The flag rows themselves stay one row per flag (057): toggling one flag
-- writes only that flag's row, never the whole set.
--
-- A tenant with no row has never had an admin flag mutation: version 0.
BEGIN;

CREATE TABLE IF NOT EXISTS public.tenant_feature_flag_versions (
    tenant_id  VARCHAR(128) PRIMARY KEY,
    version    BIGINT       NOT NULL DEFAULT 0 CHECK (version >= 0),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMIT;
