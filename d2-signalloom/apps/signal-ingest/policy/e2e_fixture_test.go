// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// The fixture e2e: awslogs fixture mode through the real policy sink with the
// REAL shipped kusari bundle, into a real store (ISC-56).
//
// Everything here is production code except the store and the clock. The
// evaluator is obscel's, the bundle is the one Flux reconciles, the sink is the
// one main.go wires, and the observations are the projection the awslogs
// collector produces in fixture mode. The only thing the test supplies is the
// corpus and the assertion.
//
// # The mutation gate
//
// Pointing this at an empty bundle directory turns it red, which is what makes
// the green bar mean something. TestE2EFixture_EmptyBundleDirIsTheMutationGate
// performs that mutation IN-TEST rather than leaving it as a manual step, so
// the gate cannot rot: if the pipeline ever starts producing findings without a
// bundle, that test fails too.

const e2eTenant = "kusari"

// e2eCorpus is the awslogs fixture projection plus the one record the shipped
// bundle's declared window needs.
//
// The fixtures carry exactly TWO iam-priv-change matches by
// arn:aws:iam::123456789012:user/kusari-agent (CreatePolicyVersion at 09:14:31
// and AttachUserPolicy at 09:15:02), and the window declares threshold 3 over
// 10m. So the corpus is one event short of a decision by construction. Rather
// than weaken the assertion to "findings only", the test adds a third
// qualifying event inside the window, built to the same §2.3 label contract the
// collector emits. The added record is the only synthetic input and it is
// called out here so nobody later reads the decision as something the shipped
// fixtures produce on their own.
func e2eCorpus(t *testing.T) []model.Observation {
	t.Helper()

	obs, err := awslogs.FixtureObservations(e2eTenant, "us-east-1")
	if err != nil {
		t.Fatalf("awslogs.FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the awslogs fixture corpus is empty; this test would assert nothing")
	}

	third := model.Observation{
		ID:             "e2e-synthetic-putuserpolicy",
		Timestamp:      time.Date(2026, 10, 2, 9, 16, 30, 0, time.UTC), // inside 10m of 09:14:31
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityStrong,
		Source:         "aws:iam",
		Confidence:     0.9,
		ActorHint:      "arn:aws:iam::123456789012:user/kusari-agent",
		RawEvidenceRef: "testdata/synthetic#0",
		Description:    "synthetic third IAM privilege change, inside the declared window",
		Labels: map[string]string{
			TenantLabel:      e2eTenant,
			"provider":       "aws",
			"aws_account_id": "123456789012",
			"aws_region":     "us-east-1",
			"event_source":   "iam.amazonaws.com",
			"event_name":     "PutUserPolicy",
			"source_ip":      "192.0.2.44",
		},
	}
	if err := third.Validate(); err != nil {
		t.Fatalf("the synthetic third event is not a valid observation: %v", err)
	}
	return append(obs, third)
}

// runE2E drives the corpus through a real policy sink over a real store.
func runE2E(t *testing.T, bundlesDir string) (*store.MemoryStore, *Metrics, *recordingAlerter) {
	t.Helper()

	bundles, err := LoadBundles(bundlesDir, testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles(%s): %v", bundlesDir, err)
	}

	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}

	st := store.NewMemoryStore()
	metrics := NewMetrics()
	alerter := &recordingAlerter{}

	// collectors.NewStoreSink is the production inner sink, and BindTenant is
	// called exactly as a collector calls it. BindTenant is a passthrough stub
	// owned by another card; calling it here means this test starts exercising
	// the real binder the moment it lands, rather than needing an edit.
	var inner collectors.IngestionSink = collectors.NewStoreSink(st)
	inner = collectors.BindTenant(inner, e2eTenant)

	sink := NewSink(inner, st, evaluator, StaticBundles(bundles), Options{
		Windows: NewWindowsWithLogger(bundles, testLogger(t)),
		Metrics: metrics,
		Alerter: alerter,
		Logger:  testLogger(t),
	})

	corpus := e2eCorpus(t)
	SortObservations(corpus)
	for i := range corpus {
		if err := sink.IngestObservation(context.Background(), &corpus[i]); err != nil {
			t.Fatalf("IngestObservation(%s): %v", corpus[i].ID, err)
		}
	}
	return st, metrics, alerter
}

func storedBySource(t *testing.T, st store.SignalStore, source string) []model.Observation {
	t.Helper()
	rows, err := st.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	var out []model.Observation
	for _, r := range rows {
		if r.Source == source {
			out = append(out, r)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// ISC-56: the fixture corpus produces findings and a decision
// ---------------------------------------------------------------------------

func TestE2EFixture_ShippedKusariBundleProducesFindingsAndADecision(t *testing.T) {
	st, metrics, alerter := runE2E(t, repoBundlesDir(t))

	findings := storedBySource(t, st, obscel.SourceFinding)
	if len(findings) == 0 {
		t.Fatal("the shipped kusari bundle produced NO findings over the awslogs fixture corpus")
	}
	t.Logf("fixture corpus produced %d findings", len(findings))

	// Every rule the shipped bundle declares that the corpus can reach.
	byRule := map[string]int{}
	for _, f := range findings {
		byRule[f.Labels[LabelRuleID]]++
		if f.Labels[LabelBundleID] != "kusari-iam-change" {
			t.Errorf("finding %s came from bundle %q, want kusari-iam-change", f.ID, f.Labels[LabelBundleID])
		}
		if f.Labels[LabelMode] != string(obscel.ModeShadow) {
			t.Errorf("finding %s is mode %q, want shadow (the shipped bundle is not promoted)",
				f.ID, f.Labels[LabelMode])
		}
	}
	for _, rule := range []string{"iam-priv-change", "access-key-created", "vpc-reject"} {
		if byRule[rule] == 0 {
			t.Errorf("rule %q matched nothing in the fixture corpus; the corpus or the rule has drifted", rule)
		}
	}
	// Three qualifying IAM privilege changes by one actor: two from the fixtures
	// plus the synthetic third.
	if byRule["iam-priv-change"] != 3 {
		t.Errorf("iam-priv-change matched %d times, want 3", byRule["iam-priv-change"])
	}

	// ... and therefore exactly one decision.
	decisions := storedBySource(t, st, obscel.SourceDecision)
	if len(decisions) != 1 {
		t.Fatalf("three qualifying IAM events inside 10m produced %d decisions, want 1", len(decisions))
	}
	d := decisions[0]
	if got := d.Labels[LabelWindowID]; got != "iam-change-burst" {
		t.Errorf("decision window_id = %q, want iam-change-burst", got)
	}
	if got := d.Labels[LabelCount]; got != "3" {
		t.Errorf("decision count = %q, want 3", got)
	}
	if got := d.Labels[LabelMode]; got != string(obscel.ModeShadow) {
		t.Errorf("decision mode = %q, want shadow", got)
	}
	if got := d.ActorHint; got != "arn:aws:iam::123456789012:user/kusari-agent" {
		t.Errorf("decision actor = %q, want the bursting identity", got)
	}
	// The triggering event is the synthetic third at 09:16:30, and the decision
	// is stamped with ITS timestamp, not with now.
	wantAt := time.Date(2026, 10, 2, 9, 16, 30, 0, time.UTC)
	if !d.Timestamp.Equal(wantAt) {
		t.Errorf("decision timestamp = %v, want the triggering observation's %v", d.Timestamp, wantAt)
	}
	if time.Since(d.Timestamp) < time.Hour {
		t.Error("the decision timestamp looks like a wall-clock reading")
	}

	// Shadow stores and does not alert.
	if len(alerter.got) != 0 {
		t.Errorf("the shipped bundle is in shadow mode and alerted %d times, want 0", len(alerter.got))
	}

	// Counters agree with the store.
	snap := metrics.Snapshot()
	if snap.Findings != uint64(len(findings)) {
		t.Errorf("counted %d findings, stored %d", snap.Findings, len(findings))
	}
	if snap.Decisions != 1 {
		t.Errorf("counted %d decisions, want 1", snap.Decisions)
	}
	if snap.EvaluatorErrors != 0 {
		t.Errorf("the shipped bundle produced %d evaluator faults over the fixture corpus, want 0",
			snap.EvaluatorErrors)
	}
	if snap.FindingWriteErrors != 0 || snap.DecisionWriteErrors != 0 {
		t.Errorf("write errors: %d findings, %d decisions; want 0 and 0",
			snap.FindingWriteErrors, snap.DecisionWriteErrors)
	}
}

// The source observations are all still there, unmodified. Policy is additive:
// it must never consume, rewrite or drop what it evaluated.
func TestE2EFixture_SourceObservationsSurviveUntouched(t *testing.T) {
	st, _, _ := runE2E(t, repoBundlesDir(t))

	want := e2eCorpus(t)
	rows, err := st.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}

	stored := map[string]model.Observation{}
	for _, r := range rows {
		stored[r.ID] = r
	}
	for _, w := range want {
		got, ok := stored[w.ID]
		if !ok {
			t.Errorf("source observation %s is missing from the store", w.ID)
			continue
		}
		if got.Source != w.Source {
			t.Errorf("observation %s source = %q, want %q", w.ID, got.Source, w.Source)
		}
		if !got.Timestamp.Equal(w.Timestamp) {
			t.Errorf("observation %s timestamp was rewritten: %v, want %v", w.ID, got.Timestamp, w.Timestamp)
		}
		if got.ActorHint != w.ActorHint {
			t.Errorf("observation %s actor_hint was rewritten: %q, want %q", w.ID, got.ActorHint, w.ActorHint)
		}
		if len(got.Labels) != len(w.Labels) {
			t.Errorf("observation %s label count changed: %d, want %d", w.ID, len(got.Labels), len(w.Labels))
		}
	}
}

// ---------------------------------------------------------------------------
// The mutation gate (ISC-56)
// ---------------------------------------------------------------------------

// Pointing the e2e at an empty bundle directory must turn it red. This runs the
// mutation in-test so the gate cannot rot: the assertions below are the exact
// inverse of the ones above, and both cannot pass at once unless the pipeline
// is doing something indefensible.
func TestE2EFixture_EmptyBundleDirIsTheMutationGate(t *testing.T) {
	st, metrics, alerter := runE2E(t, t.TempDir())

	if n := len(storedBySource(t, st, obscel.SourceFinding)); n != 0 {
		t.Errorf("an empty bundle dir produced %d findings; the e2e green bar proves nothing", n)
	}
	if n := len(storedBySource(t, st, obscel.SourceDecision)); n != 0 {
		t.Errorf("an empty bundle dir produced %d decisions", n)
	}
	if len(alerter.got) != 0 {
		t.Errorf("an empty bundle dir alerted %d times", len(alerter.got))
	}
	snap := metrics.Snapshot()
	if snap.Findings != 0 || snap.Decisions != 0 {
		t.Errorf("an empty bundle dir counted %d findings and %d decisions", snap.Findings, snap.Decisions)
	}

	// The source observations are still stored. No bundles must mean "evaluate
	// nothing", never "ingest nothing" -- that is the whole of the fail-open
	// decision, and it is the half most worth pinning.
	rows, err := st.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(rows) != len(e2eCorpus(t)) {
		t.Errorf("with no bundles the store holds %d observations, want the whole corpus of %d",
			len(rows), len(e2eCorpus(t)))
	}
}

// Promoting the shipped bundle to warn alerts; the fixture corpus is the proof
// that promotion is a one-line bundle change and nothing else.
func TestE2EFixture_PromotingToWarnAlerts(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	// Promote in memory, exactly as a reviewed commit would in the file.
	for _, b := range bundles {
		b.Mode = obscel.ModeWarn
	}

	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}
	st := store.NewMemoryStore()
	alerter := &recordingAlerter{}
	sink := NewSink(collectors.NewStoreSink(st), st, evaluator, StaticBundles(bundles), Options{
		Windows: NewWindowsWithLogger(bundles, testLogger(t)),
		Metrics: NewMetrics(),
		Alerter: alerter,
		Logger:  testLogger(t),
	})

	corpus := e2eCorpus(t)
	SortObservations(corpus)
	for i := range corpus {
		if err := sink.IngestObservation(context.Background(), &corpus[i]); err != nil {
			t.Fatalf("IngestObservation: %v", err)
		}
	}

	if len(alerter.got) != 1 {
		t.Fatalf("a promoted bundle alerted %d times, want 1", len(alerter.got))
	}
	if alerter.got[0].Mode != obscel.ModeWarn {
		t.Errorf("alerted decision mode = %q, want warn", alerter.got[0].Mode)
	}
	if alerter.got[0].Count != 3 {
		t.Errorf("alerted decision count = %d, want 3", alerter.got[0].Count)
	}
}

// ---------------------------------------------------------------------------
// The HTTP path reaches the same pipeline (ISC-56)
// ---------------------------------------------------------------------------

// policy.Store is what routes POST /api/v1/observations. The same corpus
// through the store wrapper must produce the same findings and the same
// decision as through the sink, because it is the same deciding code.
func TestE2EFixture_HTTPStoreWrapperMatchesTheSink(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}

	st := store.NewMemoryStore()
	sink := NewSink(collectors.NewStoreSink(st), st, evaluator, StaticBundles(bundles), Options{
		Windows: NewWindowsWithLogger(bundles, testLogger(t)),
		Metrics: NewMetrics(),
		Logger:  testLogger(t),
	})
	wrapped := NewStore(st, sink.(*Sink))

	// One batched Append, exactly as the handler makes it.
	corpus := e2eCorpus(t)
	SortObservations(corpus)
	if err := wrapped.Append(context.Background(), corpus); err != nil {
		t.Fatalf("policy.Store.Append: %v", err)
	}

	findings := storedBySource(t, st, obscel.SourceFinding)
	if len(findings) == 0 {
		t.Fatal("the HTTP store wrapper produced no findings; POST /api/v1/observations bypasses policy")
	}
	decisions := storedBySource(t, st, obscel.SourceDecision)
	if len(decisions) != 1 {
		t.Fatalf("the HTTP store wrapper produced %d decisions, want 1", len(decisions))
	}

	// The whole corpus landed, and it landed in ONE batch: the atomicity the
	// handler depends on is intact.
	rows, err := wrapped.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(rows) != len(corpus)+len(findings)+len(decisions) {
		t.Errorf("store holds %d rows, want %d corpus + %d findings + %d decisions",
			len(rows), len(corpus), len(findings), len(decisions))
	}
	if wrapped.Unwrap() != store.SignalStore(st) {
		t.Error("Unwrap does not return the wrapped store")
	}
}

// A findings/decisions batch arriving over HTTP is stored and not re-evaluated.
func TestE2EFixture_HTTPStoreWrapperDoesNotReEvaluatePolicyOutput(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}
	st := store.NewMemoryStore()
	sink := NewSink(collectors.NewStoreSink(st), st, evaluator, StaticBundles(bundles), Options{
		Windows: NewWindowsWithLogger(bundles, testLogger(t)),
		Logger:  testLogger(t),
	})
	wrapped := NewStore(st, sink.(*Sink))

	corpus := e2eCorpus(t)
	SortObservations(corpus)
	if err := wrapped.Append(context.Background(), corpus); err != nil {
		t.Fatalf("Append: %v", err)
	}
	before := len(storedBySource(t, st, obscel.SourceFinding))

	// Re-post the findings, as a replaying or confused client would.
	if err := wrapped.Append(context.Background(), storedBySource(t, st, obscel.SourceFinding)); err != nil {
		t.Fatalf("Append(findings): %v", err)
	}
	after := len(storedBySource(t, st, obscel.SourceFinding))
	if after != before*2 {
		t.Errorf("re-posting %d findings stored %d; want them stored once each and evaluated none",
			before, after-before)
	}
}
