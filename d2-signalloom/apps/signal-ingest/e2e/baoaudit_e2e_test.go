// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// baoCorpus is the OpenBao audit fixture projection through the production
// receiver converter, so the e2e asserts the production projection and not a
// test-only corpus.
func baoCorpus(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := baoaudit.FixtureObservations()
	if err != nil {
		t.Fatalf("baoaudit.FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the baoaudit fixture corpus is empty; every assertion would be vacuous")
	}
	return obs
}

// TestBaoAuditE2E_FixtureCorpusMatchesTheExpectationTable asserts exact
// per-rule and per-window counts for the OpenBao corpus through the production
// chain. Exact, not "at least".
func TestBaoAuditE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := baoCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleOpenBaoAudit+"/") {
			t.Errorf("a non-baoaudit rule %s fired %d findings on the OpenBao corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range baoRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range baoRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleOpenBaoAudit+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in baoRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range baoWindowExpectations {
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
	for _, w := range baoWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleOpenBaoAudit+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in baoWindowExpectations", key, n)
		}
	}

	sumRules := 0
	for _, r := range baoRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range baoWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantBaoFindings {
		t.Errorf("baoRuleExpectations sum to %d findings but wantBaoFindings is %d", sumRules, wantBaoFindings)
	}
	if sumWindows != wantBaoDecisions {
		t.Errorf("baoWindowExpectations sum to %d decisions but wantBaoDecisions is %d", sumWindows, wantBaoDecisions)
	}
	if len(c) != wantBaoObservations {
		t.Errorf("the baoaudit fixture corpus projects %d observations, want %d", len(c), wantBaoObservations)
	}

	baoFindings, baoDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleOpenBaoAudit {
			baoFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleOpenBaoAudit {
			baoDecisions++
		}
	}
	if baoFindings != wantBaoFindings || baoDecisions != wantBaoDecisions {
		t.Errorf("recorded %d OpenBao findings and %d OpenBao decisions, want %d and %d", baoFindings, baoDecisions, wantBaoFindings, wantBaoDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; an OpenBao rule errored per observation (an unguarded label read)", snap.EvaluatorErrors)
	}
}

// TestBaoAuditE2E_EveryRuleHasANegative asserts every rule names a negative
// fixture object and leaves at least one projected record in that object alone.
func TestBaoAuditE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, baoCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range baoCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range baoRuleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := baoFixtureObjectOf(r.Negative)
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
			t.Errorf("rule %s/%s fired on %d of the %d records in %s: no negative left in that object",
				r.Bundle, r.Rule, got, total, object)
		}
	}
}

// baoFixtureObjectOf pulls the "<file>" out of "baoaudit/<file>: description".
func baoFixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	return strings.TrimPrefix(head, "baoaudit/")
}

// TestBaoAuditE2E_MutationGates pairs the green bar with its inverse.
func TestBaoAuditE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := baoCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the secret-read records removes the burst", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		var trimmed []model.Observation
		for _, o := range baoCorpus(t) {
			if strings.HasPrefix(o.RawEvidenceRef, "testdata/secret-read.json") {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == len(baoCorpus(t)) {
			t.Fatal("the trim removed nothing or everything; it is not doing what it claims")
		}
		ingest(t, h, trimmed)
		if n := len(h.Recorder.Decisions); n != 0 {
			t.Errorf("with the secret-read burst records removed, stage 2 still produced %d decisions", n)
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings, so this gate cannot separate stage 2 from stage 1")
		}
	})
}
