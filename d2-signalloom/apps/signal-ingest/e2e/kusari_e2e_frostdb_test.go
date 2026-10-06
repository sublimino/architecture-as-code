//go:build frostdb

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"context"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// The same suite over the store the pod actually runs.
//
// MemoryStore and FrostDBStore differ in the two ways that matter here.
//
//  1. FrostDBStore.Append writes Parquet and is append-only by construction, so
//     a duplicate is a durable row in a segment nobody is going to rewrite. The
//     idempotency defect this suite guards was observed against FrostDB, not
//     against the MemoryStore.
//  2. FrostDBStore materialises every label key as an Arrow column and checks it
//     against store.defaultLabelAllowList, a CLOSED set. A key outside that set
//     makes Append refuse the WHOLE BATCH. So this test is also the gate that
//     keeps the §2.3 projection inside the allow-list: the Kusari fixtures
//     deliberately add no new label key, and if one were added this is where it
//     would be caught — as a refused write rather than as a dropped column.
//
// The segment store fails closed without pseudonymisation key material, which is
// the contract that stopped the kind-osramp pod, so test material is supplied
// the way collectors/awslogs/frostdb_contract_test.go supplies it.
const testPseudonymKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

func newFrostDB(t *testing.T) store.SignalStore {
	t.Helper()
	t.Setenv(store.SegmentPseudonymKeyEnv, testPseudonymKey)
	st, err := store.NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

// The expectation table holds over FrostDB, which means every projected label
// key is in the segment allow-list and every finding and decision landed.
func TestKusariE2E_FrostDBMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, newFrostDB(t), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()
	census := Census(rows(t, h))
	t.Log(SummaryTable(ruleExpectations, windowExpectations, byRule, byWindow, census))

	for _, r := range ruleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings over FrostDB, want %d", r.Bundle, r.Rule, got, r.Findings)
		}
	}
	for _, w := range windowExpectations {
		if got := byWindow[w.Bundle+"/"+w.Window]; got != w.Decisions {
			t.Errorf("window %s/%s produced %d decisions over FrostDB, want %d", w.Bundle, w.Window, got, w.Decisions)
		}
	}
	if census != (Tally{Observations: wantKusariObservations, Findings: wantKusariFindings, Decisions: wantKusariDecisions}) {
		t.Errorf("FrostDB census = %+v, want %d/%d/%d", census, wantKusariObservations, wantKusariFindings, wantKusariDecisions)
	}
	// A refused batch is the failure mode a new label key produces, and it is
	// reported through the write path rather than through a missing column.
	if snap := h.Metrics.Snapshot(); snap.FindingWriteErrors != 0 || snap.DecisionWriteErrors != 0 {
		t.Errorf("FrostDB refused %d finding and %d decision writes; a label key outside store.defaultLabelAllowList refuses the whole batch",
			snap.FindingWriteErrors, snap.DecisionWriteErrors)
	}
}

// Replay over a segment-schema-v2 FrostDB store reproduces live, byte for byte
// on the canonical projection -- the same claim its MemoryStore sibling
// (TestKusariE2E_ReplayReproducesLive) makes, now true over the store the pod
// actually runs.
//
// # What this replaced, and why it was true
//
// This test used to PIN a divergence rather than assert equality. Segment schema
// v2 is the privacy contract: FrostDBStore.Append writes hmac_actor_hint and the
// v2 layout has no actor_hint column at all, so every observation read back
// carried an EMPTY ActorHint. policy.Replay re-evaluated those rows and toObscel
// mapped the empty hint onto obs.actor, so every rule and every window saw
// obs.actor == "".
//
// That was worse than a blank column, because every allowlist in both shipped
// bundles is a NEGATIVE test on the actor. An empty actor SATISFIES the
// negation, so on replay the break-glass records live correctly ignored fired,
// kusari-operator's allowlisted console sign-in fired, cross-account-assume-role
// stopped firing entirely because its obs.actor != "" guard went false, and
// every actor-keyed window collapsed into one counter. Live 62 findings / 3
// decisions; replay 64 / 2. Wrong in both directions at once, and the runbook
// sent the operator after a clock that was not the problem.
//
// # Why it is now true
//
// The pseudonym IS the actor identity, on both paths (policy.ActorIdentity). A
// v2 row's hmac_actor_hint is used verbatim; a live observation's cleartext hint
// goes through the store's OWN pseudonymiser, so it lands on the identical
// value. The bundles' actor allowlists are rewritten into the same space at load
// (actor_vars + obscel.PseudonymiseActorVars), and Conform refuses any rule that
// compares obs.actor against a var not declared there. cross-account-assume-role
// no longer dissects the actor ARN: it compares actor_account_id against
// aws_account_id, both projected labels that round-trip through a segment.
//
// The mechanism is asserted separately below. This test asserts only the
// OUTCOME, so a mechanism change that preserved the outcome would not fail here.
func TestKusariE2E_FrostDBReplayReproducesLive(t *testing.T) {
	h := newHarness(t, newFrostDB(t), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	live := h.Recorder.CanonicalLines()
	if len(live) == 0 {
		t.Fatal("the live run recorded nothing; the equality claim would be vacuous")
	}
	replayed := replayLines(t, h, c)

	if len(live) != len(replayed) {
		t.Fatalf("live produced %d canonical lines over FrostDB, replay %d", len(live), len(replayed))
	}
	for i := range live {
		if live[i] != replayed[i] {
			t.Fatalf("canonical line %d differs over FrostDB\n  live: %s\nreplay: %s", i, live[i], replayed[i])
		}
	}
	t.Logf("FrostDB replay reproduced live exactly: %d canonical lines", len(live))
}

// The MECHANISM behind the equality above, asserted so a regression names its
// own cause instead of surfacing as an opaque line-count mismatch.
//
// Four claims, every one of which was false before this change:
//
//  1. the stored source observation still carries NO cleartext actor, so parity
//     was not bought by weakening the privacy contract;
//  2. what policy evaluates is the PSEUDONYM -- not the empty string the old
//     replay saw, and not the cleartext the old live path saw;
//  3. the bundle allowlists live in that same pseudonym space, so a negative
//     allowlist test can actually exclude somebody;
//  4. therefore the two records that prove the DIRECTION behave correctly on
//     both sides: the allowlisted console sign-in stays silent, and the two
//     genuine cross-account assumptions plus their burst decision survive.
func TestKusariE2E_FrostDBReplayMechanism_PseudonymisedActorAndAllowlists(t *testing.T) {
	h := newHarness(t, newFrostDB(t), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	// (1) The privacy contract still holds: no cleartext actor comes back.
	stored, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	sources, pseudonymised := 0, 0
	for _, o := range stored {
		if o.Source == obscel.SourceFinding || o.Source == obscel.SourceDecision {
			continue
		}
		sources++
		if o.ActorHint != "" {
			t.Errorf("a v2 segment returned a cleartext actor %q for %s; replay parity must not be bought by weakening the schema",
				o.ActorHint, o.ID)
		}
		if o.HMACActorHint != "" {
			pseudonymised++
		}
	}
	if sources == 0 {
		t.Fatal("no source observations were read back; nothing below can be established")
	}
	if pseudonymised == 0 {
		t.Fatal("no stored observation carries hmac_actor_hint; replay would have no actor to read")
	}

	// (2) What policy evaluates is that pseudonym. Every finding for an
	// actor-bearing record carries a 64-hex actor, never an ARN and never empty.
	actors := 0
	for _, f := range h.Recorder.Findings {
		if f.Actor == "" {
			continue // VPC Flow names no principal, which is correct and tested elsewhere.
		}
		actors++
		if len(f.Actor) != 64 {
			t.Errorf("finding %s carries actor %q, want a 64-character pseudonym", f.ID, f.Actor)
		}
		if strings.HasPrefix(f.Actor, "arn:") {
			t.Errorf("finding %s carries a cleartext ARN actor %q", f.ID, f.Actor)
		}
	}
	if actors == 0 {
		t.Fatal("no finding carries an actor; the pseudonymisation claim would be vacuous")
	}

	// (3) The allowlists were rewritten into the same space at load. A cleartext
	// ARN surviving here IS the silent-inversion defect: the list could never
	// match a pseudonym, so every negative allowlist test becomes always-true and
	// the exempted identity fires on every record -- identically on both sides,
	// so the equality assertion above would still pass.
	declared := 0
	for _, b := range h.Bundles {
		for _, name := range b.ActorVars {
			declared++
			for _, v := range b.Vars[name] {
				if len(v) != 64 || strings.HasPrefix(v, "arn:") {
					t.Errorf("bundle %s vars.%s holds %q, which is not a pseudonym; "+
						"obs.actor can never match it and !(obs.actor in vars.%s) becomes always-true",
						b.ID, name, v, name)
				}
			}
		}
	}
	if declared == 0 {
		t.Fatal("no bundle declares actor_vars; the shipped bundles' allowlists are unprotected")
	}

	// (4) The direction, on BOTH sides. These are the two records the pinned
	// defect used to show going the wrong way.
	for label, lines := range map[string][]string{
		"live":   h.Recorder.CanonicalLines(),
		"replay": replayLines(t, h, c),
	} {
		operator, crossAccount := 0, 0
		for _, l := range lines {
			if strings.Contains(l, "console-login-outside-allowlist") && strings.Contains(l, "source_ip=198.51.100.3") {
				operator++
			}
			if strings.Contains(l, "|cross-account-assume-role|") {
				crossAccount++
			}
		}
		if operator != 0 {
			t.Errorf("%s: kusari-operator's allowlisted console sign-in produced %d findings, want 0; "+
				"the allowlist is not excluding it", label, operator)
		}
		// Two findings and the one burst decision over them.
		if crossAccount != 3 {
			t.Errorf("%s: %d canonical lines name cross-account-assume-role, want 3 (2 findings + 1 decision)",
				label, crossAccount)
		}
	}
}

// A restart over a FrostDB segment does not re-admit the corpus. This is the
// defect in its original shape: the kind-osramp pod restarted in fixture mode
// and appended every observation and every finding a second time with an
// unchanged ID set.
func TestKusariE2E_FrostDBRestartDoesNotReAdmitTheCorpus(t *testing.T) {
	st := newFrostDB(t)
	dir := bundlesDir(t)
	c := corpus(t)

	first := newHarness(t, st, dir, collectors.NewDeduper(8192))
	ingest(t, first, c)
	before := Census(rows(t, first))
	if before.Observations == 0 {
		t.Fatal("precondition: the first pass stored nothing in FrostDB")
	}

	_, newest := Bracket(c)
	restarted := collectors.NewDeduper(8192)
	if err := restarted.Warm(context.Background(), st, collectors.DefaultDedupeWarmWindow, newest, testLogger(t)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if restarted.WarmedIDs() == 0 {
		t.Fatal("warm-up seeded nothing from FrostDB; the restart would re-admit the whole corpus")
	}

	second := newHarness(t, st, dir, restarted)
	ingest(t, second, c)

	if after := Census(rows(t, second)); after != before {
		t.Fatalf("the restart appended to FrostDB: %+v -> %+v (ids unchanged)", before, after)
	}
	if n := len(second.Recorder.Findings); n != 0 {
		t.Errorf("the restarted process evaluated %d findings over an already-durable corpus, want 0", n)
	}
}
