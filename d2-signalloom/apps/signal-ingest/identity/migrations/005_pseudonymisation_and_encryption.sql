-- Migration: 005_pseudonymisation_and_encryption.sql
-- Card: SLDP-P2-1 — Keyed HMAC pseudonyms and envelope-encrypted alias values
-- Sequence 005 reserved for this card by SLDP-P2-PRE. 006 is P2-2 (tenant/RLS), 007 is P2-3
-- (never-merge pinning in pseudonym space). Do not claim either from here.
--
-- Purpose
--   Before this migration the re-identification map was the row itself: alias_value held the
--   cleartext identifier (001_identity_graph.sql:20) next to an UNKEYED SHA-256 of the same
--   string, and BOTH idx_aliases_value_temporal (001:50) and the UNIQUE idx_aliases_idempotent_seed
--   (003) indexed the cleartext. This migration moves the identifier into AES-256-GCM envelope
--   ciphertext, makes the keyed HMAC the only indexed representation, and removes both cleartext
--   indexes so the identifier is not recoverable from index pages either.
--
-- Ordering
--   The DDL here is additive and index-level only. The row rewrite is performed by the Go step
--   identity.EncryptExistingAliasValues, which holds the key material the database does not. The
--   NOT VALID constraint below is validated by that same step once the backfill completes, so a
--   half-migrated table is visibly half-migrated rather than silently accepted.
--
-- Rollback: 005_pseudonymisation_and_encryption_rollback.sql plus identity.RollbackAliasEncryption.

-- 1. Ciphertext column for the identifier value.
ALTER TABLE aliases ADD COLUMN IF NOT EXISTS alias_value_encrypted BYTEA;

-- 2. Cleartext column becomes optional so the backfill can null it out.
--    It is retained (rather than dropped) so the rollback can restore into it without a table
--    rewrite, and so a half-migrated table is diagnosable.
ALTER TABLE aliases ALTER COLUMN alias_value DROP NOT NULL;

-- 3. Remove every index built on the cleartext identifier.
--    Leaving these in place would keep the identifier readable from index pages even after the
--    heap column is nulled, which is the whole point of the change.
DROP INDEX IF EXISTS idx_aliases_value_temporal;
DROP INDEX IF EXISTS idx_aliases_idempotent_seed;

-- 4. Pseudonymous replacements.
--    alias_value_hash is VARCHAR(64) and an HMAC-SHA256 hex digest is exactly 64 characters, so
--    the btree key is the same width as before and well inside the ~2704-byte index key limit.
CREATE UNIQUE INDEX IF NOT EXISTS idx_aliases_idempotent_seed_pseudonymous
    ON aliases (actor_id, alias_type, alias_value_hash, valid_from);

CREATE INDEX IF NOT EXISTS idx_aliases_pseudonym_temporal
    ON aliases (alias_value_hash, valid_from, valid_to);

-- 5. Fail-closed shape constraint.
--    Added NOT VALID so existing rows do not block the migration; validated by the Go backfill
--    step after every row is rewritten. A row must carry a well-formed 64-character lowercase hex
--    pseudonym, and must not carry ciphertext and cleartext at the same time.
DO $$
BEGIN
    ALTER TABLE aliases ADD CONSTRAINT chk_aliases_pseudonymised
        CHECK (
            alias_value_hash ~ '^[0-9a-f]{64}$'
            AND NOT (alias_value IS NOT NULL AND alias_value_encrypted IS NOT NULL)
        ) NOT VALID;
EXCEPTION
    WHEN duplicate_object THEN
        NULL; -- idempotent re-application
END
$$;

-- 6. Never-merge invariant, re-pinned in pseudonym space.
--
--    THE PROBLEM. check_never_merge_alias() (001_identity_graph.sql:63-93) compared
--    NEW.alias_value against delegations.principal_actor_id / delegate_actor_id. Once the backfill
--    nulls alias_value those EXISTS clauses can never match, so the trigger would FAIL OPEN:
--    reporting success while checking nothing. sldp-p2-pre-proof.md §4.2.2 names this exact
--    hazard, and §4.2.3 requires it be closed BEFORE P2-1's schema alterations land — which is why
--    it is closed here rather than deferred.
--
--    THE KEY OBSERVATION. The comparison does not require the database to compute a pseudonym.
--    alias_value and principal_actor_id are both actor-ID-shaped strings in the same namespace
--    under the same tenant key, and HMAC is a function, so:
--
--        alias_value = principal_actor_id  <=>  HMAC(k, alias_value) = HMAC(k, principal_actor_id)
--
--    Equality in pseudonym space IS equality in cleartext. The application writes both sides'
--    pseudonyms; the database only ever compares two opaque 64-character strings. No key enters
--    the database, and the check stays inside the INSERT's own transaction — so it is atomic,
--    covers every writer including psql, and has none of the read-then-write race an
--    application-layer replacement would have.
--
--    An application-layer check is retained in PostgresRepository as defence in depth, but it is
--    NOT the control of record. The trigger is.
ALTER TABLE delegations ADD COLUMN IF NOT EXISTS delegate_actor_pseudonym VARCHAR(64);
ALTER TABLE delegations ADD COLUMN IF NOT EXISTS principal_actor_pseudonym VARCHAR(64);

CREATE INDEX IF NOT EXISTS idx_delegations_delegate_pseudonym
    ON delegations (delegate_actor_id, principal_actor_pseudonym);
CREATE INDEX IF NOT EXISTS idx_delegations_principal_pseudonym
    ON delegations (principal_actor_id, delegate_actor_pseudonym);

CREATE OR REPLACE FUNCTION check_never_merge_alias() RETURNS TRIGGER AS $$
BEGIN
    -- Fail closed: a row without a well-formed keyed pseudonym is not insertable. Without this
    -- the comparison below could be skipped by supplying a NULL pseudonym.
    IF NEW.alias_value_hash IS NULL OR NEW.alias_value_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'pseudonymisation invariant violated: alias_value_hash must be a 64-character lowercase hex keyed digest, got %', coalesce(NEW.alias_value_hash, '<null>')
            USING ERRCODE = 'check_violation';
    END IF;

    -- Fail closed: a row must carry the identifier as ciphertext, not as nothing at all.
    IF NEW.alias_value_encrypted IS NULL THEN
        RAISE EXCEPTION 'pseudonymisation invariant violated: alias_value_encrypted must not be NULL for actor %', NEW.actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- The real invariant, compared in pseudonym space.
    IF EXISTS (
        SELECT 1 FROM delegations
        WHERE (delegate_actor_id = NEW.actor_id AND principal_actor_pseudonym = NEW.alias_value_hash)
           OR (principal_actor_id = NEW.actor_id AND delegate_actor_pseudonym = NEW.alias_value_hash)
    ) THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias actor % to its delegation counterparty (pseudonym %)', NEW.actor_id, NEW.alias_value_hash
            USING ERRCODE = 'check_violation';
    END IF;

    -- Transitional: a pre-migration row still carrying cleartext gets the original comparison too.
    IF NEW.alias_value IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM delegations
            WHERE (delegate_actor_id = NEW.actor_id AND principal_actor_id = NEW.alias_value)
               OR (principal_actor_id = NEW.actor_id AND delegate_actor_id = NEW.alias_value)
        ) THEN
            RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias actor % to its delegation counterparty %', NEW.actor_id, NEW.alias_value
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_aliases_never_merge ON aliases;
CREATE TRIGGER trg_aliases_never_merge
    BEFORE INSERT OR UPDATE ON aliases
    FOR EACH ROW
    EXECUTE FUNCTION check_never_merge_alias();

-- 6b. Delegation-side counterpart. check_never_merge_delegation (001:95-114) read
--     aliases.alias_value and has the identical fail-open exposure once that column is nulled.
CREATE OR REPLACE FUNCTION check_never_merge_delegation() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.delegate_actor_id = NEW.principal_actor_id THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: self-delegation % is forbidden', NEW.delegate_actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Fail closed: a delegation without both counterparty pseudonyms cannot be checked against
    -- pseudonymised aliases, so it is refused rather than admitted unchecked.
    IF NEW.delegate_actor_pseudonym IS NULL OR NEW.delegate_actor_pseudonym !~ '^[0-9a-f]{64}$'
       OR NEW.principal_actor_pseudonym IS NULL OR NEW.principal_actor_pseudonym !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'pseudonymisation invariant violated: delegation % -> % must carry both 64-hex counterparty pseudonyms', NEW.delegate_actor_id, NEW.principal_actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- The real invariant, compared in pseudonym space.
    IF EXISTS (
        SELECT 1 FROM aliases
        WHERE (actor_id = NEW.delegate_actor_id AND alias_value_hash = NEW.principal_actor_pseudonym)
           OR (actor_id = NEW.principal_actor_id AND alias_value_hash = NEW.delegate_actor_pseudonym)
    ) THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: cannot delegate between aliased identities % and %', NEW.delegate_actor_id, NEW.principal_actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Transitional cleartext comparison for pre-migration alias rows.
    IF EXISTS (
        SELECT 1 FROM aliases
        WHERE alias_value IS NOT NULL
          AND ((actor_id = NEW.delegate_actor_id AND alias_value = NEW.principal_actor_id)
            OR (actor_id = NEW.principal_actor_id AND alias_value = NEW.delegate_actor_id))
    ) THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: cannot delegate between aliased identities % and %', NEW.delegate_actor_id, NEW.principal_actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_delegations_never_merge ON delegations;
CREATE TRIGGER trg_delegations_never_merge
    BEFORE INSERT OR UPDATE ON delegations
    FOR EACH ROW
    EXECUTE FUNCTION check_never_merge_delegation();

-- 7. Grant the new column to the least-privilege role (column grants follow table grants, but
--    re-assert for environments where the role was created after 001).
DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE aliases TO signal_identity_app;
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        NULL;
END
$$;
