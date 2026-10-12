// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package e2e

import (
	"io"
	"log/slog"
	"slices"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/k8saudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// TestPolicyCoverageMatrix_K8sAudit is the coverage gate for the reference
// vertical (docs/EAP "The coverage gate"). It is frostdb-tagged because the L2
// check reads store.DefaultLabelAllowListKeys, which only exists under that tag —
// which is the whole point of L2: a rule with green unit fixtures can still have
// the frostdb store refuse every batch, and only a tagged test sees it.
//
// It asserts four things, each the failure mode the catalogue names:
//
//  1. LayerKubernetes is in the registered-layer set. Without it every k8s rule's
//     layer gate matches nothing and the vertical is a silent no-op.
//  2. The k8saudit bundle loads and carries at least one stage-1 rule.
//  3. Every rule in the loaded bundle has a +/- fixture row in the e2e table.
//     A rule with no negative is a rule that may fire on everything.
//  4. Every key the collector projects is in the default allow-list (L2).
func TestPolicyCoverageMatrix_K8sAudit(t *testing.T) {
	// 1. Registered-layer set.
	if !slices.Contains(model.InScopeLayers(), model.LayerKubernetes) {
		t.Fatalf("model.LayerKubernetes is not in InScopeLayers(); the k8s layer gate would match nothing")
	}

	// 2. The bundle loads and has rules.
	bundle := loadK8sAuditBundle(t)
	if len(bundle.Rules) == 0 {
		t.Fatalf("bundle %s has no rules", bundle.ID)
	}

	// 3. Every loaded rule has a positive AND a negative fixture in the e2e table.
	table := map[string]ruleExpectation{}
	for _, r := range k8sRuleExpectations {
		table[r.Rule] = r
	}
	for _, rule := range bundle.Rules {
		exp, ok := table[rule.ID]
		if !ok {
			t.Errorf("rule %q in bundle %s has no row in k8sRuleExpectations: a rule with no +/- fixture is unproven coverage",
				rule.ID, bundle.ID)
			continue
		}
		if exp.Positive == "" {
			t.Errorf("rule %q has no positive fixture named", rule.ID)
		}
		if exp.Negative == "" {
			t.Errorf("rule %q has no negative fixture named: a rule that fires on everything passes a positive-only suite", rule.ID)
		}
	}
	// And no table row names a rule the bundle does not have (the table cannot
	// drift ahead of the bundle either).
	have := map[string]bool{}
	for _, rule := range bundle.Rules {
		have[rule.ID] = true
	}
	for _, r := range k8sRuleExpectations {
		if !have[r.Rule] {
			t.Errorf("k8sRuleExpectations names rule %q which bundle %s does not contain", r.Rule, bundle.ID)
		}
	}

	// 4. L2: every projected key is allow-listed.
	allowed := map[string]bool{}
	for _, k := range store.DefaultLabelAllowListKeys() {
		allowed[k] = true
	}
	for _, k := range k8saudit.ProjectedKeys() {
		if !allowed[k] {
			t.Errorf("collector projects label key %q which is NOT in the default allow-list; a frostdb Append would refuse the batch", k)
		}
	}
}

func loadK8sAuditBundle(t *testing.T) *obscel.Bundle {
	t.Helper()
	dir := bundlesDir(t)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	pseudo := policy.StorePseudonymiser(store.NewMemoryStore())
	bundles, err := policy.LoadBundles(dir, log, pseudo)
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	for _, b := range bundles {
		if b.ID == bundleK8sAudit {
			return b
		}
	}
	t.Fatalf("bundle %s was not loaded from %s", bundleK8sAudit, dir)
	return nil
}
