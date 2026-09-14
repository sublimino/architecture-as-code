// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package identity

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

// This file is the only place in the repository that executes PostgresRepository's alias SQL.
//
// Before SLDP-P2-1, no test did. pool_sharing_test.go is the sole test that constructs
// NewPostgresRepository, it uses an unreachable DSN, lib/pq connects lazily, and it only compares
// *sql.DB pointers — so no statement ever ran. Every alias behaviour was asserted exclusively
// through MemoryRepository, which means migration 005, the ON CONFLICT target, the NULL-column
// scan, the index drops and both never-merge triggers were entirely unasserted by the suite.
//
// These tests require a live Postgres and are therefore gated on SLDP_PG_DSN. That gating is a
// real coverage limitation, not a formality: in CI they SKIP, so a green CI run is NOT evidence
// that any of this passed. The proof document records the manual run and its output, and
// TestAliasPG_GateIsHonest below makes the skip visible rather than silent.
//
//	docker run -d --name sldp-pg -e POSTGRES_PASSWORD=sldp -e POSTGRES_USER=sldp \
//	  -e POSTGRES_DB=sldp -p 55435:5432 postgres:16-alpine
//	SLDP_PG_DSN='postgres://sldp:sldp@127.0.0.1:55435/sldp?sslmode=disable' \
//	  go test -run TestAliasPG ./identity/... -v

const pgDSNEnv = "SLDP_PG_DSN"

// TestAliasPG_GateIsHonest always runs. It reports whether the live-Postgres tests in this file
// actually executed, so "the suite was green" cannot be mistaken for "the migration was verified".
func TestAliasPG_GateIsHonest(t *testing.T) {
	if os.Getenv(pgDSNEnv) == "" {
		t.Logf("COVERAGE GAP: %s is unset, so every live-Postgres assertion in this file was SKIPPED. "+
			"Migration 005, the ON CONFLICT target, the envelope column round-trip, the index plan and "+
			"both never-merge triggers are NOT covered by this run.", pgDSNEnv)
		return
	}
	t.Logf("live Postgres configured via %s; migration and trigger assertions will execute", pgDSNEnv)
}

func livePG(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv(pgDSNEnv)
	if dsn == "" {
		t.Skipf("%s not set; skipping live Postgres test (see TestAliasPG_GateIsHonest)", pgDSNEnv)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("ping %s: %v", dsn, err)
	}
	return db
}

// freshSchema drops and recreates the identity tables so each test starts from a known state.
func freshSchema(t *testing.T, db *sql.DB) {
	t.Helper()
	ctx := context.Background()
	stmts := []string{
		`DROP TRIGGER IF EXISTS trg_aliases_never_merge ON aliases`,
		`DROP TRIGGER IF EXISTS trg_delegations_never_merge ON delegations`,
		`DROP TABLE IF EXISTS aliases CASCADE`,
		`DROP TABLE IF EXISTS delegations CASCADE`,
		`DROP TABLE IF EXISTS actors CASCADE`,
	}
	for _, s := range stmts {
		if _, err := db.ExecContext(ctx, s); err != nil {
			t.Fatalf("reset schema (%s): %v", s, err)
		}
	}
}

func pgEncryptor(t *testing.T) Encryptor {
	t.Helper()
	e, err := NewAESGCMEncryptorWithKeys(
		[]byte("01234567890123456789012345678901"),
		[]byte("fedcba9876543210fedcba9876543210"),
		0,
	)
	if err != nil {
		t.Fatalf("NewAESGCMEncryptorWithKeys: %v", err)
	}
	return e
}

// applyLegacySchema applies 001-004 only, producing the pre-migration cleartext schema.
func applyLegacySchema(t *testing.T, db *sql.DB) {
	t.Helper()
	ctx := context.Background()
	for i, m := range []string{
		Migration001IdentityGraph,
		Migration002DelegationIndices,
		Migration003IdempotentSeeding,
		Migration004DelegationRevocation,
	} {
		if _, err := db.ExecContext(ctx, m); err != nil {
			t.Fatalf("apply legacy migration %03d: %v", i+1, err)
		}
	}
}

// TestAliasPG_MigrationEncryptsEveryExistingRow is the card's migration evidence.
//
// It seeds cleartext rows against the pre-005 schema, applies 005 plus the Go backfill, then
// asserts against the database that no cleartext survives and every row is recoverable.
func TestAliasPG_MigrationEncryptsEveryExistingRow(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)
	applyLegacySchema(t, db)

	ctx := context.Background()
	enc := pgEncryptor(t)
	const tenant = "acme-bank"

	// Seed cleartext rows exactly as the pre-migration code would have written them.
	seeded := map[string]string{}
	for i, fx := range FixtureAliases {
		actor := fmt.Sprintf("actor-%d", i)
		if _, err := db.ExecContext(ctx,
			`INSERT INTO actors (actor_id, status, created_at, updated_at) VALUES ($1,'active',NOW(),NOW())
			 ON CONFLICT (actor_id) DO NOTHING`, actor); err != nil {
			t.Fatalf("seed actor: %v", err)
		}
		// The legacy unkeyed digest, i.e. what encryption.go:136 used to produce.
		if _, err := db.ExecContext(ctx,
			`INSERT INTO aliases (actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from, created_at)
			 VALUES ($1,$2,$3,$4,'definitive',NOW() - interval '1 day',NOW())`,
			actor, fx.AliasType, fx.AliasValue, strings.Repeat("0", 64)); err != nil {
			t.Fatalf("seed alias %q: %v", fx.AliasValue, err)
		}
		seeded[actor] = fx.AliasValue
	}

	var before int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value IS NOT NULL`).Scan(&before); err != nil {
		t.Fatalf("count before: %v", err)
	}
	if before != len(FixtureAliases) {
		t.Fatalf("expected %d cleartext rows seeded, got %d", len(FixtureAliases), before)
	}
	t.Logf("pre-migration: %d rows holding cleartext alias_value", before)

	// Apply migration 005 and the Go backfill.
	if _, err := db.ExecContext(ctx, Migration005PseudonymisationAndEncryption); err != nil {
		t.Fatalf("apply 005: %v", err)
	}
	report, err := EncryptExistingAliasValues(ctx, db, enc, tenant)
	if err != nil {
		t.Fatalf("EncryptExistingAliasValues: %v", err)
	}
	t.Logf("backfill report: scanned=%d rewritten=%d remaining_cleartext=%d missing_ciphertext=%d",
		report.Scanned, report.Rewritten, report.RemainingCleartext, report.MissingCiphertext)

	if report.Rewritten != before {
		t.Errorf("backfill rewrote %d rows but %d held cleartext", report.Rewritten, before)
	}

	// Assert against the DATABASE, not the report. A report is the migration's own account of
	// itself; the column is the fact.
	var remaining, missing, badPseudonym int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value IS NOT NULL`).Scan(&remaining); err != nil {
		t.Fatalf("count remaining: %v", err)
	}
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value_encrypted IS NULL`).Scan(&missing); err != nil {
		t.Fatalf("count missing ciphertext: %v", err)
	}
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE alias_value_hash !~ '^[0-9a-f]{64}$'`).Scan(&badPseudonym); err != nil {
		t.Fatalf("count bad pseudonym: %v", err)
	}
	if remaining != 0 {
		t.Errorf("%d rows still hold cleartext alias_value after migration", remaining)
	}
	if missing != 0 {
		t.Errorf("%d rows have NULL alias_value_encrypted after migration", missing)
	}
	if badPseudonym != 0 {
		t.Errorf("%d rows carry a malformed pseudonym after migration", badPseudonym)
	}

	// Every row must round-trip back to its original cleartext.
	repo := NewPostgresRepositoryWithTenant(db, enc, tenant)
	for actor, want := range seeded {
		got, err := repo.GetAliasesForActorAsOf(ctx, actor, time.Now().UTC())
		if err != nil {
			t.Fatalf("GetAliasesForActorAsOf(%s): %v", actor, err)
		}
		if len(got) != 1 {
			t.Fatalf("actor %s: expected 1 alias, got %d", actor, len(got))
		}
		if got[0].AliasValue != want {
			t.Errorf("actor %s: round-trip mismatch, got %q want %q", actor, got[0].AliasValue, want)
		}
	}

	// And lookup by the original value must still resolve through the pseudonym path.
	found, err := repo.FindAliasesAsOf(ctx, FixtureAliases[0].AliasValue, time.Now().UTC())
	if err != nil {
		t.Fatalf("FindAliasesAsOf: %v", err)
	}
	if len(found) == 0 {
		t.Fatal("lookup by original alias value resolved nothing after migration")
	}
	t.Logf("post-migration: 0 cleartext rows, %d rows round-tripped, lookup resolved %d", len(seeded), len(found))
}

// TestAliasPG_RollbackRestoresCleartext executes the rollback rather than merely shipping the file.
func TestAliasPG_RollbackRestoresCleartext(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)
	applyLegacySchema(t, db)

	ctx := context.Background()
	enc := pgEncryptor(t)
	const tenant = "acme-bank"

	if _, err := db.ExecContext(ctx,
		`INSERT INTO actors (actor_id, status, created_at, updated_at) VALUES ('actor-rb','active',NOW(),NOW())`); err != nil {
		t.Fatalf("seed actor: %v", err)
	}
	const secret = "rollback-subject@corp.internal"
	if _, err := db.ExecContext(ctx,
		`INSERT INTO aliases (actor_id, alias_type, alias_value, alias_value_hash, edge_fidelity, valid_from, created_at)
		 VALUES ('actor-rb','email',$1,$2,'definitive',NOW() - interval '1 day',NOW())`,
		secret, strings.Repeat("0", 64)); err != nil {
		t.Fatalf("seed alias: %v", err)
	}

	if _, err := db.ExecContext(ctx, Migration005PseudonymisationAndEncryption); err != nil {
		t.Fatalf("apply 005: %v", err)
	}
	if _, err := EncryptExistingAliasValues(ctx, db, enc, tenant); err != nil {
		t.Fatalf("forward backfill: %v", err)
	}

	// Rollback: data half first, then schema half. This ordering is the documented procedure.
	rb, err := RollbackAliasEncryption(ctx, db, enc)
	if err != nil {
		t.Fatalf("RollbackAliasEncryption: %v", err)
	}
	t.Logf("rollback data pass: scanned=%d restored=%d", rb.Scanned, rb.Rewritten)

	if _, err := db.ExecContext(ctx, Migration005Rollback); err != nil {
		t.Fatalf("apply rollback SQL: %v", err)
	}

	var restored string
	if err := db.QueryRowContext(ctx, `SELECT alias_value FROM aliases WHERE actor_id='actor-rb'`).Scan(&restored); err != nil {
		t.Fatalf("read restored cleartext: %v", err)
	}
	if restored != secret {
		t.Fatalf("rollback restored %q, want %q", restored, secret)
	}

	// The cleartext indexes must be back, and the ciphertext column gone.
	var idxCount int
	if err := db.QueryRowContext(ctx,
		`SELECT count(*) FROM pg_indexes WHERE tablename='aliases'
		   AND indexname IN ('idx_aliases_value_temporal','idx_aliases_idempotent_seed')`).Scan(&idxCount); err != nil {
		t.Fatalf("count restored indexes: %v", err)
	}
	if idxCount != 2 {
		t.Errorf("rollback restored %d/2 cleartext indexes", idxCount)
	}

	var colCount int
	if err := db.QueryRowContext(ctx,
		`SELECT count(*) FROM information_schema.columns
		  WHERE table_name='aliases' AND column_name='alias_value_encrypted'`).Scan(&colCount); err != nil {
		t.Fatalf("check dropped column: %v", err)
	}
	if colCount != 0 {
		t.Errorf("rollback left alias_value_encrypted in place")
	}
	t.Logf("rollback verified: cleartext restored, %d/2 indexes rebuilt, ciphertext column dropped", idxCount)
}

// TestAliasPG_CleartextIndexesAreGone asserts against the live catalogue, not against SQL text.
func TestAliasPG_CleartextIndexesAreGone(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)

	ctx := context.Background()
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations: %v", err)
	}

	type check struct {
		name        string
		wantPresent bool
	}
	for _, c := range []check{
		{"idx_aliases_value_temporal", false},
		{"idx_aliases_idempotent_seed", false},
		{"idx_aliases_idempotent_seed_pseudonymous", true},
		{"idx_aliases_pseudonym_temporal", true},
		{"idx_aliases_hash_temporal", true},
	} {
		var n int
		if err := db.QueryRowContext(ctx,
			`SELECT count(*) FROM pg_indexes WHERE tablename='aliases' AND indexname=$1`, c.name).Scan(&n); err != nil {
			t.Fatalf("query pg_indexes for %s: %v", c.name, err)
		}
		present := n > 0
		if present != c.wantPresent {
			t.Errorf("index %s: present=%v, want %v", c.name, present, c.wantPresent)
		}
	}

	// Idempotency: applying twice must leave the same schema.
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("second ApplyMigrations (idempotency): %v", err)
	}
	var stillGone int
	if err := db.QueryRowContext(ctx,
		`SELECT count(*) FROM pg_indexes WHERE tablename='aliases' AND indexname='idx_aliases_value_temporal'`).Scan(&stillGone); err != nil {
		t.Fatalf("recheck after second apply: %v", err)
	}
	if stillGone != 0 {
		t.Error("re-applying migrations resurrected the cleartext index; 001 recreates it and 005 must drop it again")
	}
}

// TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace is the fail-open probe.
//
// This is the assertion that would have caught the defect Forge identified: with the original
// trigger text and a NULL alias_value, the illegal alias below is ACCEPTED. It only fails if the
// trigger genuinely compares in pseudonym space.
func TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)

	ctx := context.Background()
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations: %v", err)
	}
	enc := pgEncryptor(t)
	const tenant = "acme-bank"
	repo := NewPostgresRepositoryWithTenant(db, enc, tenant)
	now := time.Now().UTC()

	for _, id := range []string{"actor-delegate", "actor-principal"} {
		if err := repo.CreateActor(ctx, ActorRecord{ActorID: id, Status: "active", CreatedAt: now, UpdatedAt: now}); err != nil {
			t.Fatalf("CreateActor(%s): %v", id, err)
		}
	}
	if err := repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "actor-delegate",
		PrincipalActorID: "actor-principal",
		AuthzRef:         "grant-1",
		ValidFrom:        now.Add(-time.Hour),
		CreatedAt:        now,
	}); err != nil {
		t.Fatalf("AddDelegation: %v", err)
	}

	// Aliasing the delegate to its principal must be refused by the DATABASE.
	err := repo.AddAlias(ctx, AliasRecord{
		ActorID:    "actor-delegate",
		AliasType:  "actor",
		AliasValue: "actor-principal",
		ValidFrom:  now,
		CreatedAt:  now,
	})
	if err == nil {
		t.Fatal("FAIL OPEN: the database accepted an alias equating a delegate with its principal. " +
			"The never-merge invariant is not enforced after pseudonymisation.")
	}
	if !strings.Contains(err.Error(), "never-merge") {
		t.Fatalf("expected a never-merge violation, got: %v", err)
	}
	t.Logf("never-merge enforced at the database layer in pseudonym space: %v", err)

	// A legitimate alias must still be accepted — the trigger must not reject everything.
	if err := repo.AddAlias(ctx, AliasRecord{
		ActorID:    "actor-delegate",
		AliasType:  "email",
		AliasValue: "delegate@corp.internal",
		ValidFrom:  now,
		CreatedAt:  now,
	}); err != nil {
		t.Fatalf("a legitimate alias was rejected: %v", err)
	}
}

// TestAliasPG_TriggerRejectsUnpseudonymisedInsert proves the fail-closed arm.
func TestAliasPG_TriggerRejectsUnpseudonymisedInsert(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)

	ctx := context.Background()
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations: %v", err)
	}
	if _, err := db.ExecContext(ctx,
		`INSERT INTO actors (actor_id, status, created_at, updated_at) VALUES ('actor-x','active',NOW(),NOW())`); err != nil {
		t.Fatalf("seed actor: %v", err)
	}

	cases := []struct {
		name string
		stmt string
		args []any
	}{
		{
			"null pseudonym",
			`INSERT INTO aliases (actor_id, alias_type, alias_value_encrypted, alias_value_hash, edge_fidelity, valid_from, created_at)
			 VALUES ('actor-x','email','\x01'::bytea, NULL, 'definitive', NOW(), NOW())`, nil,
		},
		{
			"malformed pseudonym",
			`INSERT INTO aliases (actor_id, alias_type, alias_value_encrypted, alias_value_hash, edge_fidelity, valid_from, created_at)
			 VALUES ('actor-x','email','\x01'::bytea, 'NOT-A-PSEUDONYM', 'definitive', NOW(), NOW())`, nil,
		},
		{
			"missing ciphertext",
			`INSERT INTO aliases (actor_id, alias_type, alias_value_encrypted, alias_value_hash, edge_fidelity, valid_from, created_at)
			 VALUES ('actor-x','email', NULL, $1, 'definitive', NOW(), NOW())`,
			[]any{strings.Repeat("a", 64)},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := db.ExecContext(ctx, tc.stmt, tc.args...)
			if err == nil {
				t.Fatalf("the database accepted a row with %s; the fail-closed arm is not firing", tc.name)
			}
			t.Logf("rejected as expected: %v", err)
		})
	}
}

// TestAliasPG_DuplicateAliasStillRefused proves the uniqueness control survived the index swap.
//
// Migration 005 drops the UNIQUE idx_aliases_idempotent_seed, which enforced uniqueness on the
// cleartext (actor_id, alias_type, alias_value, valid_from). If its pseudonymous replacement did
// not actually take over, this card would have deleted a dedup/integrity control while describing
// itself as a privacy improvement — and every other test here would still pass.
func TestAliasPG_DuplicateAliasStillRefused(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)

	ctx := context.Background()
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations: %v", err)
	}
	repo := NewPostgresRepositoryWithTenant(db, pgEncryptor(t), "acme-bank")
	now := time.Now().UTC().Truncate(time.Microsecond)

	if err := repo.CreateActor(ctx, ActorRecord{ActorID: "actor-dup", Status: "active", CreatedAt: now, UpdatedAt: now}); err != nil {
		t.Fatalf("CreateActor: %v", err)
	}
	rec := AliasRecord{
		ActorID: "actor-dup", AliasType: "email", AliasValue: "dup@corp.internal",
		ValidFrom: now, CreatedAt: now,
	}
	if err := repo.AddAlias(ctx, rec); err != nil {
		t.Fatalf("first AddAlias: %v", err)
	}
	// The second insert must be absorbed by ON CONFLICT DO NOTHING against the pseudonymous
	// unique index, not admitted as a second row.
	if err := repo.AddAlias(ctx, rec); err != nil {
		t.Fatalf("second AddAlias returned an unexpected error: %v", err)
	}

	var n int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM aliases WHERE actor_id='actor-dup'`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Fatalf("duplicate alias produced %d rows; the uniqueness control did not survive the index swap", n)
	}

	// And the unique index must be the pseudonymous one, refusing a raw duplicate insert too.
	var idx string
	if err := db.QueryRowContext(ctx,
		`SELECT indexname FROM pg_indexes WHERE tablename='aliases' AND indexdef LIKE '%UNIQUE%' AND indexname LIKE '%idempotent%'`).Scan(&idx); err != nil {
		t.Fatalf("locate unique index: %v", err)
	}
	if idx != "idx_aliases_idempotent_seed_pseudonymous" {
		t.Errorf("unique idempotency index is %q, expected the pseudonymous replacement", idx)
	}
}

// TestAliasPG_NeverMergeSurvivesEpochRotation is the deferred-fail-open probe.
//
// The never-merge trigger compares alias_value_hash against delegations.*_actor_pseudonym. Both
// are epoch-bound. Rotating the pseudonym epoch without re-deriving the delegation columns makes
// every comparison miss — the trigger silently degrades to a no-op, which is precisely the
// fail-open this card closed, merely deferred by one rotation.
//
// This test asserts BOTH halves: that a naive rotation breaks enforcement (so the hazard is real
// and not theoretical), and that re-running the backfill to re-derive the delegation pseudonyms
// restores it. The rotation procedure in docs/signalloom/sldp-p2-1-proof.md §4 step 2 exists
// because of this.
func TestAliasPG_NeverMergeSurvivesEpochRotation(t *testing.T) {
	db := livePG(t)
	defer db.Close()
	freshSchema(t, db)

	ctx := context.Background()
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations: %v", err)
	}
	now := time.Now().UTC()
	const tenant = "acme-bank"

	encEpoch0, err := NewAESGCMEncryptorWithKeys(
		[]byte("01234567890123456789012345678901"), []byte("fedcba9876543210fedcba9876543210"), 0)
	if err != nil {
		t.Fatalf("epoch 0 encryptor: %v", err)
	}
	repo0 := NewPostgresRepositoryWithTenant(db, encEpoch0, tenant)

	for _, id := range []string{"actor-delegate", "actor-principal"} {
		if err := repo0.CreateActor(ctx, ActorRecord{ActorID: id, Status: "active", CreatedAt: now, UpdatedAt: now}); err != nil {
			t.Fatalf("CreateActor(%s): %v", id, err)
		}
	}
	if err := repo0.AddDelegation(ctx, DelegationRecord{
		DelegateActorID: "actor-delegate", PrincipalActorID: "actor-principal",
		AuthzRef: "grant-1", ValidFrom: now.Add(-time.Hour), CreatedAt: now,
	}); err != nil {
		t.Fatalf("AddDelegation: %v", err)
	}

	illegal := AliasRecord{
		ActorID: "actor-delegate", AliasType: "actor", AliasValue: "actor-principal",
		ValidFrom: now, CreatedAt: now,
	}
	if err := repo0.AddAlias(ctx, illegal); err == nil {
		t.Fatal("baseline: the illegal alias was accepted at epoch 0")
	}

	// Rotate the epoch WITHOUT re-deriving delegations.*_actor_pseudonym.
	encEpoch1, err := NewAESGCMEncryptorWithKeys(
		[]byte("01234567890123456789012345678901"), []byte("fedcba9876543210fedcba9876543210"), 1)
	if err != nil {
		t.Fatalf("epoch 1 encryptor: %v", err)
	}
	repo1 := NewPostgresRepositoryWithTenant(db, encEpoch1, tenant)

	illegal.ValidFrom = now.Add(time.Minute)
	errRotated := repo1.AddAlias(ctx, illegal)
	if errRotated == nil {
		t.Logf("CONFIRMED HAZARD: after a naive epoch rotation the illegal alias was ACCEPTED. " +
			"Delegation pseudonyms are epoch-bound and must be re-derived as part of rotation " +
			"(see sldp-p2-1-proof.md §4 step 2).")
	} else {
		t.Fatalf("expected the naive rotation to expose the hazard, but the insert was refused: %v. "+
			"If the trigger is epoch-independent this test's premise is wrong and the rotation "+
			"procedure should be re-derived.", errRotated)
	}

	// Clean up the row the hazard admitted, then run the real rotation tool.
	if _, err := db.ExecContext(ctx, `DELETE FROM aliases WHERE actor_id='actor-delegate'`); err != nil {
		t.Fatalf("cleanup: %v", err)
	}

	// EncryptExistingAliasValues is NOT the rotation tool and must not be used as one: it only
	// populates pseudonyms that are NULL, and check_never_merge_delegation refuses to let them be
	// nulled. Confirm that refusal here, so nobody "simplifies" the rotation back to a null-and-
	// backfill and silently leaves the graph half-rotated.
	if _, err := db.ExecContext(ctx, `UPDATE delegations SET delegate_actor_pseudonym = NULL`); err == nil {
		t.Fatal("the database allowed a delegation pseudonym to be nulled; the fail-closed arm of " +
			"check_never_merge_delegation is not firing")
	} else {
		t.Logf("null-and-backfill rotation correctly refused: %v", err)
	}

	if _, err := RederivePseudonymsForEpoch(ctx, db, encEpoch0, encEpoch1, tenant); err != nil {
		t.Fatalf("RederivePseudonymsForEpoch: %v", err)
	}

	illegal.ValidFrom = now.Add(2 * time.Minute)
	if err := repo1.AddAlias(ctx, illegal); err == nil {
		t.Fatal("after re-deriving delegation pseudonyms at the new epoch, the illegal alias was " +
			"STILL accepted; the rotation procedure does not restore never-merge enforcement")
	} else {
		t.Logf("enforcement restored after re-deriving delegation pseudonyms at epoch 1: %v", err)
	}
}

// BenchmarkAliasPG_FindAliasesAsOf measures the lookup this card changes, against a real database.
//
// No such benchmark existed. The "~22µs/lookup" figure quoted elsewhere in the docs comes from
// sublinear_test.go, which scans a Go slice in MemoryRepository and never touches Postgres — so it
// was never evidence about the indexed path at all.
func BenchmarkAliasPG_FindAliasesAsOf(b *testing.B) {
	dsn := os.Getenv(pgDSNEnv)
	if dsn == "" {
		b.Skipf("%s not set", pgDSNEnv)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		b.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	ctx := context.Background()
	for _, s := range []string{
		`DROP TABLE IF EXISTS aliases CASCADE`,
		`DROP TABLE IF EXISTS delegations CASCADE`,
		`DROP TABLE IF EXISTS actors CASCADE`,
	} {
		if _, err := db.ExecContext(ctx, s); err != nil {
			b.Fatalf("reset: %v", err)
		}
	}
	if err := ApplyMigrations(ctx, db); err != nil {
		b.Fatalf("ApplyMigrations: %v", err)
	}

	e, err := NewAESGCMEncryptorWithKeys(
		[]byte("01234567890123456789012345678901"),
		[]byte("fedcba9876543210fedcba9876543210"), 0)
	if err != nil {
		b.Fatalf("encryptor: %v", err)
	}
	repo := NewPostgresRepositoryWithTenant(db, e, "acme-bank")
	now := time.Now().UTC()

	const n = 12000
	if _, err := db.ExecContext(ctx,
		`INSERT INTO actors (actor_id, status, created_at, updated_at) VALUES ('bench-actor','active',NOW(),NOW())
		 ON CONFLICT (actor_id) DO NOTHING`); err != nil {
		b.Fatalf("seed actor: %v", err)
	}
	for i := 0; i < n; i++ {
		if err := repo.AddAlias(ctx, AliasRecord{
			ActorID:    "bench-actor",
			AliasType:  "email",
			AliasValue: fmt.Sprintf("user%06d@corp.internal", i),
			ValidFrom:  now.Add(-time.Hour),
			CreatedAt:  now,
		}); err != nil {
			b.Fatalf("seed alias %d: %v", i, err)
		}
	}
	if _, err := db.ExecContext(ctx, `ANALYZE aliases`); err != nil {
		b.Fatalf("analyze: %v", err)
	}

	target := fmt.Sprintf("user%06d@corp.internal", n/2)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		got, err := repo.FindAliasesAsOf(ctx, target, now)
		if err != nil {
			b.Fatalf("FindAliasesAsOf: %v", err)
		}
		if len(got) != 1 {
			b.Fatalf("expected 1 alias, got %d", len(got))
		}
	}
}
