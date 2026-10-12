// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/workspacesaas"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// identityCorpus is the identity_authorization fixture projection: SPIRE SVID
// issuance plus SaaS login, both through the production collector projections, so
// the e2e asserts the production projection and not a test-only corpus.
func identityCorpus(t *testing.T) []model.Observation {
	t.Helper()
	svid, err := spirea.FixtureObservations()
	if err != nil {
		t.Fatalf("spirea.FixtureObservations: %v", err)
	}
	login, err := workspacesaas.LoginFixtureObservations()
	if err != nil {
		t.Fatalf("workspacesaas.LoginFixtureObservations: %v", err)
	}
	c := append(append([]model.Observation(nil), svid...), login...)
	if len(c) == 0 {
		t.Fatal("the identity fixture corpus is empty; every assertion would be vacuous")
	}
	return c
}

// TestIdentityAuthE2E_FixtureCorpusMatchesTheExpectationTable: every rule
// produces exactly the findings the table names and every window exactly the
// decisions, over the identity corpus through the production chain. Exact, not
// "at least".
func TestIdentityAuthE2E_FixtureCorpusMatchesTheExpectationTable(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	c := identityCorpus(t)
	ingest(t, h, c)

	byRule := h.Recorder.FindingsByRule()
	byWindow := h.Recorder.DecisionsByWindow()

	// Only the identity-auth bundle's rules may fire on this corpus — nothing from
	// k8saudit, awslogs or application_saas, because every rule here source- and
	// layer-gates. Assert that first.
	for key, n := range byRule {
		if !strings.HasPrefix(key, bundleIdentityAuth+"/") {
			t.Errorf("a non-identity rule %s fired %d findings on the identity corpus; source/layer gating leaked", key, n)
		}
	}

	for _, r := range identityRuleExpectations {
		if got := byRule[r.Bundle+"/"+r.Rule]; got != r.Findings {
			t.Errorf("rule %s/%s produced %d findings, want %d\n  positive: %s\n  negative: %s",
				r.Bundle, r.Rule, got, r.Findings, r.Positive, r.Negative)
		}
	}
	named := map[string]bool{}
	for _, r := range identityRuleExpectations {
		named[r.Bundle+"/"+r.Rule] = true
	}
	for key, n := range byRule {
		if strings.HasPrefix(key, bundleIdentityAuth+"/") && !named[key] {
			t.Errorf("rule %s produced %d findings and is not in identityRuleExpectations; add a row with its +/- fixture", key, n)
		}
	}

	for _, w := range identityWindowExpectations {
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
	for _, w := range identityWindowExpectations {
		namedWindow[w.Bundle+"/"+w.Window] = true
	}
	for key, n := range byWindow {
		if strings.HasPrefix(key, bundleIdentityAuth+"/") && !namedWindow[key] {
			t.Errorf("window %s produced %d decisions and is not in identityWindowExpectations", key, n)
		}
	}

	// Totals agree with the tables.
	sumRules := 0
	for _, r := range identityRuleExpectations {
		sumRules += r.Findings
	}
	sumWindows := 0
	for _, w := range identityWindowExpectations {
		sumWindows += w.Decisions
	}
	if sumRules != wantIdentityFindings {
		t.Errorf("identityRuleExpectations sum to %d findings but wantIdentityFindings is %d", sumRules, wantIdentityFindings)
	}
	if sumWindows != wantIdentityDecisions {
		t.Errorf("identityWindowExpectations sum to %d decisions but wantIdentityDecisions is %d", sumWindows, wantIdentityDecisions)
	}
	if len(c) != wantIdentityObservations {
		t.Errorf("the identity fixture corpus projects %d observations, want %d", len(c), wantIdentityObservations)
	}

	iFindings, iDecisions := 0, 0
	for _, f := range h.Recorder.Findings {
		if f.BundleID == bundleIdentityAuth {
			iFindings++
		}
	}
	for _, d := range h.Recorder.Decisions {
		if d.BundleID == bundleIdentityAuth {
			iDecisions++
		}
	}
	if iFindings != wantIdentityFindings || iDecisions != wantIdentityDecisions {
		t.Errorf("recorded %d identity findings and %d identity decisions, want %d and %d", iFindings, iDecisions, wantIdentityFindings, wantIdentityDecisions)
	}

	if snap := h.Metrics.Snapshot(); snap.EvaluatorErrors != 0 {
		t.Errorf("evaluator faults: %d; an identity rule errored per observation (an unguarded label read)", snap.EvaluatorErrors)
	}
}

// TestIdentityAuthE2E_EveryRuleHasANegative: every rule names a negative fixture,
// and the object that carries it really holds records the rule left alone.
func TestIdentityAuthE2E_EveryRuleHasANegative(t *testing.T) {
	h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
	ingest(t, h, identityCorpus(t))
	byRule := h.Recorder.FindingsByRule()

	perObject := map[string]int{}
	for _, o := range identityCorpus(t) {
		perObject[strings.SplitN(o.RawEvidenceRef, "#", 2)[0]]++
	}

	for _, r := range identityRuleExpectations {
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

// streamFixtureObjectOf pulls the "<object>" out of "<object>: description" and
// prefixes it with testdata/, matching the RawEvidenceRef the stream fixture
// loaders assign (testdata/svid-issuance.json, testdata/login/saas-login.json,
// testdata/app/saas-app.json). Shared by the identity and application_saas e2e.
func streamFixtureObjectOf(s string) string {
	head, _, found := strings.Cut(s, ":")
	if !found {
		return ""
	}
	head = strings.TrimSpace(head)
	if head == "" {
		return ""
	}
	return "testdata/" + head
}

// TestIdentityAuthE2E_MutationGates pairs the green bar with its inverse.
func TestIdentityAuthE2E_MutationGates(t *testing.T) {
	t.Run("an empty bundle dir detects nothing and ingests everything", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), t.TempDir(), collectors.NewDeduper(8192))
		c := identityCorpus(t)
		ingest(t, h, c)
		census := Census(rows(t, h))
		if census.Findings != 0 || census.Decisions != 0 {
			t.Errorf("an empty bundle dir produced %d findings and %d decisions", census.Findings, census.Decisions)
		}
		if census.Observations != len(c) {
			t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d", census.Observations, len(c))
		}
	})

	t.Run("removing the MFA-absent logins removes the burst but keeps other findings", func(t *testing.T) {
		h := newHarness(t, store.NewMemoryStore(), bundlesDir(t), collectors.NewDeduper(8192))
		var trimmed []model.Observation
		for _, o := range identityCorpus(t) {
			if o.Labels["mfa"] == "absent" {
				continue
			}
			trimmed = append(trimmed, o)
		}
		if len(trimmed) == 0 || len(trimmed) == len(identityCorpus(t)) {
			t.Fatal("the trim removed nothing or everything; it is not doing what it claims")
		}
		ingest(t, h, trimmed)
		if n := len(h.Recorder.Decisions); n != 0 {
			t.Errorf("with the MFA-absent logins removed, stage 2 still produced %d decisions", n)
		}
		if len(h.Recorder.Findings) == 0 {
			t.Error("the trimmed corpus produced no findings, so this gate cannot separate stage 2 from stage 1")
		}
	})
}
