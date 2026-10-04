// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// repoBundlesDir is the shipped kusari bundle tree, reached from this package.
func repoBundlesDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "policy", "bundles"))
	if err != nil {
		t.Fatalf("resolving the bundle dir: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "kusari", "iam-change.yaml")); err != nil {
		t.Fatalf("shipped kusari bundle not found under %s: %v", dir, err)
	}
	return dir
}

// writeBundle renders a bundle into a temp dir so a test can replay with a
// bundle set it controls.
func writeBundle(t *testing.T, yaml string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "b.yaml"), []byte(yaml), 0o600); err != nil {
		t.Fatalf("writing bundle: %v", err)
	}
	return dir
}

// burstBundleYAML is the test bundle as a file: same rule and window as
// testBundle, so the replay test and the sink tests agree on semantics.
const burstBundleYAML = `
id: test-iam
tenant_id: kusari
version: 1.0.0
mode: warn
vars:
  break_glass_actors:
    - "arn:aws:iam::1:user/break-glass"
rules:
  - id: iam-priv-change
    name: IAM privilege change
    severity: high
    expression: |-
      obs.layer == "cloud_control_plane" &&
      has(obs.labels.event_name) &&
      obs.labels.event_name == "AttachUserPolicy" &&
      !(obs.actor in vars.break_glass_actors)
windows:
  - id: iam-change-burst
    over_rule: iam-priv-change
    key: [tenant_id, actor]
    window: 10m
    threshold: 3
    severity: high
`

// ---------------------------------------------------------------------------
// ISC-55: replay equals live, byte for byte
// ---------------------------------------------------------------------------

// liveRun ingests obs through a real policy sink into st, capturing the canonical
// projection of everything the pipeline produced.
func liveRun(t *testing.T, st store.SignalStore, bundles []*obscel.Bundle, obs []model.Observation) []string {
	t.Helper()
	rec := NewCanonicalRecorder()
	sink := NewSink(storeBackedSink{st}, st, newTestEvaluator(t), StaticBundles(bundles),
		Options{Windows: NewWindows(bundles), Observer: rec})

	SortObservations(obs)
	for i := range obs {
		if err := sink.IngestObservation(context.Background(), &obs[i]); err != nil {
			t.Fatalf("live IngestObservation(%s): %v", obs[i].ID, err)
		}
	}
	return rec.Lines()
}

func TestReplay_EqualsLiveOnTheAWSFixtureCorpus(t *testing.T) {
	bundlesDir := repoBundlesDir(t)
	log := testLogger(t)
	bundles, err := LoadBundles(bundlesDir, log)
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	if len(bundles) == 0 {
		t.Fatal("the shipped bundle tree loaded zero bundles")
	}

	obs, err := awslogs.FixtureObservations("kusari", "us-east-1")
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the awslogs fixture corpus is empty")
	}

	st := store.NewMemoryStore()
	liveLines := liveRun(t, st, bundles, obs)
	if len(liveLines) == 0 {
		t.Fatal("the live run over the fixture corpus produced no findings; the comparison would be vacuous")
	}

	var replayed bytes.Buffer
	nf, nd, err := Replay(context.Background(), st, ReplayOptions{
		BundlesDir: bundlesDir,
		From:       time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		To:         time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC),
		Out:        &replayed,
		Log:        log,
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}

	wantOut := strings.Join(liveLines, "\n") + "\n"
	if got := replayed.String(); got != wantOut {
		t.Errorf("replay output is not byte-identical to live.\n--- live (%d lines) ---\n%s\n--- replay (%d findings, %d decisions) ---\n%s",
			len(liveLines), wantOut, nf, nd, got)
	}
	if nf+nd != len(liveLines) {
		t.Errorf("replay reported %d findings + %d decisions = %d, want %d lines", nf, nd, nf+nd, len(liveLines))
	}
}

// Replay must reproduce DECISIONS too, not just findings, so the corpus is one
// that crosses a threshold.
func TestReplay_EqualsLiveIncludingDecisions(t *testing.T) {
	bundlesDir := writeBundle(t, burstBundleYAML)
	bundles, err := LoadBundles(bundlesDir, testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}

	var obs []model.Observation
	for i := range 4 {
		o := iamObs(timeID(i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		obs = append(obs, *o)
	}

	st := store.NewMemoryStore()
	liveLines := liveRun(t, st, bundles, obs)

	var replayed bytes.Buffer
	nf, nd, err := Replay(context.Background(), st, ReplayOptions{
		BundlesDir: bundlesDir,
		From:       baseTime.Add(-time.Hour),
		To:         baseTime.Add(time.Hour),
		Out:        &replayed,
		Log:        testLogger(t),
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if nf != 4 {
		t.Errorf("replay findings = %d, want 4", nf)
	}
	if nd != 1 {
		t.Errorf("replay decisions = %d, want 1 (the replay lost stage 2)", nd)
	}
	if got, want := replayed.String(), strings.Join(liveLines, "\n")+"\n"; got != want {
		t.Errorf("replay != live\n--- live ---\n%s\n--- replay ---\n%s", want, got)
	}
}

func timeID(i int) string {
	return "obs-" + string(rune('a'+i))
}

// Replay must not consume its own previous output: findings and decisions
// already in the store are input it skips.
func TestReplay_SkipsStoredFindingsAndDecisionsAsInput(t *testing.T) {
	bundlesDir := writeBundle(t, burstBundleYAML)
	bundles, err := LoadBundles(bundlesDir, testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}

	st := store.NewMemoryStore()
	var obs []model.Observation
	for i := range 4 {
		o := iamObs(timeID(i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		obs = append(obs, *o)
	}
	_ = liveRun(t, st, bundles, obs) // the store now holds findings and a decision

	opts := ReplayOptions{
		BundlesDir: bundlesDir,
		From:       baseTime.Add(-time.Hour),
		To:         baseTime.Add(time.Hour),
		Log:        testLogger(t),
	}

	var first, second bytes.Buffer
	opts.Out = &first
	if _, _, err := Replay(context.Background(), st, opts); err != nil {
		t.Fatalf("first Replay: %v", err)
	}
	opts.Out = &second
	if _, _, err := Replay(context.Background(), st, opts); err != nil {
		t.Fatalf("second Replay: %v", err)
	}
	if first.String() != second.String() {
		t.Error("two replays over the same store disagree; replay is consuming or writing its own output")
	}
}

// Replay with an empty bundle dir is an empty answer, not an error. The e2e
// mutation gate depends on the empty result being visible.
func TestReplay_EmptyBundleDirProducesNoOutput(t *testing.T) {
	st := store.NewMemoryStore()
	obs, err := awslogs.FixtureObservations("kusari", "us-east-1")
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	if err := st.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append: %v", err)
	}

	var out bytes.Buffer
	nf, nd, err := Replay(context.Background(), st, ReplayOptions{
		BundlesDir: t.TempDir(),
		From:       baseTime.Add(-24 * time.Hour),
		To:         baseTime.Add(24 * time.Hour),
		Out:        &out,
		Log:        testLogger(t),
	})
	if err != nil {
		t.Fatalf("an empty bundle dir must not be an error, got %v", err)
	}
	if nf != 0 || nd != 0 {
		t.Errorf("empty bundle dir produced %d findings and %d decisions, want 0 and 0", nf, nd)
	}
	if out.Len() != 0 {
		t.Errorf("empty bundle dir wrote %q, want nothing", out.String())
	}
}

// The tenant filter actually restricts the corpus.
func TestReplay_TenantFilter(t *testing.T) {
	bundlesDir := writeBundle(t, burstBundleYAML)
	st := store.NewMemoryStore()

	var rows []model.Observation
	for i := range 3 {
		o := iamObs(timeID(i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		rows = append(rows, *o)
	}
	other := iamObs("obs-z", baseTime, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
	other.Labels[TenantLabel] = "someone-else"
	rows = append(rows, *other)
	if err := st.Append(context.Background(), rows); err != nil {
		t.Fatalf("Append: %v", err)
	}

	var out bytes.Buffer
	nf, _, err := Replay(context.Background(), st, ReplayOptions{
		BundlesDir: bundlesDir,
		Tenant:     "kusari",
		From:       baseTime.Add(-time.Hour),
		To:         baseTime.Add(time.Hour),
		Out:        &out,
		Log:        testLogger(t),
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if nf != 3 {
		t.Errorf("--tenant kusari produced %d findings, want 3 (the other tenant's row leaked in)", nf)
	}
}

// ---------------------------------------------------------------------------
// Bundle loading (ISC-51)
// ---------------------------------------------------------------------------

func TestLoadBundles_MissingDirIsZeroBundlesNotAnError(t *testing.T) {
	bundles, err := LoadBundles(filepath.Join(t.TempDir(), "nope"), testLogger(t))
	if err != nil {
		t.Fatalf("a missing bundle dir must not refuse to boot, got %v", err)
	}
	if len(bundles) != 0 {
		t.Errorf("want 0 bundles, got %d", len(bundles))
	}
}

func TestLoadBundles_BrokenBundleIsAnError(t *testing.T) {
	// A bundle whose expression does not compile is a broken deployment, not an
	// empty one: a half-loaded policy set looks exactly like a policy set that
	// chose not to detect anything.
	dir := writeBundle(t, `
id: broken
tenant_id: kusari
version: 1.0.0
mode: shadow
rules:
  - id: nope
    name: nope
    severity: high
    expression: 'obs.evemt_name == "x"'
`)
	if _, err := LoadBundles(dir, testLogger(t)); err == nil {
		t.Fatal("a non-conformant bundle must refuse to load")
	}
}

func TestLoadBundles_LoadsTheShippedKusariBundle(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	var found *obscel.Bundle
	for _, b := range bundles {
		if b.ID == "kusari-iam-change" {
			found = b
		}
	}
	if found == nil {
		t.Fatal("the shipped kusari-iam-change bundle did not load")
	}
	if found.Mode != obscel.ModeShadow {
		t.Errorf("shipped bundle mode = %q, want shadow (promotion is a reviewed commit)", found.Mode)
	}
	if len(found.Windows) == 0 {
		t.Error("the shipped bundle declares no stage-2 window")
	}
}

func TestBundlesDirFromEnv(t *testing.T) {
	t.Setenv(BundlesDirEnv, "")
	if got := BundlesDirFromEnv(); got != DefaultBundlesDir {
		t.Errorf("unset %s = %q, want the ConfigMap mount %q", BundlesDirEnv, got, DefaultBundlesDir)
	}
	t.Setenv(BundlesDirEnv, "/tmp/bundles")
	if got := BundlesDirFromEnv(); got != "/tmp/bundles" {
		t.Errorf("%s = %q, want /tmp/bundles", BundlesDirEnv, got)
	}
}

// ---------------------------------------------------------------------------
// CLI argument handling
// ---------------------------------------------------------------------------

func TestIsReplayInvocation(t *testing.T) {
	for _, tc := range []struct {
		argv []string
		want bool
	}{
		{[]string{"signal-ingest"}, false},
		{[]string{"signal-ingest", "replay"}, true},
		{[]string{"signal-ingest", "replay", "--out", "/tmp/x"}, true},
		{[]string{"signal-ingest", "serve"}, false},
	} {
		if got := IsReplayInvocation(tc.argv); got != tc.want {
			t.Errorf("IsReplayInvocation(%v) = %v, want %v", tc.argv, got, tc.want)
		}
	}
}

func TestRunReplayCommand_WritesTheOutFile(t *testing.T) {
	bundlesDir := writeBundle(t, burstBundleYAML)
	st := store.NewMemoryStore()
	var rows []model.Observation
	for i := range 3 {
		o := iamObs(timeID(i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		rows = append(rows, *o)
	}
	if err := st.Append(context.Background(), rows); err != nil {
		t.Fatalf("Append: %v", err)
	}

	out := filepath.Join(t.TempDir(), "replay.txt")
	code := RunReplayCommand(context.Background(), []string{
		"signal-ingest", "replay",
		"--bundles", bundlesDir,
		"--from", "2026-10-02T08:00:00Z",
		"--to", "2026-10-02T10:00:00Z",
		"--tenant", "kusari",
		"--out", out,
	}, func() (store.SignalStore, error) { return st, nil })
	if code != 0 {
		t.Fatalf("RunReplayCommand exit code = %d, want 0", code)
	}

	body, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("reading %s: %v", out, err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) != 4 {
		t.Errorf("replay file has %d lines, want 4 (3 findings + 1 decision):\n%s", len(lines), body)
	}
}

// Replay must impose arrival order itself, because the store does not promise
// one. A corpus stored in reverse-timestamp order must still reproduce the live
// run that saw it in timestamp order.
//
// This is what makes SortObservations load-bearing rather than decorative: with
// the sort removed, the sliding window sees the newest finding first, prunes
// every older entry against that newest timestamp, and never reaches the
// threshold.
func TestReplay_ImposesArrivalOrderOnAnUnorderedStore(t *testing.T) {
	bundlesDir := writeBundle(t, burstBundleYAML)
	bundles, err := LoadBundles(bundlesDir, testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}

	// Live sees them oldest-first.
	var ordered []model.Observation
	for i := range 3 {
		o := iamObs(timeID(i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		ordered = append(ordered, *o)
	}
	liveLines := liveRun(t, store.NewMemoryStore(), bundles, ordered)

	// The store holds them newest-first.
	reversed := store.NewMemoryStore()
	for i := len(ordered) - 1; i >= 0; i-- {
		if err := reversed.Append(context.Background(), []model.Observation{ordered[i]}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}

	var out bytes.Buffer
	nf, nd, err := Replay(context.Background(), reversed, ReplayOptions{
		BundlesDir: bundlesDir,
		From:       baseTime.Add(-time.Hour),
		To:         baseTime.Add(time.Hour),
		Out:        &out,
		Log:        testLogger(t),
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if nf != 3 || nd != 1 {
		t.Errorf("replay over a reverse-ordered store produced %d findings and %d decisions, want 3 and 1", nf, nd)
	}
	if got, want := out.String(), strings.Join(liveLines, "\n")+"\n"; got != want {
		t.Errorf("replay over an unordered store != live\n--- live ---\n%s\n--- replay ---\n%s", want, got)
	}
}

func TestRunReplayCommand_RejectsBadArguments(t *testing.T) {
	open := func() (store.SignalStore, error) { return store.NewMemoryStore(), nil }
	for name, argv := range map[string][]string{
		"missing from/to":  {"signal-ingest", "replay", "--out", "/tmp/x"},
		"missing out":      {"signal-ingest", "replay", "--from", "2026-10-02T08:00:00Z", "--to", "2026-10-02T10:00:00Z"},
		"from after to":    {"signal-ingest", "replay", "--from", "2026-10-02T10:00:00Z", "--to", "2026-10-02T08:00:00Z", "--out", "/tmp/x"},
		"from not rfc3339": {"signal-ingest", "replay", "--from", "yesterday", "--to", "2026-10-02T10:00:00Z", "--out", "/tmp/x"},
	} {
		if code := RunReplayCommand(context.Background(), argv, open); code != 2 {
			t.Errorf("%s: exit code = %d, want 2", name, code)
		}
	}
}
