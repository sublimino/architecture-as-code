package privacy

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------------------------
// Regression tests for defects found by adversarial review AFTER the suite was already green.
//
// Every test here covers a defect that the original suite passed straight through. That is the
// useful property to record: 125 tests, a 23-case mutation harness and a full contract suite were
// all green while these held. They are grouped in one file so the next reader can see the class of
// thing this package's own tests did not catch.
// ---------------------------------------------------------------------------------------------

// TestReviewFinding_OneHumanCannotEnrolTwice covers the duplicate-public-key hole.
//
// The registry rejected a duplicate ID on the stated reasoning that "two entries sharing an id
// would let one person satisfy the distinctness rule twice" — and then never applied that
// reasoning to the key. Two ids sharing one key is ordinary configuration drift ("alice" and
// "alice-oncall"), not an attack, and it made the two-distinct-operators claim false without
// anyone acting maliciously. By verification time the two approvals are genuinely distinct, so the
// registry is the only place this can be caught.
func TestReviewFinding_OneHumanCannotEnrolTwice(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	_, err := NewOperatorRegistry([]Operator{
		{ID: "op-alice", PublicKey: alice.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
		{ID: "op-alice-oncall", PublicKey: alice.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
	})
	if err == nil {
		t.Fatal("two registry entries sharing one public key were accepted; one human can satisfy dual authorisation alone")
	}
	if !strings.Contains(err.Error(), "share a public key") {
		t.Errorf("the error does not name the defect: %v", err)
	}

	// Discriminating pair: two operators with DIFFERENT keys must still be accepted, or this fix
	// would pass for a registry that rejected every second entry.
	bob := newTestOperator(t, "op-bob")
	if _, err := NewOperatorRegistry([]Operator{
		{ID: "op-alice", PublicKey: alice.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
		{ID: "op-bob", PublicKey: bob.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
	}); err != nil {
		t.Fatalf("two distinct operators with distinct keys were rejected: %v", err)
	}
}

// TestReviewFinding_ExpiryIsBoundedFromNowNotOnlyFromIssue covers the attacker-chosen issue date.
//
// Bounding only ExpiresAt-minus-IssuedAt let an approver choose the horizon: IssuedAt ten years
// out with an 89-day window passed every other check — expiry after issue, now before expiry,
// window within the ceiling — and authorised erasure from today until a decade hence. The ceiling
// has to bind from the decision clock, which is the one an approver does not control.
func TestReviewFinding_ExpiryIsBoundedFromNowNotOnlyFromIssue(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	err := overrideCase(t, func(e *RetentionException, a, b testOperator) {
		e.IssuedAt = testNow.Add(10 * 365 * 24 * time.Hour)
		e.ExpiresAt = e.IssuedAt.Add(89 * 24 * time.Hour) // window itself is inside the ceiling
		e.ReviewBy = e.IssuedAt
		resign(t, e, a, b)
	}, alice, bob)

	if err == nil {
		t.Fatal("an exception issued ten years in the future with an 89-day window was ACCEPTED; " +
			"MaxExceptionValidity does not bind from the decision clock")
	}
	if !errors.Is(err, ErrExceptionNotTimeBounded) {
		t.Fatalf("want ErrExceptionNotTimeBounded, got %v", err)
	}
}

// TestReviewFinding_ReviewDateMayNotPrecedeIssue closes the other end of the review window.
//
// Only ReviewBy.After(ExpiresAt) was checked. A ReviewBy of 1970-01-01 is non-zero and is not after
// expiry, so it passed — a review scheduled before the exception existed, which reviews nothing for
// exactly the reason the existing check gives.
func TestReviewFinding_ReviewDateMayNotPrecedeIssue(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	err := overrideCase(t, func(e *RetentionException, a, b testOperator) {
		e.ReviewBy = time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC)
		resign(t, e, a, b)
	}, alice, bob)

	if err == nil {
		t.Fatal("a review date predating the exception was accepted")
	}
	if !errors.Is(err, ErrExceptionNotTimeBounded) {
		t.Fatalf("want ErrExceptionNotTimeBounded, got %v", err)
	}
}

// TestReviewFinding_PostgresSourceSetsTheTenantClaim is a source-level guard for the defect that
// mattered most, and it says plainly what it can and cannot prove.
//
// THE DEFECT: migration 008 puts FORCE ROW LEVEL SECURITY on retention_legal_holds with
// USING (tenant_id = app_current_tenant()), and app_current_tenant() is NULL when the claim is
// unset. A query on a bare pooled connection therefore SUCCEEDS and returns ZERO ROWS — which is
// the wire encoding of "determined: no holds". Every durable hold became invisible and every
// erasure was permitted. Adversarial review proved it against a live PostgreSQL 16: 0 rows without
// the claim, 1 row with it.
//
// WHAT THIS TEST PROVES: that the query still runs inside a transaction which sets the claim first.
// WHAT IT DOES NOT PROVE: that the claim actually satisfies the policy — only a live database can
// show that, and the DSN-gated suites are where that belongs. The limitation is stated here rather
// than in a commit message because a guard that reads as proving the second thing is the original
// defect one level up.
func TestReviewFinding_PostgresSourceSetsTheTenantClaim(t *testing.T) {
	src := packageGoSources(t)["postgres.go"]
	if src == "" {
		t.Fatal("postgres.go was not read; this guard would pass vacuously")
	}
	for _, want := range []string{
		"BeginTx(", // a transaction exists at all
		"set_config('app.current_tenant', $1, true)", // the claim is set, transaction-locally
		"tx.ExecContext(ctx, setTenantClaimSQL, tenantID)",
		"tx.QueryContext(ctx, activeHoldQuery", // and the READ uses that same transaction
	} {
		if !strings.Contains(src, want) {
			t.Errorf("postgres.go no longer contains %q; without it every durable legal hold is invisible "+
				"to the gate because row-level security matches nothing when the claim is unset", want)
		}
	}
	// The read must NOT go back to the bare pool, which is what the original defect did.
	if strings.Contains(src, "p.db.QueryContext(ctx, activeHoldQuery") {
		t.Error("the hold query runs on the bare pool rather than inside the claim-setting transaction; " +
			"row-level security will match nothing and zero rows will read as 'no holds'")
	}
}

// TestReviewFinding_RecordingDestroyerIsConcurrencySafe drives the recorder concurrently, which no
// test previously did — which is why `go test -race` was clean while the append was unguarded.
func TestReviewFinding_RecordingDestroyerIsConcurrencySafe(t *testing.T) {
	d := &RecordingKeyDestroyer{}
	const n = 64
	done := make(chan struct{}, n)
	for i := 0; i < n; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			_, _ = d.DestroySubjectKeys(context.Background(), "tenant-a", "actor-x")
		}()
	}
	for i := 0; i < n; i++ {
		<-done
	}
	if got := len(d.Calls()); got != n {
		t.Fatalf("recorded %d destructions, want %d; receipts were lost to an unsynchronised append", got, n)
	}
}

// TestReviewFinding_MigrationHasNoUnreachableTables covers the honesty defect.
//
// Migration 008 originally created retention_exceptions and erasure_decisions, with comments
// describing their CHECK constraints as "a database backstop". Nothing in the Go tree wrote either
// table, so every one of those constraints was unreachable and a reader would have cited defence in
// depth that did not exist. This asserts the migration creates only tables this package actually
// reads.
func TestReviewFinding_MigrationHasNoUnreachableTables(t *testing.T) {
	sql := readMigration008(t)
	sources := packageGoSources(t)
	if len(sources) == 0 {
		t.Fatal("no package sources read; this guard would pass vacuously")
	}

	var created []string
	for _, line := range strings.Split(sql, "\n") {
		const marker = "CREATE TABLE IF NOT EXISTS "
		if i := strings.Index(line, marker); i >= 0 {
			created = append(created, strings.Fields(line[i+len(marker):])[0])
		}
	}
	if len(created) == 0 {
		t.Fatal("migration 008 creates no tables at all; this guard scanned nothing")
	}

	all := strings.Join(mapValues(sources), "\n")
	for _, table := range created {
		if !strings.Contains(all, table) {
			t.Errorf("migration 008 creates %q but no non-test Go source in this package references it. "+
				"Unreachable constraints read as defence in depth that does not exist; either write the "+
				"table or delete it", table)
		}
	}
}

// TestReviewFinding_MigrationHasNoSubqueryInCheckConstraint pins the defect that would have made
// the entire migration unapplyable.
//
// PostgreSQL forbids subqueries in CHECK constraints. The original dual-operator constraint used
// `count(DISTINCT ...) FROM unnest(...)` and failed with `ERROR: cannot use subquery in check
// constraint` against PostgreSQL 16 — and because ApplyMigrations runs 007 in one transaction, the
// whole migration would have aborted, leaving even retention_legal_holds uncreated.
//
// Every test passed regardless, because they were all strings.Contains over the SQL text and
// nothing applied it to a real database. That is the sharpest lesson of this card: a schema
// assertion that never executes the schema is asserting about a document, not a database.
func TestReviewFinding_MigrationHasNoSubqueryInCheckConstraint(t *testing.T) {
	lower := strings.ToLower(executableSQLText(readMigration008(t)))
	for _, forbidden := range []string{"select count(", "from unnest(", "(select "} {
		if strings.Contains(lower, forbidden) {
			t.Errorf("migration 008 contains %q, which inside a CHECK constraint is a subquery; "+
				"PostgreSQL rejects it and ApplyMigrations would abort the whole transaction", forbidden)
		}
	}
}

// mapValues avoids pulling in a generics helper for one use.
// executableSQLText strips -- comments so this guard inspects statements, not the prose that
// explains them. See the twin helper in identity/migration_007_test.go for why.
func executableSQLText(s string) string {
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

func mapValues(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for _, v := range m {
		out = append(out, v)
	}
	return out
}
