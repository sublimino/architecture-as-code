package obscel

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// kusariBundlePath is the shipped bundle, reached from pkg/obscel. The test
// asserts on the real file rather than a fixture copy: a bundle that only ever
// passes in a copy of itself is not evidence that the deployed one loads.
const kusariBundlePath = "../../../policy/bundles/kusari/iam-change.yaml"

// TestShippedKusariBundleLoadsAndConforms is the ISC-51 gate: the bundle that
// Flux reconciles must parse, validate and compile, including every window and
// vars reference.
func TestShippedKusariBundleLoadsAndConforms(t *testing.T) {
	b, err := LoadBundleFile(kusariBundlePath)
	if err != nil {
		t.Fatalf("LoadBundleFile(%s): %v", kusariBundlePath, err)
	}
	if errs := Conform(b); len(errs) != 0 {
		t.Fatalf("Conform returned %d error(s): %v", len(errs), JoinRuleErrors(errs))
	}

	if b.TenantID != "kusari" {
		t.Errorf("tenant_id: got %q want %q", b.TenantID, "kusari")
	}
	if b.Version != "1.0.0" {
		t.Errorf("version: got %q want %q", b.Version, "1.0.0")
	}
	if b.Mode != ModeShadow {
		t.Errorf("mode: got %q want %q", b.Mode, ModeShadow)
	}
	if got := b.Vars["break_glass_actors"]; len(got) != 1 || got[0] != "arn:aws:iam::123456789012:user/break-glass" {
		t.Errorf("vars.break_glass_actors: got %v", got)
	}

	want := map[string]bool{"iam-priv-change": false, "access-key-created": false, "vpc-reject": false}
	for _, r := range b.Rules {
		if _, ok := want[r.ID]; !ok {
			t.Errorf("unexpected rule %q", r.ID)
			continue
		}
		want[r.ID] = true
	}
	for id, seen := range want {
		if !seen {
			t.Errorf("bundle is missing rule %q", id)
		}
	}

	if len(b.Windows) != 1 {
		t.Fatalf("expected 1 window, got %d", len(b.Windows))
	}
	w := b.Windows[0]
	if w.ID != "iam-change-burst" || w.OverRule != "iam-priv-change" {
		t.Errorf("window identity: got %q over %q", w.ID, w.OverRule)
	}
	if len(w.Key) != 2 || w.Key[0] != KeyTenantID || w.Key[1] != KeyActor {
		t.Errorf("window key: got %v want [tenant_id actor]", w.Key)
	}
	if w.Window != 10*time.Minute {
		t.Errorf("window duration: got %s want 10m", w.Window)
	}
	if w.Threshold != 3 {
		t.Errorf("window threshold: got %d want 3", w.Threshold)
	}
	if w.Severity != "high" {
		t.Errorf("window severity: got %q want high", w.Severity)
	}
}

// TestKusariBundleRulesMatchTheIntendedEvents drives the shipped bundle with
// observations shaped per the §2.3 label contract. Without this the bundle
// could conform perfectly and still match nothing.
func TestKusariBundleRulesMatchTheIntendedEvents(t *testing.T) {
	b, err := LoadBundleFile(kusariBundlePath)
	if err != nil {
		t.Fatalf("LoadBundleFile: %v", err)
	}
	ev, err := NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}

	cloud := func(eventName, actor string) Observation {
		o := testObservation()
		o.Actor = actor
		o.Labels = map[string]string{"event_source": "iam.amazonaws.com", "event_name": eventName}
		return o
	}
	const dev = "arn:aws:iam::123456789012:user/dev"
	const breakGlass = "arn:aws:iam::123456789012:user/break-glass"

	vpcReject := testObservation()
	vpcReject.Layer = "network_egress"
	vpcReject.Source = "aws:vpcflow"
	vpcReject.Labels = map[string]string{"event_source": "vpcflow", "event_name": "REJECT"}

	vpcAccept := vpcReject
	vpcAccept.Labels = map[string]string{"event_source": "vpcflow", "event_name": "ACCEPT"}

	unlabelled := testObservation()
	unlabelled.Labels = nil

	cases := []struct {
		name string
		obs  Observation
		want []string
	}{
		{"AttachUserPolicy by dev", cloud("AttachUserPolicy", dev), []string{"iam-priv-change"}},
		{"CreatePolicyVersion by dev", cloud("CreatePolicyVersion", dev), []string{"iam-priv-change"}},
		{"PutUserPolicy by dev", cloud("PutUserPolicy", dev), []string{"iam-priv-change"}},
		{"CreateAccessKey by dev", cloud("CreateAccessKey", dev), []string{"access-key-created"}},
		{"AttachUserPolicy by break-glass", cloud("AttachUserPolicy", breakGlass), nil},
		{"CreateAccessKey by break-glass", cloud("CreateAccessKey", breakGlass), nil},
		{"benign ListUsers by dev", cloud("ListUsers", dev), nil},
		{"VPC REJECT", vpcReject, []string{"vpc-reject"}},
		{"VPC ACCEPT", vpcAccept, nil},
		{"unlabelled cloud record", unlabelled, nil},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			findings, err := ev.EvaluateObservation(tc.obs, b)
			if err != nil {
				t.Fatalf("the shipped bundle must never fault, got: %v", err)
			}
			got := ruleIDs(findings)
			if len(got) != len(tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Fatalf("got %v, want %v", got, tc.want)
				}
			}
		})
	}
}

func writeBundle(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

const minimalBundle = `
id: b1
tenant_id: kusari
version: 1.0.0
mode: shadow
rules:
  - id: r1
    name: always
    severity: low
    expression: 'obs.layer != ""'
`

func TestLoadBundleDirIsSortedAndRepeatable(t *testing.T) {
	dir := t.TempDir()
	writeBundle(t, dir, "zzz/third.yaml", strings.Replace(minimalBundle, "id: b1", "id: b3", 1))
	writeBundle(t, dir, "aaa/first.yml", strings.Replace(minimalBundle, "id: b1", "id: b1", 1))
	writeBundle(t, dir, "mmm/second.yaml", strings.Replace(minimalBundle, "id: b1", "id: b2", 1))
	writeBundle(t, dir, "notes.md", "not a bundle")

	load := func() []string {
		bs, err := LoadBundleDir(dir)
		if err != nil {
			t.Fatalf("LoadBundleDir: %v", err)
		}
		ids := make([]string, 0, len(bs))
		for _, b := range bs {
			ids = append(ids, b.ID)
		}
		return ids
	}

	first := load()
	want := []string{"b1", "b2", "b3"}
	if strings.Join(first, ",") != strings.Join(want, ",") {
		t.Fatalf("bundles must load in sorted path order: got %v want %v", first, want)
	}
	for i := 0; i < 5; i++ {
		if got := load(); strings.Join(got, ",") != strings.Join(first, ",") {
			t.Fatalf("load %d diverged: got %v want %v", i, got, first)
		}
	}
}

func TestLoadBundleDirEmptyOrMissingIsNotAnError(t *testing.T) {
	bs, err := LoadBundleDir(filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatalf("a missing bundle dir must not be an error: %v", err)
	}
	if len(bs) != 0 {
		t.Fatalf("expected no bundles, got %d", len(bs))
	}

	bs, err = LoadBundleDir(t.TempDir())
	if err != nil {
		t.Fatalf("an empty bundle dir must not be an error: %v", err)
	}
	if len(bs) != 0 {
		t.Fatalf("expected no bundles, got %d", len(bs))
	}

	bs, err = LoadBundleDir("")
	if err != nil || len(bs) != 0 {
		t.Fatalf("an unset bundle dir must not be an error: bundles=%d err=%v", len(bs), err)
	}
}

// TestLoadBundleDirIsFailClosed: a broken bundle must stop the load, not be
// skipped. A policy-engine that boots with half its rules is indistinguishable
// at runtime from one that decided to detect nothing.
func TestLoadBundleDirIsFailClosed(t *testing.T) {
	dir := t.TempDir()
	writeBundle(t, dir, "good.yaml", minimalBundle)
	writeBundle(t, dir, "bad.yaml", strings.Replace(minimalBundle, `obs.layer != ""`, `obs.layerr != ""`, 1))

	if _, err := LoadBundleDir(dir); err == nil {
		t.Fatal("a non-compiling rule must fail the directory load")
	} else if !strings.Contains(err.Error(), "bad.yaml") {
		t.Fatalf("the error must name the offending file, got: %v", err)
	}
}

func TestLoadBundleDirRejectsDuplicateIdentity(t *testing.T) {
	dir := t.TempDir()
	writeBundle(t, dir, "a.yaml", minimalBundle)
	writeBundle(t, dir, "b.yaml", minimalBundle)
	if _, err := LoadBundleDir(dir); err == nil {
		t.Fatal("two files declaring the same tenant/id/version must be rejected")
	}
}

func TestLoadBundleFileRejectsUnknownFields(t *testing.T) {
	dir := t.TempDir()
	p := writeBundle(t, dir, "typo.yaml", minimalBundle+"\nmodee: enforce\n")
	if _, err := LoadBundleFile(p); err == nil {
		t.Fatal("an unknown top-level field must be rejected: a typo'd `modee: enforce` would otherwise leave the bundle silently in shadow")
	}
}

func TestValidateBundleHeader(t *testing.T) {
	base := func() *Bundle {
		return &Bundle{
			ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
			Rules: []Rule{{ID: "r", Severity: "low", Expression: `true`}},
		}
	}
	if errs := ValidateBundle(base()); len(errs) != 0 {
		t.Fatalf("baseline bundle must validate, got %v", JoinRuleErrors(errs))
	}

	cases := []struct {
		name   string
		mutate func(*Bundle)
		field  string
	}{
		{"missing id", func(b *Bundle) { b.ID = "" }, "id"},
		{"missing tenant_id", func(b *Bundle) { b.TenantID = "  " }, "tenant_id"},
		{"two-component version", func(b *Bundle) { b.Version = "1.0" }, "version"},
		{"v-prefixed version", func(b *Bundle) { b.Version = "v1.0.0" }, "version"},
		{"non-numeric version", func(b *Bundle) { b.Version = "latest" }, "version"},
		{"unknown mode", func(b *Bundle) { b.Mode = Mode("audit") }, "mode"},
		{"empty mode", func(b *Bundle) { b.Mode = Mode("") }, "mode"},
		{"no rules", func(b *Bundle) { b.Rules = nil }, "rules"},
		{"empty vars list", func(b *Bundle) { b.Vars = map[string][]string{"x": {}} }, "vars"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b := base()
			tc.mutate(b)
			errs := ValidateBundle(b)
			if len(errs) == 0 {
				t.Fatalf("%s must be rejected", tc.name)
			}
			for _, e := range errs {
				if e.Field == tc.field {
					return
				}
			}
			t.Fatalf("expected a defect on field %q, got %v", tc.field, errs)
		})
	}

	// A rule with no severity: a finding with no severity cannot be triaged.
	b := base()
	b.Rules[0].Severity = ""
	errs := ValidateBundle(b)
	if len(errs) == 0 || errs[0].RuleID != "r" || errs[0].Field != "severity" {
		t.Fatalf("a rule without severity must be rejected against its own id, got %v", errs)
	}

	// Valid semver variants must be accepted.
	for _, v := range []string{"0.0.1", "1.0.0-rc.1", "2.10.3+build.5", "10.20.30"} {
		b := base()
		b.Version = v
		if errs := ValidateBundle(b); len(errs) != 0 {
			t.Errorf("version %q must be accepted, got %v", v, JoinRuleErrors(errs))
		}
	}
}
