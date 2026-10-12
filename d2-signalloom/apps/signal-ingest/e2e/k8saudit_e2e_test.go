// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/k8saudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// k8sCorpus is the k8saudit-kube fixture projection — the same observations
// fixture mode replays, so the e2e asserts the production projection and not a
// test-only corpus.
func k8sCorpus(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := k8saudit.FixtureObservations()
	if err != nil {
		t.Fatalf("k8saudit.FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the k8saudit fixture corpus is empty; every assertion would be vacuous")
	}
	return obs
}

// TestK8sAuditE2E_FixtureCorpusMatchesTheExpectationTable: every rule produces
// exactly the findings the table names and every window exactly the decisions,
// over the k8saudit corpus through the production chain. Exact, not "at least".
func TestK8sAuditE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := k8sCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	// Only the k8saudit bundle's rules may fire on this corpus — nothing from the
	// awslogs/landlock bundles, because this corpus is all LayerKubernetes and
	// those rules gate on other layers. Assert that first.
	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleK8sAudit+"/") {
			t.Errorf("a non-k8saudit rule %s fired %d findings on the k8s corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range k8sRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range k8sRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleK8sAudit+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in k8sRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range k8sWindowExpectations {
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
	for _, w := range k8sWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleK8sAudit+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in k8sWindowExpectations", key, n)
		}
	}

	// Totals agree with the tables.
	sumRules := 0
	for _, r := range k8sRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range k8sWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantK8sFindings {
		t.Errorf("k8sRuleExpectations sum to %d findings but wantK8sFindings is %d", sumRules, wantK8sFindings)
	}
	if sumWindows != wantK8sDecisions {
		t.Errorf("k8sWindowExpectations sum to %d decisions but wantK8sDecisions is %d", sumWindows, wantK8sDecisions)
	}
	if len(c) != wantK8sObservations {
		t.Errorf("the k8saudit fixture corpus projects %d observations, want %d", len(c), wantK8sObservations)
	}

	kFindings, kDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleK8sAudit {
			kFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleK8sAudit {
			kDecisions++
		}
	}
	if kFindings != wantK8sFindings || kDecisions != wantK8sDecisions {
		t.Errorf("recorded %d k8s findings and %d k8s decisions, want %d and %d", kFindings, kDecisions, wantK8sFindings, wantK8sDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; a k8s rule errored per observation (an unguarded label read)", snap.EvaluatorErrors)
	}
}

// TestK8sAuditE2E_EveryRuleHasANegative: every rule names a negative fixture, and
// the object that carries it really holds records the rule left alone — a rule
// whose positive object fired on every record it projects has no negative there.
func TestK8sAuditE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, k8sCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range k8sCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range k8sRuleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := k8sFixtureObjectOf(r.Negative)
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

// k8sFixtureObjectOf pulls the "<file>" out of "k8saudit/<file>: description".
func k8sFixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	return strings.TrimPrefix(head, "k8saudit/")
}

// TestK8sAuditE2E_MutationGates pairs the green bar with its inverse.
func TestK8sAuditE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := k8sCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the exec and secret-read records removes the bursts", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		var trimmed []model.Observation
		for _, o := range k8sCorpus(t) {
			if strings.HasPrefix(o.RawEvidenceRef, "testdata/exec.json") ||
				strings.HasPrefix(o.RawEvidenceRef, "testdata/secrets-read.json") {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == len(k8sCorpus(t)) {
			t.Fatal("the trim removed nothing or everything; it is not doing what it claims")
		}
		ingest(t, h, trimmed)
		if n := len(h.Recorder.Decisions); n != 0 {
			t.Errorf("with the burst objects removed, stage 2 still produced %d decisions", n)
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings, so this gate cannot separate stage 2 from stage 1")
		}
	})
}
