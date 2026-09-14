package identity

import (
	"os"
	"strings"
	"testing"
)

// migration008 returns the embedded 007 SQL, failing loudly if it is empty.
//
// The emptiness guard is not paranoia: a mis-typed //go:embed path yields an empty string rather
// than a compile error in some configurations, and every Contains assertion below would then pass
// vacuously against "".
func migration008(t *testing.T) string {
	t.Helper()
	if Migration008RetentionLegalHolds == "" {
		t.Fatal("Migration008RetentionLegalHolds is empty; every assertion in this file would pass vacuously")
	}
	return Migration008RetentionLegalHolds
}

// TestMigration008IsWiredIntoApplyMigrations is the count-declared-against-executed guard for this
// specific migration.
//
// TestMigrationSQL_EveryFileIsEmbeddedAndExecuted already checks embedding and concatenation into
// MigrationSQL(). It does NOT check ApplyMigrations, which is the function that actually runs
// against a database — so a migration could be embedded, concatenated, asserted upon, and never
// executed, with the whole suite green.
func TestMigration008IsWiredIntoApplyMigrations(t *testing.T) {
	source, err := os.ReadFile("migrations.go")
	if err != nil {
		t.Fatalf("read migrations.go: %v", err)
	}
	src := string(source)

	if !strings.Contains(src, "//go:embed migrations/008_retention_legal_holds.sql") {
		t.Error("migration 008 has no //go:embed directive")
	}
	if !strings.Contains(MigrationSQL(), "CREATE TABLE IF NOT EXISTS retention_legal_holds") {
		t.Error("migration 008 is not concatenated into MigrationSQL()")
	}
	if !strings.Contains(src, "tx.ExecContext(ctx, Migration008RetentionLegalHolds)") {
		t.Error("migration 008 is embedded and concatenated but never executed by ApplyMigrations; " +
			"it would be declared-and-never-run while every other assertion stayed green")
	}
	// Ordering: 007 defaults tenant_id from app_current_tenant(), which 006 defines, so it must run
	// after 006. Comparing offsets in the source is crude but it is the property that matters.
	i6 := strings.Index(src, "tx.ExecContext(ctx, Migration006TenantIsolationRLS)")
	i7 := strings.Index(src, "tx.ExecContext(ctx, Migration008RetentionLegalHolds)")
	if i6 < 0 || i7 < 0 || i6 >= i7 {
		t.Errorf("migration 008 does not execute after 006 (offsets %d, %d); "+
			"007 depends on the app_current_tenant() accessor that 006 creates", i6, i7)
	}
}

func TestMigration008CreatesTheThreeRetentionTables(t *testing.T) {
	sql := migration008(t)
	for _, table := range []string{"retention_legal_holds"} {
		if !strings.Contains(sql, "CREATE TABLE IF NOT EXISTS "+table) {
			t.Errorf("migration 008 does not create %s (or does so without IF NOT EXISTS, breaking idempotency)", table)
		}
		// Tenant column on every table. SLDP-P2-2's finding was that WHERE-clause-only isolation has
		// no database backstop; a new table without tenant_id reintroduces exactly that.
		if !strings.Contains(sql, "tenant_id") {
			t.Errorf("%s has no tenant_id column", table)
		}
	}
}

// TestMigration008EnablesRowLevelSecurityOnEveryTable asserts the full 006 pattern per table.
//
// ENABLE alone is insufficient and asserting only ENABLE is the trap: without FORCE, the table
// OWNER bypasses every policy, so a superuser-owned connection with no app.current_tenant claim
// reads every tenant's holds. ENABLE-without-FORCE looks identical to correct configuration in any
// grep that only checks for "ROW LEVEL SECURITY".
func TestMigration008EnablesRowLevelSecurityOnEveryTable(t *testing.T) {
	sql := migration008(t)
	for _, table := range []string{"retention_legal_holds"} {
		for _, stmt := range []string{
			"ALTER TABLE " + table + " ENABLE ROW LEVEL SECURITY",
			"ALTER TABLE " + table + " FORCE ROW LEVEL SECURITY",
			"DROP POLICY IF EXISTS " + table + "_tenant_isolation ON " + table,
			"CREATE POLICY " + table + "_tenant_isolation ON " + table,
		} {
			if !strings.Contains(sql, stmt) {
				t.Errorf("migration 008 is missing: %s", stmt)
			}
		}
	}
	// Both halves of every policy. A USING clause without WITH CHECK filters reads while leaving
	// writes unconstrained, so a caller could insert a hold into another tenant.
	if got := strings.Count(sql, "USING (tenant_id = app_current_tenant())"); got != 1 {
		t.Errorf("found %d USING clauses, want 1 (one per table)", got)
	}
	if got := strings.Count(sql, "WITH CHECK (tenant_id = app_current_tenant())"); got != 1 {
		t.Errorf("found %d WITH CHECK clauses, want 1; a policy without WITH CHECK leaves writes unconstrained", got)
	}
}

// TestMigration008ConstrainsTheHoldTable asserts the constraints that remain reachable.
//
// An earlier draft also created retention_exceptions and erasure_decisions and asserted a long list
// of CHECK constraints on them, described in the SQL as "a database backstop". Adversarial review
// established that nothing in the Go tree wrote either table, so every one of those constraints was
// unreachable through the application — defence in depth that a reader would cite and that did not
// exist. Both tables were removed rather than caveated, and these assertions shrank with them.
// Asserting a rich constraint set on a table nobody writes is worse than asserting nothing.
func TestMigration008ConstrainsTheHoldTable(t *testing.T) {
	sql := migration008(t)
	required := map[string]string{
		"retention_legal_holds_kind_enumerated":    "a hold kind is not constrained to the three enumerated values",
		"retention_legal_holds_release_after_open": "a hold could be released before it was opened",
	}
	for constraint, why := range required {
		if !strings.Contains(sql, constraint) {
			t.Errorf("migration 008 is missing CONSTRAINT %s: %s", constraint, why)
		}
	}
	// The kind CHECK must admit exactly the three privacy.HoldKind values.
	for _, kind := range []string{"unresolved_incident", "active_containment", "operator_placed"} {
		if !strings.Contains(sql, "'"+kind+"'") {
			t.Errorf("the kind CHECK does not admit %q, which Go can produce", kind)
		}
	}
}

// TestMigration008HasNoSubqueryInACheckConstraint pins the defect that would have made the entire
// migration unapplyable, and which every text assertion in this file missed.
//
// PostgreSQL forbids subqueries in CHECK constraints. The original dual-operator constraint used
// count(DISTINCT ...) FROM unnest(...) and failed against PostgreSQL 16 with
// "ERROR: cannot use subquery in check constraint". Because ApplyMigrations runs 007 inside one
// transaction, that would have aborted the WHOLE migration, leaving retention_legal_holds
// uncreated — while this file stayed green, because every assertion here is strings.Contains over
// the SQL TEXT and nothing in the repository applies 007 to a real database.
//
// A schema assertion that never executes the schema is asserting about a document, not a database.
// This guard is the cheap half; the expensive half is a live-DB apply, which belongs with the other
// DSN-gated suites.
func TestMigration008HasNoSubqueryInACheckConstraint(t *testing.T) {
	lower := strings.ToLower(executableSQL(migration008(t)))
	for _, forbidden := range []string{"select count(", "from unnest(", "(select "} {
		if strings.Contains(lower, forbidden) {
			t.Errorf("migration 008 contains %q; inside a CHECK constraint that is a subquery, "+
				"which PostgreSQL rejects and which aborts the entire migration transaction", forbidden)
		}
	}
}

// TestMigration008IsAdditiveOnly guards the architectural constitution: never rewrite attested
// evidence, and do not mutate an existing table's data or definition.
func TestMigration008IsAdditiveOnly(t *testing.T) {
	sql := migration008(t)
	newTables := map[string]bool{"retention_legal_holds": true}

	for _, line := range strings.Split(sql, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "--") {
			continue
		}
		upper := strings.ToUpper(trimmed)
		// Destructive verbs have no business in this migration at all.
		for _, forbidden := range []string{"DROP TABLE", "TRUNCATE", "DELETE FROM", "UPDATE ", "DROP COLUMN", "ALTER COLUMN"} {
			if strings.HasPrefix(upper, forbidden) {
				t.Errorf("migration 008 contains a destructive statement: %s", trimmed)
			}
		}
		// Every ALTER TABLE must target a table this migration itself created.
		if strings.HasPrefix(upper, "ALTER TABLE ") {
			fields := strings.Fields(trimmed)
			if len(fields) >= 3 && !newTables[fields[2]] {
				t.Errorf("migration 008 alters pre-existing table %q: %s", fields[2], trimmed)
			}
		}
	}
	// Sanity, so the loop above cannot pass by iterating over nothing.
	if !strings.Contains(sql, "ALTER TABLE retention_legal_holds") {
		t.Fatal("no ALTER TABLE statements were seen at all; the additive-only loop scanned nothing meaningful")
	}
}

// executableSQL strips -- comments, so a guard inspects statements rather than prose.
//
// This is not a nicety: the first version of TestMigration008HasNoSubqueryInACheckConstraint went
// red against the migration's own header comment, which NAMES the forbidden construct while
// explaining why it was removed. A guard that matches its own documentation reports a violation
// that exists only in its explanation of the violation — the same shape as a log assertion
// satisfied by the script's comments.
func executableSQL(s string) string {
	var b strings.Builder
	for _, line := range strings.Split(s, "\n") {
		if i := strings.Index(line, "--"); i >= 0 {
			line = line[:i]
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return b.String()
}
