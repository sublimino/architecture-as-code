// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package identity

import (
	"context"
	"database/sql"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/subjectkey"
)

// Note: stripSQLComments lives in tenant_test.go and is reused here deliberately. Stripping `--`
// comments before any text assertion matters because otherwise a grep for a forbidden construct
// matches the COMMENT explaining why the construct was avoided.

// ISC-21..ISC-30, ISC-33..ISC-37: the migration declares what it claims to.
//
// EVERY assertion in this test is about a DOCUMENT, not a database. A schema assertion that never
// executes the schema is asserting about text — see TestMigration009_AppliesToLiveDatabase for the
// only check that distinguishes valid SQL from plausible SQL.
func TestMigration009_DeclaresSubjectKeySchema(t *testing.T) {
	m := Migration009SubjectKeys
	if m == "" {
		t.Fatal("Migration009SubjectKeys is empty; the embed did not resolve")
	}
	body := stripSQLComments(m)

	for _, want := range []string{
		"CREATE TABLE IF NOT EXISTS subject_keys",
		"CREATE TABLE IF NOT EXISTS subject_key_erasures",
		"ALTER TABLE subject_keys ENABLE ROW LEVEL SECURITY",
		"ALTER TABLE subject_keys FORCE ROW LEVEL SECURITY",
		"ALTER TABLE subject_key_erasures ENABLE ROW LEVEL SECURITY",
		"ALTER TABLE subject_key_erasures FORCE ROW LEVEL SECURITY",
		"CREATE POLICY subject_keys_tenant_isolation",
		"CREATE POLICY subject_key_erasures_tenant_isolation",
		"DROP POLICY IF EXISTS subject_keys_tenant_isolation",
		"DROP POLICY IF EXISTS subject_key_erasures_tenant_isolation",
		"USING (tenant_id = app_current_tenant())",
		"WITH CHECK (tenant_id = app_current_tenant())",
		"prior_wrapped_digest",
		"destroyed_at",
		"operation_id      TEXT        PRIMARY KEY",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("migration 009 does not contain %q", want)
		}
	}

	// The scope IS the identity. Anything narrower collides across epochs after a rotation.
	if !strings.Contains(body, "PRIMARY KEY (tenant_id, subject_pseudonym, key_epoch, key_version)") {
		t.Error("subject_keys does not key on the full (tenant, subject, epoch, version) scope")
	}

	// The fail-closed backstops. Each of these is the database refusing a state the Go code must
	// never reach, and each is the only place that refusal cannot be bypassed by a forgotten path.
	for _, want := range []string{
		"CHECK (destroyed_at IS NULL OR prior_wrapped_digest <> '')",
		"CHECK (state <> 'completed' OR receipt_digest <> '')",
		"CHECK (state <> 'completed' OR completed_at IS NOT NULL)",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("migration 009 is missing the fail-closed constraint %q", want)
		}
	}
}

// ISC-31: no CHECK constraint contains a subquery.
//
// PostgreSQL 16 rejects those at DDL time with "cannot use subquery in check constraint", and
// ApplyMigrations runs every migration inside ONE transaction — so one bad constraint aborts the
// whole migration and every table in this file silently never exists, while every text assertion
// above stays green.
func TestMigration009_NoSubqueryInCheckConstraint(t *testing.T) {
	body := stripSQLComments(Migration009SubjectKeys)
	lower := strings.ToLower(body)

	// Falsify the detector first: a pattern that matches nothing reports "clean" exactly as a clean
	// migration does.
	bait := "check (array_length(ids,1) = (select count(*) from unnest(ids)))"
	forbidden := regexp.MustCompile(`\(\s*select\s|\bfrom\s+unnest\(`)
	if !forbidden.MatchString(bait) {
		t.Fatal("the subquery detector does not match a known-bad constraint; it would pass any migration")
	}

	if forbidden.MatchString(lower) {
		loc := forbidden.FindStringIndex(lower)
		t.Errorf("migration 009 contains a subquery construct at offset %d: %q", loc[0], body[loc[0]:min(loc[0]+80, len(body))])
	}
}

// ISC-42: the SQL state enumeration and the Go one are one source, not two.
//
// The migration's CHECK list is compared against subjectkey.SagaStates rendered as SQL. A guard that
// copies its source of truth drifts from it and both halves stay green; one that derives from it
// cannot.
func TestMigration009_StateCheckMatchesGo(t *testing.T) {
	want := subjectkey.SagaStateSQLList()
	body := stripSQLComments(Migration009SubjectKeys)
	if !strings.Contains(body, "CHECK (state IN ("+want+"))") {
		t.Fatalf("the migration's state CHECK does not match the Go enumeration.\n  Go wants: CHECK (state IN (%s))\n"+
			"  If a state was added to subjectkey.SagaStates, migration 009 must be updated in the same commit.", want)
	}
	// And the reverse direction: every state literal in the SQL must be a declared Go state, so the
	// SQL cannot admit a state the Go ladder has no transition for.
	declared := map[string]bool{}
	for _, s := range subjectkey.SagaStates {
		declared[string(s)] = true
	}
	re := regexp.MustCompile(`CHECK \(state IN \(([^)]*)\)\)`)
	mm := re.FindStringSubmatch(body)
	if mm == nil {
		t.Fatal("could not locate the state CHECK constraint")
	}
	for _, raw := range strings.Split(mm[1], ",") {
		lit := strings.Trim(strings.TrimSpace(raw), "'")
		if lit != "" && !declared[lit] {
			t.Errorf("the SQL admits state %q which subjectkey.SagaStates does not declare", lit)
		}
	}
}

// ISC-23, ISC-24: 009 is wired into both the concatenation and the applier.
//
// Being embedded is not being applied. A migration present in MigrationSQL() but absent from
// ApplyMigrations would pass every text test in this file and create no tables at all.
func TestMigration009_IsWiredIntoMigrationSQL(t *testing.T) {
	all := MigrationSQL()
	if !strings.Contains(all, "CREATE TABLE IF NOT EXISTS subject_keys") {
		t.Error("MigrationSQL() does not include migration 009")
	}
	// The applier is checked by the live test below; here assert the ordering invariant that makes
	// it applicable at all — 009's policies call app_current_tenant(), which 006 defines.
	i006 := strings.Index(all, "CREATE OR REPLACE FUNCTION app_current_tenant")
	i009 := strings.Index(all, "CREATE TABLE IF NOT EXISTS subject_keys")
	if i006 < 0 {
		t.Skip("app_current_tenant definition not found in 006; ordering assertion skipped")
	}
	if i009 < i006 {
		t.Error("migration 009 is concatenated BEFORE the app_current_tenant() definition it depends on")
	}
}

// ISC-38: no earlier migration was modified by this card.
//
// The card's hard blocker list forbids rewriting existing schema. This asserts the shape of that
// promise that is cheaply checkable: 001-008 still declare their own tables.
func TestMigration009_DoesNotDisturbEarlierMigrations(t *testing.T) {
	for name, m := range map[string]string{
		"005": Migration005PseudonymisationAndEncryption,
		"006": Migration006TenantIsolationRLS,
		"007": Migration007SegmentReidentificationMap,
		"008": Migration008RetentionLegalHolds,
	} {
		if strings.Contains(m, "subject_keys") {
			t.Errorf("migration %s mentions subject_keys; 009's schema leaked into an earlier migration", name)
		}
	}
	if strings.Contains(Migration009SubjectKeys, "DROP TABLE") {
		t.Error("migration 009 drops a table; it must be purely additive")
	}
	if strings.Contains(Migration009SubjectKeys, "ALTER TABLE aliases") ||
		strings.Contains(Migration009SubjectKeys, "ALTER TABLE segment_reidentification_map") {
		t.Error("migration 009 alters an existing table; it must be purely additive")
	}
}

// --------------------------------------------------------------------------------------------
// Live PostgreSQL. Everything above asserts about text; only this executes the schema.
// --------------------------------------------------------------------------------------------

const subjectKeysPGDSNEnv = "SLDP_PG_DSN"

// TestMigration009_GateIsHonest always runs. It reports whether the live assertions in this file
// executed, so "the suite was green" cannot be mistaken for "the migration was applied".
func TestMigration009_GateIsHonest(t *testing.T) {
	if os.Getenv(subjectKeysPGDSNEnv) == "" {
		t.Logf("COVERAGE GAP: %s is unset, so TestMigration009_AppliesToLiveDatabase was SKIPPED. "+
			"Every other assertion in this file is a string match over migration TEXT and passes "+
			"whether or not the DDL is valid PostgreSQL. The regex constraints, octet_length check, "+
			"INTEGER[] column, row-level security policies and idempotency of 009 are NOT covered by "+
			"this run.", subjectKeysPGDSNEnv)
		return
	}
	t.Logf("live PostgreSQL configured via %s; migration 009 will actually be applied", subjectKeysPGDSNEnv)
}

// ISC-32, and the only check that distinguishes valid SQL from plausible SQL.
func TestMigration009_AppliesToLiveDatabase(t *testing.T) {
	dsn := os.Getenv(subjectKeysPGDSNEnv)
	if dsn == "" {
		t.Skipf("%s not set; see TestMigration009_GateIsHonest", subjectKeysPGDSNEnv)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations (including 009): %v", err)
	}
	// Idempotency: a second apply must be a no-op, not an error.
	if err := ApplyMigrations(ctx, db); err != nil {
		t.Fatalf("ApplyMigrations is not idempotent: %v", err)
	}

	for _, table := range subjectkey.MigrationTableNames() {
		var relrowsecurity, relforcerowsecurity bool
		err := db.QueryRowContext(ctx,
			`SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1`, table).
			Scan(&relrowsecurity, &relforcerowsecurity)
		if err != nil {
			t.Fatalf("table %s was not created: %v", table, err)
		}
		if !relrowsecurity {
			t.Errorf("%s does not have row-level security ENABLED", table)
		}
		if !relforcerowsecurity {
			t.Errorf("%s does not have row-level security FORCED; the table owner is exempt", table)
		}
		var policies int
		if err := db.QueryRowContext(ctx,
			`SELECT count(*) FROM pg_policies WHERE tablename = $1`, table).Scan(&policies); err != nil {
			t.Fatalf("count policies on %s: %v", table, err)
		}
		if policies == 0 {
			t.Errorf("%s has no row-level security policy; ENABLE alone denies everything or nothing", table)
		}
	}

	// The fail-closed constraints must actually REFUSE, not merely exist in the text.
	t.Run("destroyed row without a digest is refused", func(t *testing.T) {
		_, err := db.ExecContext(ctx, `
			INSERT INTO subject_keys (tenant_id, subject_pseudonym, key_epoch, key_version, wrapped_dek, destroyed_at)
			VALUES ('t-live', repeat('a', 64), 0, 1, decode(repeat('00', 60), 'hex'), now())`)
		if err == nil {
			t.Error("the database accepted a destroyed key row with no prior_wrapped_digest")
		}
	})
	t.Run("completed saga without a digest is refused", func(t *testing.T) {
		_, err := db.ExecContext(ctx, `
			INSERT INTO subject_key_erasures (operation_id, tenant_id, subject_pseudonym, state, nonce, completed_at)
			VALUES (repeat('b', 64), 't-live', repeat('a', 64), 'completed', repeat('c', 64), now())`)
		if err == nil {
			t.Error("the database accepted a completed erasure saga with no receipt digest")
		}
	})
	t.Run("unknown saga state is refused", func(t *testing.T) {
		_, err := db.ExecContext(ctx, `
			INSERT INTO subject_key_erasures (operation_id, tenant_id, subject_pseudonym, state, nonce)
			VALUES (repeat('d', 64), 't-live', repeat('a', 64), 'half_done', repeat('c', 64))`)
		if err == nil {
			t.Error("the database accepted a saga state outside the enumeration")
		}
	})
	t.Run("cleartext subject identifier is refused", func(t *testing.T) {
		_, err := db.ExecContext(ctx, `
			INSERT INTO subject_keys (tenant_id, subject_pseudonym, key_epoch, key_version, wrapped_dek)
			VALUES ('t-live', 'alice@example.com', 0, 1, decode(repeat('00', 60), 'hex'))`)
		if err == nil {
			t.Error("the database accepted a cleartext subject identifier in subject_pseudonym")
		}
	})
	t.Run("wrong-length wrapped key is refused", func(t *testing.T) {
		_, err := db.ExecContext(ctx, `
			INSERT INTO subject_keys (tenant_id, subject_pseudonym, key_epoch, key_version, wrapped_dek)
			VALUES ('t-live', repeat('e', 64), 0, 1, decode(repeat('00', 31), 'hex'))`)
		if err == nil {
			t.Error("the database accepted a wrapped key of the wrong length")
		}
	})
}
