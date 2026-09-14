// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"database/sql"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
)

// Live-PostgreSQL coverage for the durable store. Everything in saga_test.go and fault_test.go runs
// against MemoryStore, which is a real implementation but shares no code with the SQL paths: the
// compare-and-swap, the ON CONFLICT DO NOTHING, the `destroyed_at IS NULL` guard and the RLS
// interaction are covered ONLY here.
//
//	docker run -d --name sldp-p41-pg -e POSTGRES_PASSWORD=sldp -e POSTGRES_USER=sldp \
//	  -e POSTGRES_DB=sldp -p 55439:5432 postgres:16-alpine
//	SLDP_PG_DSN='postgres://sldp:sldp@127.0.0.1:55439/sldp?sslmode=disable' \
//	  go test -run TestSubjectKeyPG ./subjectkey/... -v
//
// RUN ONE PACKAGE AT A TIME, or pass -p 1.
//
// `go test ./subjectkey/... ./identity/...` with a DSN set runs the two packages CONCURRENTLY
// against ONE database, and identity/alias_pg_live_test.go's freshSchema does
// `DROP TABLE ... CASCADE` on the shared identity tables mid-flight. The result is a failure in the
// identity package that has nothing to do with either package's code, and that disappears when
// either is run alone -- the most misleading shape a red suite can take. Reproduced and confirmed
// 2026-09-14. The default (no DSN) path is unaffected because every live test skips.
const pgDSNEnv = "SLDP_PG_DSN"

// TestSubjectKeyPG_GateIsHonest always runs, so a green suite cannot be mistaken for a covered one.
func TestSubjectKeyPG_GateIsHonest(t *testing.T) {
	if os.Getenv(pgDSNEnv) == "" {
		t.Logf("COVERAGE GAP: %s is unset, so every live-PostgreSQL assertion in this file was "+
			"SKIPPED. PostgresStore's compare-and-swap state transition, its ON CONFLICT saga insert, "+
			"the `destroyed_at IS NULL` idempotency guard, the transaction-local tenant claim and the "+
			"row-level-security interaction are NOT covered by this run. MemoryStore shares no code "+
			"with any of them.", pgDSNEnv)
		return
	}
	t.Logf("live PostgreSQL configured via %s; PostgresStore assertions will execute", pgDSNEnv)
}

func livePG(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv(pgDSNEnv)
	if dsn == "" {
		t.Skipf("%s not set; see TestSubjectKeyPG_GateIsHonest", pgDSNEnv)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}
	if err := identity.ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations: %v", err)
	}
	resetTestTenant(t, db, testTenantFor(t))
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// testTenantFor derives a tenant scope unique to the calling test.
//
// These tests run against a PERSISTENT database, so without isolation the second run of the suite
// inherits the first run's rows. That is not a hypothetical: it produced two failures on the first
// re-run — a saga refusing with ErrVersionDrift because leftover key versions had appeared "after"
// its completed state, and a BeginSaga reporting created=false because the journal row was already
// there. Both are the guards working correctly on stale data, which is the most confusing possible
// way for a suite to go red.
func testTenantFor(t *testing.T) string {
	t.Helper()
	return "pgtest-" + t.Name()
}

// resetTestTenant removes this test's rows before it runs.
//
// The DELETE sets the transaction-local tenant claim first, because migration 009 puts FORCE ROW
// LEVEL SECURITY on both tables — FORCE binds the table owner too, so a DELETE on a bare connection
// matches ZERO rows and succeeds. A cleanup that silently deletes nothing is worse than no cleanup,
// because it looks like isolation. The row counts are therefore checked rather than assumed.
func resetTestTenant(t *testing.T, db *sql.DB, tenant string) {
	t.Helper()
	ctx := context.Background()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin cleanup: %v", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, setTenantClaimSQL, tenant); err != nil {
		t.Fatalf("set tenant claim for cleanup: %v", err)
	}
	for _, table := range []string{"subject_keys", "subject_key_erasures"} {
		if _, err := tx.ExecContext(ctx, "DELETE FROM "+table+" WHERE tenant_id = $1", tenant); err != nil {
			t.Fatalf("clean %s: %v", table, err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit cleanup: %v", err)
	}

	// Prove the cleanup reached the rows. A claim-less DELETE under FORCE RLS affects zero rows and
	// returns no error, so "it ran" is not evidence "it worked".
	tx2, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatalf("begin verify: %v", err)
	}
	defer func() { _ = tx2.Rollback() }()
	if _, err := tx2.ExecContext(ctx, setTenantClaimSQL, tenant); err != nil {
		t.Fatalf("set tenant claim for verify: %v", err)
	}
	var n int
	if err := tx2.QueryRowContext(ctx, "SELECT count(*) FROM subject_keys WHERE tenant_id = $1", tenant).Scan(&n); err != nil {
		t.Fatalf("verify cleanup: %v", err)
	}
	if n != 0 {
		t.Fatalf("cleanup left %d subject_keys rows for tenant %q; this test is not isolated", n, tenant)
	}
}

// livePGSaga builds a saga over the real store, scoped to a per-test tenant so parallel or repeated
// runs cannot collide.
func livePGSaga(t *testing.T, db *sql.DB) (*Saga, *PostgresStore, *Hierarchy, *PlaintextDEKCache) {
	t.Helper()
	store, err := NewPostgresStore(db)
	if err != nil {
		t.Fatalf("NewPostgresStore: %v", err)
	}
	h := testHierarchy(t)
	cache := NewPlaintextDEKCache()
	s, err := NewSaga(SagaConfig{
		Hierarchy: h, Store: store, Cache: cache,
		Pseudonymiser:   fakePseudonymiser{},
		StorageResidual: StorageResidualMVCCAndBackup,
		Now:             fixedClock(),
	})
	if err != nil {
		t.Fatalf("NewSaga: %v", err)
	}
	return s, store, h, cache
}

func pgProvision(t *testing.T, store *PostgresStore, h *Hierarchy, cache *PlaintextDEKCache, tenant, subject string, n int) string {
	t.Helper()
	p, err := fakePseudonymiser{}.Pseudonym(tenant, subject)
	if err != nil {
		t.Fatalf("pseudonym: %v", err)
	}
	for i := 0; i < n; i++ {
		if _, err := store.Provision(context.Background(), tenant, p, 0, func(sc KeyScope) ([]byte, error) {
			dek, err := NewDEK()
			if err != nil {
				return nil, err
			}
			cache.Put(sc, dek)
			return h.WrapDEK(sc, dek)
		}, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)); err != nil {
			t.Fatalf("provision: %v", err)
		}
	}
	return p
}

// The load-bearing test, against a real database this time.
func TestSubjectKeyPG_ErasesOneSubjectOnlyAndIsIdempotent(t *testing.T) {
	db := livePG(t)
	saga, store, h, cache := livePGSaga(t, db)
	ctx := context.Background()

	tenant := testTenantFor(t)
	target := pgProvision(t, store, h, cache, tenant, "alice", 3)
	neighbour := pgProvision(t, store, h, cache, tenant, "bob", 2)

	unwrappable := func(p string) bool {
		recs, err := store.ListVersions(ctx, tenant, p)
		if err != nil || len(recs) == 0 {
			return false
		}
		for _, r := range recs {
			if _, err := h.UnwrapDEK(r.Scope(), r.WrappedDEK); err == nil {
				return true
			}
		}
		return false
	}
	if !unwrappable(target) || !unwrappable(neighbour) {
		t.Fatal("precondition: both subjects must start readable or the postcondition proves nothing")
	}

	first, err := saga.Erase(ctx, tenant, "alice")
	if err != nil {
		t.Fatalf("Erase: %v", err)
	}
	if len(first.Versions) != 3 {
		t.Fatalf("receipt covers %d versions, expected 3", len(first.Versions))
	}
	if first.StorageResidual != StorageResidualMVCCAndBackup {
		t.Fatalf("a Postgres-backed erasure recorded storage residual %q; MVCC dead tuples and WAL "+
			"retain the ciphertext and the receipt must say so", first.StorageResidual)
	}

	if unwrappable(target) {
		t.Fatal("the erased subject's key still unwraps from PostgreSQL")
	}
	if !unwrappable(neighbour) {
		t.Fatal("a neighbour in the same tenant lost access")
	}

	// Idempotency across a real compare-and-swap and a real ON CONFLICT.
	d1, err := first.Digest()
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	second, err := saga.Erase(ctx, tenant, "alice")
	if err != nil {
		t.Fatalf("second Erase: %v", err)
	}
	d2, _ := second.Digest()
	if d1 != d2 {
		t.Fatalf("the receipt digest changed on re-run against PostgreSQL:\n  %s\n  %s", d1, d2)
	}
	if !first.CompletedAt.Equal(second.CompletedAt) {
		t.Fatalf("completed_at moved on re-run: %s vs %s", first.CompletedAt, second.CompletedAt)
	}

	// The proof, with the control that rules out "the key path is broken".
	priors := map[int]string{}
	for _, v := range first.Versions {
		priors[v.KeyVersion] = v.PriorWrappedDigest
	}
	proof, err := saga.VerifyDestroyed(ctx, tenant, target, neighbour, priors)
	if err != nil {
		t.Fatalf("VerifyDestroyed: %v", err)
	}
	if proof.Verdict != VerdictDestroyed {
		t.Fatalf("verdict %q against PostgreSQL", proof.Verdict)
	}
	if !proof.Control.UnwrapSucceeded {
		t.Fatal("the control failed to unwrap, so the target's failure proves nothing")
	}
	for _, v := range proof.Versions {
		if !v.RowPresent || !v.UnwrapFailed || !v.StoredBytesDiffer {
			t.Errorf("version %d: row=%v unwrapFailed=%v bytesDiffer=%v",
				v.KeyVersion, v.RowPresent, v.UnwrapFailed, v.StoredBytesDiffer)
		}
	}
}

// The `destroyed_at IS NULL` guard is the SQL half of idempotency and has no MemoryStore analogue.
func TestSubjectKeyPG_RepeatDestroyPreservesTheOriginalTimestamp(t *testing.T) {
	db := livePG(t)
	_, store, h, cache := livePGSaga(t, db)
	ctx := context.Background()

	tenant := testTenantFor(t)
	p := pgProvision(t, store, h, cache, tenant, "alice", 1)
	scope := KeyScope{TenantID: tenant, SubjectPseudonym: p, KeyEpoch: 0, KeyVersion: 1}

	t1 := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	t2 := time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC)

	first, err := store.DestroyVersion(ctx, scope, t1)
	if err != nil {
		t.Fatalf("first destroy: %v", err)
	}
	second, err := store.DestroyVersion(ctx, scope, t2)
	if err != nil {
		t.Fatalf("repeat destroy: %v", err)
	}
	if !first.DestroyedAt.Equal(second.DestroyedAt) {
		t.Fatalf("a repeat destroy moved destroyed_at from %s to %s; a resumed saga would produce a "+
			"different receipt digest and disagree with an already-published tombstone",
			first.DestroyedAt, second.DestroyedAt)
	}
	if first.PriorWrappedDigest != second.PriorWrappedDigest {
		t.Fatalf("a repeat destroy re-digested the OVERWRITE bytes (%s) instead of preserving the "+
			"pre-destruction digest (%s)", second.PriorWrappedDigest, first.PriorWrappedDigest)
	}
	if first.PriorWrappedDigest == "" {
		t.Fatal("no prior wrapped digest was recorded")
	}

	// The overwrite actually landed: the stored bytes no longer hash to the prior digest.
	rec, err := store.GetVersion(ctx, scope)
	if err != nil {
		t.Fatalf("GetVersion: %v", err)
	}
	if WrappedDigest(rec.WrappedDEK) == first.PriorWrappedDigest {
		t.Fatal("the row still holds the pre-destruction bytes; it is flagged, not overwritten")
	}
	if _, err := h.UnwrapDEK(scope, rec.WrappedDEK); err == nil {
		t.Fatal("the destroyed key still unwraps")
	}
}

// The saga journal's ON CONFLICT insert and compare-and-swap advance.
func TestSubjectKeyPG_SagaJournalIsIdempotentAndCompareAndSwapped(t *testing.T) {
	db := livePG(t)
	saga, store, h, cache := livePGSaga(t, db)
	ctx := context.Background()

	tenant := testTenantFor(t)
	p := pgProvision(t, store, h, cache, tenant, "alice", 1)
	opID, err := saga.OperationID(tenant, p)
	if err != nil {
		t.Fatalf("OperationID: %v", err)
	}
	rec := SagaRecord{
		OperationID: opID, TenantID: tenant, SubjectPseudonym: p,
		TargetVersions: []int{1}, Nonce: pseudo("nonce"), StartedAt: time.Now().UTC(),
	}

	got, created, err := store.BeginSaga(ctx, rec)
	if err != nil {
		t.Fatalf("BeginSaga: %v", err)
	}
	if !created {
		t.Fatal("the first BeginSaga did not report creating the row")
	}
	if got.State != StatePending {
		t.Fatalf("a new saga starts in state %q", got.State)
	}

	// A second call must NOT insert, and must return the SAME nonce — that shared nonce is what
	// makes two racing callers eventually agree on one receipt digest.
	again := rec
	again.Nonce = pseudo("different")
	got2, created2, err := store.BeginSaga(ctx, again)
	if err != nil {
		t.Fatalf("second BeginSaga: %v", err)
	}
	if created2 {
		t.Fatal("a second BeginSaga inserted a duplicate journal row")
	}
	if got2.Nonce != got.Nonce {
		t.Fatalf("the second caller got nonce %s, the first got %s; their receipt digests would differ",
			got2.Nonce, got.Nonce)
	}

	// Compare-and-swap: advancing from the wrong state must be refused, not silently applied.
	if _, err := store.AdvanceSaga(ctx, opID, StateCachesCleared, nil); err == nil {
		t.Fatal("advancing from a state the row is not in was accepted")
	}
	if _, err := store.AdvanceSaga(ctx, opID, StatePending, nil); err != nil {
		t.Fatalf("legal advance refused: %v", err)
	}
	after, err := store.LoadSaga(ctx, opID)
	if err != nil {
		t.Fatalf("LoadSaga: %v", err)
	}
	if after.State != StateKeysDestroyed {
		t.Fatalf("state is %q after one advance from pending", after.State)
	}
	// The same advance repeated must now fail, because the row has moved on.
	if _, err := store.AdvanceSaga(ctx, opID, StatePending, nil); err == nil {
		t.Fatal("the same advance applied twice; an irreversible step could double-apply")
	}
}

// The test that would have caught the defect an adversarial review found, and that the rest of this
// suite structurally could not.
//
// Every other test here uses fixedClock(), which returns whole seconds. PostgreSQL's timestamptz
// holds MICROSECONDS and rounds to nearest; Go's time.Time holds NANOSECONDS and truncates toward
// zero. With a whole-second clock both are exact and the divergence is invisible. With a clock
// carrying sub-microsecond digits, the receipt digested from the in-memory timestamp and the receipt
// rebuilt after a round trip through the database differ — and the resumed saga's digest disagrees
// with the one it persisted, which is exactly the tombstone/receipt divergence this card exists to
// prevent.
//
// A fixture that makes the defect unobservable is not coverage. This one is deliberately hostile: it
// picks a time whose nanosecond component is NOT a whole number of microseconds, and whose
// sub-microsecond remainder is above half so PostgreSQL's round-to-nearest and Go's truncate would
// disagree in opposite directions.
func TestSubjectKeyPG_NanosecondClockDoesNotDivergeTheReceiptDigest(t *testing.T) {
	db := livePG(t)
	store, err := NewPostgresStore(db)
	if err != nil {
		t.Fatalf("NewPostgresStore: %v", err)
	}
	h := testHierarchy(t)
	cache := NewPlaintextDEKCache()

	// The sub-microsecond remainder must be at or above 500ns on EVERY tick, or the two rounding
	// rules agree and the defect is unobservable. The first version of this test advanced by
	// 1234567ns per tick, which lands on remainders BELOW 500 — it passed against the reverted fix,
	// which is a fixture quietly making the bug invisible while its comment claimed the opposite.
	// Here the remainder is pinned at 750ns: PostgreSQL rounds UP to the next microsecond, Go's
	// UnixMicro truncates DOWN to the previous one, so they differ by a full microsecond.
	const remainder = 750 * time.Nanosecond
	base := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC).Add(remainder)
	n := 0
	nanoClock := func() time.Time {
		n++
		return base.Add(time.Duration(n) * time.Second)
	}
	if got := nanoClock().Nanosecond() % 1000; got != 750 {
		t.Fatalf("the clock's sub-microsecond remainder is %dns, not 750; this test cannot observe "+
			"the rounding divergence it exists to catch", got)
	}
	n = 0

	saga, err := NewSaga(SagaConfig{
		Hierarchy: h, Store: store, Cache: cache,
		Pseudonymiser:   fakePseudonymiser{},
		StorageResidual: StorageResidualMVCCAndBackup,
		Now:             nanoClock,
	})
	if err != nil {
		t.Fatalf("NewSaga: %v", err)
	}

	ctx := context.Background()
	tenant := testTenantFor(t)
	p := pgProvision(t, store, h, cache, tenant, "alice", 2)

	first, err := saga.Erase(ctx, tenant, "alice")
	if err != nil {
		t.Fatalf("Erase with a nanosecond-precision clock: %v", err)
	}
	d1, err := first.Digest()
	if err != nil {
		t.Fatalf("digest: %v", err)
	}

	// The persisted digest must already agree — Erase's own consistency check compares the rebuilt
	// digest against the one recorded at receipt_recorded, so a divergence here fails inside Erase.
	journal, err := store.LoadSaga(ctx, first.OperationID)
	if err != nil {
		t.Fatalf("LoadSaga: %v", err)
	}
	if journal.ReceiptDigest != d1 {
		t.Fatalf("the digest persisted at receipt_recorded (%s) disagrees with the returned receipt (%s); "+
			"a sub-microsecond timestamp survived into the digest", journal.ReceiptDigest, d1)
	}

	// And a resume, which rebuilds entirely from what PostgreSQL returned, must agree too.
	second, err := saga.Erase(ctx, tenant, "alice")
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	d2, _ := second.Digest()
	if d1 != d2 {
		t.Fatalf("the receipt digest diverged across a round trip through PostgreSQL:\n  first:  %s\n  resume: %s\n"+
			"  first completed_at:  %s (%d us)\n  resume completed_at: %s (%d us)",
			d1, d2, first.CompletedAt, first.CompletedAt.UnixMicro(),
			second.CompletedAt, second.CompletedAt.UnixMicro())
	}

	// Belt and braces: the durable timestamp carries no sub-microsecond digits at all, so
	// PostgreSQL's rounding is a no-op rather than a divergence waiting for a different value.
	if first.CompletedAt.Nanosecond()%1000 != 0 {
		t.Fatalf("completed_at %s carries sub-microsecond precision that timestamptz cannot hold",
			first.CompletedAt)
	}
	for _, v := range first.Versions {
		if v.DestroyedAt.Nanosecond()%1000 != 0 {
			t.Fatalf("version %d destroyed_at %s carries sub-microsecond precision", v.KeyVersion, v.DestroyedAt)
		}
	}
	if !strings.Contains(p, "") { // keep p used; the pseudonym is the store scope under test
		t.Fatal("unreachable")
	}
}
