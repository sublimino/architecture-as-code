package obscel

import (
	"strings"
	"testing"
	"time"
)

func testBundle() *Bundle {
	return &Bundle{
		ID:       "kusari-iam-change",
		TenantID: "kusari",
		Version:  "1.0.0",
		Mode:     ModeShadow,
		Vars:     map[string][]string{"break_glass_actors": {"arn:aws:iam::123456789012:user/break-glass"}},
		Rules: []Rule{
			// Deliberately out of sorted order in the slice, so any test that
			// asserts output order is asserting the sort and not the literal.
			{ID: "zz-last", Name: "always matches", Severity: "low", Expression: `obs.layer != ""`},
			{ID: "aa-first", Name: "always matches", Severity: "medium", Expression: `obs.id != ""`},
			{ID: "mm-middle", Name: "iam change", Severity: "high",
				Expression: `obs.layer == "cloud_control_plane" && !(obs.actor in vars.break_glass_actors)`},
		},
	}
}

func ruleIDs(fs []Finding) []string {
	out := make([]string, 0, len(fs))
	for _, f := range fs {
		out = append(out, f.RuleID)
	}
	return out
}

// TestRulesEvaluateInSortedRuleIDOrder is the determinism contract from doc.go.
//
// Killed mutation: replacing SortedRules' sort with the raw b.Rules slice makes
// this assert ["zz-last","aa-first","mm-middle"], i.e. file order, so a bundle
// whose stanzas are reordered by a reviewer produces a different finding stream
// for identical input and replay stops matching live byte for byte.
func TestRulesEvaluateInSortedRuleIDOrder(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	findings, err := ev.EvaluateObservation(testObservation(), testBundle())
	if err != nil {
		t.Fatalf("unexpected evaluator fault: %v", err)
	}
	got := ruleIDs(findings)
	want := []string{"aa-first", "mm-middle", "zz-last"}
	if len(got) != len(want) {
		t.Fatalf("expected %d findings, got %d (%v)", len(want), len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("rule order drifted:\n got %v\nwant %v", got, want)
		}
	}
}

// TestRepeatedEvaluationIsByteIdentical is the replay oracle in miniature: the
// same observation through the same bundle twice must project identically under
// CanonicalFinding. Map-order-dependent label or rule handling fails here.
func TestRepeatedEvaluationIsByteIdentical(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	obs := testObservation()
	b := testBundle()

	project := func() string {
		fs, err := ev.EvaluateObservation(obs, b)
		if err != nil {
			t.Fatalf("unexpected evaluator fault: %v", err)
		}
		parts := make([]string, 0, len(fs))
		for _, f := range fs {
			parts = append(parts, CanonicalFinding(f))
		}
		return strings.Join(parts, "\n")
	}

	first := project()
	for i := 0; i < 20; i++ {
		if got := project(); got != first {
			t.Fatalf("run %d diverged:\n got %q\nwant %q", i, got, first)
		}
	}
}

// TestEvaluatorFaultIsIsolated proves a broken rule neither emits a finding nor
// suppresses its neighbours.
//
// Killed mutation: returning early on the first rule error (`return findings,
// err` instead of collecting into faults and continuing) drops "ok-after" and
// the suite goes red — which is exactly the production failure mode where one
// unmaintained rule silently blinds a whole bundle.
func TestEvaluatorFaultIsIsolated(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	b := &Bundle{
		ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
		Rules: []Rule{
			{ID: "aa-ok-before", Severity: "low", Expression: `obs.id != ""`},
			// Unguarded access to a label this observation does not carry: a
			// runtime "no such key" fault, not a compile error.
			{ID: "bb-broken-runtime", Severity: "low", Expression: `obs.labels.error_code == "AccessDenied"`},
			// Not compilable at all.
			{ID: "cc-broken-compile", Severity: "low", Expression: `obs.layer ===== "x"`},
			{ID: "dd-ok-after", Severity: "low", Expression: `obs.tenant_id == "kusari"`},
		},
	}

	findings, err := ev.EvaluateObservation(testObservation(), b)
	if err == nil {
		t.Fatal("two broken rules must surface as an evaluator fault")
	}
	for _, want := range []string{"bb-broken-runtime", "cc-broken-compile"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("fault must name rule %q, got: %v", want, err)
		}
	}
	got := ruleIDs(findings)
	want := []string{"aa-ok-before", "dd-ok-after"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("healthy rules must still run:\n got %v\nwant %v", got, want)
	}
	for _, f := range findings {
		if strings.HasPrefix(f.RuleID, "bb-") || strings.HasPrefix(f.RuleID, "cc-") {
			t.Fatalf("a faulting rule must emit no finding, got %+v", f)
		}
	}
}

// TestFindingFieldsAreDerivedNotGenerated pins every field the pipeline worker
// and the replay oracle read.
//
// Killed mutation: setting Finding.Timestamp to time.Now() instead of the
// observation's timestamp makes replay over the backlog produce a different
// canonical projection on every run, which this test catches immediately.
func TestFindingFieldsAreDerivedNotGenerated(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	obs := testObservation()
	b := &Bundle{
		ID: "kusari-iam-change", TenantID: "kusari", Version: "1.2.3", Mode: ModeShadow,
		Rules: []Rule{{ID: "iam-priv-change", Severity: "high", Expression: `obs.layer == "cloud_control_plane"`}},
	}

	findings, err := ev.EvaluateObservation(obs, b)
	if err != nil {
		t.Fatalf("unexpected evaluator fault: %v", err)
	}
	if len(findings) != 1 {
		t.Fatalf("expected 1 finding, got %d", len(findings))
	}
	f := findings[0]

	if want := FindingID("kusari", "iam-priv-change", "1.2.3", "obs-1"); f.ID != want {
		t.Errorf("ID must be derived: got %q want %q", f.ID, want)
	}
	if !f.Timestamp.Equal(obs.Timestamp) {
		t.Errorf("Timestamp must be the observation's, got %s want %s", f.Timestamp, obs.Timestamp)
	}
	if f.Timestamp.Equal(time.Time{}) {
		t.Error("Timestamp must not be zero")
	}
	if f.TenantID != "kusari" {
		t.Errorf("TenantID: got %q", f.TenantID)
	}
	if f.Actor != obs.Actor {
		t.Errorf("Actor: got %q want %q", f.Actor, obs.Actor)
	}
	if f.RuleID != "iam-priv-change" {
		t.Errorf("RuleID: got %q", f.RuleID)
	}
	if f.BundleID != "kusari-iam-change" {
		t.Errorf("BundleID: got %q", f.BundleID)
	}
	if f.BundleVersion != "1.2.3" {
		t.Errorf("BundleVersion: got %q", f.BundleVersion)
	}
	if f.Severity != "high" {
		t.Errorf("Severity: got %q", f.Severity)
	}
	if f.SourceObsID != "obs-1" {
		t.Errorf("SourceObsID: got %q", f.SourceObsID)
	}
	if f.Labels["event_name"] != "AttachUserPolicy" {
		t.Errorf("Labels must be carried through: got %v", f.Labels)
	}

	// Labels must be a copy: mutating the finding must not reach back into the
	// observation that produced it.
	f.Labels["event_name"] = "tampered"
	if obs.Labels["event_name"] != "AttachUserPolicy" {
		t.Error("finding labels must be a defensive copy of the observation's")
	}
}

// TestBundleVersionParticipatesInFindingIdentity: the same event under two
// bundle versions is two detections, not one deduplicated one.
func TestBundleVersionParticipatesInFindingIdentity(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	obs := testObservation()
	mk := func(version string) Finding {
		b := &Bundle{ID: "b", TenantID: "kusari", Version: version, Mode: ModeShadow,
			Rules: []Rule{{ID: "r", Severity: "high", Expression: `true`}}}
		fs, err := ev.EvaluateObservation(obs, b)
		if err != nil || len(fs) != 1 {
			t.Fatalf("version %s: findings=%d err=%v", version, len(fs), err)
		}
		return fs[0]
	}
	if mk("1.0.0").ID == mk("1.0.1").ID {
		t.Fatal("bundle version must participate in the finding id")
	}
}

func TestEvaluateObservationRejectsNilBundle(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	if _, err := ev.EvaluateObservation(testObservation(), nil); err == nil {
		t.Fatal("a nil bundle must be an error, not an empty finding set")
	}
}

// TestNonMatchingRuleIsNotAFault: false is an answer, not a failure.
func TestNonMatchingRuleIsNotAFault(t *testing.T) {
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	b := &Bundle{ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
		Rules: []Rule{{ID: "r", Severity: "high", Expression: `obs.layer == "endpoint_host"`}}}
	findings, err := ev.EvaluateObservation(testObservation(), b)
	if err != nil {
		t.Fatalf("a rule evaluating false must not be an error: %v", err)
	}
	if len(findings) != 0 {
		t.Fatalf("expected no findings, got %d", len(findings))
	}
}

// BenchmarkEvaluateObservation measures stage-1 per-observation latency against
// the shipped kusari bundle (proposal §6 item 6: recorded in errata, never a
// gate).
func BenchmarkEvaluateObservation(b *testing.B) {
	bundle, err := LoadBundleFile(kusariBundlePath)
	if err != nil {
		b.Fatalf("LoadBundleFile: %v", err)
	}
	ev, err := NewEvaluator()
	if err != nil {
		b.Fatalf("NewEvaluator: %v", err)
	}
	obs := testObservation()

	// Warm the program cache so the measurement is evaluation, not compilation.
	if _, err := ev.EvaluateObservation(obs, bundle); err != nil {
		b.Fatalf("warm-up fault: %v", err)
	}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := ev.EvaluateObservation(obs, bundle); err != nil {
			b.Fatalf("fault: %v", err)
		}
	}
}
