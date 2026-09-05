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

// MigrationSQL returns the concatenated migration SQL scripts for external inspection or testing.
func MigrationSQL() string {
	return Migration001IdentityGraph
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

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit migration transaction: %w", err)
	}

	slog.Info("identity graph schema migration applied successfully")
	return nil
}
