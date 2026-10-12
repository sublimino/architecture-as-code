// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/gcpaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// gcpCorpus is the gcpaudit fixture projection through the production collector
// converter, so the e2e asserts the production projection and not a test-only
// corpus.
func gcpCorpus(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := gcpaudit.FixtureObservations()
	if err != nil {
		t.Fatalf("gcpaudit.FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the gcpaudit fixture corpus is empty; every assertion would be vacuous")
	}
	return obs
}

// TestGcpAuditE2E_FixtureCorpusMatchesTheExpectationTable asserts exact per-rule
// counts for the GCP admin corpus through the production chain.
func TestGcpAuditE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := gcpCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleGcpAdmin+"/") {
			t.Errorf("a non-gcpaudit rule %s fired %d findings on the GCP corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range gcpRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range gcpRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleGcpAdmin+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in gcpRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range gcpWindowExpectations {
		got := byWindow[w.Bundle+"/"+w.Window]
		if got != w.Decisions {
			t.Errorf("window %s/%s produced %d decisions, want %d (%s)", w.Bundle, w.Window, got, w.Decisions, w.Why)
		}
	}
	namedWindow := map[string]bool{}
	for _, w := range gcpWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleGcpAdmin+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in gcpWindowExpectations", key, n)
		}
	}

	sumRules := 0
	for _, r := range gcpRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range gcpWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantGcpFindings {
		t.Errorf("gcpRuleExpectations sum to %d findings but wantGcpFindings is %d", sumRules, wantGcpFindings)
	}
	if sumWindows != wantGcpDecisions {
		t.Errorf("gcpWindowExpectations sum to %d decisions but wantGcpDecisions is %d", sumWindows, wantGcpDecisions)
	}
	if len(c) != wantGcpObservations {
		t.Errorf("the gcpaudit fixture corpus projects %d observations, want %d", len(c), wantGcpObservations)
	}

	gcpFindings, gcpDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleGcpAdmin {
			gcpFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleGcpAdmin {
			gcpDecisions++
		}
	}
	if gcpFindings != wantGcpFindings || gcpDecisions != wantGcpDecisions {
		t.Errorf("recorded %d GCP findings and %d GCP decisions, want %d and %d", gcpFindings, gcpDecisions, wantGcpFindings, wantGcpDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; a GCP rule errored per observation (an unguarded label read)", snap.EvaluatorErrors)
	}
}

// TestGcpAuditE2E_EveryRuleHasANegative asserts every rule names a negative
// fixture object and leaves at least one projected record in that object alone.
func TestGcpAuditE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, gcpCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range gcpCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range gcpRuleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := gcpFixtureObjectOf(r.Negative)
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

// gcpFixtureObjectOf pulls the "<file>" out of "gcpaudit/<file>: description".
func gcpFixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	return strings.TrimPrefix(head, "gcpaudit/")
}

// TestGcpAuditE2E_MutationGates pairs the green bar with its inverse.
func TestGcpAuditE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := gcpCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})
}
