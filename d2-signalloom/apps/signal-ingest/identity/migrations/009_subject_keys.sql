-- ===========================================================================
-- Migration 009 — per-subject key hierarchy and erasure saga journal (SLDP-P4-1)
-- ===========================================================================
--
-- SEQUENCE CLAIM. 009 is claimed by SLDP-P4-1, in writing, here and in the proposal errata.
-- SLDP-P4-PRE §5.4 assigned it; SLDP-P4-2 runs concurrently in a separate worktree and must take
-- 010. The 008 collision (identity/migrations.go:59-61) happened precisely because two worktrees
-- could not see each other's tree, so a number is claimed in a document both can read, never
-- inferred from `ls`.
--
-- WHAT THIS EXISTS FOR.
--
--   Before this card every envelope in the identity graph wrapped its per-record data key under ONE
--   global service root key (identity/encryption.go, AESGCMEncryptor.key). Destroying it erases
--   every subject in every tenant at once and breaks all operational access; not destroying it
--   erases nobody. "Crypto-shredding" on that layout is a claim that cannot be true.
--
--   These two tables are the crypto-shred boundary. subject_keys holds ONE random data encryption
--   key per subject per version, stored only in wrapped form under an HKDF-derived tenant KEK. The
--   tenant KEK has no row here and never will: it is derived on demand, so the per-subject erasure
--   path has nothing to reach even if someone tried to make it.
--
-- WHY THE KEY IS RANDOM AND NOT DERIVED, since the derived design is the tidier one.
--
--   DEK = HKDF(tenant_kek, subject_pseudonym) needs no table, no version column and no provisioning
--   step, and it draws an identical architecture diagram. It also makes erasure impossible: anyone
--   holding the master key re-derives the DEK after "destruction". A derived key cannot be
--   destroyed. That asymmetry is the whole design — derivation is correct for the tenant key, which
--   must survive, and fatal for the subject key, which must not.
--
-- WHAT DESTRUCTION HERE DOES AND DOES NOT ACHIEVE, stated so nobody has to infer it.
--
--   Destroying a subject key removes the ability to RESOLVE that subject's ciphertext. It does not
--   remove the ciphertext, and it cannot remove a pseudonym already written into a signed, chained
--   Parquet segment -- rewriting one would break checkpoint continuity for everything after it.
--     * Article 17 (erasure): satisfied, by loss of resolvability.
--     * Article 5(1)(e) (storage limitation): NOT satisfied. Reconciling retention deletion with the
--       checkpoint chain is SLDP-P6-1's retention controller, not this card.
--   Further, overwriting wrapped_dek writes a NEW tuple version: the prior version holding the live
--   wrapped key stays on disk until VACUUM, and WAL and physical backups hold further copies. Every
--   DestructionReceipt records this as storage_residual rather than claiming bit-level erasure.
--
-- ROWS ARE OVERWRITTEN, NEVER DELETED.
--
--   A deleted row proves nothing: absence is equally consistent with "destroyed", "never existed"
--   and "the query was wrong". A row that is present, flagged destroyed, whose bytes refuse to
--   unwrap, and whose digest differs from the pre-destruction digest recorded in the receipt, is
--   positive evidence. subjectkey.VerifyDestroyed reads exactly those four facts.
--
-- Ordering note, inherited from 006 and 008: every data-modifying step precedes ENABLE/FORCE ROW
-- LEVEL SECURITY, because FORCE binds the table owner too.
--
-- Idempotency: every object is created IF NOT EXISTS and every policy is dropped before creation,
-- so re-running ApplyMigrations leaves the schema identical. This migration creates only new
-- objects and modifies no existing table's data or definition.
--
-- No CHECK constraint below contains a subquery. PostgreSQL 16 rejects those at DDL time with
-- "cannot use subquery in check constraint", and ApplyMigrations runs every migration inside ONE
-- transaction -- so a single unapplyable constraint would abort the whole migration and silently
-- leave every table in this file uncreated.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Per-subject wrapped data encryption keys.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS subject_keys (
    tenant_id            TEXT        NOT NULL DEFAULT app_current_tenant(),
    subject_pseudonym    TEXT        NOT NULL,
    key_epoch            INTEGER     NOT NULL DEFAULT 0,
    key_version          INTEGER     NOT NULL,
    -- The wrapped DEK: 12-byte GCM nonce + 32-byte AES-256 key + 16-byte tag. After destruction
    -- this column holds cryptographically random bytes of the SAME length, so a length check cannot
    -- be used to distinguish a live key from a destroyed one by inspection.
    wrapped_dek          BYTEA       NOT NULL,
    -- SHA-256 of wrapped_dek as it stood immediately BEFORE destruction, written at destruction
    -- time. It is what lets a RESUMED saga reproduce the original receipt digest byte for byte:
    -- without it, a resume would have nothing to digest but the random overwrite, which differs on
    -- every run and would silently break agreement with SLDP-P4-2's tombstone.
    prior_wrapped_digest TEXT        NOT NULL DEFAULT '',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    destroyed_at         TIMESTAMPTZ NULL,

    -- The scope is the identity. A pseudonym is only meaningful within a (tenant, epoch) pair --
    -- exactly the scope subjectkey.Hierarchy derives its tenant KEK over -- so all four columns are
    -- in the key. Constraining on pseudonym alone would collide across epochs after a rotation.
    CONSTRAINT subject_keys_pk
        PRIMARY KEY (tenant_id, subject_pseudonym, key_epoch, key_version),

    -- Fail-closed shape check, matching 005 and 007: a truncated or cleartext value here would be
    -- silently unjoinable rather than an error, and a CLEARTEXT subject identifier in this column
    -- would turn the key store into a re-identification corpus.
    CONSTRAINT subject_keys_pseudonym_shape
        CHECK (subject_pseudonym ~ '^[0-9a-f]{64}$'),

    CONSTRAINT subject_keys_version_positive
        CHECK (key_version > 0),

    CONSTRAINT subject_keys_epoch_non_negative
        CHECK (key_epoch >= 0),

    -- 60 = 12 + 32 + 16. Pinning the length turns a variable an attacker could influence into a
    -- checked constant and removes the length-confusion class.
    CONSTRAINT subject_keys_wrapped_length
        CHECK (octet_length(wrapped_dek) = 60),

    -- THE FAIL-CLOSED BACKSTOP. A row flagged destroyed with no prior digest cannot reproduce its
    -- own receipt, so a resumed saga would emit a digest disagreeing with the tombstone SLDP-P4-2
    -- already published. Refusing the row at the database is the only place this cannot be bypassed
    -- by a code path that forgot.
    CONSTRAINT subject_keys_destroyed_carries_digest
        CHECK (destroyed_at IS NULL OR prior_wrapped_digest <> ''),

    CONSTRAINT subject_keys_digest_shape
        CHECK (prior_wrapped_digest = '' OR prior_wrapped_digest ~ '^[0-9a-f]{64}$'),

    CONSTRAINT subject_keys_destroyed_after_created
        CHECK (destroyed_at IS NULL OR destroyed_at >= created_at)
);

-- The erasure sweep's access path: every version for one subject, in order.
CREATE INDEX IF NOT EXISTS idx_subject_keys_subject
    ON subject_keys (tenant_id, subject_pseudonym, key_version);

-- The live-key access path, used when provisioning to count versions against
-- subjectkey.MaxKeyVersionsPerSubject.
CREATE INDEX IF NOT EXISTS idx_subject_keys_live
    ON subject_keys (tenant_id, subject_pseudonym)
    WHERE destroyed_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. The erasure saga journal.
--
--    Key destruction is irreversible, so a retried step that double-applies cannot be undone.
--    Idempotency is therefore a precondition of correctness here, not a refinement of it, and this
--    table is where it lives: operation_id is deterministic in (tenant, subject pseudonym), so two
--    Article 17 requests naming the same subject resolve to ONE operation, one destruction and one
--    tombstone.
--
--    The request identifier is deliberately NOT part of operation_id. Including it would start a
--    second saga for a re-submitted request, which destroys nothing (already destroyed) and then
--    emits a SECOND receipt and a second tombstone -- one destruction, two tombstones, exactly the
--    divergence this card exists to prevent.
--
--    THE INVARIANT, STATED EXACTLY. It is not "the journal and the key store are never divergent":
--    two durable systems with a non-atomic crossing will, under a crash between them, show keys
--    destroyed with no receipt recorded, and no ordering removes that. What holds is:
--      (a) a receipt digest is never recorded while a targeted version is still live -- the state
--          ladder gives this, because receipt_recorded is reachable only from caches_cleared, which
--          is reachable only from keys_destroyed, which the saga enters only after READING BACK
--          every targeted version as destroyed;
--      (b) destruction without a recorded receipt is durably VISIBLE here and resumable;
--      (c) a resume converges on a byte-identical digest, because every digest input is read back
--          from durable state and the nonce is persisted in this row.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS subject_key_erasures (
    operation_id      TEXT        PRIMARY KEY,
    tenant_id         TEXT        NOT NULL DEFAULT app_current_tenant(),
    subject_pseudonym TEXT        NOT NULL,
    state             TEXT        NOT NULL DEFAULT 'pending',
    -- The version set snapshotted when the saga entered 'pending'. A version provisioned afterwards
    -- is caught by comparing this against a live re-read: widened while still 'pending', refused
    -- once the saga has certified every targeted version destroyed.
    target_versions   INTEGER[]   NOT NULL DEFAULT '{}',
    -- Persisted so a resumed saga reproduces the same receipt digest. It is also what stops the
    -- digest being a re-identification oracle: without a random salt, a digest over a small,
    -- guessable field set can be ground out from a candidate subject identifier, which would defeat
    -- the non-linkability requirement in SLDP-P4-PRE §6.1.
    nonce             TEXT        NOT NULL,
    receipt_digest    TEXT        NOT NULL DEFAULT '',
    started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at      TIMESTAMPTZ NULL,

    -- The enumeration is the Go one in subjectkey/store.go (SagaStates), and
    -- TestMigration009_StateCheckMatchesGo compares this SQL text against that slice rather than
    -- against a second hand-written list -- a guard that copies its source of truth drifts from it.
    CONSTRAINT subject_key_erasures_state_enumerated
        CHECK (state IN ('pending', 'keys_destroyed', 'caches_cleared', 'receipt_recorded', 'completed')),

    CONSTRAINT subject_key_erasures_pseudonym_shape
        CHECK (subject_pseudonym ~ '^[0-9a-f]{64}$'),

    CONSTRAINT subject_key_erasures_operation_id_shape
        CHECK (operation_id ~ '^[0-9a-f]{64}$'),

    CONSTRAINT subject_key_erasures_nonce_shape
        CHECK (nonce ~ '^[0-9a-f]{64}$'),

    CONSTRAINT subject_key_erasures_digest_shape
        CHECK (receipt_digest = '' OR receipt_digest ~ '^[0-9a-f]{64}$'),

    -- A completed saga with no digest would be a destruction nobody can attest. Refused here so the
    -- state cannot be reached by a code path that skipped the receipt.
    CONSTRAINT subject_key_erasures_completed_carries_digest
        CHECK (state <> 'completed' OR receipt_digest <> ''),

    -- receipt_recorded is the earliest state at which a digest may exist, and it must.
    CONSTRAINT subject_key_erasures_recorded_carries_digest
        CHECK (state NOT IN ('receipt_recorded', 'completed') OR receipt_digest <> ''),

    CONSTRAINT subject_key_erasures_completed_at_set
        CHECK (state <> 'completed' OR completed_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_subject_key_erasures_subject
    ON subject_key_erasures (tenant_id, subject_pseudonym);

-- Operational sweep: find sagas stuck mid-flight. This is how case (b) above stops being invisible.
CREATE INDEX IF NOT EXISTS idx_subject_key_erasures_incomplete
    ON subject_key_erasures (tenant_id, state, updated_at)
    WHERE state <> 'completed';

-- ---------------------------------------------------------------------------
-- 3. Row-level security, matching the 006 and 008 pattern exactly.
--
-- FORCE removes the TABLE OWNER's exemption, so an owner connection with no app.current_tenant
-- claim reads zero rows rather than every tenant's. FORCE does NOT bind a SUPERUSER or a role with
-- BYPASSRLS. The application role must be neither owner nor superuser;
-- identity/tenant_live_test.go:TestTenantIsolationPosture_AppRoleIsNeitherOwnerNorBypass asserts
-- exactly that against a live database.
--
-- For THIS table the failure mode of a missing claim is the good one: a reader with no claim sees
-- zero key rows and therefore cannot unwrap anything, rather than seeing every tenant's keys.
-- ---------------------------------------------------------------------------

ALTER TABLE subject_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE subject_keys FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS subject_keys_tenant_isolation ON subject_keys;
CREATE POLICY subject_keys_tenant_isolation ON subject_keys
    USING (tenant_id = app_current_tenant())
    WITH CHECK (tenant_id = app_current_tenant());

ALTER TABLE subject_key_erasures ENABLE ROW LEVEL SECURITY;
ALTER TABLE subject_key_erasures FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS subject_key_erasures_tenant_isolation ON subject_key_erasures;
CREATE POLICY subject_key_erasures_tenant_isolation ON subject_key_erasures
    USING (tenant_id = app_current_tenant())
    WITH CHECK (tenant_id = app_current_tenant());
