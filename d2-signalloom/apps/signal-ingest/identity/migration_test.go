package identity

import (
	"strings"
	"testing"
)

func TestMigrationSQL_SyntaxAndStructure(t *testing.T) {
	sql := MigrationSQL()
	if sql == "" {
		t.Fatal("MigrationSQL() returned empty string")
	}

	requiredSnippets := []string{
		"CREATE TABLE IF NOT EXISTS actors",
		"CREATE TABLE IF NOT EXISTS aliases",
		"CREATE TABLE IF NOT EXISTS delegations",
		"idx_aliases_actor_temporal",
		"idx_aliases_value_temporal",
		"idx_aliases_hash_temporal",
		"idx_delegations_delegate_temporal",
		"idx_delegations_principal_temporal",
		"check_never_merge_alias",
		"check_never_merge_delegation",
		"signal_identity_app",
		"chk_aliases_valid_window",
		"chk_delegations_no_self",
		"chk_delegations_valid_window",
	}

	for _, snippet := range requiredSnippets {
		if !strings.Contains(sql, snippet) {
			t.Errorf("Migration SQL missing required snippet: %q", snippet)
		}
	}
}

func TestMigrationSQL_IdempotencyGuards(t *testing.T) {
	sql := MigrationSQL()

	// Verify all CREATE TABLE statements have IF NOT EXISTS
	tableCount := strings.Count(sql, "CREATE TABLE IF NOT EXISTS")
	if tableCount < 3 {
		t.Errorf("expected at least 3 'CREATE TABLE IF NOT EXISTS', got %d", tableCount)
	}

	// Verify all CREATE INDEX statements have IF NOT EXISTS
	indexCount := strings.Count(sql, "CREATE INDEX IF NOT EXISTS")
	if indexCount < 5 {
		t.Errorf("expected at least 5 'CREATE INDEX IF NOT EXISTS', got %d", indexCount)
	}

	// Verify function and trigger idempotency
	if !strings.Contains(sql, "CREATE OR REPLACE FUNCTION") {
		t.Error("expected 'CREATE OR REPLACE FUNCTION' for idempotent trigger functions")
	}
	if !strings.Contains(sql, "DROP TRIGGER IF EXISTS") {
		t.Error("expected 'DROP TRIGGER IF EXISTS' before creating triggers")
	}
}

func TestMigrationSQL_LeastPrivilegeRoleScoped(t *testing.T) {
	sql := MigrationSQL()

	if !strings.Contains(sql, "CREATE ROLE signal_identity_app") {
		t.Error("expected migration to define least-privilege role 'signal_identity_app'")
	}
	if !strings.Contains(sql, "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE actors, aliases, delegations TO signal_identity_app") {
		t.Error("expected migration to grant scoped table permissions to 'signal_identity_app'")
	}
}
