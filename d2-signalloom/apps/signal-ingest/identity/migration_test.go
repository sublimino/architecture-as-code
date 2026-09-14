package identity

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestMigrationSQL_EveryFileIsEmbeddedAndExecuted is a count-declared-against-reported guard.
//
// MigrationSQL() and ApplyMigrations are hand-maintained lists of //go:embed variables. Adding a
// migration file and forgetting either one produces a completely green suite while the migration
// never runs — the failure is invisible because nothing counts the files on disk against the
// files wired up. This walks the directory and asserts both.
func TestMigrationSQL_EveryFileIsEmbeddedAndExecuted(t *testing.T) {
	entries, err := os.ReadDir("migrations")
	if err != nil {
		t.Fatalf("read migrations dir: %v", err)
	}

	source, err := os.ReadFile("migrations.go")
	if err != nil {
		t.Fatalf("read migrations.go: %v", err)
	}
	src := string(source)

	forward := regexp.MustCompile(`^\d{3}_.*\.sql$`)
	combined := MigrationSQL()

	seen := 0
	for _, e := range entries {
		name := e.Name()
		if !forward.MatchString(name) {
			continue
		}
		if strings.Contains(name, "_rollback") {
			// Rollback scripts are embedded but deliberately excluded from MigrationSQL().
			if !strings.Contains(src, "//go:embed migrations/"+name) {
				t.Errorf("rollback %s exists on disk but is not embedded in migrations.go", name)
			}
			continue
		}
		seen++

		if !strings.Contains(src, "//go:embed migrations/"+name) {
			t.Errorf("migration %s exists on disk but has no //go:embed directive in migrations.go", name)
			continue
		}

		body, err := os.ReadFile(filepath.Join("migrations", name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		// A distinctive line from the file must appear in MigrationSQL(), proving the embedded
		// variable is actually concatenated rather than merely declared.
		var probe string
		for _, line := range strings.Split(string(body), "\n") {
			trimmed := strings.TrimSpace(line)
			if len(trimmed) > 30 && !strings.HasPrefix(trimmed, "--") {
				probe = trimmed
				break
			}
		}
		if probe == "" {
			t.Fatalf("could not derive a probe line from %s", name)
		}
		if !strings.Contains(combined, probe) {
			t.Errorf("migration %s is embedded but its content is absent from MigrationSQL(); "+
				"it is declared and never executed. Probe line: %q", name, probe)
		}
	}

	if seen < 5 {
		t.Errorf("expected at least 5 forward migrations on disk, found %d", seen)
	}
}

// TestMigrationSQL_ClearextIndexesAreDropped asserts the SLDP-P2-1 outcome directly.
//
// This exists because the obvious assertion is a false-green. TestMigrationSQL_SyntaxAndStructure
// and sublinear_test.go:18 both check that a literal CREATE INDEX string is PRESENT in
// MigrationSQL(). Migration 005 only adds a DROP, so 001's CREATE text is still there and both of
// those stay green whether or not the index was ever removed. Presence of a CREATE proves nothing;
// only the matching DROP does.
func TestMigrationSQL_CleartextIndexesAreDropped(t *testing.T) {
	sql := MigrationSQL()

	required := []string{
		"DROP INDEX IF EXISTS idx_aliases_value_temporal",
		"DROP INDEX IF EXISTS idx_aliases_idempotent_seed",
		"idx_aliases_idempotent_seed_pseudonymous",
		"alias_value_encrypted BYTEA",
		"ALTER TABLE aliases ALTER COLUMN alias_value DROP NOT NULL",
		"delegate_actor_pseudonym",
		"principal_actor_pseudonym",
	}
	for _, want := range required {
		if !strings.Contains(sql, want) {
			t.Errorf("migration SQL is missing the SLDP-P2-1 requirement: %q", want)
		}
	}

	// The never-merge trigger must compare in pseudonym space, not only check well-formedness.
	// A trigger that merely validates the hash shape would satisfy every other assertion here
	// while enforcing nothing.
	if !strings.Contains(sql, "principal_actor_pseudonym = NEW.alias_value_hash") {
		t.Error("check_never_merge_alias does not compare the alias pseudonym against the delegation " +
			"principal pseudonym; the invariant would fail open once alias_value is NULL")
	}
	if !strings.Contains(sql, "alias_value_hash = NEW.principal_actor_pseudonym") {
		t.Error("check_never_merge_delegation does not compare in pseudonym space; " +
			"the invariant would fail open once alias_value is NULL")
	}

	// The rollback must not be part of the forward SQL. If it were, its CREATE INDEX statements
	// would satisfy a grep for the cleartext indexes and mask the drops above.
	if strings.Contains(sql, "SECURITY NOTE. Rolling back re-materialises cleartext") {
		t.Error("MigrationSQL() includes the rollback script; forward and reverse SQL must not be concatenated")
	}
}

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
		"idx_delegations_transitive_traversal",
		"idx_aliases_idempotent_seed",
		"idx_delegations_idempotent_seed",
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
