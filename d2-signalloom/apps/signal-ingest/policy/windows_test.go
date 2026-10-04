// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"fmt"
	"log/slog"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// recordingAlerter captures the decisions handed to it.
type recordingAlerter struct {
	got []obscel.Decision
	err error
}

func (r *recordingAlerter) Alert(_ context.Context, d obscel.Decision) error {
	r.got = append(r.got, d)
	return r.err
}

// runBurst feeds n qualifying observations one minute apart through a fresh sink.
func runBurst(t *testing.T, mode obscel.Mode, n int, windows *Windows, alerter Alerter) (*recordingSink, *Metrics) {
	t.Helper()
	inner := &recordingSink{}
	m := NewMetrics()
	b := testBundle(t, mode)
	if windows == nil {
		windows = NewWindows([]*obscel.Bundle{b})
	}
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b),
		Options{Windows: windows, Metrics: m, Alerter: alerter})

	for i := range n {
		at := baseTime.Add(time.Duration(i) * time.Minute)
		obs := iamObs(fmt.Sprintf("obs-%d", i), at, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}
	return inner, m
}

// ---------------------------------------------------------------------------
// ISC-48: a window fires at its declared threshold, not before
// ---------------------------------------------------------------------------

func TestWindows_FiresAtThreshold(t *testing.T) {
	for _, tc := range []struct {
		events        int
		wantDecisions int
	}{
		{events: 1, wantDecisions: 0},
		{events: 2, wantDecisions: 0},
		{events: 3, wantDecisions: 1},
	} {
		t.Run(fmt.Sprintf("%d_events", tc.events), func(t *testing.T) {
			inner, _ := runBurst(t, obscel.ModeWarn, tc.events, nil, nil)
			if n := len(inner.bySource(obscel.SourceDecision)); n != tc.wantDecisions {
				t.Errorf("%d events in-window produced %d decisions, want %d",
					tc.events, n, tc.wantDecisions)
			}
		})
	}
}

// The window is edge-triggered: a fourth event inside the window does not
// produce a second alert for the same unbroken burst.
func TestWindows_DoesNotReFireWhileAboveThreshold(t *testing.T) {
	inner, _ := runBurst(t, obscel.ModeWarn, 5, nil, nil)
	if n := len(inner.bySource(obscel.SourceDecision)); n != 1 {
		t.Errorf("5 events in one unbroken burst produced %d decisions, want 1", n)
	}
}

// ISC-49: the sliding window actually slides. Three events spread over more than
// the declared window never co-occur, so nothing fires.
func TestWindows_SlidesSoSpreadEventsNeverFire(t *testing.T) {
	inner := &recordingSink{}
	b := testBundle(t, obscel.ModeWarn) // window 10m, threshold 3
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b),
		Options{Windows: NewWindows([]*obscel.Bundle{b})})

	for i := range 3 {
		at := baseTime.Add(time.Duration(i) * 11 * time.Minute)
		obs := iamObs(fmt.Sprintf("obs-%d", i), at, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}
	if n := len(inner.bySource(obscel.SourceDecision)); n != 0 {
		t.Errorf("3 events 11 minutes apart produced %d decisions, want 0 (the window is not sliding)", n)
	}
}

// The key separates actors: two actors with two events each is not one burst.
func TestWindows_KeySeparatesActors(t *testing.T) {
	inner := &recordingSink{}
	b := testBundle(t, obscel.ModeWarn)
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b),
		Options{Windows: NewWindows([]*obscel.Bundle{b})})

	actors := []string{"arn:a", "arn:b"}
	for i := range 4 {
		obs := iamObs(fmt.Sprintf("obs-%d", i), baseTime.Add(time.Duration(i)*time.Minute),
			actors[i%2], "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}
	if n := len(inner.bySource(obscel.SourceDecision)); n != 0 {
		t.Errorf("2 events each for 2 actors produced %d decisions, want 0", n)
	}
}

// ISC-52: the decision observation's shape and derived identity.
func TestWindows_DecisionObservationShape(t *testing.T) {
	inner, _ := runBurst(t, obscel.ModeWarn, 3, nil, nil)
	decisions := inner.bySource(obscel.SourceDecision)
	if len(decisions) != 1 {
		t.Fatalf("want 1 decision, got %d", len(decisions))
	}
	d := decisions[0]

	// The triggering finding is the third observation, at baseTime+2m.
	wantAt := baseTime.Add(2 * time.Minute)
	if !d.Timestamp.Equal(wantAt) {
		t.Errorf("decision timestamp = %v, want the triggering finding's %v (never time.Now)", d.Timestamp, wantAt)
	}

	findingIDs := sortedCopy([]string{
		obscel.FindingID(testTenant, "iam-priv-change", "1.0.0", "obs-0"),
		obscel.FindingID(testTenant, "iam-priv-change", "1.0.0", "obs-1"),
		obscel.FindingID(testTenant, "iam-priv-change", "1.0.0", "obs-2"),
	})
	wantKey := obscel.KeyTenantID + "=" + testTenant + "|" + obscel.KeyActor + "=arn:aws:iam::1:user/agent"
	wantID := obscel.DecisionID(testTenant, "iam-priv-change", wantKey, findingIDs)
	if d.ID != wantID {
		t.Errorf("decision ID = %q, want the derived %q", d.ID, wantID)
	}

	wantLabels := map[string]string{
		LabelWindowID:      "iam-change-burst",
		LabelRuleID:        "iam-priv-change",
		LabelBundleID:      "test-iam",
		LabelBundleVersion: "1.0.0",
		LabelSeverity:      "high",
		LabelMode:          string(obscel.ModeWarn),
		LabelCount:         "3",
		TenantLabel:        testTenant,
		LabelFindingIDs:    joinIDs(findingIDs),
	}
	if len(d.Labels) != len(wantLabels) {
		t.Errorf("decision carries %d labels (%v), want exactly %d",
			len(d.Labels), obscel.SortedLabelKeys(d.Labels), len(wantLabels))
	}
	for k, want := range wantLabels {
		if got := d.Labels[k]; got != want {
			t.Errorf("decision label %q = %q, want %q", k, got, want)
		}
	}
	if err := d.Validate(); err != nil {
		t.Errorf("decision observation does not validate: %v", err)
	}
}

func joinIDs(ids []string) string {
	out := ""
	for i, id := range ids {
		if i > 0 {
			out += ","
		}
		out += id
	}
	return out
}

// ---------------------------------------------------------------------------
// Mode: shadow stores and does not alert; warn and enforce store and alert.
// Nothing in the customer account is touched in any mode (D5).
// ---------------------------------------------------------------------------

func TestWindows_ModeGovernsAlertingOnly(t *testing.T) {
	for _, tc := range []struct {
		mode      obscel.Mode
		wantAlert int
	}{
		{obscel.ModeShadow, 0},
		{obscel.ModeWarn, 1},
		{obscel.ModeEnforce, 1},
	} {
		t.Run(string(tc.mode), func(t *testing.T) {
			alerter := &recordingAlerter{}
			inner, m := runBurst(t, tc.mode, 3, nil, alerter)

			decisions := inner.bySource(obscel.SourceDecision)
			if len(decisions) != 1 {
				t.Fatalf("mode %s stored %d decisions, want 1 in every mode", tc.mode, len(decisions))
			}
			if got := decisions[0].Labels[LabelMode]; got != string(tc.mode) {
				t.Errorf("stored decision mode label = %q, want %q", got, string(tc.mode))
			}
			if len(alerter.got) != tc.wantAlert {
				t.Errorf("mode %s alerted %d times, want %d", tc.mode, len(alerter.got), tc.wantAlert)
			}
			if n := m.Snapshot().DecisionsByMode[string(tc.mode)]; n != 1 {
				t.Errorf("decisions_total{mode=%q} = %d, want 1", tc.mode, n)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// ISC-50: boot warm-up rebuilds the counters from the store
// ---------------------------------------------------------------------------

// A restart mid-burst must land on the same decision as an uninterrupted run.
func TestWindows_WarmupReproducesUninterruptedDecisionID(t *testing.T) {
	// Uninterrupted: three events through one sink.
	uninterrupted, _ := runBurst(t, obscel.ModeWarn, 3, nil, nil)
	want := uninterrupted.bySource(obscel.SourceDecision)
	if len(want) != 1 {
		t.Fatalf("uninterrupted run produced %d decisions, want 1", len(want))
	}

	// Restarted: two events, then a new Windows warmed from the store, then the third.
	st := store.NewMemoryStore()
	b := testBundle(t, obscel.ModeWarn)
	eval := newTestEvaluator(t)

	first := NewSink(storeBackedSink{st}, st, eval, bundlesFor(b),
		Options{Windows: NewWindows([]*obscel.Bundle{b})})
	for i := range 2 {
		obs := iamObs(fmt.Sprintf("obs-%d", i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := first.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("pre-restart IngestObservation(%d): %v", i, err)
		}
	}
	if n := countSource(t, st, obscel.SourceFinding); n != 2 {
		t.Fatalf("want 2 findings stored before the restart, got %d", n)
	}
	if n := countSource(t, st, obscel.SourceDecision); n != 0 {
		t.Fatalf("want 0 decisions before the restart, got %d", n)
	}

	// --- process restart ---
	warmed := NewWindows([]*obscel.Bundle{b})
	// `now` is the third event's timestamp: at boot the horizon is taken from the
	// clock, and the test pins it rather than reading one.
	third := baseTime.Add(2 * time.Minute)
	if err := warmed.Warm(context.Background(), st, third); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if n := warmed.WarmedCount(); n != 2 {
		t.Fatalf("warm-up rebuilt %d entries, want 2", n)
	}

	after := &recordingSink{}
	second := NewSink(after, st, eval, bundlesFor(b), Options{Windows: warmed})
	if err := second.IngestObservation(context.Background(),
		iamObs("obs-2", third, "arn:aws:iam::1:user/agent", "AttachUserPolicy")); err != nil {
		t.Fatalf("post-restart IngestObservation: %v", err)
	}

	got := after.bySource(obscel.SourceDecision)
	if len(got) != 1 {
		t.Fatalf("post-restart run produced %d decisions, want 1 (warm-up lost the counter)", len(got))
	}
	if got[0].ID != want[0].ID {
		t.Errorf("decision ID after restart = %q, want the uninterrupted %q", got[0].ID, want[0].ID)
	}
	if !got[0].Timestamp.Equal(want[0].Timestamp) {
		t.Errorf("decision timestamp after restart = %v, want %v", got[0].Timestamp, want[0].Timestamp)
	}
}

// Warm-up must not re-alert a decision the previous process already alerted.
func TestWindows_WarmupDoesNotEmitForAnAlreadyBreachedWindow(t *testing.T) {
	st := store.NewMemoryStore()
	b := testBundle(t, obscel.ModeWarn)
	alerter := &recordingAlerter{}
	eval := newTestEvaluator(t)

	first := NewSink(storeBackedSink{st}, st, eval, bundlesFor(b),
		Options{Windows: NewWindows([]*obscel.Bundle{b}), Alerter: alerter})
	for i := range 3 {
		obs := iamObs(fmt.Sprintf("obs-%d", i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := first.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}
	if len(alerter.got) != 1 {
		t.Fatalf("pre-restart alerts = %d, want 1", len(alerter.got))
	}

	// Restart over an already-breached window.
	warmed := NewWindows([]*obscel.Bundle{b})
	if err := warmed.Warm(context.Background(), st, baseTime.Add(2*time.Minute)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	after := &recordingAlerter{}
	second := NewSink(&recordingSink{}, st, eval, bundlesFor(b),
		Options{Windows: warmed, Alerter: after})
	// A fourth event, still inside the window. The latch is already set.
	if err := second.IngestObservation(context.Background(),
		iamObs("obs-3", baseTime.Add(3*time.Minute), "arn:aws:iam::1:user/agent", "AttachUserPolicy")); err != nil {
		t.Fatalf("post-restart IngestObservation: %v", err)
	}
	if len(after.got) != 0 {
		t.Errorf("warm-up re-armed an already-breached window and re-alerted %d times, want 0", len(after.got))
	}
}

// The warm-up horizon is the longest declared window, not a guess.
func TestWindows_LongestWindow(t *testing.T) {
	b := testBundle(t, obscel.ModeWarn)
	b2 := testBundle(t, obscel.ModeWarn)
	b2.ID = "other"
	b2.Windows[0].Window = 45 * time.Minute
	ws := NewWindows([]*obscel.Bundle{b, b2})
	if got := ws.LongestWindow(); got != 45*time.Minute {
		t.Errorf("LongestWindow = %v, want 45m", got)
	}
	if got := ws.Len(); got != 2 {
		t.Errorf("Len = %d, want 2", got)
	}
}

// Warm-up ignores findings from a bundle version that is no longer loaded:
// counting them would attribute old evidence to a new policy.
func TestWindows_WarmupIgnoresUnloadedBundleVersions(t *testing.T) {
	st := store.NewMemoryStore()
	b := testBundle(t, obscel.ModeWarn)

	stale := findingObservation(obscel.Finding{
		ID:            "stale-1",
		Timestamp:     baseTime,
		TenantID:      testTenant,
		Actor:         "arn:aws:iam::1:user/agent",
		RuleID:        "iam-priv-change",
		BundleID:      "test-iam",
		BundleVersion: "0.9.0", // not the loaded 1.0.0
		Severity:      "high",
		SourceObsID:   "obs-stale",
	}, iamObs("obs-stale", baseTime, "arn:aws:iam::1:user/agent", "AttachUserPolicy"), obscel.ModeWarn)
	if err := st.Append(context.Background(), []model.Observation{stale}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	ws := NewWindows([]*obscel.Bundle{b})
	if err := ws.Warm(context.Background(), st, baseTime); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if n := ws.WarmedCount(); n != 0 {
		t.Errorf("warm-up folded in %d findings from an unloaded bundle version, want 0", n)
	}
}

// Replaying the same finding twice must not count it twice.
func TestWindows_OfferIsIdempotentOnFindingID(t *testing.T) {
	b := testBundle(t, obscel.ModeWarn)
	ws := NewWindows([]*obscel.Bundle{b})
	f := obscel.Finding{
		ID: "f-1", Timestamp: baseTime, TenantID: testTenant,
		Actor: "a", RuleID: "iam-priv-change", BundleID: "test-iam",
		BundleVersion: "1.0.0", Severity: "high",
	}
	for range 5 {
		if d := ws.Offer(f, b); len(d) != 0 {
			t.Fatalf("the same finding offered repeatedly fired %d decisions, want 0", len(d))
		}
	}
	if n := ws.WarmedCount(); n != 1 {
		t.Errorf("the same finding counted %d times, want 1", n)
	}
}

// A nil Windows is a valid stage-2: stage 1 still emits findings.
func TestWindows_NilIsStageOneOnly(t *testing.T) {
	inner, _ := runBurst(t, obscel.ModeWarn, 3, nil, nil)
	_ = inner
	inner2 := &recordingSink{}
	b := testBundle(t, obscel.ModeWarn)
	sink := NewSink(inner2, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{})
	for i := range 3 {
		obs := iamObs(fmt.Sprintf("obs-%d", i), baseTime.Add(time.Duration(i)*time.Minute),
			"arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation: %v", err)
		}
	}
	if n := len(inner2.bySource(obscel.SourceFinding)); n != 3 {
		t.Errorf("stage 1 without stage 2 produced %d findings, want 3", n)
	}
	if n := len(inner2.bySource(obscel.SourceDecision)); n != 0 {
		t.Errorf("no Windows must mean no decisions, got %d", n)
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// storeBackedSink is an IngestionSink that writes straight to a SignalStore,
// equivalent to collectors.StoreSink but without importing the collectors
// package's constructor into a window test.
type storeBackedSink struct{ st store.SignalStore }

func (s storeBackedSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	if obs == nil {
		return nil
	}
	return s.st.Append(ctx, []model.Observation{*obs})
}

func countSource(t *testing.T, st store.SignalStore, source string) int {
	t.Helper()
	rows, err := st.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	n := 0
	for _, r := range rows {
		if r.Source == source {
			n++
		}
	}
	return n
}

// testLogger routes package logs into the test's output so a warm-up or load
// warning is attributable to the test that provoked it.
func testLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.NewTextHandler(testWriter{t}, &slog.HandlerOptions{Level: slog.LevelWarn}))
}

type testWriter struct{ t *testing.T }

func (w testWriter) Write(p []byte) (int, error) {
	w.t.Logf("%s", p)
	return len(p), nil
}
