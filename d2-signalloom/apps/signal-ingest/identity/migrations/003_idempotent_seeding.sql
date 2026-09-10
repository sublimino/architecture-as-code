-- Migration: 003_idempotent_seeding.sql
-- Purpose: Ensure atomic idempotent seeding with ON CONFLICT DO NOTHING support

CREATE UNIQUE INDEX IF NOT EXISTS idx_aliases_idempotent_seed
    ON aliases (actor_id, alias_type, alias_value, valid_from);

CREATE UNIQUE INDEX IF NOT EXISTS idx_delegations_idempotent_seed
    ON delegations (delegate_actor_id, principal_actor_id, valid_from);
