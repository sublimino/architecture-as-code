-- Migration: 002_delegation_indices.sql
-- Purpose: Optimize recursive and transitive delegation graph traversal with composite and partial B-Tree indices.

-- 1. Composite index covering delegate -> principal lookups with temporal window
CREATE INDEX IF NOT EXISTS idx_delegations_transitive_traversal
    ON delegations (delegate_actor_id, principal_actor_id, valid_from, valid_to);

-- 2. Partial index for open-ended active delegations (valid_to IS NULL)
CREATE INDEX IF NOT EXISTS idx_delegations_active_open_ended
    ON delegations (delegate_actor_id, principal_actor_id, valid_from)
    WHERE valid_to IS NULL;

-- 3. Reverse traversal index for downstream delegation querying
CREATE INDEX IF NOT EXISTS idx_delegations_reverse_transitive
    ON delegations (principal_actor_id, delegate_actor_id, valid_from, valid_to);
