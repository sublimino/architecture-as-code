package identity

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq" // Postgres driver for the live suite

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// SLDP-P2-2 hostile-context suite.
//
// Everything here runs against a real PostgreSQL server. That is not a preference. Row-level
// security is a server behaviour, and no amount of asserting on the migration text distinguishes a
// policy that denies from a policy that was written down: both produce identical strings. The
// sibling file tenant_test.go covers the text; this file covers the control.
//
// Two properties make the suite trustworthy rather than merely green:
//
//  1. Every session that is supposed to be confined authenticates as signal_identity_app, a
//     non-superuser, non-owner, NOBYPASSRLS role. A test run as the superuser that owns the tables
//     would see every row and would therefore prove nothing -- it could only ever fail.
//  2. TestTenantRLS_Falsification disables row-level security and re-runs the central probe,
//     asserting that the leak APPEARS. Without that, "no cross-tenant rows were returned" is
//     satisfied just as well by an empty table, a typo'd query, or a connection that never reached
//     the data. A control whose failure mode also satisfies it is not a control.
//
// Run with:
//
//	docker run -d --name pg -e POSTGRES_PASSWORD=devpass -e POSTGRES_DB=signalloom -p 55432:5432 postgres:16-alpine
//	IDENTITY_TEST_DATABASE_URL='postgres://postgres:devpass@127.0.0.1:55432/signalloom?sslmode=disable' \
//	  go test ./identity/... -run TestTenant -count=1 -v
//
// or `make test-identity-rls-live`.

const (
	liveDSNEnv     = "IDENTITY_TEST_DATABASE_URL"
	appRole        = "signal_identity_app"
	appRolePass    = "sldp-p2-2-app" //nolint:gosec // ephemeral test credential, never leaves the test database
	maintRole      = "signal_identity_maintenance"
	maintRolePass  = "sldp-p2-2-maint" //nolint:gosec // ephemeral test credential
	tenantA        = "tenant-alpha"
	tenantB        = "tenant-beta"
	tenantSmall    = "tenant-gamma" // deliberately tiny, so a tenant predicate is genuinely selective
	subjectA       = "spiffe://cluster.local/ns/alpha/sa/ingest"
	subjectB       = "spiffe://cluster.local/ns/beta/sa/ingest"
	legacyActorID  = "legacy-actor-predating-tenancy"
	sharedAliasVal = "collision@example.test"
)

// liveHarness is a migrated database plus one pool per role.
type liveHarness struct {
	admin *sql.DB // superuser: schema setup only, never used to prove isolation
	app   *sql.DB // signal_identity_app: the confined role
	maint *sql.DB // signal_identity_maintenance: the explicit cross-tenant path
	repo  *PostgresRepository
}

// requireLive returns a migrated harness, or skips.
//
// The skip is loud and the failure is louder. A silent skip is indistinguishable from a pass, which
// is how a suite that never ran gets counted as coverage -- so when the DSN IS set, an unusable
// server is a FATAL, never a skip. The only thing that skips is a machine that never asked to run
// these tests.
func requireLive(t *testing.T) *liveHarness {
	t.Helper()

	dsn := os.Getenv(liveDSNEnv)
	if dsn == "" {
		t.Skipf("SKIPPING LIVE ROW-LEVEL-SECURITY SUITE: %s is not set. "+
			"These tests are the only evidence that tenant isolation is enforced rather than merely declared; "+
			"the text assertions in tenant_test.go cannot substitute. Run `make test-identity-rls-live`.", liveDSNEnv)
	}

	admin, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("%s is set but unusable (%v). Refusing to skip: a configured-but-broken database must fail, not vanish.", liveDSNEnv, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := admin.PingContext(ctx); err != nil {
		t.Fatalf("%s is set but the server is unreachable (%v). Refusing to skip.", liveDSNEnv, err)
	}

	h := &liveHarness{admin: admin}
	t.Cleanup(func() {
		for _, db := range []*sql.DB{h.app, h.maint, h.admin} {
			if db != nil {
				_ = db.Close()
			}
		}
	})

	h.resetSchema(t)
	h.seedLegacyRowsThenMigrate(t)
	h.openRolePools(t, dsn)
	h.seedTenantData(t)
	return h
}

func (h *liveHarness) exec(t *testing.T, db *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := db.ExecContext(context.Background(), q, args...); err != nil {
		t.Fatalf("exec failed: %v\nSQL: %s", err, strings.TrimSpace(q))
	}
}

// resetSchema drops everything this card and its predecessors create, so each run starts from a
// known state rather than from whatever the previous run left.
func (h *liveHarness) resetSchema(t *testing.T) {
	t.Helper()
	h.exec(t, h.admin, `DROP TABLE IF EXISTS aliases, delegations, actors, identity_tenant_backfill_report CASCADE`)
	h.exec(t, h.admin, `DROP FUNCTION IF EXISTS app_current_tenant() CASCADE`)
	h.exec(t, h.admin, `DROP FUNCTION IF EXISTS app_maintenance_reason() CASCADE`)
	h.exec(t, h.admin, `DROP FUNCTION IF EXISTS identity_quarantine_tenant() CASCADE`)
	h.exec(t, h.admin, `DROP FUNCTION IF EXISTS check_never_merge_alias() CASCADE`)
	h.exec(t, h.admin, `DROP FUNCTION IF EXISTS check_never_merge_delegation() CASCADE`)
}

// seedLegacyRowsThenMigrate applies 001-004, inserts rows that predate tenancy, then applies 006.
//
// Splitting the migration run in half is the only way to produce a genuine backfill. Running
// ApplyMigrations against an empty database backfills nothing, so the report would be empty and the
// "every quarantined row is named" criterion would pass vacuously.
func (h *liveHarness) seedLegacyRowsThenMigrate(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	for i, m := range []string{
		Migration001IdentityGraph,
		Migration002DelegationIndices,
		Migration003IdempotentSeeding,
		Migration004DelegationRevocation,
	} {
		if _, err := h.admin.ExecContext(ctx, m); err != nil {
			t.Fatalf("pre-tenancy migration %d failed: %v", i+1, err)
		}
	}

	h.exec(t, h.admin, `INSERT INTO actors (actor_id, status) VALUES ($1, 'provisional')`, legacyActorID)
	h.exec(t, h.admin, `INSERT INTO aliases (actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from)
	                    VALUES ($1, 'email', 'legacy@example.test', 'legacyhash', 'strong', NOW() - interval '1 day')`, legacyActorID)
	h.exec(t, h.admin, `INSERT INTO actors (actor_id, status) VALUES ('legacy-principal', 'provisional')`)
	h.exec(t, h.admin, `INSERT INTO delegations (delegate_actor_id, principal_actor_id, authz_ref, valid_from)
	                    VALUES ($1, 'legacy-principal', 'legacy-grant', NOW() - interval '1 day')`, legacyActorID)

	if _, err := h.admin.ExecContext(ctx, Migration006TenantIsolationRLS); err != nil {
		t.Fatalf("migration 006 failed against a populated database: %v", err)
	}
}

// openRolePools grants LOGIN to the two roles and opens a pool for each.
//
// The migration deliberately does not grant LOGIN -- handing out a credential nobody rotates is not
// a migration's job -- so the test environment does it here, which is also the honest place for it.
func (h *liveHarness) openRolePools(t *testing.T, adminDSN string) {
	t.Helper()
	h.exec(t, h.admin, fmt.Sprintf("ALTER ROLE %s LOGIN PASSWORD '%s'", appRole, appRolePass))
	h.exec(t, h.admin, fmt.Sprintf("ALTER ROLE %s LOGIN PASSWORD '%s'", maintRole, maintRolePass))
	h.exec(t, h.admin, fmt.Sprintf("GRANT USAGE ON SCHEMA public TO %s, %s", appRole, maintRole))
	h.exec(t, h.admin, fmt.Sprintf("GRANT SELECT, INSERT, UPDATE, DELETE ON actors, aliases, delegations TO %s", appRole))
	h.exec(t, h.admin, fmt.Sprintf("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %s, %s", appRole, maintRole))

	h.app = openAs(t, adminDSN, appRole, appRolePass)
	h.maint = openAs(t, adminDSN, maintRole, maintRolePass)

	// One connection, so "the next checkout is the same physical connection" is a certainty rather
	// than a race. The stale-claim test depends on it.
	h.app.SetMaxOpenConns(1)
	h.app.SetMaxIdleConns(1)

	h.repo = NewPostgresRepository(h.app, NewNoopEncryptor())
}

func openAs(t *testing.T, adminDSN, role, password string) *sql.DB {
	t.Helper()
	// Rewrite only the credential portion, leaving host/db/params as configured.
	dsn := adminDSN
	if i := strings.Index(dsn, "://"); i > 0 {
		rest := dsn[i+3:]
		if at := strings.Index(rest, "@"); at >= 0 {
			dsn = dsn[:i+3] + role + ":" + password + "@" + rest[at+1:]
		}
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open pool as %s: %v", role, err)
	}
	if err := db.PingContext(context.Background()); err != nil {
		t.Fatalf("connect as %s: %v", role, err)
	}
	return db
}

// seedTenantData writes tenant A and tenant B rows THROUGH the claim mechanism, never by naming
// tenant_id. If the column default were not sourced from the claim this would fail here rather
// than silently producing rows tagged with the wrong tenant.
func (h *liveHarness) seedTenantData(t *testing.T) {
	t.Helper()
	for _, spec := range []struct{ tenant, subject, suffix string }{
		{tenantA, subjectA, "alpha"},
		{tenantB, subjectB, "beta"},
	} {
		claim, err := NewTenantClaim(spec.tenant, spec.subject)
		if err != nil {
			t.Fatalf("NewTenantClaim: %v", err)
		}
		ctx := WithTenantClaim(context.Background(), claim)
		err = h.repo.WithTenant(ctx, func(ctx context.Context, scoped *PostgresRepository) error {
			now := time.Now().UTC().Add(-time.Hour)
			if err := scoped.CreateActor(ctx, ActorRecord{ActorID: "actor-" + spec.suffix, Status: model.ActorProvisional}); err != nil {
				return err
			}
			if err := scoped.CreateActor(ctx, ActorRecord{ActorID: "principal-" + spec.suffix, Status: model.ActorProvisional}); err != nil {
				return err
			}
			// The same alias value in both tenants. Isolation that only works when the values
			// differ is not isolation, it is a coincidence.
			if err := scoped.AddAlias(ctx, AliasRecord{
				ActorID: "actor-" + spec.suffix, AliasType: "email", AliasValue: sharedAliasVal,
				EdgeFidelity: model.FidelityStrong, ValidFrom: now,
			}); err != nil {
				return err
			}
			return scoped.AddDelegation(ctx, DelegationRecord{
				DelegateActorID: "actor-" + spec.suffix, PrincipalActorID: "principal-" + spec.suffix,
				AuthzRef: "grant-" + spec.suffix, ValidFrom: now,
			})
		})
		if err != nil {
			t.Fatalf("seed tenant %s: %v", spec.tenant, err)
		}
	}
}

// countAs runs a COUNT(*) on the given pool with an optional claim already set on the session.
func countAs(t *testing.T, db *sql.DB, table string) int {
	t.Helper()
	var n int
	if err := db.QueryRowContext(context.Background(), "SELECT count(*) FROM "+table).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

// -------------------------------------------------------------------------------------------
// Posture
// -------------------------------------------------------------------------------------------

func TestTenantIsolationPosture_AppRoleIsNeitherOwnerNorBypass(t *testing.T) {
	h := requireLive(t)
	posture, err := AssertTenantIsolationPosture(context.Background(), h.app)
	if err != nil {
		t.Fatalf("application role posture is not safe: %v", err)
	}
	if posture.IsSuperuser {
		t.Error("application role is SUPERUSER")
	}
	if posture.HasBypassRLS {
		t.Error("application role has BYPASSRLS")
	}
	if len(posture.OwnedTables) != 0 {
		t.Errorf("application role owns tables %v; an owner bypasses policies unless FORCE is set", posture.OwnedTables)
	}
	for _, table := range rlsTables {
		tp := posture.Tables[table]
		if !tp.RowSecurityEnabled || !tp.RowSecurityForced {
			t.Errorf("%s: enabled=%v forced=%v; both must be true", table, tp.RowSecurityEnabled, tp.RowSecurityForced)
		}
		if tp.PolicyCount < 2 {
			t.Errorf("%s: expected a tenant policy and a maintenance policy, found %d", table, tp.PolicyCount)
		}
	}
	t.Logf("posture: user=%s super=%v bypass=%v policies=%d",
		posture.CurrentUser, posture.IsSuperuser, posture.HasBypassRLS, posture.TenantPolicies)
}

// The posture assertion must be able to fail, or it is decoration. The superuser pool is the
// natural negative control: it is exactly the connection that ignores every policy.
func TestTenantIsolationPosture_RejectsASuperuserConnection(t *testing.T) {
	h := requireLive(t)
	_, err := AssertTenantIsolationPosture(context.Background(), h.admin)
	if err == nil {
		t.Fatal("posture assertion accepted a SUPERUSER connection; it cannot detect the condition it exists to detect")
	}
	if !strings.Contains(err.Error(), "SUPERUSER") {
		t.Errorf("posture error does not name the problem: %v", err)
	}
	t.Logf("negative control rejected as expected: %v", err)
}

// -------------------------------------------------------------------------------------------
// Missing claim
// -------------------------------------------------------------------------------------------

func TestTenantRLS_MissingClaimReadsNothing(t *testing.T) {
	h := requireLive(t)
	// No claim has been set on this pool. If the control were absent this would return every row
	// in the database, including the legacy quarantined ones.
	for _, table := range rlsTables {
		if n := countAs(t, h.app, table); n != 0 {
			t.Errorf("%s: an unclaimed session read %d rows; it must read none", table, n)
		}
	}
}

func TestTenantRLS_MissingClaimCannotWrite(t *testing.T) {
	h := requireLive(t)
	_, err := h.app.ExecContext(context.Background(),
		`INSERT INTO actors (actor_id, status) VALUES ('unclaimed-write', 'provisional')`)
	if err == nil {
		t.Fatal("an unclaimed session inserted a row; the write path does not fail closed")
	}
	// The NOT NULL violation is the expected shape: the column default evaluates
	// app_current_tenant(), which is NULL with no claim.
	if !strings.Contains(err.Error(), "null value") && !strings.Contains(err.Error(), "row-level security") {
		t.Errorf("unexpected refusal shape (still a refusal, but worth knowing): %v", err)
	}
	t.Logf("unclaimed write refused: %v", err)
}

func TestTenantRLS_WithTenantRefusesAnUnclaimedContext(t *testing.T) {
	h := requireLive(t)
	err := h.repo.WithTenant(context.Background(), func(context.Context, *PostgresRepository) error {
		t.Error("callback ran with no claim")
		return nil
	})
	if err != ErrNoTenantClaim {
		t.Fatalf("expected ErrNoTenantClaim, got %v", err)
	}
}

// -------------------------------------------------------------------------------------------
// Forged claim
// -------------------------------------------------------------------------------------------

func TestTenantRLS_ForgedClaimCannotReadAnotherTenant(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()
	conn, err := h.app.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(ctx, "RESET ALL")
		_ = conn.Close()
	}()

	// A session forging tenant B's claim. This is the strongest adversary the database layer can
	// face: the attacker already controls the claim.
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", tenantB); err != nil {
		t.Fatalf("set claim: %v", err)
	}

	var alphaVisible int
	if err := conn.QueryRowContext(ctx,
		"SELECT count(*) FROM actors WHERE actor_id LIKE 'actor-alpha%'").Scan(&alphaVisible); err != nil {
		t.Fatalf("query: %v", err)
	}
	if alphaVisible != 0 {
		t.Errorf("a session claiming %s read %d of %s's actors", tenantB, alphaVisible, tenantA)
	}

	// The positive control: the same session DOES see its own rows, so a zero above means
	// confinement rather than an empty table or a broken query.
	var betaVisible int
	if err := conn.QueryRowContext(ctx,
		"SELECT count(*) FROM actors WHERE actor_id LIKE 'actor-beta%'").Scan(&betaVisible); err != nil {
		t.Fatalf("query: %v", err)
	}
	if betaVisible == 0 {
		t.Fatal("the session cannot see its own rows either; this test proves nothing about isolation")
	}
}

func TestTenantRLS_ForgedClaimCannotWriteIntoAnotherTenant(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()
	conn, err := h.app.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(ctx, "RESET ALL")
		_ = conn.Close()
	}()
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", tenantB); err != nil {
		t.Fatalf("set claim: %v", err)
	}

	// Naming another tenant explicitly is what WITH CHECK exists to stop. Without it, a caller can
	// plant rows in a tenant it cannot read -- isolation that looks intact from its own side.
	_, err = conn.ExecContext(ctx,
		`INSERT INTO actors (actor_id, status, tenant_id) VALUES ('planted', 'provisional', $1)`, tenantA)
	if err == nil {
		t.Fatal("a session claiming tenant B wrote a row tagged tenant A; WITH CHECK is not enforcing")
	}
	if !strings.Contains(err.Error(), "row-level security") {
		t.Errorf("refused, but not by the policy: %v", err)
	}
	t.Logf("cross-tenant write refused: %v", err)
}

func TestTenantRLS_EmptyClaimIsNotAWildcard(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()
	conn, err := h.app.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(ctx, "RESET ALL")
		_ = conn.Close()
	}()

	// The empty string is the value RESET ALL leaves behind, so it is the claim an attacker gets
	// for free by doing nothing. app_current_tenant() maps it to NULL precisely so it matches
	// nothing rather than matching rows tagged ''.
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', '', false)"); err != nil {
		t.Fatalf("set claim: %v", err)
	}
	var n int
	if err := conn.QueryRowContext(ctx, "SELECT count(*) FROM actors").Scan(&n); err != nil {
		t.Fatalf("query: %v", err)
	}
	if n != 0 {
		t.Errorf("an empty claim read %d actors", n)
	}
}

// -------------------------------------------------------------------------------------------
// Stale claim on a reused connection
// -------------------------------------------------------------------------------------------

func TestTenantRLS_StaleClaimDoesNotSurviveConnectionReuse(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	claim, err := NewTenantClaim(tenantA, subjectA)
	if err != nil {
		t.Fatalf("NewTenantClaim: %v", err)
	}
	var sawInside int
	err = h.repo.WithTenant(WithTenantClaim(ctx, claim), func(ctx context.Context, scoped *PostgresRepository) error {
		return scoped.db.QueryRowContext(ctx, "SELECT count(*) FROM actors").Scan(&sawInside)
	})
	if err != nil {
		t.Fatalf("WithTenant: %v", err)
	}
	if sawInside == 0 {
		t.Fatal("the claimed session saw no rows of its own; the reuse assertion below would be vacuous")
	}

	// The pool has exactly one connection, so this is physically the same connection that carried
	// tenant A's claim a moment ago.
	if n := countAs(t, h.app, "actors"); n != 0 {
		t.Errorf("a reused connection still sees %d actors from the previous tenant's transaction", n)
	}
	var leftover string
	if err := h.app.QueryRowContext(ctx,
		"SELECT coalesce(current_setting('app.current_tenant', true), '')").Scan(&leftover); err != nil {
		t.Fatalf("read setting: %v", err)
	}
	if leftover != "" {
		t.Errorf("the tenant claim %q survived on the pooled connection", leftover)
	}
}

// This is the test that gives the reset hook its reason to exist.
//
// SET LOCAL already makes a stale claim impossible for code that goes through WithTenant --
// PostgreSQL discards it at transaction end without being asked. What it does NOT clear is a
// SESSION-level claim set by code that bypassed WithTenant entirely. That is what RESET ALL on
// release is for, and this test is the only thing in the suite that would notice if it were
// deleted.
func TestTenantRLS_ResetHookClearsASessionLevelClaimLeftByOtherCode(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	// Simulate a code path that sets the claim at session scope and returns the connection.
	conn, err := h.app.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", tenantA); err != nil {
		t.Fatalf("set session claim: %v", err)
	}
	_ = conn.Close() // back to the pool, still carrying tenant A at session scope

	var beforeLeak int
	if err := h.app.QueryRowContext(ctx, "SELECT count(*) FROM actors").Scan(&beforeLeak); err != nil {
		t.Fatalf("query: %v", err)
	}
	if beforeLeak == 0 {
		t.Fatal("the session-level claim did not take effect; this test cannot observe the hook")
	}

	// Now take the same connection through WithTenant. Its release hook must scrub the session
	// setting, not merely the transaction-local one.
	claim, err := NewTenantClaim(tenantB, subjectB)
	if err != nil {
		t.Fatalf("NewTenantClaim: %v", err)
	}
	if err := h.repo.WithTenant(WithTenantClaim(ctx, claim), func(context.Context, *PostgresRepository) error {
		return nil
	}); err != nil {
		t.Fatalf("WithTenant: %v", err)
	}

	var afterLeak int
	if err := h.app.QueryRowContext(ctx, "SELECT count(*) FROM actors").Scan(&afterLeak); err != nil {
		t.Fatalf("query: %v", err)
	}
	if afterLeak != 0 {
		t.Errorf("the session-level claim survived release: %d rows still visible. The reset hook is not running.", afterLeak)
	}
}

func TestTenantRLS_ResetHookRunsAfterAFailedCallback(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()
	claim, err := NewTenantClaim(tenantA, subjectA)
	if err != nil {
		t.Fatalf("NewTenantClaim: %v", err)
	}
	sentinel := fmt.Errorf("deliberate failure")
	if err := h.repo.WithTenant(WithTenantClaim(ctx, claim), func(context.Context, *PostgresRepository) error {
		return sentinel
	}); err != sentinel {
		t.Fatalf("expected the callback error to propagate unwrapped, got %v", err)
	}
	if n := countAs(t, h.app, "actors"); n != 0 {
		t.Errorf("a failed tenant transaction left %d rows visible on the pooled connection", n)
	}
}

// -------------------------------------------------------------------------------------------
// Repository methods through the claim
// -------------------------------------------------------------------------------------------

func TestTenantRLS_RepositoryQueriesAreConfined(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	for _, spec := range []struct{ tenant, subject, own, other string }{
		{tenantA, subjectA, "actor-alpha", "actor-beta"},
		{tenantB, subjectB, "actor-beta", "actor-alpha"},
	} {
		claim, err := NewTenantClaim(spec.tenant, spec.subject)
		if err != nil {
			t.Fatalf("NewTenantClaim: %v", err)
		}
		err = h.repo.WithTenant(WithTenantClaim(ctx, claim), func(ctx context.Context, scoped *PostgresRepository) error {
			asOf := time.Now().UTC()

			// Both tenants hold an alias with the SAME value. A tenant-blind query returns two rows.
			aliases, err := scoped.FindAliasesAsOf(ctx, sharedAliasVal, asOf)
			if err != nil {
				return fmt.Errorf("FindAliasesAsOf: %w", err)
			}
			if len(aliases) != 1 {
				return fmt.Errorf("%s: FindAliasesAsOf on a value shared by both tenants returned %d rows, want exactly 1", spec.tenant, len(aliases))
			}
			if aliases[0].ActorID != spec.own {
				return fmt.Errorf("%s: alias resolved to %s, which belongs to the other tenant", spec.tenant, aliases[0].ActorID)
			}

			if _, err := scoped.GetActiveGraphForActorAsOf(ctx, spec.own, asOf); err != nil {
				return fmt.Errorf("%s: own graph unreadable: %w", spec.tenant, err)
			}
			if _, err := scoped.GetActiveGraphForActorAsOf(ctx, spec.other, asOf); err == nil {
				return fmt.Errorf("%s: read the other tenant's graph for %s", spec.tenant, spec.other)
			}

			dels, err := scoped.GetDelegationsForDelegateAsOf(ctx, spec.other, asOf)
			if err != nil {
				return fmt.Errorf("GetDelegationsForDelegateAsOf: %w", err)
			}
			if len(dels) != 0 {
				return fmt.Errorf("%s: read %d of the other tenant's delegations", spec.tenant, len(dels))
			}
			return nil
		})
		if err != nil {
			t.Errorf("%v", err)
		}
	}
}

// -------------------------------------------------------------------------------------------
// Backfill
// -------------------------------------------------------------------------------------------

func TestTenantRLS_BackfillQuarantinesAndNamesEveryLegacyRow(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	var total, quarantined int
	if err := h.admin.QueryRowContext(ctx, `SELECT count(*) FROM actors`).Scan(&total); err != nil {
		t.Fatalf("count: %v", err)
	}
	if err := h.admin.QueryRowContext(ctx,
		`SELECT count(*) FROM actors WHERE tenant_id = identity_quarantine_tenant()`).Scan(&quarantined); err != nil {
		t.Fatalf("count: %v", err)
	}
	if quarantined != 2 {
		t.Errorf("expected the 2 pre-tenancy actors to be quarantined, got %d", quarantined)
	}
	if total < quarantined {
		t.Errorf("rows were lost: %d total, %d quarantined", total, quarantined)
	}

	rows, err := h.admin.QueryContext(ctx,
		`SELECT table_name, row_key, assigned_tenant, reason FROM identity_tenant_backfill_report ORDER BY table_name, row_key`)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	defer rows.Close()
	seen := map[string]int{}
	for rows.Next() {
		var table, key, tenant, reason string
		if err := rows.Scan(&table, &key, &tenant, &reason); err != nil {
			t.Fatalf("scan: %v", err)
		}
		seen[table]++
		if tenant != QuarantineTenant {
			t.Errorf("%s/%s assigned to %q, not the quarantine tenant", table, key, tenant)
		}
		if reason == "" {
			t.Errorf("%s/%s has no recorded reason", table, key)
		}
		t.Logf("backfill report: %s row_key=%s tenant=%s reason=%s", table, key, tenant, reason)
	}
	for table, want := range map[string]int{"actors": 2, "aliases": 1, "delegations": 1} {
		if seen[table] != want {
			t.Errorf("report names %d %s rows, want %d", seen[table], table, want)
		}
	}

	// The quarantine tenant must not be reachable through the ordinary path. Two layers say so:
	// NewTenantClaim refuses it, and no principal binding maps to it.
	if _, err := NewTenantClaim(QuarantineTenant, subjectA); err == nil {
		t.Error("a principal was able to claim the quarantine tenant")
	}
}

func TestTenantRLS_MigrationIsIdempotentAndDoesNotDuplicateTheReport(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	var before int
	if err := h.admin.QueryRowContext(ctx, `SELECT count(*) FROM identity_tenant_backfill_report`).Scan(&before); err != nil {
		t.Fatalf("count: %v", err)
	}
	for i := 0; i < 2; i++ {
		if _, err := h.admin.ExecContext(ctx, Migration006TenantIsolationRLS); err != nil {
			t.Fatalf("re-applying migration 006 (pass %d) failed: %v", i+1, err)
		}
	}
	var after int
	if err := h.admin.QueryRowContext(ctx, `SELECT count(*) FROM identity_tenant_backfill_report`).Scan(&after); err != nil {
		t.Fatalf("count: %v", err)
	}
	if after != before {
		t.Errorf("re-running the migration changed the report from %d to %d rows", before, after)
	}
}

// -------------------------------------------------------------------------------------------
// Maintenance path
// -------------------------------------------------------------------------------------------

func TestTenantRLS_MaintenanceRoleWithoutAReasonSeesNothing(t *testing.T) {
	h := requireLive(t)
	// The maintenance role is the one role entitled to cross tenants, and it still reads nothing
	// until it declares why. The failure mode of the sanctioned path is the same fail-closed
	// silence as the ordinary path.
	if n := countAs(t, h.maint, "actors"); n != 0 {
		t.Errorf("the maintenance role read %d actors without declaring a reason", n)
	}
}

func TestTenantRLS_MaintenanceRoleWithAReasonCrossesTenants(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	var crossTenant int
	err := MaintenanceSession(ctx, h.maint, "SLDP-P2-2 acceptance: resolve backfill quarantine",
		func(ctx context.Context, tx *sql.Tx) error {
			return tx.QueryRowContext(ctx, "SELECT count(DISTINCT tenant_id) FROM actors").Scan(&crossTenant)
		})
	if err != nil {
		t.Fatalf("maintenance session: %v", err)
	}
	// tenant-alpha, tenant-beta and the quarantine tenant.
	if crossTenant < 3 {
		t.Errorf("a reason-bearing maintenance session saw %d distinct tenants, want at least 3", crossTenant)
	}

	// And the reason does not outlive the session.
	var leftover string
	if err := h.maint.QueryRowContext(ctx,
		"SELECT coalesce(current_setting('app.maintenance_reason', true), '')").Scan(&leftover); err != nil {
		t.Fatalf("read setting: %v", err)
	}
	if leftover != "" {
		t.Errorf("maintenance reason %q survived the session", leftover)
	}
}

func TestTenantRLS_ApplicationRoleCannotUseTheMaintenancePath(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()
	// The maintenance policies are scoped TO signal_identity_maintenance. Declaring a reason as the
	// application role must change nothing, or the reason GUC would be a universal skeleton key.
	var n int
	err := MaintenanceSession(ctx, h.app, "attempting to escalate via the maintenance reason",
		func(ctx context.Context, tx *sql.Tx) error {
			return tx.QueryRowContext(ctx, "SELECT count(*) FROM actors").Scan(&n)
		})
	if err != nil {
		t.Fatalf("maintenance session as app role: %v", err)
	}
	if n != 0 {
		t.Errorf("the application role read %d actors by declaring a maintenance reason", n)
	}
}

// -------------------------------------------------------------------------------------------
// Query plans
// -------------------------------------------------------------------------------------------

// seedPlannerCorpus writes a corpus with a realistic tenant-size skew.
//
// A planner given six rows sequentially scans whatever you build, so the corpus has to be large
// enough for the choice to be real. The skew is the other half: two large tenants and one small
// one, because a tenant holding half the table is a tenant for which a sequential scan is genuinely
// correct, and testing only that case would prove nothing about the index.
func (h *liveHarness) seedPlannerCorpus(t *testing.T) {
	t.Helper()
	h.exec(t, h.admin, `
		INSERT INTO actors (actor_id, status, tenant_id)
		SELECT 'bulk-' || g, 'provisional',
		       CASE WHEN g <= 20 THEN $3 WHEN g % 2 = 0 THEN $1 ELSE $2 END
		FROM generate_series(1, 12000) g
		ON CONFLICT (actor_id) DO NOTHING`, tenantA, tenantB, tenantSmall)
	h.exec(t, h.admin, `
		INSERT INTO aliases (actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from, tenant_id)
		SELECT 'bulk-' || g, 'email', 'bulk-' || g || '@example.test', md5('bulk-' || g), 'strong', NOW() - interval '2 hours',
		       CASE WHEN g <= 20 THEN $3 WHEN g % 2 = 0 THEN $1 ELSE $2 END
		FROM generate_series(1, 12000) g
		ON CONFLICT DO NOTHING`, tenantA, tenantB, tenantSmall)
	h.exec(t, h.admin, `ANALYZE actors`)
	h.exec(t, h.admin, `ANALYZE aliases`)
}

// TestTenantRLS_HighSelectivityLookupKeepsItsExistingPlan records what happens to the alias_value
// lookup -- the single hottest statement in repository.go -- once row-level security prepends a
// tenant predicate to it.
//
// The result is a finding, and it is the opposite of what the card's "composite index" framing
// assumes. alias_value is near-unique, so the pre-existing idx_aliases_value_temporal finds one
// row and the tenant predicate costs one comparison on that row. A tenant-leading index would
// start the scan on a two-value column and is correctly rejected by the planner. Adding one and
// asserting it gets used would mean forcing a worse plan to satisfy a criterion.
//
// What matters for the latency budget is therefore asserted instead: the plan is still an index
// scan, not a sequential one, and the tenant predicate is present in it.
func TestTenantRLS_HighSelectivityLookupKeepsItsExistingPlan(t *testing.T) {
	h := requireLive(t)
	h.seedPlannerCorpus(t)

	const hotLookup = `EXPLAIN (COSTS OFF) SELECT id, actor_id, alias_value FROM aliases
	                   WHERE alias_value = 'bulk-4242@example.test' AND valid_from <= NOW()
	                     AND (valid_to IS NULL OR NOW() < valid_to)`

	plan := explainAs(t, h.app, tenantA, hotLookup)
	t.Logf("PLAN, alias_value lookup under row-level security:\n%s", plan)

	if strings.Contains(plan, "Seq Scan") {
		t.Errorf("the hottest alias lookup degraded to a sequential scan under row-level security:\n%s", plan)
	}
	if !strings.Contains(plan, "Index Scan") && !strings.Contains(plan, "Index Only Scan") {
		t.Errorf("the hottest alias lookup is no longer an index scan:\n%s", plan)
	}
	// The tenant predicate must actually be in the plan. If it is absent the query is not confined,
	// whatever the policy says.
	if !strings.Contains(plan, "tenant_id") {
		t.Errorf("the plan carries no tenant predicate, so the query is not confined:\n%s", plan)
	}
}

// TestTenantRLS_TenantLeadingIndexIsUsedForTenantScopedEnumeration measures the path where the
// tenant-leading index does earn its place: an enumeration with no selective key of its own, where
// the tenant predicate is the only thing narrowing the scan.
//
// Before and after are produced by dropping and recreating the index, so the "before" is measured
// rather than remembered.
func TestTenantRLS_TenantLeadingIndexIsUsedForTenantScopedEnumeration(t *testing.T) {
	h := requireLive(t)
	h.seedPlannerCorpus(t)

	const enumeration = `EXPLAIN (COSTS OFF) SELECT count(*) FROM aliases
	                     WHERE valid_from <= NOW() AND (valid_to IS NULL OR NOW() < valid_to)`

	planAfter := explainAs(t, h.app, tenantSmall, enumeration)
	t.Logf("PLAN AFTER tenant-leading composite index:\n%s", planAfter)

	h.exec(t, h.admin, `DROP INDEX IF EXISTS idx_aliases_tenant_actor_temporal`)
	h.exec(t, h.admin, `DROP INDEX IF EXISTS idx_aliases_tenant_value_temporal`)
	h.exec(t, h.admin, `DROP INDEX IF EXISTS idx_aliases_tenant_hash_temporal`)
	h.exec(t, h.admin, `ANALYZE aliases`)
	planBefore := explainAs(t, h.app, tenantSmall, enumeration)
	t.Logf("PLAN BEFORE tenant-leading composite index:\n%s", planBefore)

	// Restore, so nothing later in this run measures a degraded schema.
	h.exec(t, h.admin, `CREATE INDEX IF NOT EXISTS idx_aliases_tenant_actor_temporal ON aliases (tenant_id, actor_id, valid_from, valid_to)`)
	h.exec(t, h.admin, `CREATE INDEX IF NOT EXISTS idx_aliases_tenant_value_temporal ON aliases (tenant_id, alias_value, valid_from, valid_to)`)
	h.exec(t, h.admin, `CREATE INDEX IF NOT EXISTS idx_aliases_tenant_hash_temporal  ON aliases (tenant_id, alias_value_hash, valid_from, valid_to)`)
	h.exec(t, h.admin, `ANALYZE aliases`)

	afterUsesTenantIndex := strings.Contains(planAfter, "idx_aliases_tenant_")
	if !afterUsesTenantIndex {
		t.Errorf("a tenant-scoped enumeration does not use any tenant-leading index:\n%s", planAfter)
	}
	// The before/after must differ, or the index changed nothing and the criterion is decoration.
	if planAfter == planBefore {
		t.Errorf("dropping every tenant-leading index changed the plan not at all; the index is not doing anything:\nplan:\n%s", planBefore)
	}
	if strings.Contains(planBefore, "idx_aliases_tenant_") {
		t.Errorf("the 'before' plan still names an index that was dropped:\n%s", planBefore)
	}
}

func explainAs(t *testing.T, db *sql.DB, tenant, query string) string {
	t.Helper()
	ctx := context.Background()
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(ctx, "RESET ALL")
		_ = conn.Close()
	}()
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", tenant); err != nil {
		t.Fatalf("set claim: %v", err)
	}
	rows, err := conn.QueryContext(ctx, query)
	if err != nil {
		t.Fatalf("explain: %v", err)
	}
	defer rows.Close()
	var b strings.Builder
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatalf("scan plan: %v", err)
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String()
}

// -------------------------------------------------------------------------------------------
// Referential-integrity existence oracle
// -------------------------------------------------------------------------------------------

// Foreign-key checks run as the table owner with row security bypassed, so before the trigger added
// in section 7 of migration 006, a cross-tenant reference SUCCEEDED while a reference to a
// genuinely absent actor FAILED -- two distinguishable answers to "does this identifier exist
// somewhere in the estate", from a session that can read neither.
//
// This test asserts the two are now indistinguishable. The second half is the one that matters: an
// assertion that the cross-tenant write is refused would pass just as well if all writes were
// refused, so the same-tenant control has to be shown working in the same run.
func TestTenantRLS_ForeignKeyIsNotACrossTenantExistenceOracle(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	conn, err := h.app.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(ctx, "RESET ALL")
		_ = conn.Close()
	}()
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", tenantB); err != nil {
		t.Fatalf("set claim: %v", err)
	}

	// A reference to tenant A's actor, which this session cannot see.
	_, crossTenantErr := conn.ExecContext(ctx,
		`INSERT INTO delegations (delegate_actor_id, principal_actor_id, authz_ref, valid_from)
		 VALUES ('actor-beta', 'principal-alpha', 'oracle-probe', NOW())`)
	if crossTenantErr == nil {
		t.Fatal("a session claiming tenant B created a delegation referencing tenant A's actor")
	}

	// A reference to an identifier that exists nowhere at all.
	_, absentErr := conn.ExecContext(ctx,
		`INSERT INTO delegations (delegate_actor_id, principal_actor_id, authz_ref, valid_from)
		 VALUES ('actor-beta', 'no-such-actor-anywhere', 'oracle-control', NOW())`)
	if absentErr == nil {
		t.Fatal("a delegation was created referencing an actor that does not exist")
	}

	crossMsg := strings.ReplaceAll(crossTenantErr.Error(), "principal-alpha", "X")
	absentMsg := strings.ReplaceAll(absentErr.Error(), "no-such-actor-anywhere", "X")
	if crossMsg != absentMsg {
		t.Errorf("the two refusals are distinguishable, so the oracle is still open:\n  cross-tenant: %s\n  absent:       %s",
			crossTenantErr, absentErr)
	}
	t.Logf("both refused identically: %q", crossMsg)

	// The positive control. Without it, "both are refused" is also satisfied by a trigger that
	// refuses everything, which would be a broken product rather than a closed oracle.
	if _, err := conn.ExecContext(ctx,
		`INSERT INTO delegations (delegate_actor_id, principal_actor_id, authz_ref, valid_from)
		 VALUES ('actor-beta', 'principal-beta', 'same-tenant-control', NOW() - interval '5 minutes')`); err != nil {
		t.Fatalf("a legitimate same-tenant delegation was refused; the trigger rejects everything: %v", err)
	}
}

// -------------------------------------------------------------------------------------------
// Structural guards
//
// Everything in this block exists because the controls above are correct for the schema as it
// stands today and decay silently when it changes. Each guard is DERIVED from the catalogue rather
// than checked against a hand-written list, because a hand-written list is a copy of the source of
// truth and drifts away from it without anything going red.
// -------------------------------------------------------------------------------------------

// The maintenance gate is "a distinct role AND a declared reason". If the application role is a
// member of the maintenance role, the first half evaporates: SET ROLE is one statement away from
// any code path or injection point, and the reason GUC degrades from a control into a comment.
func TestTenantRLS_AppRoleCannotAssumeTheMaintenanceRole(t *testing.T) {
	h := requireLive(t)
	var member bool
	if err := h.admin.QueryRowContext(context.Background(), `
		SELECT EXISTS (
			SELECT 1 FROM pg_auth_members m
			JOIN pg_roles grantee ON grantee.oid = m.member
			JOIN pg_roles granted ON granted.oid = m.roleid
			WHERE grantee.rolname = $1 AND granted.rolname = $2
		)`, appRole, maintRole).Scan(&member); err != nil {
		t.Fatalf("pg_auth_members: %v", err)
	}
	if member {
		t.Errorf("%s is a member of %s; SET ROLE defeats the maintenance gate entirely", appRole, maintRole)
	}

	// The behavioural half. Membership is the usual route but not the only one.
	conn, err := h.app.Conn(context.Background())
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(context.Background(), "RESET ALL")
		_ = conn.Close()
	}()
	if _, err := conn.ExecContext(context.Background(), "SET ROLE "+maintRole); err == nil {
		t.Errorf("%s successfully assumed %s", appRole, maintRole)
	}
}

// app_current_tenant() must be STABLE. IMMUTABLE is the tempting mistake -- it would allow the
// function in an index expression -- and it is a total bypass: the planner constant-folds an
// IMMUTABLE function into a cached generic plan, and a pooled connection then serves the tenant
// baked into that plan to whoever holds the connection next.
func TestTenantRLS_ClaimAccessorsAreStableNotImmutable(t *testing.T) {
	h := requireLive(t)
	rows, err := h.admin.QueryContext(context.Background(), `
		SELECT proname, provolatile, prosecdef
		FROM pg_proc
		WHERE proname IN ('app_current_tenant', 'app_maintenance_reason')`)
	if err != nil {
		t.Fatalf("pg_proc: %v", err)
	}
	defer rows.Close()
	seen := 0
	for rows.Next() {
		var (
			name      string
			volatile  string
			secDefine bool
		)
		if err := rows.Scan(&name, &volatile, &secDefine); err != nil {
			t.Fatalf("scan: %v", err)
		}
		seen++
		if volatile != "s" {
			t.Errorf("%s has provolatile=%q, want \"s\" (STABLE). IMMUTABLE lets the planner fold a tenant into a cached plan.", name, volatile)
		}
		if secDefine {
			t.Errorf("%s is SECURITY DEFINER; a policy accessor must run as the invoker", name)
		}
	}
	if seen != 2 {
		t.Errorf("found %d claim accessors, want 2", seen)
	}
}

// The section-7 trigger closes the referential-integrity oracle for the foreign keys that exist
// today. Adding a table that references actors reopens it with nothing going red, so this guard is
// derived from pg_constraint rather than from a list.
func TestTenantRLS_EveryForeignKeyIntoActorsHasATenantScopedTrigger(t *testing.T) {
	h := requireLive(t)
	rows, err := h.admin.QueryContext(context.Background(), `
		SELECT c.conrelid::regclass::text
		FROM pg_constraint c
		WHERE c.contype = 'f' AND c.confrelid = 'actors'::regclass
		GROUP BY 1`)
	if err != nil {
		t.Fatalf("pg_constraint: %v", err)
	}
	defer rows.Close()
	var referencing []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("scan: %v", err)
		}
		referencing = append(referencing, name)
	}
	if len(referencing) == 0 {
		t.Fatal("no foreign keys into actors were found at all; this guard is not looking at the right catalogue")
	}
	for _, table := range referencing {
		var covered bool
		if err := h.admin.QueryRowContext(context.Background(), `
			SELECT EXISTS (
				SELECT 1 FROM pg_trigger tg
				JOIN pg_proc p ON p.oid = tg.tgfoid
				WHERE tg.tgrelid = $1::regclass
				  AND NOT tg.tgisinternal
				  AND p.proname = 'check_tenant_scoped_actor_reference'
			)`, table).Scan(&covered); err != nil {
			t.Fatalf("pg_trigger: %v", err)
		}
		if !covered {
			t.Errorf("table %s has a foreign key into actors but no check_tenant_scoped_actor_reference trigger; "+
				"referential integrity bypasses row-level security, so that FK is a cross-tenant existence oracle", table)
		}
	}
	t.Logf("foreign keys into actors, all trigger-covered: %v", referencing)
}

// A view over an RLS-protected table evaluates the policy as the VIEW OWNER unless it was created
// with security_invoker=true, and a MATERIALISED view does not apply row-level security to its
// contents at all -- the refresh runs as the owner and the result is an ordinary, unfiltered table.
// Either is a complete bypass. There are none today; this guard is here so that stays true.
func TestTenantRLS_NoViewBypassesThePoliciesOnTheIdentityTables(t *testing.T) {
	h := requireLive(t)
	rows, err := h.admin.QueryContext(context.Background(), `
		SELECT DISTINCT dependent.relname, dependent.relkind, dependent.reloptions::text
		FROM pg_depend d
		JOIN pg_rewrite r ON r.oid = d.objid
		JOIN pg_class dependent ON dependent.oid = r.ev_class
		JOIN pg_class source ON source.oid = d.refobjid
		WHERE d.classid = 'pg_rewrite'::regclass
		  AND source.relname = ANY($1)
		  AND dependent.relkind IN ('v', 'm')
		  AND dependent.relname <> source.relname`, pqStringArray(rlsTables))
	if err != nil {
		t.Fatalf("pg_depend: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var name, kind string
		var opts *string
		if err := rows.Scan(&name, &kind, &opts); err != nil {
			t.Fatalf("scan: %v", err)
		}
		if kind == "m" {
			t.Errorf("materialised view %q is built over an RLS-protected identity table; its contents are unfiltered", name)
			continue
		}
		if opts == nil || !strings.Contains(*opts, "security_invoker=true") {
			t.Errorf("view %q over an identity table is not security_invoker=true, so it evaluates policies as its owner (reloptions=%v)", name, opts)
		}
	}
}

// TRUNCATE is not covered by any row-level security policy. A role holding it can wipe every
// tenant's rows regardless of how tight the policies are.
func TestTenantRLS_AppRoleHoldsNoTruncateOrReferencesPrivilege(t *testing.T) {
	h := requireLive(t)
	for _, table := range rlsTables {
		for _, priv := range []string{"TRUNCATE", "REFERENCES"} {
			var held bool
			if err := h.admin.QueryRowContext(context.Background(),
				`SELECT has_table_privilege($1, $2, $3)`, appRole, table, priv).Scan(&held); err != nil {
				t.Fatalf("has_table_privilege: %v", err)
			}
			if held {
				// TRUNCATE ignores policies outright; REFERENCES lets the role create new foreign
				// keys into actors, which is how the oracle closed in section 7 comes back.
				t.Errorf("%s holds %s on %s", appRole, priv, table)
			}
		}
	}
}

// The quarantine tenant must be unreachable from an ordinary session even when the claim is forged
// directly, because the database cannot tell a claim that came through NewTenantClaim from one that
// did not.
func TestTenantRLS_ForgedQuarantineClaimReadsNothing(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()
	conn, err := h.app.Conn(ctx)
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	defer func() {
		_, _ = conn.ExecContext(ctx, "RESET ALL")
		_ = conn.Close()
	}()
	if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", QuarantineTenant); err != nil {
		t.Fatalf("set claim: %v", err)
	}
	for _, table := range rlsTables {
		var n int
		if err := conn.QueryRowContext(ctx, "SELECT count(*) FROM "+table).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		if n != 0 {
			t.Errorf("a session forging the quarantine claim read %d rows from %s", n, table)
		}
	}

	// The positive control: those rows DO exist, and the maintenance path can see them. Without
	// this, the zeros above are equally explained by an empty backfill.
	var quarantined int
	if err := MaintenanceSession(ctx, h.maint, "SLDP-P2-2 control: confirm quarantined rows exist",
		func(ctx context.Context, tx *sql.Tx) error {
			return tx.QueryRowContext(ctx,
				`SELECT count(*) FROM actors WHERE tenant_id = $1`, QuarantineTenant).Scan(&quarantined)
		}); err != nil {
		t.Fatalf("maintenance session: %v", err)
	}
	if quarantined == 0 {
		t.Fatal("there are no quarantined rows, so the assertions above prove nothing")
	}
}

// -------------------------------------------------------------------------------------------
// Falsification
// -------------------------------------------------------------------------------------------

// TestTenantRLS_Falsification is what makes every assertion above mean something.
//
// The suite's central claim is "a session claiming tenant B sees none of tenant A's rows". Zero is
// also what you get from an empty table, a mistyped predicate, a connection that failed open into
// an empty result, or a policy that denies everything including the caller's own rows. So this test
// removes the control and asserts that the leak APPEARS -- and restores it before returning.
//
// If this test ever goes green while the others do, the others are measuring nothing.
func TestTenantRLS_Falsification(t *testing.T) {
	h := requireLive(t)
	ctx := context.Background()

	probe := func() int {
		conn, err := h.app.Conn(ctx)
		if err != nil {
			t.Fatalf("lease: %v", err)
		}
		defer func() {
			_, _ = conn.ExecContext(ctx, "RESET ALL")
			_ = conn.Close()
		}()
		if _, err := conn.ExecContext(ctx, "SELECT set_config('app.current_tenant', $1, false)", tenantB); err != nil {
			t.Fatalf("set claim: %v", err)
		}
		var n int
		if err := conn.QueryRowContext(ctx,
			"SELECT count(*) FROM actors WHERE actor_id LIKE 'actor-alpha%'").Scan(&n); err != nil {
			t.Fatalf("probe: %v", err)
		}
		return n
	}

	confined := probe()
	if confined != 0 {
		t.Fatalf("baseline is already leaking: %d rows", confined)
	}

	restored := false
	defer func() {
		if !restored {
			h.exec(t, h.admin, `ALTER TABLE actors ENABLE ROW LEVEL SECURITY`)
			h.exec(t, h.admin, `ALTER TABLE actors FORCE ROW LEVEL SECURITY`)
		}
	}()

	h.exec(t, h.admin, `ALTER TABLE actors DISABLE ROW LEVEL SECURITY`)
	leaked := probe()

	h.exec(t, h.admin, `ALTER TABLE actors ENABLE ROW LEVEL SECURITY`)
	h.exec(t, h.admin, `ALTER TABLE actors FORCE ROW LEVEL SECURITY`)
	restored = true

	if leaked == 0 {
		t.Fatalf("with row-level security DISABLED the probe still returned 0 rows. " +
			"The probe cannot distinguish enforcement from its absence, so every isolation assertion " +
			"in this file is vacuous.")
	}
	t.Logf("falsified correctly: %d cross-tenant rows visible with RLS off, %d with it on", leaked, confined)

	// And the control is genuinely back on.
	if again := probe(); again != 0 {
		t.Fatalf("row-level security was not restored: %d rows still visible", again)
	}
}
