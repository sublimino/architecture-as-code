package identity

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"
)

// SLDP-P2-2 unit surface. These tests need no database and run in the default
// `go test ./identity/...` pass.
//
// What they can and cannot prove is worth stating plainly, because getting it wrong is how a
// control ends up asserted only in string-grep form. A test over the migration TEXT proves the
// statement was written. It cannot prove PostgreSQL accepted it, that the policy denies anything,
// or that the role attributes hold. Those live in tenant_live_test.go against a real server, and
// the falsification test there is what gives the whole suite discriminating power.
//
// The text assertions still earn their place: they are the regression guard that catches a later
// edit deleting FORCE ROW LEVEL SECURITY or scoping a policy TO PUBLIC, in a repository where the
// live suite is opt-in and may not run on every developer's machine.

func TestMigration006_TenantColumnOnAllThreeTables(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	for _, table := range []string{"actors", "aliases", "delegations"} {
		add := "ALTER TABLE " + table + "      ADD COLUMN IF NOT EXISTS tenant_id VARCHAR(255);"
		if !strings.Contains(sql, "ALTER TABLE "+table) || !strings.Contains(sql, "ADD COLUMN IF NOT EXISTS tenant_id") {
			t.Errorf("migration 006 does not add tenant_id to %s (looked for %q)", table, add)
		}
		if !strings.Contains(sql, "ALTER TABLE "+table+"      ALTER COLUMN tenant_id SET NOT NULL;") &&
			!strings.Contains(sql, "ALTER TABLE "+table+"     ALTER COLUMN tenant_id SET NOT NULL;") &&
			!strings.Contains(sql, "ALTER TABLE "+table+" ALTER COLUMN tenant_id SET NOT NULL;") {
			t.Errorf("migration 006 does not set tenant_id NOT NULL on %s", table)
		}
	}
}

func TestMigration006_DefaultSourcedFromClaimNotFromCaller(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	got := strings.Count(sql, "ALTER COLUMN tenant_id SET DEFAULT app_current_tenant()")
	if got != 3 {
		t.Errorf("expected all three identity tables to default tenant_id from the claim, got %d", got)
	}
}

func TestMigration006_EnablesAndForcesRowLevelSecurity(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	for _, table := range []string{"actors", "aliases", "delegations"} {
		if !regexp.MustCompile(`ALTER TABLE ` + table + `\s+ENABLE ROW LEVEL SECURITY;`).MatchString(sql) {
			t.Errorf("migration 006 does not ENABLE row level security on %s", table)
		}
		// FORCE is the half that binds the table owner. Without it, a connection authenticating as
		// the owner -- which is what a migration-role connection is -- reads every tenant while
		// pg_class.relrowsecurity still reports true.
		if !regexp.MustCompile(`ALTER TABLE ` + table + `\s+FORCE\s+ROW LEVEL SECURITY;`).MatchString(sql) {
			t.Errorf("migration 006 does not FORCE row level security on %s", table)
		}
	}
}

func TestMigration006_PoliciesCarryBothUsingAndWithCheck(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	for _, policy := range []string{"tenant_isolation_actors", "tenant_isolation_aliases", "tenant_isolation_delegations"} {
		idx := strings.Index(sql, "CREATE POLICY "+policy)
		if idx < 0 {
			t.Errorf("missing policy %s", policy)
			continue
		}
		body := sql[idx:]
		if end := strings.Index(body, ";"); end > 0 {
			body = body[:end]
		}
		// USING alone is a read-side control only. Without WITH CHECK a caller can insert rows
		// tagged with another tenant that it then cannot see -- a write-side leak that reads as
		// working isolation from the caller's side.
		const tenantPredicate = "tenant_id = app_current_tenant() AND tenant_id <> identity_quarantine_tenant()"
		if !strings.Contains(body, "USING ("+tenantPredicate+")") {
			t.Errorf("policy %s has no tenant USING clause", policy)
		}
		if !strings.Contains(body, "WITH CHECK ("+tenantPredicate+")") {
			t.Errorf("policy %s has no tenant WITH CHECK clause", policy)
		}
		// The quarantine half is separately load-bearing. NewTenantClaim refuses to build a claim
		// naming the quarantine tenant, but the database cannot tell a claim that came through
		// NewTenantClaim from one set directly with set_config, so the exclusion has to be in the
		// policy or every backfilled row is readable by anyone who forges the claim.
		if !strings.Contains(body, "identity_quarantine_tenant()") {
			t.Errorf("policy %s does not exclude the quarantine tenant", policy)
		}
	}
}

func TestMigration006_Anti_NoPolicyIsUnscopedOrConstant(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	// Every CREATE POLICY statement must either key on the tenant claim or be scoped to the
	// maintenance role AND require a declared reason. A permissive policy that is neither is ORed
	// with the tenant policy and opens every row to every session.
	for _, stmt := range splitCreatePolicyStatements(sql) {
		tenantKeyed := strings.Contains(stmt, "app_current_tenant()")
		maintenance := strings.Contains(stmt, "TO signal_identity_maintenance") &&
			strings.Contains(stmt, "app_maintenance_reason() IS NOT NULL")
		if !tenantKeyed && !maintenance {
			t.Errorf("policy statement is neither tenant-keyed nor a reason-gated maintenance policy:\n%s", stmt)
		}
		if strings.Contains(stmt, "TO PUBLIC") {
			t.Errorf("policy statement is scoped TO PUBLIC:\n%s", stmt)
		}
	}
}

func TestMigration006_Anti_NoHardcodedTenantLiteral(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	for _, literal := range []string{"tenant-demo", "tenant-a", "tenant-b"} {
		if strings.Contains(sql, literal) {
			t.Errorf("migration 006 hardcodes tenant literal %q; policies must key on the claim", literal)
		}
	}
}

func TestMigration006_Anti_NeverGrantsBypassRLS(t *testing.T) {
	sql := MigrationSQL()
	if strings.Contains(strings.ToUpper(sql), " BYPASSRLS") && !strings.Contains(strings.ToUpper(sql), "NOBYPASSRLS") {
		t.Fatal("migration set grants BYPASSRLS")
	}
	// The positive half: both roles must be pinned NOBYPASSRLS, because the attribute is what
	// makes every policy in this file decorative.
	for _, role := range []string{"signal_identity_app", "signal_identity_maintenance"} {
		if !strings.Contains(sql, "ALTER ROLE "+role+" NOSUPERUSER NOBYPASSRLS") {
			t.Errorf("role %s is not pinned NOSUPERUSER NOBYPASSRLS", role)
		}
	}
}

func TestMigration006_Anti_DoesNotDeleteOrTruncateExistingRows(t *testing.T) {
	sql := strings.ToUpper(Migration006TenantIsolationRLS)
	for _, destructive := range []string{"DROP TABLE", "TRUNCATE", "DELETE FROM ACTORS", "DELETE FROM ALIASES", "DELETE FROM DELEGATIONS"} {
		if strings.Contains(sql, destructive) {
			t.Errorf("migration 006 contains destructive statement %q", destructive)
		}
	}
}

func TestMigration006_BackfillReportsEveryQuarantinedRow(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	if !strings.Contains(sql, "CREATE TABLE IF NOT EXISTS identity_tenant_backfill_report") {
		t.Fatal("no backfill report table")
	}
	for _, table := range []string{"'actors'", "'aliases'", "'delegations'"} {
		if !strings.Contains(sql, "INSERT INTO identity_tenant_backfill_report (table_name, row_key, assigned_tenant, reason)") ||
			!strings.Contains(sql, table+", ") {
			t.Errorf("backfill report does not record rows for %s", table)
		}
	}
	// The report must be written BEFORE the UPDATE, or there is no longer any way to tell which
	// rows it should have named.
	reportIdx := strings.Index(sql, "INSERT INTO identity_tenant_backfill_report")
	updateIdx := strings.Index(sql, "UPDATE actors      SET tenant_id = identity_quarantine_tenant()")
	if reportIdx < 0 || updateIdx < 0 || reportIdx > updateIdx {
		t.Error("backfill report is not written before the backfill UPDATE")
	}
}

func TestMigration006_DataStepsPrecedeRowLevelSecurity(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	lastUpdate := strings.LastIndex(sql, "UPDATE delegations SET tenant_id = identity_quarantine_tenant()")
	firstEnable := strings.Index(sql, "ENABLE ROW LEVEL SECURITY")
	if lastUpdate < 0 || firstEnable < 0 {
		t.Fatal("migration 006 is missing the backfill or the RLS enablement")
	}
	// FORCE binds the table owner, so a backfill run after enablement would be policy-checked
	// against a claim that a migration does not have.
	if lastUpdate > firstEnable {
		t.Error("backfill runs after row-level security is enabled; it would be policy-checked with no claim set")
	}
}

func TestMigration006_ClaimAccessorsMapEmptyToNull(t *testing.T) {
	sql := Migration006TenantIsolationRLS
	// RESET ALL restores a custom GUC to the empty string, not NULL. Without the nullif, a reset
	// connection would match rows whose tenant_id is ''.
	if !strings.Contains(sql, `nullif(current_setting('app.current_tenant', true), '')`) {
		t.Error("app_current_tenant() does not map the empty string to NULL")
	}
	if !strings.Contains(sql, `nullif(current_setting('app.maintenance_reason', true), '')`) {
		t.Error("app_maintenance_reason() does not map the empty string to NULL")
	}
	// A SECURITY DEFINER accessor inside a policy executes with the definer's rights and is a
	// standard row-level-security escalation route. Scan statements, not commentary.
	if strings.Contains(strings.ToUpper(stripSQLComments(sql)), "SECURITY DEFINER") {
		t.Error("migration 006 defines a SECURITY DEFINER function; policy accessors must be INVOKER")
	}
}

func TestMigration006_TenantLeadingIndexesExist(t *testing.T) {
	for _, idx := range []string{
		"idx_actors_tenant_actor",
		"idx_aliases_tenant_actor_temporal",
		"idx_aliases_tenant_value_temporal",
		"idx_aliases_tenant_hash_temporal",
		"idx_delegations_tenant_delegate_temporal",
		"idx_delegations_tenant_principal_temporal",
	} {
		if !strings.Contains(Migration006TenantIsolationRLS, idx) {
			t.Errorf("missing tenant-leading index %s", idx)
		}
		// Leading with tenant_id is the whole point: row-level security prepends the tenant
		// predicate to every lookup, and an index that does not lead with it leaves that predicate
		// as a post-scan filter.
		if !regexp.MustCompile(`CREATE INDEX IF NOT EXISTS ` + idx + `\s*\n?\s*ON \w+ \(tenant_id,`).MatchString(Migration006TenantIsolationRLS) {
			t.Errorf("index %s does not lead with tenant_id", idx)
		}
	}
}

func TestMigration006_IsWiredIntoTheMigrationRunner(t *testing.T) {
	if !strings.Contains(MigrationSQL(), "006_tenant_isolation_rls.sql") {
		t.Fatal("migration 006 is not reachable through MigrationSQL(); it would never be applied")
	}
}

func TestMigration006_DoesNotClaimSequence005(t *testing.T) {
	// 005 belongs to SLDP-P2-1, which was in_progress on the board while this card ran.
	if strings.Contains(Migration006TenantIsolationRLS, "005_") {
		t.Error("migration 006 references sequence 005, which is reserved for SLDP-P2-1")
	}
}

func TestNewTenantClaim_RejectsIncompleteAndReservedClaims(t *testing.T) {
	cases := []struct {
		name     string
		tenant   string
		subject  string
		wantErr  bool
		contains string
	}{
		{"valid", "tenant-a", "spiffe://cluster.local/ns/x/sa/y", false, ""},
		{"empty tenant", "", "spiffe://cluster.local/ns/x/sa/y", true, "tenant identifier is empty"},
		{"whitespace tenant", "   ", "spiffe://cluster.local/ns/x/sa/y", true, "tenant identifier is empty"},
		{"empty subject", "tenant-a", "", true, "principal subject is empty"},
		{"whitespace subject", "tenant-a", "  ", true, "principal subject is empty"},
		{"quarantine tenant", QuarantineTenant, "spiffe://cluster.local/ns/x/sa/y", true, "reserved"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			claim, err := NewTenantClaim(tc.tenant, tc.subject)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error for %q/%q, got claim %+v", tc.tenant, tc.subject, claim)
				}
				if !errors.Is(err, ErrInvalidTenantClaim) {
					t.Errorf("error does not wrap ErrInvalidTenantClaim: %v", err)
				}
				if !strings.Contains(err.Error(), tc.contains) {
					t.Errorf("error %q does not mention %q", err, tc.contains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if claim.TenantID != tc.tenant || claim.PrincipalSubject != tc.subject {
				t.Errorf("claim did not round-trip: %+v", claim)
			}
		})
	}
}

func TestTenantClaimContext_RoundTripAndAbsence(t *testing.T) {
	ctx := context.Background()
	if _, ok := TenantClaimFromContext(ctx); ok {
		t.Error("a bare context reported a tenant claim")
	}

	claim, err := NewTenantClaim("tenant-a", "spiffe://cluster.local/ns/x/sa/y")
	if err != nil {
		t.Fatalf("NewTenantClaim: %v", err)
	}
	got, ok := TenantClaimFromContext(WithTenantClaim(ctx, claim))
	if !ok {
		t.Fatal("claim did not survive the context round trip")
	}
	if got != claim {
		t.Errorf("claim changed in transit: got %+v want %+v", got, claim)
	}

	// A zero claim placed on the context directly must still report absent. "Present but empty" is
	// the shape that turns a refusal into an unscoped read.
	if _, ok := TenantClaimFromContext(WithTenantClaim(ctx, TenantClaim{})); ok {
		t.Error("a zero claim reported as present")
	}
}

func TestWithTenant_RefusesWithoutAClaim(t *testing.T) {
	repo := NewPostgresRepository(nil, NewNoopEncryptor())
	called := false
	err := repo.WithTenant(context.Background(), func(context.Context, *PostgresRepository) error {
		called = true
		return nil
	})
	if !errors.Is(err, ErrNoTenantClaim) {
		t.Fatalf("expected ErrNoTenantClaim, got %v", err)
	}
	if called {
		t.Error("the callback ran without a tenant claim; there is no default tenant")
	}
}

func TestMaintenanceSession_RefusesAnEmptyReason(t *testing.T) {
	for _, reason := range []string{"", "   ", "\t\n"} {
		err := MaintenanceSession(context.Background(), nil, reason, nil)
		if !errors.Is(err, ErrEmptyMaintenanceReason) {
			t.Errorf("reason %q: expected ErrEmptyMaintenanceReason, got %v", reason, err)
		}
	}
}

func TestAssertTenantIsolationPosture_RefusesANilHandle(t *testing.T) {
	if _, err := AssertTenantIsolationPosture(context.Background(), nil); !errors.Is(err, ErrTenantIsolationPosture) {
		t.Fatalf("expected ErrTenantIsolationPosture, got %v", err)
	}
}

func TestPqStringArray_QuotesProperly(t *testing.T) {
	if got := pqStringArray([]string{"actors", "aliases"}); got != `{"actors","aliases"}` {
		t.Errorf("got %q", got)
	}
	if got := pqStringArray([]string{`a"b`}); got != `{"a\"b"}` {
		t.Errorf("got %q", got)
	}
}

// stripSQLComments removes `--` line comments.
//
// This is not tidiness. The first run of TestMigration006_Anti_NoPolicyIsUnscopedOrConstant failed
// on the sentence "There is no CREATE POLICY IF NOT EXISTS, so each policy is dropped first", and
// TestMigration006_ClaimAccessorsMapEmptyToNull failed on "deliberately NOT SECURITY DEFINER" --
// two false accusations produced by a guard reading the commentary that explains it. A guard that
// scans its own prose is measuring the wrong thing in both directions: it can fail on an innocent
// sentence, and it can be satisfied by one. Everything below scans statements only.
func stripSQLComments(sql string) string {
	var b strings.Builder
	for _, line := range strings.Split(sql, "\n") {
		if idx := strings.Index(line, "--"); idx >= 0 {
			line = line[:idx]
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String()
}

// splitCreatePolicyStatements returns each CREATE POLICY statement body.
func splitCreatePolicyStatements(sql string) []string {
	var out []string
	rest := stripSQLComments(sql)
	for {
		idx := strings.Index(rest, "CREATE POLICY ")
		if idx < 0 {
			return out
		}
		rest = rest[idx:]
		end := strings.Index(rest, ";")
		if end < 0 {
			out = append(out, rest)
			return out
		}
		out = append(out, rest[:end])
		rest = rest[end:]
	}
}
