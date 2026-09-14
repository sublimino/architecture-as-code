package identity

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"log/slog"
)

//go:embed migrations/001_identity_graph.sql
var Migration001IdentityGraph string

//go:embed migrations/002_delegation_indices.sql
var Migration002DelegationIndices string

//go:embed migrations/003_idempotent_seeding.sql
var Migration003IdempotentSeeding string

//go:embed migrations/004_delegation_revocation.sql
var Migration004DelegationRevocation string

// Migration006TenantIsolationRLS adds tenant_id plus enforced row-level security to the identity
// graph (SLDP-P2-2). Sequence 005 is reserved for SLDP-P2-1 and is deliberately not claimed here;
// the two are independent, so either concatenation order applies cleanly.
//
//go:embed migrations/006_tenant_isolation_rls.sql
var Migration006TenantIsolationRLS string

// MigrationSQL returns the concatenated migration SQL scripts for external inspection or testing.
func MigrationSQL() string {
	return Migration001IdentityGraph + "\n" + Migration002DelegationIndices + "\n" + Migration003IdempotentSeeding + "\n" + Migration004DelegationRevocation + "\n" + Migration006TenantIsolationRLS
}

// ApplyMigrations executes the idempotent identity graph schema migrations on the provided database connection.
// It is designed to be fully idempotent: multiple invocations leave the database schema identical and error-free.
func ApplyMigrations(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("cannot apply migrations on nil db connection")
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin migration transaction: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, Migration001IdentityGraph); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 001: %w", err)
	}

	if _, err := tx.ExecContext(ctx, Migration002DelegationIndices); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 002: %w", err)
	}

	if _, err := tx.ExecContext(ctx, Migration003IdempotentSeeding); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 003: %w", err)
	}

	if _, err := tx.ExecContext(ctx, Migration004DelegationRevocation); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 004: %w", err)
	}

	// 006 must run after the tables and indexes it constrains exist. It is internally ordered so
	// that every data-modifying step precedes ENABLE/FORCE ROW LEVEL SECURITY -- FORCE binds the
	// table owner, so a backfill run after enablement would be policy-checked against a claim that
	// is not set during a migration.
	if _, err := tx.ExecContext(ctx, Migration006TenantIsolationRLS); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 006: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit migration transaction: %w", err)
	}

	slog.Info("identity graph schema migration applied successfully")
	return nil
}
