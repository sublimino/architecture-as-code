// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"crypto/ed25519"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/fleet-manager/pkg/attestation"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"

	k8sruntime "k8s.io/apimachinery/pkg/runtime"
)

// ─────────────────────────────────────────────────────────────────────────────
// SLER-P6-3 — End-to-end acceptance suite for multi-plane containment
//
// This suite proves the HAPPY PATH: one containment decision fans out across
// all five enforcement planes, is attested, and is reversed only through a
// governance-gated resume with mandatory credential rotation. It is deliberately
// NOT an adversarial suite — SLER-P6-1 (scripts/run-redteam-suite.sh plus
// test/crkc-adversarial-redteam.bats) proves an attacker cannot escape the
// cascade. The two are kept distinct, and
// TestAcceptance_DoesNotDuplicateRedTeamScenarios asserts they stay that way
// rather than trusting this comment to enforce it.
//
// ─── Why coverage is derived, not listed ─────────────────────────────────────
//
// scripts/run-redteam-suite.sh:320 carries
//
//	REQUIRED_PLANES=("freeze" "mesh" "bao" "spire" "admission")
//
// — a hand-written bash array. It is correct today and silently wrong the moment
// a plane is added or renamed, because nothing connects it to the enum that
// actually decides. test/acceptance-spec-coverage.bats was written after exactly
// that class of drift cost real coverage (commit d9d1d2f rewrote a Playwright
// test that nothing was ever wired to run), and its discipline is the one this
// file follows: one side of every coverage check is derived from the artefact
// that decides — here AllEnforcementPlanes() in schema.go:74, which is P1-2's
// plane enum and the same list frozen_contract_table_test.go:262 freezes.
//
// The derivation is only worth anything if it can fail. Three controls prove it
// does: an empty registry must report every plane uncovered (vacuity control), a
// synthetic sixth plane must report itself uncovered (drift control), and a
// scenario claiming a plane outside the enum must report it unknown (rename
// control). Each is an executed test, not a sentence.
// ─────────────────────────────────────────────────────────────────────────────

// acceptanceCoverageProbe is a plane name no scenario can legitimately claim.
//
// Negative control, in the spirit of acceptance-spec-coverage.bats's
// __spec-coverage-guard-probe__. If a matcher ever reports this name as covered,
// the matching is too broad and every coverage result below is worthless.
const acceptanceCoverageProbe EnforcementPlane = "__acceptance-coverage-probe__"

// acceptanceRuntimeLedger is where each run appends its own wall-clock cost, so
// a gradual creep across many small additions is visible before the suite
// becomes impractical to run on every CI change.
const acceptanceRuntimeLedger = "docs/signalloom/evidence/sler-p6-3-acceptance-runtime.jsonl"

// acceptanceRuntimeCeilingMs is the practical-for-CI budget for the whole
// acceptance corpus. The fleet-manager package as a whole runs in ~1.5 s, and
// this suite is a small fraction of that; 20 s leaves an order of magnitude of
// headroom while still failing long before the suite could reasonably be called
// "on-demand only".
const acceptanceRuntimeCeilingMs = 20000

// denialMatrixExportPath is P5-2's MACHINE-READABLE export. The suite reads this
// rather than the prose sibling (sler-p5-2-denial-matrix.md) precisely so a
// re-benchmark in P5-2 flows through to these assertions with no edit here.
const denialMatrixExportPath = "docs/signalloom/sler-p5-2-denial-matrix.json"

// redteamEvidencePath is P6-1's published scenario corpus, read only to assert
// this suite does not duplicate its scenario names.
const redteamEvidencePath = "docs/signalloom/evidence/adversarial-redteam-proof.json"

// ─────────────────────────────────────────────────────────────────────────────
// Scenario registry
// ─────────────────────────────────────────────────────────────────────────────

// acceptanceScenario declares one end-to-end acceptance case and, critically,
// which enforcement planes it actually exercises.
//
// Planes is the ONLY coverage claim in this file. It is checked against the enum
// in both directions, so it cannot name a plane that does not exist and cannot
// omit one that does.
type acceptanceScenario struct {
	ID     string
	Name   string
	Kind   string // lifecycle | partial | combined | environment
	Planes []EnforcementPlane
}

// acceptanceScenarios is a function rather than a package var so the coverage
// controls can substitute a mutated registry without touching global state.
func acceptanceScenarios() []acceptanceScenario {
	return []acceptanceScenario{
		{
			ID:   "acc-01",
			Name: "Single decision fans out across every enforcement plane",
			Kind: "lifecycle",
			// Claims all five because ContainAllPlanes dispatches all five and
			// TestAcceptance_FullLifecycle_FivePlanes asserts each PlaneResult
			// individually rather than reading the aggregate.
			Planes: []EnforcementPlane{PlaneFreeze, PlaneMesh, PlaneBao, PlaneSpire, PlaneAdmission},
		},
		{
			ID:     "acc-02",
			Name:   "Containment decision is written as an attested forensic record",
			Kind:   "lifecycle",
			Planes: []EnforcementPlane{PlaneFreeze, PlaneMesh, PlaneBao, PlaneSpire, PlaneAdmission},
		},
		{
			ID:   "acc-03",
			Name: "Governance-gated resume rotates credentials on both credential planes",
			Kind: "lifecycle",
			// Resume touches the credential planes and the freeze plane it
			// reverses. Mesh and admission re-open through their own Restore/
			// Unblock calls, which this scenario does not drive, so it does not
			// claim them — an overclaim here would let a real gap read as covered.
			Planes: []EnforcementPlane{PlaneFreeze, PlaneBao, PlaneSpire},
		},
		{
			ID:     "acc-04",
			Name:   "A single unreachable plane yields partial containment naming that plane",
			Kind:   "partial",
			Planes: []EnforcementPlane{PlaneFreeze, PlaneMesh, PlaneBao, PlaneSpire, PlaneAdmission},
		},
		{
			ID:   "acc-05",
			Name: "Credential and mesh planes contain together in one decision",
			Kind: "combined",
			// The happy-path mirror of P6-1 scenario-21, which attacks the same
			// combined surface. P6-1 asserts zero leaks and zero secret accesses
			// under attack; this asserts both planes report OutcomeContained on
			// one decision with bounded latency. Same surface, different question.
			Planes: []EnforcementPlane{PlaneBao, PlaneMesh},
		},
		{
			ID:     "acc-06",
			Name:   "Every plane client is wired and answering before any assertion is trusted",
			Kind:   "environment",
			Planes: []EnforcementPlane{PlaneFreeze, PlaneMesh, PlaneBao, PlaneSpire, PlaneAdmission},
		},
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Derived coverage
// ─────────────────────────────────────────────────────────────────────────────

// planeCoverageDrift is the pure comparison at the centre of this file.
//
// uncovered: planes the enum declares that no scenario exercises. This is what
// goes red when a sixth plane lands.
// unknown:   planes a scenario claims that the enum does not declare. This is
// what goes red when a plane is RENAMED — the direction a one-way check misses,
// because a renamed plane leaves the old name claimed and the new name orphaned.
func planeCoverageDrift(enum []EnforcementPlane, scenarios []acceptanceScenario) (uncovered, unknown []EnforcementPlane) {
	declared := make(map[EnforcementPlane]bool, len(enum))
	for _, p := range enum {
		declared[p] = true
	}

	claimed := make(map[EnforcementPlane]bool)
	for _, s := range scenarios {
		for _, p := range s.Planes {
			claimed[p] = true
		}
	}

	for _, p := range enum {
		if !claimed[p] {
			uncovered = append(uncovered, p)
		}
	}
	for p := range claimed {
		if !declared[p] {
			unknown = append(unknown, p)
		}
	}

	sortPlanes(uncovered)
	sortPlanes(unknown)
	return uncovered, unknown
}

func sortPlanes(p []EnforcementPlane) {
	sort.Slice(p, func(i, j int) bool { return p[i] < p[j] })
}

// scenariosCovering returns every scenario claiming the named plane.
func scenariosCovering(plane EnforcementPlane, scenarios []acceptanceScenario) []string {
	var out []string
	for _, s := range scenarios {
		for _, p := range s.Planes {
			if p == plane {
				out = append(out, s.ID)
				break
			}
		}
	}
	return out
}

func TestAcceptanceCoverage_DerivedFromPlaneEnum(t *testing.T) {
	enum := AllEnforcementPlanes()
	scenarios := acceptanceScenarios()

	// Vacuity controls. Every check below is a set difference, and an empty
	// input on either side makes all of them pass while comparing nothing —
	// the precise shape acceptance-spec-coverage.bats's own self-test guards.
	if len(enum) == 0 {
		t.Fatal("AllEnforcementPlanes() returned no planes; every coverage check below would pass vacuously")
	}
	if len(scenarios) == 0 {
		t.Fatal("the acceptance scenario registry is empty; every coverage check below would pass vacuously")
	}

	uncovered, unknown := planeCoverageDrift(enum, scenarios)

	if len(uncovered) > 0 {
		t.Errorf("planes declared by AllEnforcementPlanes() with NO acceptance scenario: %v\n"+
			"a plane the enum enforces but this suite never exercises is a plane whose\n"+
			"multi-plane acceptance run is green while never touching it. Add a scenario\n"+
			"to acceptanceScenarios() claiming it, and a test that actually drives it.", uncovered)
	}
	if len(unknown) > 0 {
		t.Errorf("acceptance scenarios claim planes the enum does not declare: %v\n"+
			"either the plane was renamed in schema.go and this registry still names the\n"+
			"old value, or the claim is a typo. Either way the coverage it reports is fiction.", unknown)
	}

	// Positive control per plane: naming the plane must resolve to at least one
	// scenario ID. A matcher that answered "covered" to everything would pass
	// the set difference above; this fails if the mapping is not real.
	for _, p := range enum {
		if ids := scenariosCovering(p, scenarios); len(ids) == 0 {
			t.Errorf("plane %q resolves to no scenario ID even though the drift check passed", p)
		}
	}

	// Negative control. No scenario can legitimately claim this name, so if it
	// resolves the matching is too broad and every result above is worthless.
	if ids := scenariosCovering(acceptanceCoverageProbe, scenarios); len(ids) > 0 {
		t.Errorf("probe plane %q resolved to scenarios %v; the matcher is too broad and "+
			"the coverage check would pass vacuously forever", acceptanceCoverageProbe, ids)
	}
}

// TestAcceptanceCoverage_FailsOnSyntheticSixthPlane is the drift control the
// card asks for, executed rather than asserted in prose.
//
// It adds a sixth plane to the enum the guard reads — without touching schema.go
// — and proves the guard reports it uncovered. If someone later "simplifies" the
// coverage check into something that cannot fail, this test goes red.
func TestAcceptanceCoverage_FailsOnSyntheticSixthPlane(t *testing.T) {
	const sixth EnforcementPlane = "quarantine"

	enum := append(AllEnforcementPlanes(), sixth)
	uncovered, unknown := planeCoverageDrift(enum, acceptanceScenarios())

	if len(unknown) != 0 {
		t.Fatalf("adding a plane to the enum should not produce unknown claims, got %v", unknown)
	}
	if len(uncovered) != 1 || uncovered[0] != sixth {
		t.Fatalf("a sixth plane with no scenario must be reported uncovered; got %v.\n"+
			"the coverage guard cannot detect a new plane, which is the entire drift\n"+
			"class this suite exists to close.", uncovered)
	}
}

// TestAcceptanceCoverage_FailsOnRenamedPlane is the reverse direction: a plane
// renamed in schema.go leaves this registry claiming a name that no longer
// exists. A one-way check reports that as "all five covered" because the old
// claim still satisfies nothing and the new plane is simply absent from claims.
func TestAcceptanceCoverage_FailsOnRenamedPlane(t *testing.T) {
	scenarios := []acceptanceScenario{{
		ID:     "synthetic",
		Kind:   "lifecycle",
		Planes: append(AllEnforcementPlanes(), EnforcementPlane("mesh-v2")),
	}}

	uncovered, unknown := planeCoverageDrift(AllEnforcementPlanes(), scenarios)
	if len(uncovered) != 0 {
		t.Fatalf("all enum planes are claimed here; got uncovered %v", uncovered)
	}
	if len(unknown) != 1 || unknown[0] != "mesh-v2" {
		t.Fatalf("a claim on a non-existent plane must be reported unknown; got %v", unknown)
	}
}

// TestAcceptanceCoverage_FailsOnEmptyRegistry proves the guard is not satisfied
// by the absence of scenarios — the way a set-difference guard most commonly
// rots into a no-op.
func TestAcceptanceCoverage_FailsOnEmptyRegistry(t *testing.T) {
	uncovered, _ := planeCoverageDrift(AllEnforcementPlanes(), nil)
	if len(uncovered) != len(AllEnforcementPlanes()) {
		t.Fatalf("an empty registry must leave every plane uncovered; got %v", uncovered)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// P5-2 denial-matrix bounds — sourced from the JSON export, never hard-coded
// ─────────────────────────────────────────────────────────────────────────────

// acceptanceDenialBounds maps an EnforcementPlane onto its published entry.
//
// Keyed on the entry's own .plane FIELD, deliberately, not on the JSON object
// key. The export keys OpenBao as "openbao" while its plane value is "bao"
// (docs/signalloom/sler-p5-2-denial-matrix.json). Keying on the map key would
// silently leave PlaneBao without a bound, and every bao timing assertion would
// then be skipped rather than failed — a gap that reads as coverage.
type acceptanceDenialBounds map[EnforcementPlane]PublishedPlaneDenial

// loadAcceptanceDenialBounds reads P5-2's machine-readable export.
//
// Every failure path names the file and the card that owns it. A raw
// "unexpected end of JSON input" from encoding/json tells a maintainer nothing
// about which of the repo's several JSON artefacts broke or who to ask.
func loadAcceptanceDenialBounds(path string) (acceptanceDenialBounds, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf(
				"SLER-P5-2 denial-matrix export is missing at %s: this acceptance suite sources "+
					"every timing bound from that file so a re-benchmark flows through without an "+
					"edit here; regenerate it from SLER-P5-2 before running this suite", path)
		}
		return nil, fmt.Errorf("SLER-P5-2 denial-matrix export at %s is unreadable: %w", path, err)
	}

	var parsed PublishedDenialMatrix
	if err := json.Unmarshal(data, &parsed); err != nil {
		return nil, fmt.Errorf(
			"SLER-P5-2 denial-matrix export at %s is not valid JSON (%v): the suite cannot derive "+
				"timing bounds from a malformed export, and asserting against hard-coded figures "+
				"instead would silently outlive the next re-benchmark", path, err)
	}

	if len(parsed.Planes) == 0 {
		return nil, fmt.Errorf(
			"SLER-P5-2 denial-matrix export at %s parsed but declares no planes: every timing "+
				"assertion would be skipped rather than failed", path)
	}

	bounds := make(acceptanceDenialBounds, len(parsed.Planes))
	for key, entry := range parsed.Planes {
		if entry.Plane == "" {
			return nil, fmt.Errorf(
				"SLER-P5-2 denial-matrix export at %s: entry %q carries no \"plane\" field, so it "+
					"cannot be bound to an EnforcementPlane; the export keys OpenBao as %q while its "+
					"plane value is %q, which is why this index reads the field and not the key",
				path, key, "openbao", PlaneBao)
		}
		if !entry.Plane.IsValid() {
			return nil, fmt.Errorf(
				"SLER-P5-2 denial-matrix export at %s: entry %q names plane %q, which is not a member "+
					"of AllEnforcementPlanes(); export and schema have diverged",
				path, key, entry.Plane)
		}
		if prev, dup := bounds[entry.Plane]; dup {
			return nil, fmt.Errorf(
				"SLER-P5-2 denial-matrix export at %s: plane %q is declared twice (%q and %q); the "+
					"bound this suite would assert against is whichever the map iterated last",
				path, entry.Plane, prev.DisplayName, entry.DisplayName)
		}
		if entry.RegressionThresholdMs <= 0 {
			return nil, fmt.Errorf(
				"SLER-P5-2 denial-matrix export at %s: plane %q has regression_threshold_ms=%d; a "+
					"non-positive threshold cannot bound anything and would make the timing assertion "+
					"for that plane unfalsifiable",
				path, entry.Plane, entry.RegressionThresholdMs)
		}
		bounds[entry.Plane] = entry
	}
	return bounds, nil
}

// exceedsPublishedBound is the timing predicate, extracted so it can be
// falsified independently of a live containment run.
//
// This matters more than it looks. Under the in-process fakes every plane
// reports 0 ms, so `latency <= threshold` is true no matter what the threshold
// says — an assertion that cannot currently fail and would therefore never
// notice if the bounds stopped being read at all. What these assertions actually
// guard is a REGRESSION in the fan-out code path (a plane that starts blocking,
// a serialised dispatch) measured against P5-2's published figure rather than a
// number written here. TestAcceptance_TimingPredicateIsFalsifiable proves the
// predicate can say "no".
func exceedsPublishedBound(latencyMs int64, bound PublishedPlaneDenial) bool {
	return latencyMs > bound.RegressionThresholdMs
}

func TestAcceptance_TimingPredicateIsFalsifiable(t *testing.T) {
	bounds := acceptanceBounds(t)

	for _, plane := range AllEnforcementPlanes() {
		bound := bounds[plane]

		// At the threshold: inside. One over: outside. If either direction is
		// wrong, every per-plane timing assertion in this file is decoration.
		if exceedsPublishedBound(bound.RegressionThresholdMs, bound) {
			t.Errorf("plane %q: a latency exactly at the published threshold (%d ms) is reported "+
				"as a regression", plane, bound.RegressionThresholdMs)
		}
		if !exceedsPublishedBound(bound.RegressionThresholdMs+1, bound) {
			t.Errorf("plane %q: a latency ONE ms over the published threshold (%d ms) is not "+
				"reported as a regression; the timing assertions cannot fail", plane, bound.RegressionThresholdMs)
		}

		// And the bound must come from the export, not from a constant that
		// happens to be large. A threshold matching the published p99 exactly
		// would mean the export's own headroom was silently discarded.
		if bound.GuaranteedDenialP99Ms >= bound.RegressionThresholdMs {
			t.Errorf("plane %q: published p99 %d ms is not below its regression threshold %d ms",
				plane, bound.GuaranteedDenialP99Ms, bound.RegressionThresholdMs)
		}
	}
}

func acceptanceBounds(t testing.TB) acceptanceDenialBounds {
	t.Helper()
	path := filepath.Join(findRepoRoot(t), denialMatrixExportPath)
	bounds, err := loadAcceptanceDenialBounds(path)
	if err != nil {
		t.Fatalf("%v", err)
	}
	return bounds
}

func TestAcceptance_DenialBoundsCoverEveryPlane(t *testing.T) {
	bounds := acceptanceBounds(t)

	var missing []EnforcementPlane
	for _, p := range AllEnforcementPlanes() {
		if _, ok := bounds[p]; !ok {
			missing = append(missing, p)
		}
	}
	if len(missing) > 0 {
		t.Fatalf("planes with no bound in %s: %v\n"+
			"a plane with no published bound has its timing assertion SKIPPED, not failed, "+
			"which reads as coverage. PlaneBao is the one this catches in practice: the export "+
			"keys it \"openbao\" and only indexing on the .plane field resolves it.",
			denialMatrixExportPath, missing)
	}

	// Positive control on the trap itself. If this ever fails, the index has
	// been rewritten to key on the JSON map key and bao is silently unbound.
	if got, ok := bounds[PlaneBao]; !ok {
		t.Error("PlaneBao did not resolve; the bounds index is keyed on the JSON map key, not .plane")
	} else if got.RegressionThresholdMs <= 0 {
		t.Errorf("PlaneBao threshold = %d, want > 0", got.RegressionThresholdMs)
	}
}

func TestAcceptance_DenialBoundsDegradeGracefully(t *testing.T) {
	dir := t.TempDir()

	cases := []struct {
		name     string
		write    func() string
		wantText []string
	}{
		{
			name:     "missing export",
			write:    func() string { return filepath.Join(dir, "absent.json") },
			wantText: []string{"SLER-P5-2", "missing", "absent.json"},
		},
		{
			name: "truncated export",
			write: func() string {
				p := filepath.Join(dir, "truncated.json")
				mustWriteFile(t, p, `{"schema_version":"x","planes":{`)
				return p
			},
			wantText: []string{"SLER-P5-2", "not valid JSON", "truncated.json"},
		},
		{
			name: "export with no planes",
			write: func() string {
				p := filepath.Join(dir, "empty.json")
				mustWriteFile(t, p, `{"schema_version":"x","planes":{}}`)
				return p
			},
			wantText: []string{"SLER-P5-2", "no planes", "empty.json"},
		},
		{
			name: "entry with no plane field",
			write: func() string {
				p := filepath.Join(dir, "nofield.json")
				mustWriteFile(t, p, `{"planes":{"openbao":{"display_name":"x","regression_threshold_ms":30}}}`)
				return p
			},
			wantText: []string{"no \"plane\" field", "nofield.json"},
		},
		{
			name: "entry naming a plane the schema does not declare",
			write: func() string {
				p := filepath.Join(dir, "bogus.json")
				mustWriteFile(t, p, `{"planes":{"x":{"plane":"quarantine","regression_threshold_ms":30}}}`)
				return p
			},
			wantText: []string{"not a member of AllEnforcementPlanes", "bogus.json"},
		},
		{
			name: "entry with an unfalsifiable threshold",
			write: func() string {
				p := filepath.Join(dir, "zero.json")
				mustWriteFile(t, p, `{"planes":{"mesh":{"plane":"mesh","regression_threshold_ms":0}}}`)
				return p
			},
			wantText: []string{"regression_threshold_ms=0", "unfalsifiable"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := loadAcceptanceDenialBounds(tc.write())
			if err == nil {
				t.Fatal("want a clear error, got nil — a broken export would be treated as usable bounds")
			}
			for _, want := range tc.wantText {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("error message does not name %q, so a maintainer cannot act on it:\n  %v", want, err)
				}
			}
		})
	}
}

func mustWriteFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture %s: %v", path, err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Environment preflight — loud failure, never a skip
// ─────────────────────────────────────────────────────────────────────────────

// TestAcceptance_EnvironmentPreflight_FailsLoudly is scenario acc-06.
//
// A misconfigured CI run must not report false coverage. The failure mode this
// closes is the one test/obsidian-lint.bats hit in a different repo: a skip in
// setup on a missing dependency turned a build failure into eighty-one silent
// passes. Nothing in this file calls t.Skip, and
// TestAcceptance_SuiteContainsNoSkips asserts that mechanically.
func TestAcceptance_EnvironmentPreflight_FailsLoudly(t *testing.T) {
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Per-plane wiring. A nil client here is a plane that silently contributes
	// no PlaneResult, which AggregateOutcome then reads as a four-plane success.
	wiring := []struct {
		plane  EnforcementPlane
		wired  bool
		detail string
	}{
		{PlaneFreeze, client.clientset != nil, "kubernetes clientset (pod state / cgroup freeze label)"},
		{PlaneMesh, client.meshClient != nil, "mesh client (Cilium / conntrack isolation)"},
		{PlaneBao, client.baoClient != nil, "OpenBao client (lease + token revocation)"},
		{PlaneSpire, client.spireClient != nil, "SPIRE client (entry eviction)"},
		{PlaneAdmission, client.admissionClient != nil, "admission client (node-capability-guard)"},
	}

	observed := newPlaneAssertions()
	var unwired []string
	for _, w := range wiring {
		observed.record(w.plane)
		if !w.wired {
			unwired = append(unwired, fmt.Sprintf("%s: %s is nil", w.plane, w.detail))
		}
	}
	if len(unwired) > 0 {
		t.Fatalf("acceptance environment is incomplete; refusing to report coverage:\n  %s\n"+
			"a plane with no client contributes no PlaneResult, and AggregateOutcome reads the "+
			"remainder as a full success. That is false coverage, published.",
			strings.Join(unwired, "\n  "))
	}

	// Every wired plane must also ANSWER. Presence is not liveness.
	if err := client.Health(ctx); err != nil {
		t.Fatalf("plane health probe failed: %v\n"+
			"the clients are wired but at least one does not answer; any containment result "+
			"this suite produced would be about a plane that was never reachable", err)
	}

	if len(wiring) != len(AllEnforcementPlanes()) {
		t.Fatalf("preflight checks %d planes but the enum declares %d; a plane was added to "+
			"schema.go without a wiring check here", len(wiring), len(AllEnforcementPlanes()))
	}

	assertScenarioClaimObserved(t, "acc-06", observed)
}

// TestAcceptance_SuiteContainsNoSkips is the mechanical half of the loud-failure
// requirement. A skip anywhere in this file turns a misconfigured environment
// into a green run reporting coverage it never obtained.
func TestAcceptance_SuiteContainsNoSkips(t *testing.T) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller could not locate this file; the no-skip guard cannot read its own source")
	}
	src, err := os.ReadFile(thisFile)
	if err != nil {
		t.Fatalf("read own source %s: %v", thisFile, err)
	}

	for _, forbidden := range forbiddenSkipCalls() {
		if strings.Contains(string(src), forbidden) {
			t.Errorf("%s appears in %s — this suite must fail loudly on a misconfigured "+
				"environment, never skip; a skipped acceptance run reports coverage it did not obtain",
				forbidden, filepath.Base(thisFile))
		}
	}
}

// forbiddenSkipCalls builds its needles by concatenation on purpose.
//
// Written as plain literals, this list matched ITSELF: the guard read its own
// source, found each forbidden token in its own slice, and reported four
// violations in a file containing no skip at all. Note that the same trap
// catches PROSE — an earlier version of this very comment quoted the token and
// tripped the guard a second time, which is why nothing below spells one out.
// A guard that cannot distinguish the thing it forbids
// from its own description of that thing is not a guard. Splitting each needle
// means no complete token appears anywhere in this file's bytes, while the
// assembled string is exactly what a real call site would contain —
// TestAcceptance_NoSkipGuardIsFalsifiable proves the assembled form still
// matches.
func forbiddenSkipCalls() []string {
	return []string{
		"t." + "Skip(",
		"t." + "Skipf(",
		"t." + "SkipNow(",
		"testing." + "Short()",
	}
}

// TestAcceptance_NoSkipGuardIsFalsifiable proves the needles above still match a
// genuine call site. Without it, splitting the literals could just as easily
// have produced strings that match nothing, and the no-skip guard would pass
// forever over a file full of skips.
func TestAcceptance_NoSkipGuardIsFalsifiable(t *testing.T) {
	needles := forbiddenSkipCalls()
	if len(needles) == 0 {
		t.Fatal("no forbidden call patterns; the no-skip guard checks nothing")
	}

	// Synthetic source containing exactly the calls the guard must catch.
	synthetic := "func TestX(t *testing.T) {\n\tt." + "Skip(\"nope\")\n\tt." + "Skipf(\"%s\", x)\n\t" +
		"t." + "SkipNow()\n\tif testing." + "Short() { return }\n}"

	for _, needle := range needles {
		if !strings.Contains(synthetic, needle) {
			t.Errorf("pattern %q does not match a real call site; the no-skip guard is inert", needle)
		}
	}

	// Negative control: a file with no skips must produce no match, or the
	// guard would flag every file and be ignored.
	clean := "func TestY(t *testing.T) {\n\tt.Fatal(\"loud\")\n}"
	for _, needle := range needles {
		if strings.Contains(clean, needle) {
			t.Errorf("pattern %q matched a clean file; the guard over-matches", needle)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// acc-01 — one decision, five planes, asserted individually
// ─────────────────────────────────────────────────────────────────────────────

func TestAcceptance_FullLifecycle_FivePlanes(t *testing.T) {
	bounds := acceptanceBounds(t)
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	started := time.Now()
	dec, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", "agent-cardvault", "acc-01-contain")
	elapsed := time.Since(started)
	recordAcceptanceRuntime(t, "acc-01", elapsed)

	if err != nil {
		t.Fatalf("containment returned an error on the happy path: %v", err)
	}
	if dec == nil {
		t.Fatal("containment returned a nil decision")
	}
	if dec.OverallOutcome != OutcomeContained {
		t.Errorf("overall outcome = %q, want %q", dec.OverallOutcome, OutcomeContained)
	}
	if err := dec.ValidateDecision(); err != nil {
		t.Errorf("decision fails its own P1-2 structural invariants: %v", err)
	}

	// Index by plane, then assert EACH plane individually. Reading only
	// OverallOutcome is the aggregate trap: four contained planes and one
	// missing plane aggregate to "contained" because a plane that never
	// reported contributes no result to disagree with.
	byPlane := indexPlaneResults(dec.PlaneResults)
	observed := newPlaneAssertions()

	if len(dec.PlaneResults) != len(AllEnforcementPlanes()) {
		t.Fatalf("got %d plane results, want %d (one per plane in AllEnforcementPlanes())",
			len(dec.PlaneResults), len(AllEnforcementPlanes()))
	}

	for _, plane := range AllEnforcementPlanes() {
		plane := plane
		t.Run(string(plane), func(t *testing.T) {
			res, ok := byPlane[plane]
			if !ok {
				t.Fatalf("no PlaneResult for %q; this plane was dispatched but never reported, "+
					"and the aggregate outcome does not show its absence", plane)
			}
			if res.Outcome != OutcomeContained {
				t.Errorf("outcome = %q, want %q (error: %q)", res.Outcome, OutcomeContained, res.Error)
			}
			if res.Error != "" {
				t.Errorf("contained plane carries a non-empty error: %q", res.Error)
			}
			if strings.TrimSpace(res.Timestamp) == "" {
				t.Error("PlaneResult has an empty Timestamp; a forensic record built from this " +
					"cannot place the action in an incident timeline")
			} else if _, err := time.Parse(time.RFC3339Nano, res.Timestamp); err != nil {
				t.Errorf("Timestamp %q is not RFC3339Nano: %v", res.Timestamp, err)
			}
			if res.LatencyMs < 0 {
				t.Errorf("negative latency %d ms", res.LatencyMs)
			}

			// Timing bound comes from P5-2's JSON export, never from a figure
			// written into this file.
			bound, ok := bounds[plane]
			if !ok {
				t.Fatalf("no published bound for %q in %s", plane, denialMatrixExportPath)
			}
			observed.record(plane)
			if exceedsPublishedBound(res.LatencyMs, bound) {
				t.Errorf("latency %d ms exceeds the published regression threshold %d ms "+
					"(%s, source: %s)", res.LatencyMs, bound.RegressionThresholdMs,
					bound.DisplayName, denialMatrixExportPath)
			}
		})
	}

	// Bind the registry's coverage CLAIM to what this scenario actually
	// asserted on, rather than trusting the struct literal.
	assertScenarioClaimObserved(t, "acc-01", observed)
}

func indexPlaneResults(results []PlaneResult) map[EnforcementPlane]PlaneResult {
	out := make(map[EnforcementPlane]PlaneResult, len(results))
	for _, r := range results {
		out[r.Plane] = r
	}
	return out
}

// ─────────────────────────────────────────────────────────────────────────────
// acc-02 — the decision becomes an attested forensic record (P5-1)
// ─────────────────────────────────────────────────────────────────────────────

func TestAcceptance_ContainmentIsAttested(t *testing.T) {
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	ctx := context.Background()
	started := time.Now()
	dec, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", "agent-cardvault", "acc-02-contain")
	if err != nil {
		t.Fatalf("containment: %v", err)
	}

	engine := newAcceptanceAttestationEngine(t)

	planes := make([]attestation.PlaneExecutionEvidence, 0, len(dec.PlaneResults))
	for _, r := range dec.PlaneResults {
		planes = append(planes, attestation.PlaneExecutionEvidence{
			Plane:     string(r.Plane),
			Outcome:   string(r.Outcome),
			LatencyMs: r.LatencyMs,
			Error:     r.Error,
		})
	}

	record, envelope, err := engine.AttestContainment(ctx, attestation.ContainmentAttestationRequest{
		EventType:      attestation.EventContainmentCompleted,
		IdempotencyKey: dec.IdempotencyKey,
		Authorization: attestation.AuthorizationEvidence{
			DecisionID:            dec.DecisionID,
			TriggerReason:         dec.Reason.Code,
			TriggerDescription:    dec.Reason.Description,
			TriggeredBy:           dec.Reason.TriggeredBy,
			DelegationEdgeRevoked: dec.Reason.DelegationEdgeRevoked,
		},
		Target: attestation.TargetIdentity{
			AgentID:   dec.Target.AgentID,
			Namespace: dec.Target.Namespace,
			SPIFFEID:  dec.Target.SPIFFEID,
		},
		Execution: attestation.ExecutionEvidence{
			OverallOutcome: string(dec.OverallOutcome),
			TotalLatencyMs: dec.DurationMs,
			Planes:         planes,
		},
	})
	recordAcceptanceRuntime(t, "acc-02", time.Since(started))

	if err != nil {
		t.Fatalf("attesting the containment decision failed: %v\n"+
			"a production enforcement with no attested record of the deciding evidence is "+
			"the condition this mission treats as a hard blocker", err)
	}
	if err := record.Validate(); err != nil {
		t.Errorf("forensic record fails its own invariants: %v", err)
	}

	// The record must carry ALL five planes, not a summary. An attested record
	// that drops a plane is an incident timeline with a hole in it.
	if got := len(record.Execution.Planes); got != len(AllEnforcementPlanes()) {
		t.Errorf("attested record carries %d planes, want %d", got, len(AllEnforcementPlanes()))
	}
	attested := make(map[string]bool, len(record.Execution.Planes))
	for _, p := range record.Execution.Planes {
		attested[p.Plane] = true
	}
	observed := newPlaneAssertions()
	for _, p := range AllEnforcementPlanes() {
		if !attested[string(p)] {
			t.Errorf("plane %q enforced but absent from the attested record", p)
			continue
		}
		observed.record(p)
	}
	assertScenarioClaimObserved(t, "acc-02", observed)

	if record.Attestation.StatementDigest == "" {
		t.Error("attested record carries no statement digest")
	}

	// The envelope must actually verify. A signature nobody checks is a claim.
	result, err := engine.Verify(envelope)
	if err != nil {
		t.Fatalf("verifying the DSSE envelope failed: %v", err)
	}
	if !result.Valid {
		t.Errorf("DSSE envelope did not verify: %+v", result)
	}
}

func newAcceptanceAttestationEngine(t *testing.T) *attestation.AttestationEngine {
	t.Helper()
	// Deterministic seed: the acceptance suite must not depend on entropy for a
	// reproducible run, and a fixed key makes a failing envelope reproducible.
	priv := ed25519.NewKeyFromSeed([]byte("SLER-P6-3 acceptance attestation")[:ed25519.SeedSize])
	signer, err := attestation.NewLocalEd25519SignerFromKey(priv)
	if err != nil {
		t.Fatalf("build acceptance signer: %v", err)
	}
	engine, err := attestation.NewAttestationEngine(signer, attestation.NewKeyHistoryStore(), "sler-p6-3-acceptance")
	if err != nil {
		t.Fatalf("build attestation engine: %v", err)
	}
	return engine
}

// ─────────────────────────────────────────────────────────────────────────────
// acc-03 — governance-gated resume with mandatory rotation (P4-3)
// ─────────────────────────────────────────────────────────────────────────────

func TestAcceptance_GovernanceGatedResumeClosesTheLifecycle(t *testing.T) {
	token, registry := liveDualSignedToken(t)
	ledger := NewReplayLedger()

	spire := newCountingRotateSpireClient(OutcomeContained)
	bao := newRotateBaoServer(http.StatusOK)
	defer bao.Close()
	client := newResumeFleetClient(t, spire, bao.URL)

	started := time.Now()
	resp, err := EnforceResume(context.Background(), ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: "acc-03-resume",
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}, registry, dualPolicy(), ledger, client)
	recordAcceptanceRuntime(t, "acc-03", time.Since(started))

	if err != nil {
		t.Fatalf("governance-gated resume failed on the happy path: %v", err)
	}
	if !resp.Success {
		t.Errorf("resume Success = false, want true (error: %q)", resp.Error)
	}

	// Rotation is not optional. An unfreeze that restores the agent's previous
	// credentials hands a contained agent back the exact identity that was
	// revoked when it was contained.
	if !resp.CredentialsRotated {
		t.Error("CredentialsRotated = false; resume must force credential rotation, " +
			"otherwise the resumed agent carries the identity that was revoked on containment")
	}
	if resp.ProcessesResumed < 1 {
		t.Errorf("ProcessesResumed = %d, want >= 1", resp.ProcessesResumed)
	}

	// Both credential planes must have been driven, not just reported.
	observed := newPlaneAssertions()
	if resp.ProcessesResumed >= 1 {
		observed.record(PlaneFreeze) // the freeze this resume reverses
	}
	if spire.reenterCalls.Load() >= 1 {
		observed.record(PlaneSpire)
	}
	if bao.rotateCalls.Load() >= 1 {
		observed.record(PlaneBao)
	}
	defer assertScenarioClaimObserved(t, "acc-03", observed)

	if got := spire.reenterCalls.Load(); got != 1 {
		t.Errorf("SPIRE re-entry calls = %d, want 1 — the spire plane was not actually driven", got)
	}
	if got := bao.rotateCalls.Load(); got != 1 {
		t.Errorf("OpenBao rotate calls = %d, want 1 — the bao plane was not actually driven", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// acc-04 — partial containment, naming the plane that failed
// ─────────────────────────────────────────────────────────────────────────────

// TestAcceptance_PartialContainment_NamesTheFailingPlane is the case the whole
// of P1-2 and P1-5's schema work exists to make representable. A suite that only
// ever tests full success and full failure does not prove the schema achieved
// its purpose.
//
// It asserts three separable things, because a maintainer reading a failed run
// needs all three and a single aggregate gives none of them:
//  1. the decision is PARTIAL, not contained and not unavailable;
//  2. the SPECIFIC failing plane is identifiable from the result, by name;
//  3. every sibling plane is still contained — a partial is not a licence for
//     the other four to quietly do nothing.
func TestAcceptance_PartialContainment_NamesTheFailingPlane(t *testing.T) {
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	// Inject the failure on exactly one plane: OpenBao unreachable.
	failingBao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer failingBao.Close()
	client.baoClient = NewOpenBaoClient(OpenBaoConfig{
		Address: failingBao.URL,
		Token:   "test-token",
		Timeout: 2 * time.Second,
	})

	started := time.Now()
	dec, err := client.ContainAllPlanes(context.Background(), "fe-signalloom-agents", "agent-cardvault", "acc-04-partial")
	recordAcceptanceRuntime(t, "acc-04", time.Since(started))

	if err == nil {
		t.Fatal("a plane failure must surface as an error; got nil, which is indistinguishable " +
			"from a clean five-plane containment at the HTTP layer")
	}
	if dec == nil {
		t.Fatal("a partial containment must still return a decision; a nil decision loses the " +
			"record of the four planes that DID contain")
	}

	// (1) Partial, specifically. Not contained, not unavailable.
	if dec.OverallOutcome != OutcomePartial {
		t.Errorf("overall outcome = %q, want %q — the schema can represent partial containment "+
			"and collapsing it to either extreme throws away the only honest answer",
			dec.OverallOutcome, OutcomePartial)
	}

	// (2) The specific failing plane, by name.
	failed := failingPlanes(dec.PlaneResults)
	if len(failed) != 1 {
		t.Fatalf("want exactly one failing plane, got %d: %v", len(failed), failed)
	}
	if failed[0] != PlaneBao {
		t.Fatalf("failing plane reported as %q, want %q — a maintainer reading this run would "+
			"instrument the wrong plane", failed[0], PlaneBao)
	}
	// The failing result must carry a reason, not just an outcome.
	baoRes := indexPlaneResults(dec.PlaneResults)[PlaneBao]
	if strings.TrimSpace(baoRes.Error) == "" {
		t.Error("the failing plane's PlaneResult carries no error text; the run says WHICH plane " +
			"failed but not why, which still costs the next reader an instrumentation cycle")
	}
	t.Logf("partial containment: plane=%s outcome=%s error=%q", baoRes.Plane, baoRes.Outcome, baoRes.Error)

	// (3) Siblings still contained. A partial must not excuse the rest.
	for _, plane := range AllEnforcementPlanes() {
		if plane == PlaneBao {
			continue
		}
		res, ok := indexPlaneResults(dec.PlaneResults)[plane]
		if !ok {
			t.Errorf("sibling plane %q reported no result under a partial containment", plane)
			continue
		}
		if res.Outcome != OutcomeContained {
			t.Errorf("sibling plane %q outcome = %q, want %q — one plane's failure must not "+
				"silently abandon the others", plane, res.Outcome, OutcomeContained)
		}
	}

	// All five planes still report. A partial containment that drops the failing
	// plane's record entirely would aggregate to "contained" over four results.
	if got := len(dec.PlaneResults); got != len(AllEnforcementPlanes()) {
		t.Errorf("partial containment carries %d plane results, want %d", got, len(AllEnforcementPlanes()))
	}
}

// failingPlanes returns every plane whose result is not a clean containment.
func failingPlanes(results []PlaneResult) []EnforcementPlane {
	var out []EnforcementPlane
	for _, r := range results {
		if r.Outcome != OutcomeContained {
			out = append(out, r.Plane)
		}
	}
	sortPlanes(out)
	return out
}

// TestAcceptance_PartialContainment_DetectorIsFalsifiable proves failingPlanes
// does not simply return everything (which would make the "exactly one" check
// above pass for the wrong reason) or nothing.
func TestAcceptance_PartialContainment_DetectorIsFalsifiable(t *testing.T) {
	allGood := []PlaneResult{{Plane: PlaneMesh, Outcome: OutcomeContained}, {Plane: PlaneBao, Outcome: OutcomeContained}}
	if got := failingPlanes(allGood); len(got) != 0 {
		t.Errorf("clean results reported as failing: %v", got)
	}
	mixed := []PlaneResult{{Plane: PlaneMesh, Outcome: OutcomeContained}, {Plane: PlaneSpire, Outcome: OutcomeUnavailable}}
	if got := failingPlanes(mixed); len(got) != 1 || got[0] != PlaneSpire {
		t.Errorf("failingPlanes(mixed) = %v, want [spire]", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// acc-05 — combined credential + mesh plane, the happy-path mirror of P6-1's
// scenario-21
// ─────────────────────────────────────────────────────────────────────────────

func TestAcceptance_CombinedCredentialAndMeshPlane(t *testing.T) {
	bounds := acceptanceBounds(t)
	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()

	ctx := context.Background()
	started := time.Now()
	dec, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", "agent-cardvault", "acc-05-combined")
	recordAcceptanceRuntime(t, "acc-05", time.Since(started))
	if err != nil {
		t.Fatalf("combined containment: %v", err)
	}

	byPlane := indexPlaneResults(dec.PlaneResults)

	// P6-1 scenario-21 attacks this same pair and asserts zero packet leaks and
	// zero secret accesses under a simultaneous replay-and-egress attempt. The
	// question here is the complementary one: on the ordinary path, do both
	// planes actually contain, within their separately published bounds, on one
	// decision. Deliberately NOT a re-run of the attack.
	observed := newPlaneAssertions()
	for _, plane := range []EnforcementPlane{PlaneBao, PlaneMesh} {
		res, ok := byPlane[plane]
		if !ok {
			t.Fatalf("combined scenario: no result for plane %q", plane)
		}
		observed.record(plane)
		if res.Outcome != OutcomeContained {
			t.Errorf("plane %q outcome = %q, want %q", plane, res.Outcome, OutcomeContained)
		}
		bound := bounds[plane]
		if exceedsPublishedBound(res.LatencyMs, bound) {
			t.Errorf("plane %q latency %d ms exceeds published threshold %d ms (source: %s)",
				plane, res.LatencyMs, bound.RegressionThresholdMs, denialMatrixExportPath)
		}
	}

	// Both planes must belong to ONE decision — the point of "combined". Two
	// separate decisions that each contained one plane would satisfy the
	// per-plane assertions above and prove nothing about simultaneity.
	if dec.IdempotencyKey != "acc-05-combined" {
		t.Errorf("idempotency key = %q, want the single key both planes were driven under",
			dec.IdempotencyKey)
	}

	assertScenarioClaimObserved(t, "acc-05", observed)
}

// TestAcceptance_DoesNotDuplicateRedTeamScenarios keeps this suite and P6-1
// distinct by construction rather than by comment.
//
// Re-running the same attack under two suites with two pass criteria wastes CI
// time and, worse, makes a failure ambiguous about which contract broke.
func TestAcceptance_DoesNotDuplicateRedTeamScenarios(t *testing.T) {
	path := filepath.Join(findRepoRoot(t), redteamEvidencePath)
	data, err := os.ReadFile(path)
	if err != nil {
		// The corpus is generated by scripts/run-redteam-suite.sh. Its absence
		// is reported, not skipped: an unread corpus cannot prove non-overlap.
		t.Fatalf("P6-1 red-team corpus is missing at %s: %v\n"+
			"run `bash scripts/run-redteam-suite.sh` first; without it this suite cannot "+
			"demonstrate it does not duplicate P6-1's scenarios", path, err)
	}

	var corpus struct {
		Scenarios []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"scenarios"`
	}
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatalf("P6-1 corpus at %s is not valid JSON: %v", path, err)
	}
	if len(corpus.Scenarios) == 0 {
		t.Fatalf("P6-1 corpus at %s declares no scenarios; the overlap check would pass vacuously", path)
	}

	redteam := make(map[string]bool, len(corpus.Scenarios))
	for _, s := range corpus.Scenarios {
		redteam[normaliseScenarioName(s.Name)] = true
	}

	for _, s := range acceptanceScenarios() {
		if redteam[normaliseScenarioName(s.Name)] {
			t.Errorf("acceptance scenario %s (%q) duplicates a P6-1 red-team scenario name.\n"+
				"this suite proves the happy-path lifecycle works; P6-1 proves an adversary "+
				"cannot escape it. Keep the questions distinct.", s.ID, s.Name)
		}
		if strings.HasPrefix(s.ID, "scenario-") {
			t.Errorf("acceptance scenario ID %q uses P6-1's id namespace", s.ID)
		}
	}

	// Positive control: the comparison must be capable of finding a match at
	// all. Without it a normaliser that mangled every string would pass forever.
	probe := normaliseScenarioName(corpus.Scenarios[0].Name)
	if !redteam[probe] {
		t.Fatalf("the name comparison cannot match P6-1's own first scenario %q; "+
			"the non-overlap result above is meaningless", corpus.Scenarios[0].Name)
	}
}

func normaliseScenarioName(s string) string {
	return strings.Join(strings.Fields(strings.ToLower(strings.TrimSpace(s))), " ")
}

// ─────────────────────────────────────────────────────────────────────────────
// Runtime ledger — so creep is visible before it becomes impractical
// ─────────────────────────────────────────────────────────────────────────────

// recordAcceptanceRuntime appends one scenario timing to the ledger.
//
// A write failure is a WARNING, never a test failure: the ledger is
// observability, and a read-only CI filesystem must not turn an otherwise
// passing acceptance run red. The ceiling assertion below does not depend on the
// ledger being writable.
func recordAcceptanceRuntime(t *testing.T, scenarioID string, elapsed time.Duration) {
	t.Helper()
	t.Logf("scenario %s took %v", scenarioID, elapsed)

	path := filepath.Join(findRepoRoot(t), acceptanceRuntimeLedger)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Logf("WARN: acceptance runtime ledger directory %s is not writable (%v); "+
			"timing history will not be recorded for this run", filepath.Dir(path), err)
		return
	}

	line, err := json.Marshal(map[string]any{
		"card":        "SLER-P6-3",
		"scenario":    scenarioID,
		"elapsed_ms":  elapsed.Milliseconds(),
		"ceiling_ms":  acceptanceRuntimeCeilingMs,
		"recorded_at": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		t.Logf("WARN: could not encode runtime ledger entry: %v", err)
		return
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Logf("WARN: acceptance runtime ledger %s is not writable (%v); "+
			"timing history will not be recorded for this run", path, err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		t.Logf("WARN: writing to the runtime ledger failed: %v", err)
	}
}

// TestAcceptance_RuntimeIsPracticalForCI measures the whole acceptance corpus in
// one pass and fails if it drifts past the stated ceiling.
//
// The ledger records history; this is the gate. Without the gate, the history is
// a chart nobody reads until the suite has already become an on-demand-only
// burden — which is precisely how a suite stops running on every change.
func TestAcceptance_RuntimeIsPracticalForCI(t *testing.T) {
	started := time.Now()

	client, server := setupFull5PlaneFleetClient(t, 1)
	defer server.Close()
	ctx := context.Background()

	// Exercise the dominant cost — a full five-plane fan-out — three times, so
	// the measurement is not a single sample.
	for i := 0; i < 3; i++ {
		if _, err := client.ContainAllPlanes(ctx, "fe-signalloom-agents", "agent-cardvault",
			fmt.Sprintf("acc-runtime-%d", i)); err != nil {
			t.Fatalf("containment pass %d: %v", i, err)
		}
	}

	elapsed := time.Since(started)
	recordAcceptanceRuntime(t, "acc-runtime-probe", elapsed)

	if elapsed.Milliseconds() > acceptanceRuntimeCeilingMs {
		t.Errorf("three full five-plane containment passes took %v, over the %d ms CI ceiling.\n"+
			"see %s for the trend — a suite that stops being cheap stops being run on every change",
			elapsed, acceptanceRuntimeCeilingMs, acceptanceRuntimeLedger)
	}
}

// TestAcceptance_RuntimeLedgerIsWritten proves the ledger mechanism is real and
// not a no-op that the WARN path silently swallows on every run.
func TestAcceptance_RuntimeLedgerIsWritten(t *testing.T) {
	path := filepath.Join(findRepoRoot(t), acceptanceRuntimeLedger)
	recordAcceptanceRuntime(t, "acc-ledger-selftest", 1*time.Millisecond)

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("runtime ledger %s was not created: %v\n"+
			"without it a gradual creep in suite runtime has no recorded history", path, err)
	}
	if !strings.Contains(string(data), "acc-ledger-selftest") {
		t.Errorf("ledger at %s does not contain the entry just written; the recorder is a no-op", path)
	}

	// Every line must be parseable, or the trend cannot be read back.
	for i, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("ledger line %d is not valid JSON: %v", i+1, err)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Claim-vs-observation — binding the registry's coverage claim to behaviour
//
// Added after an advisor pass found the joint where this whole derivation chain
// could be true and still vacuous: acceptanceScenarios() DECLARES which planes
// each scenario exercises, and nothing bound that declaration to the scenario
// actually asserting anything about those planes. A scenario declaring five
// planes and asserting on one was green, and coverage read 5/5.
//
// Every per-plane assertion in the driving tests now routes through
// planeAssertions.record, and each scenario closes by comparing what it claimed
// against what it actually touched. Coverage is therefore computed from
// execution, not from a struct literal.
// ─────────────────────────────────────────────────────────────────────────────

type planeAssertions struct {
	seen map[EnforcementPlane]int
}

func newPlaneAssertions() *planeAssertions {
	return &planeAssertions{seen: make(map[EnforcementPlane]int)}
}

func (p *planeAssertions) record(plane EnforcementPlane) { p.seen[plane]++ }

func (p *planeAssertions) planes() []EnforcementPlane {
	out := make([]EnforcementPlane, 0, len(p.seen))
	for plane := range p.seen {
		out = append(out, plane)
	}
	sortPlanes(out)
	return out
}

// assertScenarioClaimObserved fails when a scenario's declared plane set differs
// in EITHER direction from the planes it actually asserted on.
//
// over-claimed: declared but never touched — the vacuity this closes.
// under-claimed: touched but not declared — coverage the registry under-reports,
// which is less dangerous but still a registry that does not describe reality.
func assertScenarioClaimObserved(t *testing.T, id string, observed *planeAssertions) {
	t.Helper()

	var claimed []EnforcementPlane
	found := false
	for _, s := range acceptanceScenarios() {
		if s.ID == id {
			claimed, found = s.Planes, true
			break
		}
	}
	if !found {
		t.Fatalf("no scenario %q in acceptanceScenarios(); a driving test with no registry row "+
			"contributes no coverage claim and is invisible to the derived guard", id)
	}

	claimSet := make(map[EnforcementPlane]bool, len(claimed))
	for _, p := range claimed {
		claimSet[p] = true
	}
	obsSet := make(map[EnforcementPlane]bool, len(observed.seen))
	for p := range observed.seen {
		obsSet[p] = true
	}

	var overClaimed, underClaimed []EnforcementPlane
	for _, p := range claimed {
		if !obsSet[p] {
			overClaimed = append(overClaimed, p)
		}
	}
	for p := range obsSet {
		if !claimSet[p] {
			underClaimed = append(underClaimed, p)
		}
	}
	sortPlanes(overClaimed)
	sortPlanes(underClaimed)

	if len(overClaimed) > 0 {
		t.Errorf("scenario %s CLAIMS planes it made no assertion about: %v\n"+
			"the derived coverage guard counts this scenario as covering them, so the suite "+
			"reports coverage it did not obtain — the exact vacuity the derivation exists to "+
			"prevent, one level up.", id, overClaimed)
	}
	if len(underClaimed) > 0 {
		t.Errorf("scenario %s asserted on planes it does not claim: %v\n"+
			"add them to the registry row, or the registry does not describe what runs.",
			id, underClaimed)
	}
	if len(observed.seen) == 0 {
		t.Errorf("scenario %s recorded no plane assertions at all; its coverage claim is entirely "+
			"unbacked", id)
	}
}

// TestAcceptance_ClaimObservationCheckIsFalsifiable proves the comparison above
// can say "no" in both directions. Without it, a helper that compared nothing
// would let every scenario's claim pass unexamined — which is precisely the
// state this mechanism was added to fix.
func TestAcceptance_ClaimObservationCheckIsFalsifiable(t *testing.T) {
	scenarios := []acceptanceScenario{{
		ID:     "probe",
		Planes: []EnforcementPlane{PlaneMesh, PlaneBao},
	}}

	diff := func(observed []EnforcementPlane) (over, under []EnforcementPlane) {
		claimSet := map[EnforcementPlane]bool{PlaneMesh: true, PlaneBao: true}
		obsSet := make(map[EnforcementPlane]bool)
		for _, p := range observed {
			obsSet[p] = true
		}
		for _, p := range scenarios[0].Planes {
			if !obsSet[p] {
				over = append(over, p)
			}
		}
		for p := range obsSet {
			if !claimSet[p] {
				under = append(under, p)
			}
		}
		sortPlanes(over)
		sortPlanes(under)
		return over, under
	}

	if over, under := diff([]EnforcementPlane{PlaneMesh, PlaneBao}); len(over) != 0 || len(under) != 0 {
		t.Errorf("an exact match reported drift: over=%v under=%v", over, under)
	}
	if over, _ := diff([]EnforcementPlane{PlaneMesh}); len(over) != 1 || over[0] != PlaneBao {
		t.Errorf("an over-claim was not detected; got %v", over)
	}
	if _, under := diff([]EnforcementPlane{PlaneMesh, PlaneBao, PlaneSpire}); len(under) != 1 || under[0] != PlaneSpire {
		t.Errorf("an under-claim was not detected; got %v", under)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Partial containment across EVERY plane, not just OpenBao
//
// The original partial-containment test injected a failure on OpenBao alone and
// the claim "the suite names the failing plane" was then true for bao and
// generalised in prose. Table-driven here: each plane is failed in turn and the
// same three assertions run, so "names the failing plane" is verified for all
// five rather than asserted for one.
// ─────────────────────────────────────────────────────────────────────────────

// failingSpireClient answers, but with a plane-level failure.
type failingSpireClient struct{ fastMockSpireClient }

func (m *failingSpireClient) EvictAgent(context.Context, SpireEvictionRequest) (*SpireEvictionResponse, error) {
	return nil, fmt.Errorf("spire entry eviction: %w", ErrEnforcementUnavailable)
}

type failingMeshClient struct{ fastMockMeshClient }

func (m *failingMeshClient) IsolateAgentMesh(context.Context, MeshIsolationRequest) (*MeshIsolationResponse, error) {
	return nil, fmt.Errorf("mesh isolation: %w", ErrEnforcementUnavailable)
}

type failingAdmissionClient struct{ fastMockAdmissionClient }

func (m *failingAdmissionClient) BlockAdmission(context.Context, AdmissionBlockRequest) (*AdmissionBlockResponse, error) {
	return nil, fmt.Errorf("admission block: %w", ErrEnforcementUnavailable)
}

func TestAcceptance_PartialContainment_EveryPlaneInTurn(t *testing.T) {
	cases := []struct {
		plane EnforcementPlane
		// breaks installs a failure on exactly one plane of an otherwise
		// healthy five-plane client.
		breaks func(t *testing.T, c *k8sFleetClient)
	}{
		{PlaneBao, func(t *testing.T, c *k8sFleetClient) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusInternalServerError)
			}))
			t.Cleanup(srv.Close)
			c.baoClient = NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "t", Timeout: 2 * time.Second})
		}},
		{PlaneSpire, func(_ *testing.T, c *k8sFleetClient) { c.spireClient = &failingSpireClient{} }},
		{PlaneMesh, func(_ *testing.T, c *k8sFleetClient) { c.meshClient = &failingMeshClient{} }},
		{PlaneAdmission, func(_ *testing.T, c *k8sFleetClient) { c.admissionClient = &failingAdmissionClient{} }},
		{PlaneFreeze, func(_ *testing.T, c *k8sFleetClient) {
			// The freeze plane writes the pod state label. Failing only the pod
			// PATCH makes that write fail while the pod stays readable, so the
			// credential planes still observe the subject from its
			// ServiceAccount. (An empty clientset would also blind the identity
			// lookup and cap bao and spire at partial.)
			fk := fake.NewSimpleClientset(agentPod("agent-cardvault", "active", nil))
			failOn(fk, "patch", injectedPatchFault)
			c.clientset = fk
		}},
	}

	// The table must cover the enum, or "every plane in turn" is prose. Derived,
	// not counted by hand.
	covered := make(map[EnforcementPlane]bool, len(cases))
	for _, tc := range cases {
		covered[tc.plane] = true
	}
	for _, p := range AllEnforcementPlanes() {
		if !covered[p] {
			t.Fatalf("plane %q is never the injected failure; the claim that partial containment "+
				"names the failing plane would be verified for the others and merely asserted "+
				"for this one", p)
		}
	}

	observed := newPlaneAssertions()
	defer assertScenarioClaimObserved(t, "acc-04", observed)

	for _, tc := range cases {
		tc := tc
		observed.record(tc.plane)
		t.Run(string(tc.plane), func(t *testing.T) {
			client, server := setupFull5PlaneFleetClient(t, 1)
			defer server.Close()
			tc.breaks(t, client)

			dec, err := client.ContainAllPlanes(context.Background(), "fe-signalloom-agents",
				"agent-cardvault", "acc-04-"+string(tc.plane))

			if err == nil {
				t.Fatalf("plane %q was made unreachable but containment returned no error; a "+
					"failed enforcement is indistinguishable from a clean one at the HTTP layer", tc.plane)
			}
			if dec == nil {
				t.Fatal("a partial containment must still return a decision")
			}
			if dec.OverallOutcome == OutcomeContained {
				t.Errorf("overall outcome = %q with plane %q broken; a failing plane must not "+
					"aggregate to full containment", dec.OverallOutcome, tc.plane)
			}

			failed := failingPlanes(dec.PlaneResults)
			if len(failed) != 1 {
				t.Fatalf("want exactly one failing plane, got %d: %v", len(failed), failed)
			}
			if failed[0] != tc.plane {
				t.Fatalf("broke plane %q but the run names %q; a maintainer reading this would "+
					"instrument the wrong plane", tc.plane, failed[0])
			}

			byPlane := indexPlaneResults(dec.PlaneResults)
			if res := byPlane[tc.plane]; strings.TrimSpace(res.Error) == "" {
				t.Errorf("plane %q failed but its PlaneResult carries no error text; the run says "+
					"WHICH plane failed but not why", tc.plane)
			}
			for _, sibling := range AllEnforcementPlanes() {
				if sibling == tc.plane {
					continue
				}
				res, ok := byPlane[sibling]
				if !ok {
					t.Errorf("sibling plane %q reported no result", sibling)
					continue
				}
				if res.Outcome != OutcomeContained {
					t.Errorf("sibling plane %q outcome = %q, want %q — one plane's failure must "+
						"not silently abandon the others", sibling, res.Outcome, OutcomeContained)
				}
			}
			if got := len(dec.PlaneResults); got != len(AllEnforcementPlanes()) {
				t.Errorf("got %d plane results under a partial containment, want %d", got,
					len(AllEnforcementPlanes()))
			}
			t.Logf("partial containment: failing plane=%s outcome=%s", tc.plane, byPlane[tc.plane].Outcome)
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Negative controls for the two remaining round-trips
// ─────────────────────────────────────────────────────────────────────────────

// slowMeshClient answers correctly but takes longer than mesh's published
// regression threshold.
type slowMeshClient struct {
	fastMockMeshClient
	delay time.Duration
}

func (m *slowMeshClient) IsolateAgentMesh(ctx context.Context, req MeshIsolationRequest) (*MeshIsolationResponse, error) {
	time.Sleep(m.delay)
	return m.fastMockMeshClient.IsolateAgentMesh(ctx, req)
}

// TestAcceptance_PlaneLatencyProvenance is the negative control the timing
// assertions were missing — and it found something.
//
// The control was written to prove a slow plane makes its published bound bind.
// Injecting a 65 ms delay into the mesh client produced a PlaneResult reporting
// **1 ms**. The cause is not a test bug:
// k8sclient.go:658 builds the mesh result via MeshIsolationResponseToPlaneResult,
// which copies resp.LatencyMs — the number the plane client reports ABOUT
// ITSELF. The orchestrator never times the call. The same holds for bao, spire
// and admission. Only PlaneFreeze is wall-clock measured, at
// k8sclient.go:1037 (`elapsed := time.Since(t0).Milliseconds()`).
//
// The consequence is worth stating plainly, because it bounds what every timing
// assertion in this suite — and any downstream reading of P5-2's numbers — can
// mean: for four of the five planes, a plane that is genuinely slow while
// reporting a small number is INVISIBLE. Those assertions detect a plane that
// reports a regression, not a plane that has one.
//
// This is the plane clients' contract, owned by the P2/P3/P4 cards, not this
// one, so it is recorded rather than changed. But it is recorded as an EXECUTED
// characterisation rather than a sentence in a document: if a plane is later
// made orchestrator-measured, this test goes red and names it, which is exactly
// the notification the next maintainer needs.
func TestAcceptance_PlaneLatencyProvenance(t *testing.T) {
	bounds := acceptanceBounds(t)

	// ── Half 1: freeze IS measured, so its bound genuinely binds ───────────
	t.Run("freeze_is_orchestrator_measured", func(t *testing.T) {
		freezeBound := bounds[PlaneFreeze]
		delay := time.Duration(freezeBound.RegressionThresholdMs+40) * time.Millisecond

		client, server := setupFull5PlaneFleetClient(t, 1)
		defer server.Close()

		// Slow the pod-state write, which is the freeze plane's enforcement
		// call, without failing it.
		fk := fake.NewSimpleClientset(agentPod("agent-cardvault", "active", nil))
		fk.PrependReactor("patch", "pods", func(k8stesting.Action) (bool, k8sruntime.Object, error) {
			time.Sleep(delay)
			return false, nil, nil // fall through to the default reactor
		})
		client.clientset = fk

		dec, err := client.ContainAllPlanes(context.Background(), "fe-signalloom-agents",
			"agent-cardvault", "acc-timing-freeze")
		if err != nil {
			t.Fatalf("containment with a slow-but-healthy freeze plane should still succeed: %v", err)
		}

		res, ok := indexPlaneResults(dec.PlaneResults)[PlaneFreeze]
		if !ok {
			t.Fatal("no freeze PlaneResult")
		}
		if res.Outcome != OutcomeContained {
			t.Fatalf("slow freeze plane outcome = %q, want %q — the control must isolate latency, "+
				"not introduce a failure", res.Outcome, OutcomeContained)
		}
		if !exceedsPublishedBound(res.LatencyMs, freezeBound) {
			t.Fatalf("freeze took a real %v but reported %d ms against a published threshold of "+
				"%d ms, and the bound did NOT bind.\nthe freeze plane is documented as the one "+
				"orchestrator-measured plane; if that is no longer true, every timing assertion "+
				"in this suite is reading a number that never moves.",
				delay, res.LatencyMs, freezeBound.RegressionThresholdMs)
		}
		t.Logf("freeze bound binds on a real delay: %d ms > published threshold %d ms",
			res.LatencyMs, freezeBound.RegressionThresholdMs)
	})

	// ── Half 2: mesh is SELF-REPORTED, and this is the characterisation ────
	t.Run("mesh_is_plane_self_reported", func(t *testing.T) {
		meshBound := bounds[PlaneMesh]
		delay := time.Duration(meshBound.RegressionThresholdMs+40) * time.Millisecond

		client, server := setupFull5PlaneFleetClient(t, 1)
		defer server.Close()
		client.meshClient = &slowMeshClient{delay: delay}

		start := time.Now()
		dec, err := client.ContainAllPlanes(context.Background(), "fe-signalloom-agents",
			"agent-cardvault", "acc-timing-mesh")
		wall := time.Since(start)
		if err != nil {
			t.Fatalf("containment with a slow-but-healthy mesh plane should still succeed: %v", err)
		}

		res, ok := indexPlaneResults(dec.PlaneResults)[PlaneMesh]
		if !ok {
			t.Fatal("no mesh PlaneResult")
		}

		// The call really did take longer than the bound...
		if wall < delay {
			t.Fatalf("the injected delay did not take effect: wall clock %v < delay %v", wall, delay)
		}
		// ...and the reported latency really does not reflect it.
		if exceedsPublishedBound(res.LatencyMs, meshBound) {
			t.Fatalf("mesh now reports %d ms for a call that took %v, which EXCEEDS its published "+
				"threshold of %d ms.\nthat is an improvement: the mesh plane appears to have "+
				"become orchestrator-measured. Update this characterisation and "+
				"docs/signalloom/sler-p6-3-proof.md section 7.2, which currently records mesh, "+
				"bao, spire and admission as reporting their own latency.",
				res.LatencyMs, wall, meshBound.RegressionThresholdMs)
		}
		t.Logf("characterised: mesh call took %v but PlaneResult.LatencyMs reports %d ms "+
			"(self-reported by the plane client, not measured by the orchestrator)", wall, res.LatencyMs)
	})
}

// TestAcceptance_AttestationRejectsATamperedEnvelope is the negative control for
// the DSSE round-trip.
//
// Signing and verifying in-process with the same key and serialiser is a
// round-trip that cannot fail, so asserting result.Valid proves only that the
// two halves agree with each other. A forensic record whose signature nobody
// can actually falsify is a claim, not evidence.
func TestAcceptance_AttestationRejectsATamperedEnvelope(t *testing.T) {
	engine := newAcceptanceAttestationEngine(t)

	_, envelope, err := engine.AttestContainment(context.Background(), attestation.ContainmentAttestationRequest{
		EventType:      attestation.EventContainmentCompleted,
		IdempotencyKey: "acc-tamper-control",
		Authorization:  attestation.AuthorizationEvidence{DecisionID: "dec-tamper", TriggerReason: "TEST", TriggeredBy: "acceptance"},
		Target:         attestation.TargetIdentity{AgentID: "agent-cardvault", Namespace: "fe-signalloom-agents"},
		Execution: attestation.ExecutionEvidence{
			OverallOutcome: string(OutcomeContained),
			Planes:         []attestation.PlaneExecutionEvidence{{Plane: string(PlaneFreeze), Outcome: string(OutcomeContained)}},
		},
	})
	if err != nil {
		t.Fatalf("attest: %v", err)
	}

	// Positive half: the untampered envelope verifies.
	if result, err := engine.Verify(envelope); err != nil || !result.Valid {
		t.Fatalf("a freshly signed envelope did not verify (err=%v, result=%+v)", err, result)
	}

	// Negative half: flip one byte of the base64 payload. Verification must
	// refuse — either by error or by reporting invalid.
	tampered := tamperEnvelopePayload(t, envelope)
	result, err := engine.Verify(tampered)
	if err == nil && result != nil && result.Valid {
		t.Fatal("a tampered envelope VERIFIED. the attested forensic record is not tamper-evident, " +
			"so every attestation assertion in this suite proves only that the signer and the " +
			"verifier agree with each other.")
	}
	t.Logf("tampered envelope correctly refused (err=%v)", err)
}

// tamperEnvelopePayload flips a character inside the DSSE envelope's payload.
func tamperEnvelopePayload(t *testing.T, envelope []byte) []byte {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(envelope, &doc); err != nil {
		t.Fatalf("envelope is not JSON: %v", err)
	}
	payload, ok := doc["payload"].(string)
	if !ok || len(payload) < 8 {
		t.Fatalf("envelope has no usable payload field: %v", doc["payload"])
	}
	// Change a character in the middle of the base64 body. Swapping between two
	// valid base64 alphabet characters keeps the envelope decodable, so the
	// refusal comes from the SIGNATURE check rather than from a decode error —
	// which is the property under test.
	idx := len(payload) / 2
	repl := byte('A')
	if payload[idx] == 'A' {
		repl = 'B'
	}
	doc["payload"] = payload[:idx] + string(repl) + payload[idx+1:]

	out, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("re-marshal tampered envelope: %v", err)
	}
	return out
}
