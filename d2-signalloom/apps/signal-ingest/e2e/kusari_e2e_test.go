// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// testLogger discards by default and goes to the test log under -v, so a failing
// run can show the bundle loader's and stage 2's own account of what happened
// without a passing run burying the table.
func testLogger(t *testing.T) *slog.Logger {
	t.Helper()
	if !testing.Verbose() {
		return slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return slog.New(slog.NewTextHandler(&testWriter{t: t}, &slog.HandlerOptions{Level: slog.LevelInfo}))
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

type testWriter struct{ t *testing.T }

func (w *testWriter) Write(p []byte) (int, error) {
	w.t.Logf("%s", strings.TrimRight(string(p), "\n"))
	return len(p), nil
}

func bundlesDir(t *testing.T) string {
	t.Helper()
	dir, err := RepoBundlesDir()
	if err != nil {
		t.Fatalf("RepoBundlesDir: %v", err)
	}
	return dir
}

func corpus(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := KusariCorpus()
	if err != nil {
		t.Fatalf("KusariCorpus: %v", err)
	}
	return obs
}

// newHarness is the production chain over a MemoryStore. The frostdb variant
// supplies the same thing over a FrostDBStore; everything else in this file is
// store-agnostic and both run it.
func newHarness(t *testing.T, st store.SignalStore, dir string, d *collectors.Deduper) *Harness {
	t.Helper()
	h, err := NewHarness(st, dir, d, testLogger(t))
	if err != nil {
		t.Fatalf("NewHarness: %v", err)
	}
	return h
}

func ingest(t *testing.T, h *Harness, c []model.Observation) {
	t.Helper()
	if err := h.Ingest(context.Background(), c); err != nil {
		t.Fatalf("Ingest: %v", err)
	}
}

func rows(t *testing.T, h *Harness) []model.Observation {
	t.Helper()
	got, err := h.Rows(context.Background())
	if err != nil {
		t.Fatalf("Rows: %v", err)
	}
	return got
}

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

// Every rule produces exactly the findings the table names, and every window
// exactly the decisions, over the Kusari fixture corpus through the production
// chain.
//
// Exact rather than "at least": an over-triggering rule is how a detection
// control becomes noise nobody reads, and a lower bound cannot see it.
func TestKusariE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()
	census := Census(rows(t, h))
	t.Log(SummaryTable(ruleExpectations, windowExpectations, byRule, byWindow, census))

	for _, r := range ruleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	// And nothing fired that the table does not name. Without this the table is
	// a lower bound: a new rule, or a rule that widened, would pass silently.
	named := map[string]bool{}
	for _, r := range ruleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if !named[key] {
			t.Errorf("rule %s produced %d findings and is not in ruleExpectations; add a row with its positive and negative fixture", key, n)
		}
	}

	for _, w := range windowExpectations {
		got := byWindow[w.Bundle+"/"+w.Window]
		if got != w.Decisions {
			t.Errorf("window %s/%s produced %d decisions, want %d (%s)", w.Bundle, w.Window, got, w.Decisions, w.Why)
		}
		if w.Decisions != 1 || got != 1 {
			continue
		}
		for _, d := range h.Recorder.Decisions {
			if d.BundleID == w.Bundle && d.WindowID == w.Window && d.Count != w.Count {
				t.Errorf("decision %s/%s cites %d findings, want %d", w.Bundle, w.Window, d.Count, w.Count)
			}
		}
	}
	namedWindow := map[string]bool{}
	for _, w := range windowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in windowExpectations", key, n)
		}
	}

	// Totals agree with the tables, which is the cross-check that keeps the two
	// in step when somebody edits one of them.
	sumRules := 0
	for _, r := range ruleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range windowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantKusariFindings {
		t.Errorf("ruleExpectations sum to %d findings but wantKusariFindings is %d", sumRules, wantKusariFindings)
	}
	if sumWindows != wantKusariDecisions {
		t.Errorf("windowExpectations sum to %d decisions but wantKusariDecisions is %d", sumWindows, wantKusariDecisions)
	}
	if len(c) != wantKusariObservations {
		t.Errorf("the kusari fixture corpus projects %d observations, want %d", len(c), wantKusariObservations)
	}
	if census != (Tally{Observations: wantKusariObservations, Findings: wantKusariFindings, Decisions: wantKusariDecisions}) {
		t.Errorf("stored census = %+v, want %d/%d/%d", census, wantKusariObservations, wantKusariFindings, wantKusariDecisions)
	}

	// Both bundles are in shadow: nothing here is promoted, and a promotion that
	// slipped in unreviewed is red.
	for _, f := range h.Recorder.Findings {
		if f.BundleVersion == "" {
			t.Errorf("finding %s carries no bundle version; its ID is not reproducible", f.ID)
		}
	}
	for _, b := range h.Bundles {
		if b.Mode != obscel.ModeShadow {
			t.Errorf("bundle %s is mode %q, want shadow; promotion is a reviewed commit", b.ID, b.Mode)
		}
	}
	// And no evaluator faults: a rule that errors per observation is detection
	// silently degraded, and it is counted rather than returned.
	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 || snap.FindingWriteErrors != 0 || snap.DecisionWriteErrors != 0 {
		t.Errorf("faults: %d evaluator, %d finding writes, %d decision writes; want 0",
			snap.EvaluatorErrors, snap.FindingWriteErrors, snap.DecisionWriteErrors)
	}
}

// Every rule names a negative fixture, and the fixture object that carries it
// really does hold records the rule left alone.
//
// This is the cheap mechanical half of "every rule has a negative". A rule whose
// positive fixture object projects exactly as many observations as the rule
// produced findings has no negative IN THAT OBJECT — every record fired — which
// is the shape of a rule that matches too much.
func TestKusariE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, corpus(t))
	byRule := h.Recorder.FindingsByRule()

	// Observation count per fixture object, keyed by the evidence-ref prefix.
	perObject := map[string]int{}
	for _, o := range corpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range ruleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture recorded; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := fixtureObjectOf(r.Negative)
		if object == "" {
			t.Errorf("rule %s/%s names a negative without a fixture object: %q", r.Bundle, r.Rule, r.Negative)
			continue
		}
		total, ok := perObject["testdata/"+object]
		if !ok {
			t.Errorf("rule %s/%s names fixture object %q, which projects nothing", r.Bundle, r.Rule, object)
			continue
		}
		if got := byRule[r.Bundle+"/"+r.Rule]; got >= total {
			t.Errorf("rule %s/%s fired on %d of the %d records in %s: there is no negative left in that object",
				r.Bundle, r.Rule, got, total, object)
		}
	}
}

// fixtureObjectOf pulls the "kusari/<file>" prefix out of an expectation's
// free-text Negative field, which is written as "<object>: <description>".
func fixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	if !strings.HasPrefix(head, "kusari/") {
		return ""
	}
	return head
}

// ---------------------------------------------------------------------------
// Replay equals live
// ---------------------------------------------------------------------------

// Replaying the stored observations through the same stage 1 and stage 2 code,
// with the clock replaced by observation timestamps, reproduces the live run
// byte for byte on the canonical projection.
//
// Nothing here is a second implementation of anything: policy.Replay builds a
// policy.Sink over a discarding inner sink and feeds it observations read back
// from the store. If the two sides differ, the difference is in the data or in
// the bundle, never in two copies of the rules that drifted.
func TestKusariE2E_ReplayReproducesLive(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	live := h.Recorder.CanonicalLines()
	if len(live) == 0 {
		t.Fatal("the live run recorded nothing; the equality claim would be vacuous")
	}

	from, to := Bracket(c)
	var buf bytes.Buffer
	nf, nd, err := policy.Replay(context.Background(), h.Store, policy.ReplayOptions{
		BundlesDir: bundlesDir(t),
		From:       from,
		To:         to,
		Tenant:     Tenant,
		Out:        &buf,
		Log:        testLogger(t),
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if nf != wantKusariFindings || nd != wantKusariDecisions {
		t.Errorf("replay produced %d findings and %d decisions, want %d and %d",
			nf, nd, wantKusariFindings, wantKusariDecisions)
	}

	replayed := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
	if len(replayed) != len(live) {
		t.Fatalf("replay wrote %d canonical lines, live recorded %d", len(replayed), len(live))
	}
	for i := range live {
		if live[i] != replayed[i] {
			t.Fatalf("replay diverged from live at line %d\n  live:   %s\n  replay: %s", i, live[i], replayed[i])
		}
	}
	t.Logf("replay equals live: %d canonical lines (%d findings, %d decisions), compared as sorted text",
		len(live), nf, nd)
}

// The equality claim is not vacuous: replaying with a DIFFERENT bundle set
// produces a different answer. Without this, a replay that silently produced
// nothing would compare equal to a live run that also produced nothing, and the
// test above would be green on a pipeline that had stopped detecting.
func TestKusariE2E_ReplayWithNoBundlesIsTheMutationGate(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)
	ingest(t, h, c)

	from, to := Bracket(c)
	var buf bytes.Buffer
	nf, nd, err := policy.Replay(context.Background(), h.Store, policy.ReplayOptions{
		BundlesDir: t.TempDir(), From: from, To: to, Tenant: Tenant, Out: &buf, Log: testLogger(t),
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if nf != 0 || nd != 0 {
		t.Fatalf("replaying with an empty bundle dir produced %d findings and %d decisions, want 0 and 0", nf, nd)
	}
	if buf.Len() != 0 {
		t.Fatalf("replaying with an empty bundle dir wrote %d bytes, want none", buf.Len())
	}
	if len(h.Recorder.CanonicalLines()) == 0 {
		t.Fatal("the live run also produced nothing, so this gate proves nothing")
	}
}

// ---------------------------------------------------------------------------
// Idempotency
// ---------------------------------------------------------------------------

// A second pass of the same corpus changes nothing — and, the part that matters,
// stage 1 and stage 2 never see the replayed record at all.
//
// Observation.ID is derived from the evidence reference precisely so a record
// that arrives twice is recognisably the same record. The consequence of not
// enforcing that is a stage-2 burst counter reachable by a redelivery rather
// than by events, which is a false positive manufactured by the pipeline.
func TestKusariE2E_SecondPassIsANoOp(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := corpus(t)

	ingest(t, h, c)
	first := Census(rows(t, h))
	firstFindings := len(h.Recorder.Findings)
	firstDecisions := len(h.Recorder.Decisions)
	if first.Observations == 0 || firstFindings == 0 || firstDecisions == 0 {
		t.Fatalf("precondition: the first pass must produce all three, got %+v / %d findings / %d decisions",
			first, firstFindings, firstDecisions)
	}

	ingest(t, h, c)
	second := Census(rows(t, h))

	if first != second {
		t.Errorf("the second pass changed the store: %+v -> %+v", first, second)
	}
	if got := len(h.Recorder.Findings); got != firstFindings {
		t.Errorf("stage 1 evaluated %d findings over two passes, want %d: a redelivery reached the evaluator",
			got, firstFindings)
	}
	if got := len(h.Recorder.Decisions); got != firstDecisions {
		t.Errorf("stage 2 produced %d decisions over two passes, want %d: a burst counter was advanced by a redelivery",
			got, firstDecisions)
	}
	if rep := h.Recorder.RepeatedFindings(); len(rep) != 0 {
		t.Errorf("stage 1 saw repeated findings: %v", rep)
	}
	if rep := h.Recorder.RepeatedDecisions(); len(rep) != 0 {
		t.Errorf("stage 2 saw repeated decisions: %v", rep)
	}
	if h.Deduper.Dropped() == 0 {
		t.Error("the deduper refused nothing on the second pass; the no-op above is happening for some other reason")
	}
	t.Logf("second pass: %d records refused as replays, store unchanged at %+v", h.Deduper.Dropped(), second)
}

// A process restart does not re-admit the corpus: a NEW accepted-ID set, warmed
// from the store the process inherits, refuses what is already durable.
func TestKusariE2E_RestartDoesNotReAdmitTheCorpus(t *testing.T) {
	st := store.NewMemoryStore()
	dir := bundlesDir(t)
	c := corpus(t)

	first := newHarness(t, st, dir, collectors.NewDeduper(8192))
	ingest(t, first, c)
	before := Census(rows(t, first))

	// --- restart ---
	_, newest := Bracket(c)
	restarted := collectors.NewDeduper(8192)
	if err := restarted.Warm(context.Background(), st, collectors.DefaultDedupeWarmWindow, newest, testLogger(t)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if restarted.WarmedIDs() == 0 {
		t.Fatal("warm-up seeded nothing; the restart would re-admit the whole corpus")
	}

	second := newHarness(t, st, dir, restarted)
	ingest(t, second, c)

	if after := Census(rows(t, second)); after != before {
		t.Errorf("the restart appended: %+v -> %+v", before, after)
	}
	if n := len(second.Recorder.Findings); n != 0 {
		t.Errorf("the restarted process evaluated %d findings over an already-ingested corpus, want 0", n)
	}
}

// ---------------------------------------------------------------------------
// Mutation gates
// ---------------------------------------------------------------------------

// The green bar above has to mean something, so each claim is paired with its
// inverse and the inverse is run here rather than left as a manual step.
func TestKusariE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := corpus(t)
		ingest(t, h, c)

		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		// No bundles must mean "evaluate nothing", never "ingest nothing". That
		// is the whole of the fail-open decision and it is the half most worth
		// pinning: a detection control that drops telemetry is worse than one
		// that detects nothing.
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the burst records removes the decisions", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		// Drop the two objects that carry a burst, leaving their stage-1 rules
		// reachable through nothing. If a decision still fires, stage 2 is
		// counting something other than the evidence it cites.
		var trimmed []model.Observation
		for _, o := range corpus(t) {
			ref := o.RawEvidenceRef
			if strings.HasPrefix(ref, "testdata/"+awslogs.KusariFixtureIAMBurst) ||
				strings.HasPrefix(ref, "testdata/"+awslogs.KusariFixtureVPCRejectBurst) ||
				strings.HasPrefix(ref, "testdata/"+awslogs.KusariFixtureAssumeRole) {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == wantKusariObservations {
			t.Fatalf("the trim removed %d of %d observations; it is not doing what it claims",
				wantKusariObservations-len(trimmed), wantKusariObservations)
		}
		ingest(t, h, trimmed)
		if n := len(h.Recorder.Decisions); n != 0 {
			t.Errorf("with every burst removed, stage 2 still produced %d decisions: %+v", n, h.Recorder.Decisions)
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings either, so this gate cannot distinguish stage 2 from stage 1")
		}
	})
}
