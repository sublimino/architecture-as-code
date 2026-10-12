// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// netEgressCorpus is the netebpf socket-trace fixture projection — the same
// observations fixture mode replays, so the e2e asserts the production projection
// and not a test-only corpus.
func netEgressCorpus(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := netebpf.FixtureObservations()
	if err != nil {
		t.Fatalf("netebpf.FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the netebpf fixture corpus is empty; every assertion would be vacuous")
	}
	return obs
}

// TestNetEgressE2E_FixtureCorpusMatchesTheExpectationTable: every rule produces
// exactly the findings the table names and every window exactly the decisions,
// over the netebpf corpus through the production chain. Exact, not "at least".
func TestNetEgressE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := netEgressCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	// Only the network-egress bundle's rules may fire on this corpus — nothing
	// from the awslogs VPC Flow rules (which share the network_egress layer but
	// gate on event_name == "REJECT"), and nothing from the other-layer bundles.
	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleNetEgress+"/") {
			t.Errorf("a non-netebpf rule %s fired %d findings on the netebpf corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range netEgressRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range netEgressRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleNetEgress+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in netEgressRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range netEgressWindowExpectations {
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
	for _, w := range netEgressWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleNetEgress+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in netEgressWindowExpectations", key, n)
		}
	}

	// Totals agree with the tables.
	sumRules := 0
	for _, r := range netEgressRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range netEgressWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantNetEgressFindings {
		t.Errorf("netEgressRuleExpectations sum to %d findings but wantNetEgressFindings is %d", sumRules, wantNetEgressFindings)
	}
	if sumWindows != wantNetEgressDecisions {
		t.Errorf("netEgressWindowExpectations sum to %d decisions but wantNetEgressDecisions is %d", sumWindows, wantNetEgressDecisions)
	}
	if len(c) != wantNetEgressObservations {
		t.Errorf("the netebpf fixture corpus projects %d observations, want %d", len(c), wantNetEgressObservations)
	}

	nFindings, nDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleNetEgress {
			nFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleNetEgress {
			nDecisions++
		}
	}
	if nFindings != wantNetEgressFindings || nDecisions != wantNetEgressDecisions {
		t.Errorf("recorded %d netebpf findings and %d decisions, want %d and %d", nFindings, nDecisions, wantNetEgressFindings, wantNetEgressDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; a netebpf rule errored per observation (an unguarded label read)", snap.EvaluatorErrors)
	}
}

// TestNetEgressE2E_EveryRuleHasANegative: every rule names a negative fixture, and
// the object that carries it really holds records the rule left alone.
func TestNetEgressE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, netEgressCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range netEgressCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range netEgressRuleExpectations {
		if strings.TrimSpace(r.Negative) == "" {
			t.Errorf("rule %s/%s has no negative fixture; a rule that fires on everything passes a positive-only suite", r.Bundle, r.Rule)
			continue
		}
		object := netEgressFixtureObjectOf(r.Negative)
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

// netEgressFixtureObjectOf pulls the "<file>" out of "netebpf/<file>: description".
func netEgressFixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	return strings.TrimPrefix(head, "netebpf/")
}

// TestNetEgressE2E_MutationGates pairs the green bar with its inverse.
func TestNetEgressE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := netEgressCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the direct-IP records removes the burst", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		var trimmed []model.Observation
		for _, o := range netEgressCorpus(t) {
			if strings.HasPrefix(o.RawEvidenceRef, "testdata/direct-ip-egress.json") {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == len(netEgressCorpus(t)) {
			t.Fatal("the trim removed nothing or everything; it is not doing what it claims")
		}
		ingest(t, h, trimmed)
		for _, d := range h.Recorder.Decisions {
			if d.BundleID == bundleNetEgress {
				t.Errorf("with the direct-IP object removed, %s still produced a decision %s", bundleNetEgress, d.WindowID)
			}
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings, so this gate cannot separate stage 2 from stage 1")
		}
	})
}
