// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/workspacesaas"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// saasCorpus is the application_saas fixture projection through the production
// collector projection, so the e2e asserts the production projection and not a
// test-only corpus.
func saasCorpus(t *testing.T) []model.Observation {
	t.Helper()
	c, err := workspacesaas.AppSaaSFixtureObservations()
	if err != nil {
		t.Fatalf("workspacesaas.AppSaaSFixtureObservations: %v", err)
	}
	if len(c) == 0 {
		t.Fatal("the application_saas fixture corpus is empty; every assertion would be vacuous")
	}
	return c
}

// TestApplicationSaaSE2E_FixtureCorpusMatchesTheExpectationTable: every rule
// produces exactly the findings the table names and every window exactly the
// decisions, over the application_saas corpus through the production chain.
func TestApplicationSaaSE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := saasCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	// Only the application-saas bundle's rules may fire — nothing from k8saudit,
	// awslogs or identity_authorization, because every rule here source- and
	// layer-gates.
	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleAppSaaS+"/") {
			t.Errorf("a non-application-saas rule %s fired %d findings on the saas corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range saasRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range saasRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleAppSaaS+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in saasRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range saasWindowExpectations {
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
	for _, w := range saasWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleAppSaaS+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in saasWindowExpectations", key, n)
		}
	}

	// Totals agree with the tables.
	sumRules := 0
	for _, r := range saasRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range saasWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantSaaSFindings {
		t.Errorf("saasRuleExpectations sum to %d findings but wantSaaSFindings is %d", sumRules, wantSaaSFindings)
	}
	if sumWindows != wantSaaSDecisions {
		t.Errorf("saasWindowExpectations sum to %d decisions but wantSaaSDecisions is %d", sumWindows, wantSaaSDecisions)
	}
	if len(c) != wantSaaSObservations {
		t.Errorf("the application_saas fixture corpus projects %d observations, want %d", len(c), wantSaaSObservations)
	}

	sFindings, sDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleAppSaaS {
			sFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleAppSaaS {
			sDecisions++
		}
	}
	if sFindings != wantSaaSFindings || sDecisions != wantSaaSDecisions {
		t.Errorf("recorded %d saas findings and %d saas decisions, want %d and %d", sFindings, sDecisions, wantSaaSFindings, wantSaaSDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; a saas rule errored per observation (an unguarded label read or a bad int() parse)", snap.EvaluatorErrors)
	}
}

// TestApplicationSaaSE2E_EveryRuleHasANegative: every rule names a negative
// fixture, and the object that carries it really holds records the rule left
// alone.
func TestApplicationSaaSE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, saasCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range saasCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range saasRuleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := streamFixtureObjectOf(r.Negative)
		if object == "" {
			t.Errorf("rule %s/%s names a negative without a fixture object: %q", r.Bundle, r.Rule, r.Negative)
			continue
		}
		total, ok := perObject[object]
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

// TestApplicationSaaSE2E_MutationGates pairs the green bar with its inverse.
func TestApplicationSaaSE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := saasCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the bulk downloads removes the burst but keeps other findings", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		var trimmed []model.Observation
		for _, o := range saasCorpus(t) {
			if o.Labels["event_type"] == "workspace_volume_spike" {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == len(saasCorpus(t)) {
			t.Fatal("the trim removed nothing or everything; it is not doing what it claims")
		}
		ingest(t, h, trimmed)
		if n := len(h.Recorder.Decisions); n != 0 {
			t.Errorf("with the bulk downloads removed, stage 2 still produced %d decisions", n)
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings, so this gate cannot separate stage 2 from stage 1")
		}
	})
}
