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

//go:embed migrations/005_pseudonymisation_and_encryption.sql
var Migration005PseudonymisationAndEncryption string

// Migration005Rollback is the schema half of the 005 rollback. It is NOT executed by
// ApplyMigrations; it is embedded so operators and tests can run it without a file path, and so
// its text is covered by the migration test suite.
//
//go:embed migrations/005_pseudonymisation_and_encryption_rollback.sql
var Migration005Rollback string

// Migration006TenantIsolationRLS adds tenant_id plus enforced row-level security to the identity
// graph (SLDP-P2-2). Sequence 005 is reserved for SLDP-P2-1 and is deliberately not claimed here;
// the two are independent, so either concatenation order applies cleanly.
//
//go:embed migrations/006_tenant_isolation_rls.sql
var Migration006TenantIsolationRLS string

// Migration006Rollback is the rollback script for 006_tenant_isolation_rls.sql.
//
//go:embed migrations/006_tenant_isolation_rls_rollback.sql
var Migration006Rollback string

// Migration008RetentionLegalHolds adds durable Article 17(3) legal holds (SLDP-P3-2).
//
// Sequence 008, not 007. SLDP-P3-1 ran concurrently and claimed 007; neither worktree could see the
// other's migration, so the collision was visible only in the proposal's errata. A sequence number
// has to be claimed in writing, not inferred from the tree.
//
//go:embed migrations/008_retention_legal_holds.sql
var Migration008RetentionLegalHolds string

// MigrationSQL returns the concatenated forward migration SQL scripts for external inspection or
// testing. The rollback script is deliberately excluded: including it would make a grep for a
// dropped index match the rollback's re-creation of it, so a test asserting "the cleartext index
// is gone" would pass whether or not the forward migration removed it.
func MigrationSQL() string {
	return Migration001IdentityGraph + "\n" +
		Migration002DelegationIndices + "\n" +
		Migration003IdempotentSeeding + "\n" +
		Migration004DelegationRevocation + "\n" +
		Migration005PseudonymisationAndEncryption + "\n" +
		Migration006TenantIsolationRLS + "\n" +
		Migration008RetentionLegalHolds
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

	if _, err := tx.ExecContext(ctx, Migration005PseudonymisationAndEncryption); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 005: %w", err)
	}

	// 006 must run after the tables and indexes it constrains exist. It is internally ordered so
	// that every data-modifying step precedes ENABLE/FORCE ROW LEVEL SECURITY -- FORCE binds the
	// table owner, so a backfill run after enablement would be policy-checked against a claim that
	// is not set during a migration.
	if _, err := tx.ExecContext(ctx, Migration006TenantIsolationRLS); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 006: %w", err)
	}

	// 008 must run after 006 because its table defaults tenant_id from app_current_tenant(), the
	// claim accessor 006 defines, and because it follows the same ordering discipline: the table and
	// its index are created before ENABLE/FORCE ROW LEVEL SECURITY is applied.
	if _, err := tx.ExecContext(ctx, Migration008RetentionLegalHolds); err != nil {
		return fmt.Errorf("failed to execute identity graph migration 008: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit migration transaction: %w", err)
	}

	slog.Info("identity graph schema migration applied successfully")
	return nil
}
