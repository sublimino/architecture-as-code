-- Migration: 007_segment_reidentification_map.sql
-- Card: SLDP-P3-1 — Remove cleartext identity from immutable columnar segments
--
-- Sequence claim. 005 is P2-1, 006 is P2-2. The header of 005 reserved 007 for P2-3, but P2-3
-- landed with no migration and no reference to 007 exists anywhere in the tree (verified by
-- `rg '007_' --type go --type sql`), so 007 is genuinely the next free number. SLDP-P3-2 is running
-- concurrently in a sibling worktree and also writes to this directory; by card order P3-1 takes
-- 007 and P3-2 takes 008. Recorded in the P3-1 errata for the phase Governor.
--
-- Purpose
--   SLDP-P3-1 removes six cleartext identifier columns from the FrostDB segment schema and replaces
--   them with keyed HMAC pseudonyms (segment column schema signalloom.observations/v2). That makes
--   the segment minimised, but it also makes it one-way: a pseudonym is a keyed digest, so nothing
--   in the columnar store can answer "which subject is this?".
--
--   The mapping has to live somewhere, and WHERE is the entire point. A Parquet segment is signed
--   and chained into a checkpoint, so it can never be rewritten or deleted without breaking
--   verification of everything after it — an Article 17 erasure request can therefore never reach
--   it. A Postgres row can be deleted, and a per-subject key can be destroyed. So the map lives
--   here, encrypted and tenant-scoped, where erasure has somewhere to land.
--
--   Erasure itself is NOT built here. SLDP-P3-2 (legal hold and dual-operator authorisation) and
--   SLDP-P4-1 (per-subject key hierarchy and the erasure saga) own that. This migration creates the
--   surface those cards act on.
--
-- Ordering
--   Runs after 006, which creates the tenant claim function and the RLS conventions this table
--   follows. It is additive: no existing table is altered.
--
-- Rollback: 007_segment_reidentification_map_rollback.sql

-- 1. The map itself.
--
--    identifier_encrypted is BYTEA holding AES-256-GCM envelope ciphertext, matching the
--    representation 005 introduced for aliases.alias_value_encrypted. There is deliberately no
--    cleartext column: 005 retained one only so a half-migrated table stayed diagnosable during a
--    backfill, and this table has nothing to backfill from.
CREATE TABLE IF NOT EXISTS segment_reidentification_map (
    id                   BIGSERIAL PRIMARY KEY,
    tenant_id            TEXT        NOT NULL,
    pseudonym_epoch      INTEGER     NOT NULL,
    tenant_scope         TEXT        NOT NULL,
    identifier_kind      TEXT        NOT NULL,
    pseudonym            VARCHAR(64) NOT NULL,
    identifier_encrypted BYTEA       NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    erased_at            TIMESTAMPTZ
);

COMMENT ON TABLE segment_reidentification_map IS
    'Re-identification map for pseudonymised columns in signalloom.observations/v2 segments. '
    'Deliberately relocated out of the immutable columnar store (SLDP-P3-1) because a signed '
    'Parquet segment cannot be rewritten, so erasure can never reach it. This table can be.';

COMMENT ON COLUMN segment_reidentification_map.pseudonym_epoch IS
    'Rotation epoch bound into the pseudonym. Without it a rotation would orphan every row, '
    'because the same subject maps to a different pseudonym after the epoch increments.';

COMMENT ON COLUMN segment_reidentification_map.identifier_encrypted IS
    'AES-256-GCM envelope ciphertext. The database never holds the key, matching migration 005.';

-- 2. Idempotency and the join key.
--
--    A pseudonym is only meaningful within a (tenant, scope, epoch) triple — that is exactly the
--    scope pseudonym.KeyRing derives its key over — so the uniqueness constraint is over all four
--    columns. Constraining on pseudonym alone would collide across epochs after a rotation.
CREATE UNIQUE INDEX IF NOT EXISTS idx_segment_reid_unique
    ON segment_reidentification_map (tenant_id, tenant_scope, pseudonym_epoch, pseudonym);

--    Reverse lookup for an erasure sweep: find every row for a subject across scopes.
CREATE INDEX IF NOT EXISTS idx_segment_reid_tenant_kind
    ON segment_reidentification_map (tenant_id, identifier_kind);

-- 3. Fail-closed shape constraint.
--
--    The pseudonym column must hold a well-formed 64-character lowercase hex digest — the same
--    shape check 005 applies to aliases.alias_value_hash. A truncated or cleartext value in this
--    column would be silently unjoinable rather than an error.
DO $$
BEGIN
    ALTER TABLE segment_reidentification_map
        ADD CONSTRAINT chk_segment_reid_pseudonym_shape
        CHECK (pseudonym ~ '^[0-9a-f]{64}$');
EXCEPTION
    WHEN duplicate_object THEN
        NULL; -- idempotent re-application
END
$$;

DO $$
BEGIN
    ALTER TABLE segment_reidentification_map
        ADD CONSTRAINT chk_segment_reid_ciphertext_nonempty
        CHECK (octet_length(identifier_encrypted) > 0);
EXCEPTION
    WHEN duplicate_object THEN
        NULL; -- idempotent re-application
END
$$;

-- 4. Tenant isolation.
--
--    ENABLE plus FORCE, following 006. FORCE matters here specifically: without it the table owner
--    bypasses every policy, and the application connects as the owner in most deployments — so an
--    unforced policy is a policy that never runs in production and always passes in a test run as
--    a non-owner.
ALTER TABLE segment_reidentification_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE segment_reidentification_map FORCE ROW LEVEL SECURITY;

--    The predicate reuses 006's app_current_tenant() helper rather than calling current_setting()
--    directly. The helper maps an empty string to NULL, so a connection that never set the claim
--    matches no rows instead of matching rows whose tenant_id happens to be ''. Inlining
--    current_setting() here would have been a second, subtly different definition of "the current
--    tenant" — and the two would drift.
DROP POLICY IF EXISTS segment_reid_tenant_isolation ON segment_reidentification_map;
CREATE POLICY segment_reid_tenant_isolation
    ON segment_reidentification_map
    USING (tenant_id = app_current_tenant())
    WITH CHECK (tenant_id = app_current_tenant());
