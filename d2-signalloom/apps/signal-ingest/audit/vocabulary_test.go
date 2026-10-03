package audit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// Live, 2026-10-03: signal-ingest shipped with event type batch_chain before
// fe-signalloom (which owns the migrations) had run 051, which admits it.
// Every batch's audit write violated signal_audit_trail_event_type_check, the
// handler failed closed with 503, and the sentinel delivered nothing until
// fe-signalloom was rolled -- while every signal-ingest pod reported Ready.
// Readiness now checks the live constraint admits AllEventTypes, so a
// wrong-order deploy stalls the rollout instead of failing every batch.

// pgDef is what pg_get_constraintdef returns for 051's constraint: Postgres
// rewrites IN (...) as = ANY (ARRAY[...]) with ::text casts.
func pgDef(types ...string) string {
	quoted := make([]string, len(types))
	for i, t := range types {
		quoted[i] = "'" + t + "'::text"
	}
	return "CHECK ((event_type = ANY (ARRAY[" + strings.Join(quoted, ", ") + "])))"
}

func allNames() []string {
	out := make([]string, len(AllEventTypes))
	for i, t := range AllEventTypes {
		out[i] = string(t)
	}
	return out
}

func source(def string, found bool, err error) ConstraintSource {
	return func(context.Context) (string, bool, error) { return def, found, err }
}

func TestCheckVocabularyPassesWhenEveryTypeIsAdmitted(t *testing.T) {
	if err := CheckVocabulary(context.Background(), source(pgDef(allNames()...), true, nil), AllEventTypes); err != nil {
		t.Fatalf("every type admitted, got %v", err)
	}
}

func TestCheckVocabularyNamesTheMissingTypes(t *testing.T) {
	var without []string
	for _, n := range allNames() {
		if n != string(EventBatchChain) {
			without = append(without, n)
		}
	}
	err := CheckVocabulary(context.Background(), source(pgDef(without...), true, nil), AllEventTypes)
	var gap *VocabularyError
	if !errors.As(err, &gap) {
		t.Fatalf("err = %v, want *VocabularyError", err)
	}
	if len(gap.Missing) != 1 || gap.Missing[0] != EventBatchChain {
		t.Fatalf("missing = %v, want [batch_chain]", gap.Missing)
	}
	if msg := err.Error(); !strings.Contains(msg, "batch_chain") || !strings.Contains(msg, "fe-signalloom") {
		t.Fatalf("error %q must name the type and the owner of the migrations", msg)
	}
}

// A literal is admitted only by exact match: 'batch_chain_v2' is not 'batch_chain'.
func TestCheckVocabularyMatchesLiteralsExactly(t *testing.T) {
	names := allNames()
	for i, n := range names {
		if n == string(EventBatchChain) {
			names[i] = "batch_chain_v2"
		}
	}
	var gap *VocabularyError
	if err := CheckVocabulary(context.Background(), source(pgDef(names...), true, nil), AllEventTypes); !errors.As(err, &gap) {
		t.Fatalf("err = %v: a prefix-sharing literal admitted batch_chain", err)
	}
}

func TestCheckVocabularyFailsClosedWhenTheConstraintIsAbsent(t *testing.T) {
	err := CheckVocabulary(context.Background(), source("", false, nil), AllEventTypes)
	if !errors.Is(err, ErrEventTypeConstraintAbsent) {
		t.Fatalf("err = %v, want ErrEventTypeConstraintAbsent", err)
	}
}

func TestCheckVocabularyFailsClosedWhenTheQueryErrors(t *testing.T) {
	boom := errors.New("pq: permission denied for table pg_constraint")
	if err := CheckVocabulary(context.Background(), source("", false, boom), AllEventTypes); !errors.Is(err, boom) {
		t.Fatalf("err = %v, want the query error wrapped", err)
	}
}

// A definition with no admitted literals cannot be shown to admit anything.
func TestCheckVocabularyFailsClosedOnADefinitionItCannotRead(t *testing.T) {
	for _, def := range []string{"CHECK ((length(event_type) > 0))", "CHECK ((status = ANY (ARRAY['a'::text])))"} {
		if err := CheckVocabulary(context.Background(), source(def, true, nil), AllEventTypes); err == nil {
			t.Fatalf("%q: passed, want a fail-closed error", def)
		}
	}
}

// Offline parity, the forgotten-migration case: the NEWEST fe-signalloom
// migration that (re)defines the event_type constraint must admit every
// type signal-ingest emits. The readiness check catches deploy order; this
// catches a type added here with no migration written for it.
func TestAllEventTypesAdmittedByTheNewestConstraintMigration(t *testing.T) {
	dir := "../../fe-signalloom/src/db/migrations"
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	defRe := regexp.MustCompile(`(?is)ADD\s+CONSTRAINT\s+signal_audit_trail_event_type_check\s+CHECK\s*\(\s*event_type\s+IN\s*\(([^)]*)\)`)
	var newest, list string
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			t.Fatal(err)
		}
		if m := defRe.FindStringSubmatch(string(b)); m != nil {
			newest, list = n, m[1]
		}
	}
	if newest == "" {
		t.Fatalf("no migration in %s defines signal_audit_trail_event_type_check", dir)
	}
	admitted := map[string]bool{}
	for _, m := range regexp.MustCompile(`'([^']+)'`).FindAllStringSubmatch(list, -1) {
		admitted[m[1]] = true
	}
	for _, et := range AllEventTypes {
		if !admitted[string(et)] {
			t.Errorf("%s (newest constraint migration) does not admit %q: write a migration before shipping the type", newest, et)
		}
	}
}
