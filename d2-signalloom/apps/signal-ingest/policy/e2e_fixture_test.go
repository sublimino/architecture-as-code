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

	bundles, err := LoadBundles(bundlesDir, testLogger(t), nil)
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

	// The composition order mirrors production exactly, and the order matters.
	//
	// main.go hands the registry the POLICY sink, and a collector that knows its
	// tenant from configuration wraps the sink it was given with the binder
	// (collectors/awslogs_adapter.go boundSink: BindTenant(c.sink, ...)). So the
	// chain a collector observation travels is:
	//
	//	BindTenant  ->  policy.Sink  ->  collectors.StoreSink  ->  store
	//
	// The binder is OUTSIDE policy, which is what lets stage 1 read a tenant that
	// the binder has stamped. Were it inside, an observation whose tenant_id the
	// collector supplies by configuration rather than in the record would reach
	// stage 1 unstamped, resolve zero bundles, and be silently undetected --
	// a no-op detection control that looks exactly like a quiet estate.
	// TestE2EFixture_BinderOutsidePolicyLetsStageOneSeeAStampedTenant pins it.
	var chain collectors.IngestionSink = collectors.NewStoreSink(st)
	sink := NewSink(chain, st, evaluator, StaticBundles(bundles), Options{
		Windows: NewWindowsWithLogger(bundles, testLogger(t)),
		Metrics: metrics,
		Alerter: alerter,
		Logger:  testLogger(t),
	})
	bound := collectors.BindTenant(sink, e2eTenant)

	corpus := e2eCorpus(t)
	SortObservations(corpus)
	for i := range corpus {
		if err := bound.IngestObservation(context.Background(), &corpus[i]); err != nil {
			t.Fatalf("IngestObservation(%s): %v", corpus[i].ID, err)
		}
	}
	return st, metrics, alerter
}

// Stage 1 resolves bundles from the tenant_id label on the observation it is
// HANDED, so whatever establishes tenancy must run BEFORE the policy sink.
//
// This is the invariant behind the composition order, and it is the half that is
// verifiable here. An observation whose tenant label is absent matches no bundle
// and produces nothing, while every write still succeeds -- a no-op detection
// control that looks exactly like a quiet estate, and one that no assertion
// about stored observations can see.
//
// Production satisfies the invariant by composing the binder outside policy:
// main.go hands the registry the policy sink, and
// collectors/awslogs_adapter.go boundSink wraps the sink it was given with
// BindTenant(c.sink, cfg.TenantID). The ordering assertion that closes the loop
// -- an UNSTAMPED observation becoming a finding through the bound chain --
// needs the real binder, which arrives with the tenant-binder card (D7, P1-4).
// On this branch collectors.BindTenant is still the declared passthrough stub,
// so that assertion cannot pass yet and is deliberately not written as a test
// that would be red on merge-base. See the report for the follow-up.
func TestE2EFixture_StageOneResolvesBundlesFromTheStampedTenantLabel(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t), nil)
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}

	newEvent := func(labels map[string]string) *model.Observation {
		return &model.Observation{
			ID:             "e2e-tenancy-attachuserpolicy",
			Timestamp:      time.Date(2026, 10, 2, 9, 20, 0, 0, time.UTC),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityStrong,
			Source:         "aws:iam",
			Confidence:     0.9,
			ActorHint:      "arn:aws:iam::123456789012:user/kusari-agent",
			RawEvidenceRef: "testdata/tenancy#0",
			Description:    "IAM privilege change",
			Labels:         labels,
		}
	}

	for _, tc := range []struct {
		name         string
		labels       map[string]string
		wantFindings int
	}{
		{
			name: "stamped tenant matches the bundle",
			labels: map[string]string{
				TenantLabel:    e2eTenant,
				"event_source": "iam.amazonaws.com",
				"event_name":   "AttachUserPolicy",
			},
			wantFindings: 1,
		},
		{
			// The failure mode the composition order exists to prevent.
			name: "absent tenant matches nothing, silently",
			labels: map[string]string{
				"event_source": "iam.amazonaws.com",
				"event_name":   "AttachUserPolicy",
			},
			wantFindings: 0,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := store.NewMemoryStore()
			sink := NewSink(collectors.NewStoreSink(st), st, evaluator, StaticBundles(bundles), Options{
				Windows: NewWindowsWithLogger(bundles, testLogger(t)),
				Logger:  testLogger(t),
			})
			if err := sink.IngestObservation(context.Background(), newEvent(tc.labels)); err != nil {
				t.Fatalf("IngestObservation: %v", err)
			}

			// Narrowed to kusari-iam-change: see iamChangeBundleID. The
			// claim is that a STAMPED tenant resolves this bundle and an
			// absent one resolves nothing, which is per-bundle either way.
			findings := storedByBundle(t, st, obscel.SourceFinding, iamChangeBundleID)
			if len(findings) != tc.wantFindings {
				t.Fatalf("got %d findings from %s, want %d", len(findings), iamChangeBundleID, tc.wantFindings)
			}
			// Either way the observation itself landed: an unresolvable tenant
			// degrades detection, never ingest.
			rows, err := st.QueryRange(context.Background(), store.Query{})
			if err != nil {
				t.Fatalf("QueryRange: %v", err)
			}
			allFindings := len(storedBySource(t, st, obscel.SourceFinding))
			if len(rows) != 1+allFindings {
				t.Errorf("store holds %d rows, want 1 observation + %d findings", len(rows), allFindings)
			}
			if tc.wantFindings == 0 && allFindings != 0 {
				t.Errorf("an observation with no tenant label produced %d findings across the loaded bundle set, want 0 from every bundle", allFindings)
			}
			if tc.wantFindings == 1 && findings[0].Labels[TenantLabel] != e2eTenant {
				t.Errorf("finding tenant_id = %q, want %q", findings[0].Labels[TenantLabel], e2eTenant)
			}
		})
	}
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

// iamChangeBundleID is the bundle THIS file is about.
//
// Every assertion below used to be written as though the tenant had exactly one
// bundle, so "the shipped bundle fired" and "the store holds one finding" were
// the same statement. They are not any more: policy/bundles/kusari/ now also
// holds cloud-signals.yaml, which covers the EKS, console, STS, S3, GuardDuty
// and VPC Flow surfaces and deliberately overlaps the IAM path (its header says
// so, and the overlap is what lets the narrow IAM bundle be promoted to warn on
// its own schedule). Findings are per bundle by construction -- Finding.ID
// hashes the bundle version -- so the same event legitimately produces one
// finding per bundle.
//
// So the counts here are narrowed to this bundle rather than relaxed. Narrowing
// keeps every original claim exactly as strong: "the shipped kusari-iam-change
// bundle produced three iam-priv-change findings and one decision over the
// fixture corpus" is still asserted to the event. What is no longer asserted is
// that NO OTHER bundle fired, which was never the invariant -- it was an
// artefact of there being nothing else to fire. The cross-bundle totals, which
// are the thing worth pinning now, are asserted in
// d2-signalloom/apps/signal-ingest/e2e against the whole loaded set.
const iamChangeBundleID = "kusari-iam-change"

// storedByBundle is storedBySource narrowed to the findings or decisions one
// bundle produced.
func storedByBundle(t *testing.T, st store.SignalStore, source, bundleID string) []model.Observation {
	t.Helper()
	var out []model.Observation
	for _, r := range storedBySource(t, st, source) {
		if r.Labels[LabelBundleID] == bundleID {
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

	// Narrowed to kusari-iam-change: see iamChangeBundleID.
	findings := storedByBundle(t, st, obscel.SourceFinding, iamChangeBundleID)
	if len(findings) == 0 {
		t.Fatal("the shipped kusari bundle produced NO findings over the awslogs fixture corpus")
	}
	t.Logf("fixture corpus produced %d findings from %s (%d across every loaded bundle)",
		len(findings), iamChangeBundleID, len(storedBySource(t, st, obscel.SourceFinding)))

	// Every rule the shipped bundle declares that the corpus can reach.
	byRule := map[string]int{}
	for _, f := range findings {
		byRule[f.Labels[LabelRuleID]]++
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

	// ... and therefore exactly one decision FROM THIS BUNDLE. Narrowed: see
	// iamChangeBundleID.
	decisions := storedByBundle(t, st, obscel.SourceDecision, iamChangeBundleID)
	if len(decisions) != 1 {
		t.Fatalf("three qualifying IAM events inside 10m produced %d decisions from %s, want 1", len(decisions), iamChangeBundleID)
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

	// Counters agree with the store. The counters are per PROCESS, not per
	// bundle, so these compare against every loaded bundle's output -- which is
	// the right comparison for a counter and is why they are not narrowed.
	snap := metrics.Snapshot()
	allFindings := storedBySource(t, st, obscel.SourceFinding)
	allDecisions := storedBySource(t, st, obscel.SourceDecision)
	if snap.Findings != uint64(len(allFindings)) {
		t.Errorf("counted %d findings, stored %d", snap.Findings, len(allFindings))
	}
	if snap.Decisions != uint64(len(allDecisions)) {
		t.Errorf("counted %d decisions, stored %d", snap.Decisions, len(allDecisions))
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
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t), nil)
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

	// Narrowed to this bundle's alert: see iamChangeBundleID. Every loaded
	// bundle was promoted above (the loop sets Mode on all of them, exactly as a
	// reviewed commit would in each file), so each one that fires a decision
	// alerts. The claim here is about kusari-iam-change's decision.
	var promoted []obscel.Decision
	for _, d := range alerter.got {
		if d.Mode != obscel.ModeWarn {
			t.Errorf("alerted decision %s mode = %q, want warn", d.ID, d.Mode)
		}
		if d.BundleID == iamChangeBundleID {
			promoted = append(promoted, d)
		}
	}
	if len(promoted) != 1 {
		t.Fatalf("a promoted %s alerted %d times, want 1 (%d alerts across every loaded bundle)",
			iamChangeBundleID, len(promoted), len(alerter.got))
	}
	if promoted[0].Count != 3 {
		t.Errorf("alerted decision count = %d, want 3", promoted[0].Count)
	}
	if promoted[0].WindowID != "iam-change-burst" {
		t.Errorf("alerted decision window = %q, want iam-change-burst", promoted[0].WindowID)
	}
}

// ---------------------------------------------------------------------------
// The HTTP path reaches the same pipeline (ISC-56)
// ---------------------------------------------------------------------------

// policy.Store is what routes POST /api/v1/observations. The same corpus
// through the store wrapper must produce the same findings and the same
// decision as through the sink, because it is the same deciding code.
func TestE2EFixture_HTTPStoreWrapperMatchesTheSink(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t), nil)
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
	// Narrowed to this bundle: see iamChangeBundleID.
	decisions := storedBySource(t, st, obscel.SourceDecision)
	if n := len(storedByBundle(t, st, obscel.SourceDecision, iamChangeBundleID)); n != 1 {
		t.Fatalf("the HTTP store wrapper produced %d decisions from %s, want 1", n, iamChangeBundleID)
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
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t), nil)
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
