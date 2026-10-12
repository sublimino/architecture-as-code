// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"io"
	"log/slog"
	"regexp"
	"sort"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// This file generalises the single-vertical k8saudit coverage gate
// (k8saudit_coverage_matrix_test.go) into an ESTATE-WIDE gate over every bundle
// the tenant ships. Where that test proves the one reference vertical is whole,
// this one proves the whole estate is: a new layer, a new rule, or a new rule
// with no negative fixture becomes a RED test the moment it lands, not a silent
// hole somebody finds in production.
//
// Two of the three estate assertions live here because they are store-agnostic
// (they read bundles, model layers, and the expectation tables, none of which
// need the frostdb store). The third — the L2 projected-key check — needs
// store.DefaultLabelAllowListKeys, which only compiles under -tags frostdb, so
// it lives in coverage_matrix_frostdb_test.go. `go test ./e2e/...` is green in
// both tag modes; this file is the part that runs in both.

// obsLayerLiteral extracts the layer a rule gates on. obscel.Rule has no Layer
// field by design — the layer is a term inside the CEL predicate — so the gate
// recovers it the only way it exists: by reading the `obs.layer == "<layer>"`
// literal out of the expression. A rule may name zero or more; the covered set
// is the union across every loaded stage-1 rule. Parsing (not a hand-kept list)
// is the point: a rule that stops gating on a layer silently shrinks the covered
// set and the gate sees it.
var obsLayerLiteral = regexp.MustCompile(`obs\.layer\s*==\s*"([a-z_]+)"`)

// knownUncoveredLayers is the closed set of in-scope layers that legitimately
// have NO stage-1 CEL rule, each with the reason it is exempt. It exists so the
// exemption is a FACT the test enforces, not a gap the test fails to notice:
// TestPolicyCoverageMatrix_EstateLayerCoverage asserts InScopeLayers() minus the
// covered set equals this set EXACTLY, so adding an in-scope layer without a rule
// fails (the set grows), and adding a rule for an exempt layer also fails (the
// exemption rots and must be removed deliberately).
//
//   - behavioural: the behavioural layer is produced and judged sentinel-side
//     (apps/stun-sentinel), not by a CEL bundle in this engine. It carries no
//     obs.layer == "behavioural" rule anywhere by design.
var knownUncoveredLayers = map[model.Layer]string{
	model.LayerBehavioural: "sentinel-side (apps/stun-sentinel); no in-engine CEL rule by design",
}

// loadAllBundlesForCoverage loads every bundle the tenant ships, exactly as the
// boot loader does, so the gate sees the real estate rather than a curated
// subset. It mirrors loadK8sAuditBundle's construction (same dir, same silent
// logger, same store-backed pseudonymiser) but returns the whole set.
func loadAllBundlesForCoverage(t *testing.T) []*obscel.Bundle {
	t.Helper()
	dir := bundlesDir(t)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	pseudo := policy.StorePseudonymiser(store.NewMemoryStore())
	bundles, err := policy.LoadBundles(dir, log, pseudo)
	if err != nil {
		t.Fatalf("LoadBundles(%s): %v", dir, err)
	}
	if len(bundles) == 0 {
		t.Fatalf("LoadBundles(%s) returned no bundles; the estate gate has nothing to check", dir)
	}
	return bundles
}

// coveredLayers returns the set of layers gated on by at least one stage-1 rule
// across all loaded bundles, parsed from the rule expressions.
func coveredLayers(bundles []*obscel.Bundle) map[model.Layer]bool {
	covered := map[model.Layer]bool{}
	for _, b := range bundles {
		for _, r := range b.Rules {
			for _, m := range obsLayerLiteral.FindAllStringSubmatch(r.Expression, -1) {
				covered[model.Layer(m[1])] = true
			}
		}
	}
	return covered
}

// TestPolicyCoverageMatrix_EstateLayerCoverage asserts assertion 1: every
// in-scope layer that has a collector is covered by at least one stage-1 rule in
// some loaded bundle, with the behavioural layer the one documented exception.
//
// The failure mode this catches: a collector ships observations for a new layer
// (or an existing layer loses its last rule) and nothing in the engine judges
// them — a silent no-op detection surface.
func TestPolicyCoverageMatrix_EstateLayerCoverage(t *testing.T) {
	bundles := loadAllBundlesForCoverage(t)
	covered := coveredLayers(bundles)
	t.Logf("layers covered by a stage-1 rule: %v", sortedLayers(covered))

	// Every in-scope layer is either covered by a rule or an explicit exception.
	for _, layer := range model.InScopeLayers() {
		if covered[layer] {
			continue
		}
		if reason, ok := knownUncoveredLayers[layer]; ok {
			t.Logf("layer %q is uncovered by design: %s", layer, reason)
			continue
		}
		t.Errorf("in-scope layer %q is covered by NO stage-1 rule and is not a documented exception: "+
			"a collector for this layer would emit observations no rule ever judges", layer)
	}

	// The exception set cannot rot: every exempt layer must still be in scope and
	// must still be genuinely uncovered. An exempt layer that gained a rule, or
	// that left the in-scope set, is a stale exemption that must be removed.
	inScope := map[model.Layer]bool{}
	for _, layer := range model.InScopeLayers() {
		inScope[layer] = true
	}
	for layer := range knownUncoveredLayers {
		if !inScope[layer] {
			t.Errorf("knownUncoveredLayers names %q which is not in InScopeLayers(); remove the stale exemption", layer)
		}
		if covered[layer] {
			t.Errorf("knownUncoveredLayers names %q but a stage-1 rule now covers it; the exemption is stale and must be removed", layer)
		}
	}
}

// aggregatedRuleExpectation carries a row plus the table it came from, so a
// duplicate (bundle, rule) across two tables names both sources.
type aggregatedRuleExpectation struct {
	exp   ruleExpectation
	table string
}

// allRuleExpectationTables is every per-stream expectation table in the suite,
// named. A new stream adds its table here; forgetting to is caught the same way
// a missing fixture is — the stream's rules show up with no row. Keep this the
// single enumeration of the tables so there is one place to extend.
var allRuleExpectationTables = map[string][]ruleExpectation{
	"ruleExpectations (iam-change, cloud-signals)": ruleExpectations,
	"k8sRuleExpectations":                          k8sRuleExpectations,
	"identityRuleExpectations":                     identityRuleExpectations,
	"saasRuleExpectations":                         saasRuleExpectations,
	"endpointRuleExpectations":                     endpointRuleExpectations,
	"gcpRuleExpectations":                          gcpRuleExpectations,
	"netEgressRuleExpectations":                    netEgressRuleExpectations,
	"baoRuleExpectations":                          baoRuleExpectations,
}

// ruleKey identifies a rule uniquely across the estate. Rule ids are only unique
// within a bundle (nothing stops two bundles sharing an id), so the key is the
// pair, never the id alone.
type ruleKey struct {
	bundle string
	rule   string
}

// knownRulesWithoutFixtureRow is the closed set of loaded stage-1 rules that
// legitimately have no row in the per-stream Kusari expectation tables, each with
// the test that DOES prove it instead. Same contract as knownUncoveredLayers:
// the gate asserts each exempt rule is genuinely loaded AND genuinely absent from
// every table, so the exemption cannot silently cover a rule that later gained a
// row, nor name a rule that no longer exists.
//
//   - kusari-landlock-denial/landlock-verified-denial: a containment rule whose
//     output drives the decision-to-stun dispatcher, not the Kusari detection
//     fixture corpus. Its positive (VERIFIED + denial_reason) and negatives
//     (empty denial_reason, missing denial_reason, lowercase verified) are proven
//     by correlation/landlock_policy_test.go, and its persistence by
//     store/nono_denial_frostdb_test.go.
var knownRulesWithoutFixtureRow = map[ruleKey]string{
	{bundle: "kusari-landlock-denial", rule: "landlock-verified-denial"}: "covered by correlation/landlock_policy_test.go (positive + negatives) and store/nono_denial_frostdb_test.go, not by a Kusari fixture-corpus row",
}

// TestPolicyCoverageMatrix_EstateRuleFixtures asserts assertion 2: every stage-1
// rule in every loaded bundle has BOTH a positive and a negative fixture row in
// the per-stream expectation tables, and no table row names a rule no loaded
// bundle contains.
//
// The failure mode a negative catches: a rule with only a positive fixture may
// fire on everything and still pass a positive-only suite. The failure mode the
// reverse direction catches: a table that drifts ahead of the bundles, naming a
// rule that was renamed or removed.
func TestPolicyCoverageMatrix_EstateRuleFixtures(t *testing.T) {
	bundles := loadAllBundlesForCoverage(t)

	// Aggregate all tables, keyed on (bundle, rule). A duplicate key across tables
	// is itself a defect — two rows for one rule means a copy that can diverge.
	rows := map[ruleKey]aggregatedRuleExpectation{}
	for tableName, table := range allRuleExpectationTables {
		for _, exp := range table {
			k := ruleKey{bundle: exp.Bundle, rule: exp.Rule}
			if prev, dup := rows[k]; dup {
				t.Errorf("rule %q in bundle %q has rows in two tables (%s and %s); one rule, one row",
					exp.Rule, exp.Bundle, prev.table, tableName)
				continue
			}
			rows[k] = aggregatedRuleExpectation{exp: exp, table: tableName}
		}
	}

	// Index the loaded rules so the reverse-direction check can test membership.
	loadedRules := map[ruleKey]bool{}
	for _, b := range bundles {
		for _, r := range b.Rules {
			loadedRules[ruleKey{bundle: b.ID, rule: r.ID}] = true
		}
	}

	// Forward: every loaded stage-1 rule has a +/- row, or is a documented
	// exception.
	for _, b := range bundles {
		for _, r := range b.Rules {
			k := ruleKey{bundle: b.ID, rule: r.ID}
			if _, exempt := knownRulesWithoutFixtureRow[k]; exempt {
				continue
			}
			row, ok := rows[k]
			if !ok {
				t.Errorf("rule %q in bundle %q has no row in any expectation table and is not a documented exception: "+
					"a rule with no +/- fixture is unproven coverage", r.ID, b.ID)
				continue
			}
			if row.exp.Positive == "" {
				t.Errorf("rule %q in bundle %q (table %s) has an empty Positive fixture", r.ID, b.ID, row.table)
			}
			if row.exp.Negative == "" {
				t.Errorf("rule %q in bundle %q (table %s) has an empty Negative fixture: "+
					"a rule that fires on everything passes a positive-only suite", r.ID, b.ID, row.table)
			}
		}
	}

	// Reverse: no table row names a (bundle, rule) that no loaded bundle contains.
	for k, row := range rows {
		if !loadedRules[k] {
			t.Errorf("table %s names rule %q in bundle %q which no loaded bundle contains: the table drifted ahead of the estate",
				row.table, k.rule, k.bundle)
		}
	}

	// The exception set cannot rot: every exempt rule must be loaded AND genuinely
	// have no table row.
	for k, reason := range knownRulesWithoutFixtureRow {
		if !loadedRules[k] {
			t.Errorf("knownRulesWithoutFixtureRow names rule %q in bundle %q which no loaded bundle contains; remove the stale exemption (%s)",
				k.rule, k.bundle, reason)
		}
		if _, hasRow := rows[k]; hasRow {
			t.Errorf("knownRulesWithoutFixtureRow names rule %q in bundle %q but it now HAS a table row; the exemption is stale and must be removed",
				k.rule, k.bundle)
		}
	}
}

// sortedLayers is a stable rendering of a layer set, for log lines.
func sortedLayers(set map[model.Layer]bool) []string {
	out := make([]string, 0, len(set))
	for l := range set {
		out = append(out, string(l))
	}
	sort.Strings(out)
	return out
}
