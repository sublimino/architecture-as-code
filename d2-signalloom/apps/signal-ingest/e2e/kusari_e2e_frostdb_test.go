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

// FINDING. Replay over a segment-schema-v2 FrostDB store does NOT reproduce
// live, and it cannot, and the direction of the error is the dangerous one.
//
// # The mechanism
//
// Segment schema v2 is the privacy contract: FrostDBStore.Append pseudonymises
// the actor into `hmac_actor_hint` and digests the evidence reference into
// `evidence_ref_digest`, and it writes NO cleartext `actor_hint` or
// `raw_evidence_ref` column at all (store/frostdb.go: the v2 schema simply has
// no such field, and the read path's `if idx, ok := colIdx["actor_hint"]` finds
// nothing). So every observation read back carries an EMPTY ActorHint.
//
// policy.Replay reads raw observations out of the store and re-evaluates them.
// toObscel maps ActorHint onto obs.actor. Therefore on replay every rule and
// every window sees obs.actor == "".
//
// # Why that is worse than "the actor column is blank"
//
// Every allowlist in both shipped bundles is written as a NEGATIVE test on the
// actor -- `!(obs.actor in vars.break_glass_actors)` and its siblings. With an
// empty actor the negative is satisfied, so on replay:
//
//   - the break-glass records that live correctly ignored FIRE;
//   - kusari-operator's allowlisted console sign-in, which exists in the corpus
//     precisely as the rule's negative fixture, FIRES;
//   - cross-account-assume-role stops firing entirely, because its `obs.actor
//     != ""` guard is now false, so two true positives DISAPPEAR;
//   - every window keyed on `actor` collapses into one counter, so the
//     cross-account burst decision vanishes and the IAM burst decision is
//     reached by a mixture of two identities' events.
//
// A replay therefore produces findings against the identities an operator
// deliberately exempted, and loses the ones it was looking for. An operator
// reading the runbook's "Replay differs from live -> investigate as a
// determinism defect" would be sent after a clock that is not the problem.
//
// # Status
//
// Not fixable from this card: store/ is out of scope, and the fix is a design
// decision between two live contracts -- the SLAWS replay-oracle claim (ISC-55)
// and the SLDP segment-schema-v2 privacy contract. The plausible shapes are (a)
// replay evaluates against `hmac_actor_hint` with the bundle's allowlists
// pseudonymised through the same key, or (b) the canonical projection and every
// actor-reading rule move to the pseudonym as their actor identity. Both are
// cross-package.
//
// This test PINS the divergence rather than asserting an equality that is false.
// When the defect is fixed this test goes red, which is the moment to replace it
// with the equality assertion its MemoryStore sibling already makes.
//
// See docs/EAP/kusari-e2e.md, "Replay over a durable segment".
func TestKusariE2E_FrostDBReplayCannotReproduceLive_PseudonymisedActor(t *testing.T) {
	h := newHarness(t, newFrostDB(t), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	// The mechanism, asserted directly: the stored observation has no actor.
	stored, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	sources := 0
	for _, o := range stored {
		if o.Source == obscel.SourceFinding || o.Source == obscel.SourceDecision {
			continue
		}
		sources++
		if o.ActorHint != "" {
			t.Fatalf("a v2 segment returned a cleartext actor %q for %s; the schema has changed and this test's premise is gone -- re-assert replay equality instead",
				o.ActorHint, o.ID)
		}
	}
	if sources == 0 {
		t.Fatal("no source observations were read back; the premise cannot be established")
	}

	live := h.Recorder.CanonicalLines()
	replayed := replayLines(t, h, c)
	if len(live) == len(replayed) {
		t.Fatalf("FrostDB replay produced the same %d canonical lines as live; the actor divergence this test pins has been fixed -- replace it with the equality assertion", len(live))
	}

	// The DIRECTION, which is the part worth pinning. Both halves must hold:
	// records that live ignored now fire, and records that live caught are lost.
	liveSet := map[string]bool{}
	for _, l := range live {
		liveSet[l] = true
	}
	replaySet := map[string]bool{}
	for _, l := range replayed {
		replaySet[l] = true
	}

	// kusari-operator's console sign-in is the negative fixture for
	// console-login-outside-allowlist. It must fire on replay and not live.
	operatorFired := false
	for l := range replaySet {
		if strings.Contains(l, "console-login-outside-allowlist") && strings.Contains(l, "source_ip=198.51.100.3") {
			operatorFired = !liveSet[l]
		}
	}
	if !operatorFired {
		t.Error("the allowlisted console sign-in did not fire on replay; the inverted-allowlist half of this finding no longer reproduces")
	}

	// The two genuine cross-account assumptions, and the burst decision over
	// them, are lost on replay. The substring matches the rule field of a
	// finding line AND the rule field of a decision line, so the count is
	// "canonical lines that mention the rule", which is three: two findings and
	// one decision. All three must go to zero.
	liveCrossAccount, replayCrossAccount := 0, 0
	for l := range liveSet {
		if strings.Contains(l, "|cross-account-assume-role|") {
			liveCrossAccount++
		}
	}
	for l := range replaySet {
		if strings.Contains(l, "|cross-account-assume-role|") {
			replayCrossAccount++
		}
	}
	if liveCrossAccount == 0 {
		t.Fatal("live produced no cross-account findings; the lost-detection half cannot be shown")
	}
	if replayCrossAccount != 0 {
		t.Errorf("replay produced %d cross-account findings, want 0: the lost-detection half of this finding no longer reproduces", replayCrossAccount)
	}

	t.Logf("PINNED DEFECT: FrostDB v2 replay produced %d canonical lines against live's %d; "+
		"%d canonical lines naming cross-account-assume-role (2 findings + 1 decision) lost, "+
		"allowlisted identities fired. See the comment on this test.",
		len(replayed), len(live), liveCrossAccount)
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
