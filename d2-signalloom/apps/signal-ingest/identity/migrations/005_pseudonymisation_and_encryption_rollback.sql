-- Rollback: 005_pseudonymisation_and_encryption_rollback.sql
-- Card: SLDP-P2-1
--
-- Reverses the schema half of 005. The DATA half — decrypting alias_value_encrypted back into
-- alias_value — must run FIRST, via identity.RollbackAliasEncryption, because the database does
-- not hold the key. Running this file against a table whose rows still have NULL alias_value will
-- fail at step 4, which is deliberate: a rollback that silently leaves the cleartext unrecoverable
-- is not a rollback.
--
-- Order of operations:
--   1. identity.RollbackAliasEncryption(ctx, db, enc, tenant)   -- decrypts, repopulates alias_value
--   2. this file                                                -- restores schema and indexes
--
-- SECURITY NOTE. Rolling back re-materialises cleartext identifiers in the heap and rebuilds two
-- cleartext indexes. It reintroduces exactly the exposure 005 removed and should be treated as an
-- incident-response action, not a routine one.

-- 0. Restore the original delegation never-merge trigger (001_identity_graph.sql:95-120 verbatim),
--    which compares cleartext. Safe only because step 1 of the procedure has already restored
--    aliases.alias_value.
CREATE OR REPLACE FUNCTION check_never_merge_delegation() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.delegate_actor_id = NEW.principal_actor_id THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: self-delegation % is forbidden', NEW.delegate_actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM aliases
        WHERE (actor_id = NEW.delegate_actor_id AND alias_value = NEW.principal_actor_id)
           OR (actor_id = NEW.principal_actor_id AND alias_value = NEW.delegate_actor_id)
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

DROP INDEX IF EXISTS idx_delegations_delegate_pseudonym;
DROP INDEX IF EXISTS idx_delegations_principal_pseudonym;
ALTER TABLE delegations DROP COLUMN IF EXISTS delegate_actor_pseudonym;
ALTER TABLE delegations DROP COLUMN IF EXISTS principal_actor_pseudonym;

-- 1. Restore the original never-merge trigger function (001_identity_graph.sql:63-93 verbatim).
CREATE OR REPLACE FUNCTION check_never_merge_alias() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM delegations
        WHERE delegate_actor_id = NEW.actor_id
          AND principal_actor_id = NEW.alias_value
    ) THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias delegate % to its delegation principal %', NEW.actor_id, NEW.alias_value
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM delegations
        WHERE principal_actor_id = NEW.actor_id
          AND delegate_actor_id = NEW.alias_value
    ) THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias principal % to its delegate %', NEW.actor_id, NEW.alias_value
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_aliases_never_merge ON aliases;
CREATE TRIGGER trg_aliases_never_merge
    BEFORE INSERT OR UPDATE ON aliases
    FOR EACH ROW
    EXECUTE FUNCTION check_never_merge_alias();

-- 2. Drop the fail-closed shape constraint.
ALTER TABLE aliases DROP CONSTRAINT IF EXISTS chk_aliases_pseudonymised;

-- 3. Drop the pseudonymous indexes.
DROP INDEX IF EXISTS idx_aliases_idempotent_seed_pseudonymous;
DROP INDEX IF EXISTS idx_aliases_pseudonym_temporal;

-- 4. Restore NOT NULL on the cleartext column.
--    Fails loudly if step 1 of the rollback procedure (the Go decrypt pass) was skipped.
ALTER TABLE aliases ALTER COLUMN alias_value SET NOT NULL;

-- 5. Rebuild the cleartext indexes exactly as 001 and 003 defined them.
CREATE INDEX IF NOT EXISTS idx_aliases_value_temporal
    ON aliases (alias_value, valid_from, valid_to);

CREATE UNIQUE INDEX IF NOT EXISTS idx_aliases_idempotent_seed
    ON aliases (actor_id, alias_type, alias_value, valid_from);

-- 6. Drop the ciphertext column last, so a failure above leaves the data recoverable.
ALTER TABLE aliases DROP COLUMN IF EXISTS alias_value_encrypted;
