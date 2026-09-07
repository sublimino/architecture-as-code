-- Migration: 001_identity_graph.sql
-- Purpose: Persist the identity spine as a temporal graph with half-open [valid_from, valid_to) validity
-- and structural never-merge invariants separating identity aliases from acts-on-behalf-of delegations.

-- 1. Actors table: Canonical actors
CREATE TABLE IF NOT EXISTS actors (
    actor_id VARCHAR(255) PRIMARY KEY,
    status VARCHAR(64) NOT NULL DEFAULT 'provisional',
    metadata BYTEA NOT NULL DEFAULT '\x7b7d', -- Encrypted JSON metadata or raw bytes
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Aliases table: Typed time-valid identity aliases
-- Invariant: Maps alias strings (e.g. email, SPIFFE ID, username) to canonical actors.
CREATE TABLE IF NOT EXISTS aliases (
    id BIGSERIAL PRIMARY KEY,
    actor_id VARCHAR(255) NOT NULL REFERENCES actors(actor_id) ON DELETE CASCADE,
    alias_type VARCHAR(64) NOT NULL,
    alias_value VARCHAR(512) NOT NULL,
    alias_value_hash VARCHAR(64) NOT NULL,
    edge_fidelity VARCHAR(32) NOT NULL, -- 'definitive', 'strong', 'suggestive', 'circumstantial'
    valid_from TIMESTAMPTZ NOT NULL,
    valid_to TIMESTAMPTZ, -- NULL represents open-ended / still-active validity
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_aliases_valid_window CHECK (valid_to IS NULL OR valid_from < valid_to)
);

-- 3. Delegations table: Acts-on-behalf-of authority relationships
-- Invariant: Delegations are distinct from aliases. A delegate never merges into a principal.
CREATE TABLE IF NOT EXISTS delegations (
    id BIGSERIAL PRIMARY KEY,
    delegate_actor_id VARCHAR(255) NOT NULL REFERENCES actors(actor_id) ON DELETE CASCADE,
    principal_actor_id VARCHAR(255) NOT NULL REFERENCES actors(actor_id) ON DELETE CASCADE,
    authz_ref TEXT NOT NULL, -- Authorization token / grant reference (encrypted or plaintext)
    valid_from TIMESTAMPTZ NOT NULL,
    valid_to TIMESTAMPTZ, -- NULL represents open-ended / still-active validity
    metadata BYTEA NOT NULL DEFAULT '\x7b7d',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_delegations_no_self CHECK (delegate_actor_id <> principal_actor_id),
    CONSTRAINT chk_delegations_valid_window CHECK (valid_to IS NULL OR valid_from < valid_to)
);

-- 4. B-Tree Temporal Indexes for sub-linear as-of lookups
CREATE INDEX IF NOT EXISTS idx_actors_created_at ON actors (created_at);

CREATE INDEX IF NOT EXISTS idx_aliases_actor_temporal 
    ON aliases (actor_id, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_aliases_value_temporal 
    ON aliases (alias_value, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_aliases_hash_temporal 
    ON aliases (alias_value_hash, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_delegations_delegate_temporal 
    ON delegations (delegate_actor_id, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_delegations_principal_temporal 
    ON delegations (principal_actor_id, valid_from, valid_to);

-- 5. Structural Never-Merge Invariant Functions and Triggers
CREATE OR REPLACE FUNCTION check_never_merge_alias() RETURNS TRIGGER AS $$
BEGIN
    -- Prevent an alias from pointing an actor to an actor it delegates for
    IF EXISTS (
        SELECT 1 FROM delegations
        WHERE delegate_actor_id = NEW.actor_id
          AND principal_actor_id = NEW.alias_value
    ) THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: cannot alias delegate % to its delegation principal %', NEW.actor_id, NEW.alias_value
            USING ERRCODE = 'check_violation';
    END IF;

    -- Prevent an alias from pointing an actor to an actor delegating to it
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

CREATE OR REPLACE FUNCTION check_never_merge_delegation() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.delegate_actor_id = NEW.principal_actor_id THEN
        RAISE EXCEPTION 'structural never-merge invariant violated: self-delegation % is forbidden', NEW.delegate_actor_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Prevent a delegation between actors that are already aliased to each other
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

-- 6. Confidentiality Controls: Least-privilege DB role
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'signal_identity_app') THEN
        CREATE ROLE signal_identity_app;
    END IF;
EXCEPTION
    WHEN insufficient_privilege THEN
        -- Role creation may be restricted in some environments; ignore if unprivileged
        NULL;
END
$$;

DO $$
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE actors, aliases, delegations TO signal_identity_app;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO signal_identity_app;
EXCEPTION
    WHEN undefined_object OR insufficient_privilege THEN
        NULL;
END
$$;
