-- Migration: 004_delegation_revocation.sql
-- Purpose: Support real-time delegation revocation and status indexing for Stun Sentinel containment.

ALTER TABLE delegations ADD COLUMN IF NOT EXISTS status VARCHAR(64) NOT NULL DEFAULT 'active';

CREATE INDEX IF NOT EXISTS idx_delegations_status
    ON delegations (status);

CREATE INDEX IF NOT EXISTS idx_delegations_delegate_valid_to
    ON delegations (delegate_actor_id, valid_to);

CREATE INDEX IF NOT EXISTS idx_delegations_principal_valid_to
    ON delegations (principal_actor_id, valid_to);
