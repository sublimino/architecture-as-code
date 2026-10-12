// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/ebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// endpointCorpus is the Tetragon endpoint_host fixture projection — the same
// observations ProjectEndpoint produces in production, so the e2e asserts the
// production projection and not a test-only corpus.
func endpointCorpus(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := ebpf.FixtureEndpointObservations()
	if err != nil {
		t.Fatalf("ebpf.FixtureEndpointObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the Tetragon endpoint fixture corpus is empty; every assertion would be vacuous")
	}
	return obs
}

// TestEndpointE2E_FixtureCorpusMatchesTheExpectationTable: every rule produces
// exactly the findings the table names and every window exactly the decisions,
// over the Tetragon corpus through the production chain. Exact, not "at least".
func TestEndpointE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := endpointCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	// Only the endpoint-runtime bundle's rules may fire on this corpus — nothing
	// from the agent-nono landlock-denial rule (which shares the endpoint_host
	// layer but gates on verification_status), and nothing from the other bundles.
	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleEndpoint+"/") {
			t.Errorf("a non-tetragon rule %s fired %d findings on the endpoint corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range endpointRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range endpointRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleEndpoint+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in endpointRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range endpointWindowExpectations {
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
	for _, w := range endpointWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleEndpoint+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in endpointWindowExpectations", key, n)
		}
	}

	// Totals agree with the tables.
	sumRules := 0
	for _, r := range endpointRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range endpointWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantEndpointFindings {
		t.Errorf("endpointRuleExpectations sum to %d findings but wantEndpointFindings is %d", sumRules, wantEndpointFindings)
	}
	if sumWindows != wantEndpointDecisions {
		t.Errorf("endpointWindowExpectations sum to %d decisions but wantEndpointDecisions is %d", sumWindows, wantEndpointDecisions)
	}
	if len(c) != wantEndpointObservations {
		t.Errorf("the Tetragon fixture corpus projects %d observations, want %d", len(c), wantEndpointObservations)
	}

	nFindings, nDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleEndpoint {
			nFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleEndpoint {
			nDecisions++
		}
	}
	if nFindings != wantEndpointFindings || nDecisions != wantEndpointDecisions {
		t.Errorf("recorded %d tetragon findings and %d decisions, want %d and %d", nFindings, nDecisions, wantEndpointFindings, wantEndpointDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; a tetragon rule errored per observation (an unguarded label read)", snap.EvaluatorErrors)
	}
}

// TestEndpointE2E_EveryRuleHasANegative: every rule names a negative fixture, and
// the object that carries it really holds records the rule left alone.
func TestEndpointE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, endpointCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range endpointCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range endpointRuleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := endpointFixtureObjectOf(r.Negative)
		if object == "" {
			t.Errorf("rule %s/%s names a negative without a fixture object: %q", r.Bundle, r.Rule, r.Negative)
			continue
		}
		total, ok := perObject["endpoint_testdata/"+object]
		if !ok {
			t.Errorf("rule %s/%s names fixture object %q, which projects nothing", r.Bundle, r.Rule, object)
			continue
		}
		if got := byRule[r.Bundle+"/"+r.Rule]; got >= total {
			t.Errorf("rule %s/%s fired on %d of the %d records in %s: no negative left in that object",
				r.Bundle, r.Rule, got, total, object)
		}
	}
}

// endpointFixtureObjectOf pulls the "<file>" out of "ebpf/<file>: description".
func endpointFixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	return strings.TrimPrefix(head, "ebpf/")
}

// TestEndpointE2E_MutationGates pairs the green bar with its inverse.
func TestEndpointE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := endpointCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the sensitive-file records removes the burst", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		var trimmed []model.Observation
		for _, o := range endpointCorpus(t) {
			if strings.HasPrefix(o.RawEvidenceRef, "endpoint_testdata/sensitive-file-open.json") {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == len(endpointCorpus(t)) {
			t.Fatal("the trim removed nothing or everything; it is not doing what it claims")
		}
		ingest(t, h, trimmed)
		for _, d := range h.Recorder.Decisions {
			if d.BundleID == bundleEndpoint {
				t.Errorf("with the sensitive-file object removed, %s still produced a decision %s", bundleEndpoint, d.WindowID)
			}
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings, so this gate cannot separate stage 2 from stage 1")
		}
	})
}
