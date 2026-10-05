// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

// recordingSink captures every observation handed to it, in arrival order.
type recordingSink struct {
	mu   sync.Mutex
	obs  []model.Observation
	fail error
}

func (r *recordingSink) IngestObservation(_ context.Context, obs *model.Observation) error {
	if r.fail != nil {
		return r.fail
	}
	if obs == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.obs = append(r.obs, *obs)
	return nil
}

func (r *recordingSink) bySource(source string) []model.Observation {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []model.Observation
	for _, o := range r.obs {
		if o.Source == source {
			out = append(out, o)
		}
	}
	return out
}

// spyStore is a SignalStore that permits QueryRange until WarmupDone is
// signalled and fails hard afterwards.
//
// This is the whole of the evidence for "store first, decide second, and never
// read back on the hot path" (ISC-57). The hot path reading the store would be
// invisible in a functional assertion — findings would still be correct — so
// the only way to pin it is to make the read itself a test failure.
type spyStore struct {
	inner      store.SignalStore
	t          *testing.T
	mu         sync.Mutex
	warm       bool
	queryCalls int
}

func newSpyStore(t *testing.T) *spyStore {
	return &spyStore{inner: store.NewMemoryStore(), t: t}
}

// WarmupDone closes the QueryRange window. Every later read is a defect.
func (s *spyStore) WarmupDone() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.warm = true
}

func (s *spyStore) Append(ctx context.Context, obs []model.Observation) error {
	return s.inner.Append(ctx, obs)
}

func (s *spyStore) QueryRange(ctx context.Context, q store.Query) ([]model.Observation, error) {
	s.mu.Lock()
	warm := s.warm
	s.queryCalls++
	s.mu.Unlock()
	if warm {
		s.t.Errorf("QueryRange called on the hot path after warm-up: stage 1 must never read the store")
		return nil, errors.New("spyStore: QueryRange is forbidden after warm-up")
	}
	return s.inner.QueryRange(ctx, q)
}

func (s *spyStore) DropPartition(ctx context.Context, before time.Time) error {
	return s.inner.DropPartition(ctx, before)
}

func (s *spyStore) Close() error { return s.inner.Close() }

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const testTenant = "kusari"

func testBundle(t *testing.T, mode obscel.Mode) *obscel.Bundle {
	t.Helper()
	b := &obscel.Bundle{
		ID:       "test-iam",
		TenantID: testTenant,
		Version:  "1.0.0",
		Mode:     mode,
		// Declared, because the rule below compares obs.actor against it and
		// Conform refuses an actor comparison against an undeclared list. These
		// tests run with a nil pseudonymiser, so the list stays cleartext and
		// matches the cleartext actor the sink passes through — consistent on
		// both sides, which is the property that matters.
		ActorVars: []string{"break_glass_actors"},
		Vars: map[string][]string{
			"break_glass_actors": {"arn:aws:iam::1:user/break-glass"},
		},
		Rules: []obscel.Rule{{
			ID:       "iam-priv-change",
			Name:     "IAM privilege change",
			Severity: "high",
			Expression: `obs.layer == "cloud_control_plane" && ` +
				`has(obs.labels.event_name) && ` +
				`obs.labels.event_name == "AttachUserPolicy" && ` +
				`!(obs.actor in vars.break_glass_actors)`,
		}},
		Windows: []obscel.Window{{
			ID:        "iam-change-burst",
			OverRule:  "iam-priv-change",
			Key:       []string{obscel.KeyTenantID, obscel.KeyActor},
			Window:    10 * time.Minute,
			Threshold: 3,
			Severity:  "high",
		}},
	}
	if errs := obscel.Conform(b); len(errs) > 0 {
		t.Fatalf("test bundle is not conformant: %v", obscel.JoinRuleErrors(errs))
	}
	return b
}

func bundlesFor(b ...*obscel.Bundle) func(string) []*obscel.Bundle {
	return func(tenant string) []*obscel.Bundle {
		var out []*obscel.Bundle
		for _, x := range b {
			if x.TenantID == tenant {
				out = append(out, x)
			}
		}
		return out
	}
}

var baseTime = time.Date(2026, 10, 2, 9, 0, 0, 0, time.UTC)

func iamObs(id string, at time.Time, actor, eventName string) *model.Observation {
	return &model.Observation{
		ID:             id,
		Timestamp:      at,
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityStrong,
		Source:         "aws:iam",
		Confidence:     0.9,
		ActorHint:      actor,
		RawEvidenceRef: "testdata/iam.json#0",
		Description:    "iam event",
		Labels: map[string]string{
			"tenant_id":  testTenant,
			"event_name": eventName,
			"provider":   "aws",
		},
	}
}

func newTestEvaluator(t *testing.T) obscel.Evaluator {
	t.Helper()
	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}
	return ev
}

// ---------------------------------------------------------------------------
// ISC-46: stage 1 runs at the sink, store first, decide second
// ---------------------------------------------------------------------------

func TestSink_ForwardsToInnerBeforeEvaluating(t *testing.T) {
	inner := &recordingSink{}
	b := testBundle(t, obscel.ModeShadow)
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{})

	src := iamObs("obs-1", baseTime, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
	if err := sink.IngestObservation(context.Background(), src); err != nil {
		t.Fatalf("IngestObservation: %v", err)
	}

	inner.mu.Lock()
	got := append([]model.Observation(nil), inner.obs...)
	inner.mu.Unlock()

	if len(got) != 2 {
		t.Fatalf("want the source observation then its finding, got %d observations", len(got))
	}
	if got[0].ID != "obs-1" {
		t.Errorf("source observation must reach the inner sink FIRST; got %q", got[0].ID)
	}
	if got[1].Source != obscel.SourceFinding {
		t.Errorf("second observation source = %q, want %q", got[1].Source, obscel.SourceFinding)
	}
}

func TestSink_SourceAppendErrorPropagatesAndSuppressesEvaluation(t *testing.T) {
	boom := errors.New("store is down")
	inner := &recordingSink{fail: boom}
	b := testBundle(t, obscel.ModeShadow)
	m := NewMetrics()
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{Metrics: m})

	err := sink.IngestObservation(context.Background(), iamObs("obs-1", baseTime, "a", "AttachUserPolicy"))
	if !errors.Is(err, boom) {
		t.Fatalf("want the inner sink error returned verbatim, got %v", err)
	}
	if n := m.Snapshot().Findings; n != 0 {
		t.Errorf("a failed source write must not produce findings, got %d", n)
	}
}

func TestSink_FindingObservationShape(t *testing.T) {
	inner := &recordingSink{}
	b := testBundle(t, obscel.ModeWarn)
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{})

	actor := "arn:aws:iam::1:user/agent"
	src := iamObs("obs-1", baseTime, actor, "AttachUserPolicy")
	if err := sink.IngestObservation(context.Background(), src); err != nil {
		t.Fatalf("IngestObservation: %v", err)
	}

	findings := inner.bySource(obscel.SourceFinding)
	if len(findings) != 1 {
		t.Fatalf("want 1 finding, got %d", len(findings))
	}
	f := findings[0]

	wantID := obscel.FindingID(testTenant, "iam-priv-change", "1.0.0", "obs-1")
	if f.ID != wantID {
		t.Errorf("finding ID = %q, want the derived %q", f.ID, wantID)
	}
	if !f.Timestamp.Equal(baseTime) {
		t.Errorf("finding timestamp = %v, want the source observation's %v (never time.Now)", f.Timestamp, baseTime)
	}
	if f.Layer != model.LayerCloudControlPlane {
		t.Errorf("finding layer = %q, want the source observation's layer", f.Layer)
	}
	if f.ActorHint != actor {
		t.Errorf("finding actor_hint = %q, want %q", f.ActorHint, actor)
	}
	if f.RawEvidenceRef != "obs-1" {
		t.Errorf("finding raw_evidence_ref = %q, want the source observation ID", f.RawEvidenceRef)
	}

	wantLabels := map[string]string{
		"rule_id":               "iam-priv-change",
		"bundle_id":             "test-iam",
		"bundle_version":        "1.0.0",
		"severity":              "high",
		"tenant_id":             testTenant,
		"source_observation_id": "obs-1",
		"mode":                  string(obscel.ModeWarn),
		// The pseudonymous actor. This sink has no pseudonymiser configured, so
		// ActorIdentity passes the cleartext hint through -- the documented
		// development fallback, loudly warned about at NewSink. On any path with
		// a pseudonymiser this is a 64-hex digest; either way the label is
		// present, and its presence is what lets warm-up rebuild an actor-keyed
		// window over a v2 segment that carries no cleartext actor column.
		"actor_pseudonym": "arn:aws:iam::1:user/agent",
	}
	if len(f.Labels) != len(wantLabels) {
		t.Errorf("finding carries %d labels (%v), want exactly %d (%v)",
			len(f.Labels), obscel.SortedLabelKeys(f.Labels), len(wantLabels), obscel.SortedLabelKeys(wantLabels))
	}
	for k, want := range wantLabels {
		if got := f.Labels[k]; got != want {
			t.Errorf("finding label %q = %q, want %q", k, got, want)
		}
	}
	// The source observation's own labels must NOT leak into the finding.
	if _, leaked := f.Labels["event_name"]; leaked {
		t.Error("finding labels must carry the policy label set only; event_name leaked from the source observation")
	}
	if err := f.Validate(); err != nil {
		t.Errorf("finding observation does not validate: %v", err)
	}
}

// ISC-47: findings never re-enter stage 1.
func TestSink_FindingsAndDecisionsDoNotReEnterStageOne(t *testing.T) {
	inner := &recordingSink{}
	// A bundle whose rule matches ANY observation: if the guard were missing this
	// would recurse without bound rather than merely double-count.
	b := &obscel.Bundle{
		ID: "match-all", TenantID: testTenant, Version: "1.0.0", Mode: obscel.ModeShadow,
		Rules: []obscel.Rule{{ID: "always", Name: "always", Severity: "low", Expression: "true"}},
	}
	if errs := obscel.Conform(b); len(errs) > 0 {
		t.Fatalf("bundle not conformant: %v", obscel.JoinRuleErrors(errs))
	}
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{})

	if err := sink.IngestObservation(context.Background(), iamObs("obs-1", baseTime, "a", "Whatever")); err != nil {
		t.Fatalf("IngestObservation: %v", err)
	}
	if n := len(inner.bySource(obscel.SourceFinding)); n != 1 {
		t.Fatalf("want exactly 1 finding from 1 observation, got %d (stage 1 re-entered its own output)", n)
	}

	// Feeding a finding straight back in must produce nothing at all.
	before := len(inner.bySource(obscel.SourceFinding))
	fin := inner.bySource(obscel.SourceFinding)[0]
	if err := sink.IngestObservation(context.Background(), &fin); err != nil {
		t.Fatalf("IngestObservation(finding): %v", err)
	}
	after := inner.bySource(obscel.SourceFinding)
	if len(after) != before+1 {
		t.Fatalf("re-ingesting a finding must store it and evaluate nothing; findings went %d -> %d", before, len(after))
	}
}

// ISC-57: the hot path never calls QueryRange.
func TestSink_HotPathNeverQueriesTheStore(t *testing.T) {
	inner := &recordingSink{}
	spy := newSpyStore(t)
	b := testBundle(t, obscel.ModeWarn)
	windows := NewWindows([]*obscel.Bundle{b})

	if err := windows.Warm(context.Background(), spy, baseTime); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	spy.WarmupDone()

	sink := NewSink(inner, spy, newTestEvaluator(t), bundlesFor(b), Options{Windows: windows})
	for i := range 5 {
		at := baseTime.Add(time.Duration(i) * time.Minute)
		obs := iamObs(fmt.Sprintf("obs-%d", i), at, "arn:aws:iam::1:user/agent", "AttachUserPolicy")
		if err := sink.IngestObservation(context.Background(), obs); err != nil {
			t.Fatalf("IngestObservation(%d): %v", i, err)
		}
	}
	// The t.Errorf inside spyStore.QueryRange is the assertion; this bounds it.
	if spy.queryCalls != 1 {
		t.Errorf("QueryRange called %d times, want exactly 1 (the warm-up)", spy.queryCalls)
	}
}

// An evaluator fault is counted and logged, never returned to the caller.
func TestSink_EvaluatorErrorIsCountedNotReturned(t *testing.T) {
	inner := &recordingSink{}
	m := NewMetrics()
	b := testBundle(t, obscel.ModeShadow)
	sink := NewSink(inner, newSpyStore(t), faultyEvaluator{}, bundlesFor(b), Options{Metrics: m})

	if err := sink.IngestObservation(context.Background(), iamObs("obs-1", baseTime, "a", "AttachUserPolicy")); err != nil {
		t.Fatalf("an evaluator fault must not surface to the writer, got %v", err)
	}
	if n := m.Snapshot().EvaluatorErrors; n != 1 {
		t.Errorf("evaluator_errors = %d, want 1", n)
	}
	if n := len(inner.bySource(obscel.SourceFinding)); n != 0 {
		t.Errorf("a faulting evaluator produced %d findings, want 0", n)
	}
	// The source observation still landed.
	if n := len(inner.obs); n != 1 {
		t.Errorf("source observation count = %d, want 1", n)
	}
}

type faultyEvaluator struct{}

func (faultyEvaluator) EvaluateObservation(_ obscel.Observation, _ *obscel.Bundle) ([]obscel.Finding, error) {
	return nil, errors.New("rule \"iam-priv-change\": evaluation error: synthetic fault")
}

// A finding that cannot be written is counted; ingest still succeeds.
func TestSink_FindingAppendFailureIsCounted(t *testing.T) {
	inner := &failSecondSink{}
	m := NewMetrics()
	b := testBundle(t, obscel.ModeShadow)
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{Metrics: m})

	if err := sink.IngestObservation(context.Background(), iamObs("obs-1", baseTime, "a", "AttachUserPolicy")); err != nil {
		t.Fatalf("a failed finding write must not fail the source write, got %v", err)
	}
	if n := m.Snapshot().FindingWriteErrors; n != 1 {
		t.Errorf("finding_write_errors = %d, want 1", n)
	}
}

// failSecondSink accepts the first observation and refuses every later one, so the
// source write succeeds and the finding write fails.
type failSecondSink struct {
	n int
}

func (f *failSecondSink) IngestObservation(_ context.Context, _ *model.Observation) error {
	f.n++
	if f.n == 1 {
		return nil
	}
	return errors.New("append refused")
}

// A tenant with no bundle is evaluated against nothing and costs nothing.
func TestSink_UnknownTenantProducesNoFindings(t *testing.T) {
	inner := &recordingSink{}
	b := testBundle(t, obscel.ModeShadow)
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{})

	obs := iamObs("obs-1", baseTime, "a", "AttachUserPolicy")
	obs.Labels["tenant_id"] = "someone-else"
	if err := sink.IngestObservation(context.Background(), obs); err != nil {
		t.Fatalf("IngestObservation: %v", err)
	}
	if n := len(inner.bySource(obscel.SourceFinding)); n != 0 {
		t.Errorf("want 0 findings for a tenant with no bundle, got %d", n)
	}
}

// Label serialisation order is canonical, not map order.
func TestFindingLabelsAreSorted(t *testing.T) {
	inner := &recordingSink{}
	b := testBundle(t, obscel.ModeEnforce)
	sink := NewSink(inner, newSpyStore(t), newTestEvaluator(t), bundlesFor(b), Options{})
	if err := sink.IngestObservation(context.Background(), iamObs("obs-1", baseTime, "a", "AttachUserPolicy")); err != nil {
		t.Fatalf("IngestObservation: %v", err)
	}
	f := inner.bySource(obscel.SourceFinding)[0]
	keys := obscel.SortedLabelKeys(f.Labels)
	sorted := append([]string(nil), keys...)
	sort.Strings(sorted)
	if strings.Join(keys, ",") != strings.Join(sorted, ",") {
		t.Errorf("label keys %v are not in sorted order", keys)
	}
}
