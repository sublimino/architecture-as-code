// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// discardLogger keeps test output readable without losing the code path that formats the log lines —
// the formatting itself is asserted in TestRetentionController_OverdueIsLoggedWithSinkAndAge via a
// capturing handler.
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func readFile(name string) (string, error) {
	raw, err := os.ReadFile(name)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// ---------------------------------------------------------------------------
// Construction — every fail-open configuration is refused
// ---------------------------------------------------------------------------

func TestRetentionController_RefusesEveryFailOpenConfiguration(t *testing.T) {
	base := func() Config {
		return Config{
			Clock:     fixedClock{at: testNow},
			Ledger:    NewMemoryLedger(),
			Evaluator: &fakeEvaluator{deletable: true},
			Audit:     &countingAudit{},
			Sinks:     []Sink{inProcessSink("postgres_actors", 1)},
			Policies: PolicySet{TenantID: "tenant-a", Policies: []Policy{
				{TenantID: "tenant-a", SinkID: "postgres_actors", Period: DefaultIdentityPeriod},
			}},
			Logger: discardLogger(),
		}
	}
	if _, err := NewController(base()); err != nil {
		t.Fatalf("the baseline config must be accepted: %v", err)
	}

	cases := map[string]func(*Config){
		"nil ledger":      func(c *Config) { c.Ledger = nil },
		"nil clock":       func(c *Config) { c.Clock = nil },
		"nil evaluator":   func(c *Config) { c.Evaluator = nil },
		"nil audit":       func(c *Config) { c.Audit = nil },
		"empty sink set":  func(c *Config) { c.Sinks = nil },
		"nil sink":        func(c *Config) { c.Sinks = []Sink{nil} },
		"duplicate sinks": func(c *Config) { c.Sinks = append(c.Sinks, inProcessSink("postgres_actors", 1)) },
		"policy gap":      func(c *Config) { c.Policies.Policies = nil },
		"unbounded policy": func(c *Config) {
			c.Policies.Policies[0].Period = MaxRetentionPeriod + time.Hour
		},
		"unverified clock": func(c *Config) { c.Clock = LocalClock{} },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := base()
			mutate(&cfg)
			if _, err := NewController(cfg); err == nil {
				t.Fatalf("%s must be refused at construction", name)
			}
		})
	}
}

// TestRetentionController_EmptySinkSetIsRefused is the anti-criterion for a vacuous pass.
func TestRetentionController_EmptySinkSetIsRefused(t *testing.T) {
	_, err := NewController(Config{
		Clock: fixedClock{at: testNow}, Ledger: NewMemoryLedger(),
		Evaluator: &fakeEvaluator{}, Audit: &countingAudit{},
		Policies: PolicySet{TenantID: "tenant-a"}, Sinks: nil, Logger: discardLogger(),
	})
	if err == nil {
		t.Fatal("an empty sink set must be refused; every acceptance criterion would pass vacuously")
	}
	if !strings.Contains(err.Error(), "vacuously") {
		t.Errorf("the refusal should say why: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Sweep — coverage, per-copy receipts, four outcomes
// ---------------------------------------------------------------------------

func TestRetentionController_SweepEmitsOneReceiptPerCopy(t *testing.T) {
	sinks := []Sink{
		inProcessSink("postgres_actors", 3),
		inProcessSink("postgres_aliases", 5),
		inProcessSink("postgres_delegations", 0), // already absent
	}
	h := newHarness(t, sinks)

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if !res.OK() {
		t.Fatalf("sweep not OK: %+v", res)
	}
	if got := len(res.Receipts); got != 3 {
		t.Fatalf("got %d receipts for 3 copies, want 3", got)
	}
	if got := h.ledger.Count("tenant-a"); got != 3 {
		t.Fatalf("ledger holds %d receipts, want 3", got)
	}
	if res.Dispositions[DispositionPurged] != 2 {
		t.Errorf("purged = %d, want 2", res.Dispositions[DispositionPurged])
	}
	if res.Dispositions[DispositionAlreadyAbsent] != 1 {
		t.Errorf("already_absent = %d, want 1", res.Dispositions[DispositionAlreadyAbsent])
	}
	if res.RecordsRemoved != 8 {
		t.Errorf("records removed = %d, want 8", res.RecordsRemoved)
	}
	if res.ClockSource != ClockSourceTrustedSync {
		t.Errorf("clock source = %q", res.ClockSource)
	}
	// One audit event per receipt.
	if got := h.audit.events.Load(); got != 3 {
		t.Errorf("audit events = %d, want 3", got)
	}
	if h.audit.last.EventType != "partition_dropped" {
		t.Errorf("audit event type = %q", h.audit.last.EventType)
	}
	if !strings.Contains(string(h.audit.last.Detail), `"cause":"retention"`) {
		t.Error("audit detail must carry cause=retention so retention sweeps stay distinguishable from Article 17 decisions")
	}
	if !strings.Contains(string(h.audit.last.Detail), `"receipt_digest"`) {
		t.Error("audit detail must carry the receipt digest, per P6-PRE §6 invariant 3")
	}
}

// TestRetentionController_AlreadyAbsentIsDistinguishableFromPurged is the card's explicit requirement.
func TestRetentionController_AlreadyAbsentIsDistinguishableFromPurged(t *testing.T) {
	absent := inProcessSink("postgres_delegations", 0)
	purged := inProcessSink("postgres_actors", 4)
	h := newHarness(t, []Sink{absent, purged})

	if _, err := h.ctrl.Sweep(t.Context(), "tenant-a"); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	byDisposition := map[string]Disposition{}
	for _, spec := range []string{"postgres_delegations", "postgres_actors"} {
		policy, _ := h.ctrl.policies.For(spec)
		id := NewOperationID("tenant-a", spec, policy.Boundary(testNow.Truncate(time.Microsecond)))
		r, found, err := h.ledger.Get(t.Context(), "tenant-a", id)
		if err != nil || !found {
			t.Fatalf("receipt for %s not in the ledger (found=%v err=%v)", spec, found, err)
		}
		byDisposition[spec] = r.Disposition
		if r.ComplianceNote == "" {
			t.Errorf("%s receipt carries no compliance note", spec)
		}
	}
	if byDisposition["postgres_delegations"] != DispositionAlreadyAbsent {
		t.Errorf("an empty sink yielded %q, want already_absent — 'deleted' and 'never existed' are different facts",
			byDisposition["postgres_delegations"])
	}
	if byDisposition["postgres_actors"] != DispositionPurged {
		t.Errorf("a populated sink yielded %q, want purged", byDisposition["postgres_actors"])
	}
}

// TestRetentionController_UnreachableSinkNeverReadsAsSuccess is the headline anti-criterion.
func TestRetentionController_UnreachableSinkNeverReadsAsSuccess(t *testing.T) {
	good := inProcessSink("postgres_actors", 2)
	bad := inProcessSink("postgres_aliases", 0)
	bad.err = fmt.Errorf("%w: connection refused", ErrSinkUnreachable)
	h := newHarness(t, []Sink{good, bad})

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("a sweep with an unreachable sink must return an error; a caller checking err==nil must not read it as clean")
	}
	if !errors.Is(err, ErrSweepIncomplete) {
		t.Fatalf("error should wrap ErrSweepIncomplete: %v", err)
	}
	if res.OK() {
		t.Fatal("SweepResult.OK() must be false when a sink was unreachable")
	}
	if res.Dispositions[DispositionUnreachable] != 1 {
		t.Fatalf("unreachable = %d, want 1", res.Dispositions[DispositionUnreachable])
	}
	if len(res.Failures) == 0 {
		t.Error("the unreachable sink must appear in Failures")
	}
	// The reachable sink still worked — a partial failure must not become a total one.
	if res.Dispositions[DispositionPurged] != 1 {
		t.Errorf("purged = %d, want 1: one broken sink must not stop the others", res.Dispositions[DispositionPurged])
	}
	// And a receipt exists for the unreachable copy, which is what keeps it outstanding.
	var foundUnreachable bool
	for _, o := range res.Outstanding {
		if o.SinkID == "postgres_aliases" && o.Disposition == DispositionUnreachable {
			foundUnreachable = true
		}
	}
	if !foundUnreachable {
		t.Error("the unreachable copy must remain outstanding")
	}
	if got := h.ctrl.Metrics().ConsecutiveFailures("postgres_aliases"); got != 1 {
		t.Errorf("consecutive failures for the broken sink = %d, want 1", got)
	}
	if got := h.ctrl.Metrics().ConsecutiveFailures("postgres_actors"); got != 0 {
		t.Errorf("consecutive failures for the healthy sink = %d, want 0", got)
	}
}

// ---------------------------------------------------------------------------
// Legal hold precedence
// ---------------------------------------------------------------------------

func TestRetentionController_HoldBlocksDeletionAndStaysOutstanding(t *testing.T) {
	sink := inProcessSink("postgres_actors", 9)
	h := newHarness(t, []Sink{sink})
	h.evaluator.deletable = false
	h.evaluator.holdIDs = []string{"hold-1", "hold-2"}

	// A lawful hold INSIDE its propagation window must not fail the sweep. Failing every sweep that
	// encounters a hold makes the signal permanently red and therefore ignored; the copy is instead
	// reported outstanding, and TestRetentionController_PermanentHoldGoesOverdue covers the case where
	// it stops being tolerable.
	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("a hold inside its window must not fail the sweep: %v", err)
	}
	if len(res.Outstanding) != 1 || res.Outstanding[0].Disposition != DispositionHeld {
		t.Fatalf("the held copy must be reported outstanding: %+v", res.Outstanding)
	}
	if got := sink.calls.Load(); got != 0 {
		t.Fatalf("the sink was purged %d times despite an active hold", got)
	}
	if res.Dispositions[DispositionHeld] != 1 {
		t.Fatalf("held = %d, want 1", res.Dispositions[DispositionHeld])
	}

	policy, _ := h.ctrl.policies.For("postgres_actors")
	id := NewOperationID("tenant-a", "postgres_actors", policy.Boundary(testNow.Truncate(time.Microsecond)))
	r, found, _ := h.ledger.Get(t.Context(), "tenant-a", id)
	if !found {
		t.Fatal("a held copy must still earn a receipt")
	}
	if len(r.HoldIDs) != 2 {
		t.Errorf("held receipt names %d holds, want 2", len(r.HoldIDs))
	}
	if r.RecordsRemoved != 0 {
		t.Errorf("held receipt claims %d records removed", r.RecordsRemoved)
	}
	if r.Disposition.Complete() {
		t.Fatal("held must not be complete, or a permanent hold becomes indefinite retention the gauge cannot see")
	}
	if r.ComplianceNote != ComplianceNoteHeld {
		t.Errorf("held compliance note = %q", r.ComplianceNote)
	}
}

// TestRetentionController_PermanentHoldGoesOverdue is the fail-open path IterativeDepth surfaced.
func TestRetentionController_PermanentHoldGoesOverdue(t *testing.T) {
	sink := inProcessSink("postgres_actors", 1)
	h := newHarness(t, []Sink{sink})
	h.evaluator.deletable = false
	h.evaluator.holdIDs = []string{"hold-forever"}

	if _, err := h.ctrl.Sweep(t.Context(), "tenant-a"); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	// Now reconcile from far past the deadline. The held copy must be counted overdue, so hold-driven
	// retention is visible as retention rather than hidden behind a lawful-looking disposition.
	future := testNow.Add(DefaultIdentityPeriod + MaxPropagationDelay + 48*time.Hour)
	outstanding, err := h.ledger.Outstanding(t.Context(), "tenant-a", h.ctrl.specs(), future)
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	overdue := Overdue(outstanding, future)
	if len(overdue) != 1 {
		t.Fatalf("overdue = %d, want 1; a permanently held copy must eventually breach its deadline", len(overdue))
	}
	if overdue[0].Disposition != DispositionHeld {
		t.Errorf("overdue disposition = %q, want held", overdue[0].Disposition)
	}
	if overdue[0].OverdueAge(future) <= 0 {
		t.Error("overdue age must be positive")
	}
	// And the gauge separates it from an unreachable backlog.
	m := NewMetrics()
	m.SetOutstanding("tenant-a", outstanding, future)
	if !strings.Contains(m.Render(), `disposition="held"`) {
		t.Error("the gauge must label hold-driven overdue as held, so a DPO sees hold-driven retention as such")
	}
}

func TestRetentionController_HoldSourceErrorFailsClosed(t *testing.T) {
	sink := inProcessSink("postgres_actors", 7)
	h := newHarness(t, []Sink{sink})
	h.evaluator.err = privacy.ErrIncidentStateUnavailable

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("an undetermined hold lookup must not permit a clean sweep")
	}
	if got := sink.calls.Load(); got != 0 {
		t.Fatalf("the sink was purged %d times while hold state was unknown", got)
	}
	if res.Dispositions[DispositionUnreachable] != 1 {
		t.Errorf("a hold-source failure must yield an unreachable receipt, got %+v", res.Dispositions)
	}
	if len(res.Failures) != 1 {
		t.Errorf("failures = %d, want 1", len(res.Failures))
	}
}

func TestRetentionController_PrecedenceIsDelegatedNotReimplemented(t *testing.T) {
	// The precedence rule lives in privacy.Retention. This asserts the controller does not carry a
	// second copy: no comparison of hold release times, no hold-active logic, no HoldKind switch.
	source := mustReadFile(t, "controller.go")
	for _, forbidden := range []string{"ReleasedAt", "Hold.Active", "activeHoldsAt", "HoldKind"} {
		if strings.Contains(source, forbidden) {
			t.Errorf("controller.go references %q; precedence must stay in privacy.Retention or the two copies drift", forbidden)
		}
	}
	if !strings.Contains(source, "c.evaluator.Evaluate(") {
		t.Fatal("the controller no longer calls the evaluator; precedence would be unenforced")
	}
	// And the real privacy.Retention satisfies the interface the controller depends on — a compile-time
	// assertion, so a signature change cannot silently leave the fake as the only implementation.
	var _ Evaluator = (*privacy.Retention)(nil)
}

// ---------------------------------------------------------------------------
// Idempotence — resume after a partial sweep
// ---------------------------------------------------------------------------

func TestRetentionController_ResumeAfterPartialSweepNeitherDoubleCountsNorSkips(t *testing.T) {
	good := inProcessSink("postgres_actors", 4)
	broken := inProcessSink("postgres_aliases", 6)
	broken.err = fmt.Errorf("%w: first attempt", ErrSinkUnreachable)
	h := newHarness(t, []Sink{good, broken})

	// Sweep 1: one sink purges, one is unreachable. A genuine partial sweep.
	first, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("expected the first sweep to be incomplete")
	}
	if first.RecordsRemoved != 4 {
		t.Fatalf("first sweep removed %d, want 4", first.RecordsRemoved)
	}
	if got := good.calls.Load(); got != 1 {
		t.Fatalf("healthy sink purged %d times in sweep 1", got)
	}
	ledgerAfterFirst := h.ledger.Count("tenant-a")
	if ledgerAfterFirst != 2 {
		t.Fatalf("ledger holds %d receipts after sweep 1, want 2 (one purged, one unreachable)", ledgerAfterFirst)
	}

	// Sweep 2: the broken sink recovers.
	broken.err = nil
	second, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("second sweep: %v", err)
	}
	if !second.OK() {
		t.Fatalf("second sweep not OK: %+v", second)
	}

	// NOT SKIPPED: the previously-unreachable sink was retried.
	if got := broken.calls.Load(); got != 2 {
		t.Errorf("the previously-unreachable sink was purged %d times across both sweeps, want 2 (retried)", got)
	}
	// NOT DOUBLE-COUNTED: the already-complete sink was not re-purged.
	if got := good.calls.Load(); got != 1 {
		t.Errorf("the already-complete sink was purged %d times, want 1; a resume must not re-purge and double-count", got)
	}
	if second.RecordsRemoved != 6 {
		t.Errorf("second sweep removed %d, want 6 (only the recovered sink)", second.RecordsRemoved)
	}
	// One ledger row per copy, not per attempt.
	if got := h.ledger.Count("tenant-a"); got != 2 {
		t.Errorf("ledger holds %d receipts after two sweeps over two copies, want 2", got)
	}
	if second.OverdueCount != 0 {
		t.Errorf("overdue after recovery = %d, want 0", second.OverdueCount)
	}
}

func TestRetentionController_RepeatedSweepIsIdempotent(t *testing.T) {
	sink := inProcessSink("postgres_actors", 3)
	h := newHarness(t, []Sink{sink})

	for i := range 5 {
		res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
		if err != nil {
			t.Fatalf("sweep %d: %v", i+1, err)
		}
		if got := h.ledger.Count("tenant-a"); got != 1 {
			t.Fatalf("after sweep %d the ledger holds %d receipts, want 1", i+1, got)
		}
		if i > 0 && res.RecordsRemoved != 0 {
			t.Errorf("sweep %d reported %d records removed; an already-complete copy must not be re-purged", i+1, res.RecordsRemoved)
		}
	}
	if got := sink.calls.Load(); got != 1 {
		t.Fatalf("the sink was purged %d times across 5 sweeps, want 1", got)
	}
}

func TestRetentionController_LedgerFailureIsNotSwallowed(t *testing.T) {
	sink := inProcessSink("postgres_actors", 2)
	h := newHarness(t, []Sink{sink})
	h.ledger.FailNext(errors.New("connection reset"))

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("a ledger failure must not read as a clean sweep: the deletion may have happened and cannot be proven")
	}
	if res.OK() {
		t.Fatal("SweepResult.OK() must be false")
	}
	if len(res.Failures) != 1 {
		t.Fatalf("failures = %d, want 1", len(res.Failures))
	}
	if !strings.Contains(res.Failures["postgres_actors"], "unavailable") {
		t.Errorf("the failure should name unavailability: %q", res.Failures["postgres_actors"])
	}
}

func TestRetentionController_AuditFailureIsSurfaced(t *testing.T) {
	sink := inProcessSink("postgres_actors", 2)
	h := newHarness(t, []Sink{sink})
	h.audit.err = audit.ErrAuditDisabled

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("an audit write failure must be surfaced; an unaudited deletion is unprovable")
	}
	if len(res.Failures) != 1 {
		t.Fatalf("failures = %d, want 1", len(res.Failures))
	}
}

// ---------------------------------------------------------------------------
// Continuity resolution
// ---------------------------------------------------------------------------

func TestRetentionController_ContinuitySinkRequiresBothLinkagePurges(t *testing.T) {
	reidMap := inProcessSink("postgres_segment_reidentification_map", 12)
	subjectKeys := inProcessSink("postgres_subject_keys", 3)
	segmentSpec, _ := SpecByID("parquet_segment_objects")

	ledger := NewMemoryLedger()
	segment, err := NewContinuitySink(segmentSpec, LinkageSinksFor("parquet_segment_objects"), LinkageLookup(ledger))
	if err != nil {
		t.Fatalf("NewContinuitySink: %v", err)
	}

	// Order matters: the continuity sink is swept LAST so its linkage precondition can be satisfied
	// within the same sweep.
	sinks := []Sink{reidMap, subjectKeys, segment}
	policies := PolicySet{TenantID: "tenant-a"}
	for _, s := range sinks {
		spec, _ := SpecByID(s.SinkID())
		policies.Policies = append(policies.Policies, Policy{TenantID: "tenant-a", SinkID: s.SinkID(), Period: spec.DefaultPeriod})
	}
	ctrl, err := NewController(Config{
		Clock: fixedClock{at: testNow}, Ledger: ledger, Evaluator: &fakeEvaluator{deletable: true},
		Audit: &countingAudit{}, Policies: policies, Sinks: sinks, Logger: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewController: %v", err)
	}

	res, err := ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if res.Dispositions[DispositionRetainedUnresolvableToken] != 1 {
		t.Fatalf("retained_unresolvable_token = %d, want 1: %+v", res.Dispositions[DispositionRetainedUnresolvableToken], res.Dispositions)
	}

	policy, _ := policies.For("parquet_segment_objects")
	id := NewOperationID("tenant-a", "parquet_segment_objects", policy.Boundary(testNow.Truncate(time.Microsecond)))
	r, found, _ := ledger.Get(t.Context(), "tenant-a", id)
	if !found {
		t.Fatal("no receipt for the segment sink")
	}
	if len(r.LinkageReceipts) != 2 {
		t.Fatalf("the segment receipt cross-references %d linkage receipts, want 2; without both, the token stays resolvable", len(r.LinkageReceipts))
	}
	if r.RecordsRemoved != 0 || r.PartitionsDropped != 0 {
		t.Error("the continuity sink must report no removals; it deletes nothing")
	}
	if r.ResidualState != ResidualAttestedBytes {
		t.Errorf("residual = %q, want the attested-bytes statement", r.ResidualState)
	}
	if r.ComplianceNote != ComplianceNoteRetainedToken {
		t.Errorf("compliance note = %q", r.ComplianceNote)
	}
	// The note must NOT claim Article 5(1)(e) satisfaction for retained bytes. Recital 26 is the
	// controller's call, and a receipt that asserts it would be overclaiming to a regulator.
	if strings.Contains(r.ComplianceNote, "article_5_1_e_storage_limitation_satisfied") {
		t.Error("the retained-token note must not claim Article 5(1)(e) satisfaction for bytes it kept")
	}
	if !strings.Contains(r.ComplianceNote, "recital_26") {
		t.Error("the retained-token note must hand the Recital 26 assessment to the controller explicitly")
	}
}

func TestRetentionController_ContinuitySinkGoesOverdueWhenLinkagePurgeFails(t *testing.T) {
	// The attested plane is covered by the gate, not excused from it. With the linkage purge broken,
	// the segment sink must go outstanding and eventually overdue.
	reidMap := inProcessSink("postgres_segment_reidentification_map", 0)
	reidMap.err = fmt.Errorf("%w: down", ErrSinkUnreachable)
	subjectKeys := inProcessSink("postgres_subject_keys", 3)
	segmentSpec, _ := SpecByID("parquet_segment_objects")

	ledger := NewMemoryLedger()
	segment, _ := NewContinuitySink(segmentSpec, LinkageSinksFor("parquet_segment_objects"), LinkageLookup(ledger))
	sinks := []Sink{reidMap, subjectKeys, segment}
	policies := PolicySet{TenantID: "tenant-a"}
	for _, s := range sinks {
		spec, _ := SpecByID(s.SinkID())
		policies.Policies = append(policies.Policies, Policy{TenantID: "tenant-a", SinkID: s.SinkID(), Period: spec.DefaultPeriod})
	}
	ctrl, _ := NewController(Config{
		Clock: fixedClock{at: testNow}, Ledger: ledger, Evaluator: &fakeEvaluator{deletable: true},
		Audit: &countingAudit{}, Policies: policies, Sinks: sinks, Logger: discardLogger(),
	})

	res, err := ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("expected an incomplete sweep")
	}
	if res.Dispositions[DispositionRetainedUnresolvableToken] != 0 {
		t.Fatal("the segment sink claimed a retained-token disposition it had not earned")
	}
	if res.Dispositions[DispositionUnreachable] != 2 {
		t.Errorf("unreachable = %d, want 2 (the broken linkage sink and the segment that depends on it)", res.Dispositions[DispositionUnreachable])
	}
}

// ---------------------------------------------------------------------------
// External attestation
// ---------------------------------------------------------------------------

func TestRetentionController_ExternalSinkIsUnreachableUntilAttested(t *testing.T) {
	spec, _ := SpecByID("postgres_physical_backup")
	external := NewExternalSink(spec)
	h := newHarness(t, []Sink{external})

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("an external sink must leave the sweep incomplete until attested")
	}
	if res.Dispositions[DispositionUnreachable] != 1 {
		t.Fatalf("unreachable = %d, want 1", res.Dispositions[DispositionUnreachable])
	}

	// Attest it.
	receipt, err := h.ctrl.SubmitExternalReceipt(t.Context(), ExternalAttestation{
		TenantID: "tenant-a", SinkID: "postgres_physical_backup",
		Attestor: "backup-operator", Records: 1200,
	})
	if err != nil {
		t.Fatalf("SubmitExternalReceipt: %v", err)
	}
	if receipt.Disposition != DispositionPurged {
		t.Errorf("attested disposition = %q, want purged", receipt.Disposition)
	}
	if err := receipt.VerifyDigest(); err != nil {
		t.Errorf("attested receipt does not verify: %v", err)
	}

	// The copy is now complete.
	outstanding, err := h.ctrl.Reconcile(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if len(outstanding) != 0 {
		t.Fatalf("outstanding = %d after attestation, want 0: %+v", len(outstanding), outstanding)
	}
}

func TestRetentionController_ExternalAttestationRefusesWrongReachAndAnonymity(t *testing.T) {
	h := newHarness(t, []Sink{inProcessSink("postgres_actors", 1)})

	// No attestor.
	if _, err := h.ctrl.SubmitExternalReceipt(t.Context(), ExternalAttestation{
		TenantID: "tenant-a", SinkID: "postgres_physical_backup",
	}); err == nil {
		t.Error("an anonymous attestation must be refused")
	}
	// A sink that must be purged in-process cannot be attested away. Otherwise every sink has an
	// off switch.
	if _, err := h.ctrl.SubmitExternalReceipt(t.Context(), ExternalAttestation{
		TenantID: "tenant-a", SinkID: "postgres_actors", Attestor: "someone",
	}); err == nil {
		t.Error("an in-process sink must not be dischargeable by attestation")
	}
	// An unknown sink.
	if _, err := h.ctrl.SubmitExternalReceipt(t.Context(), ExternalAttestation{
		TenantID: "tenant-a", SinkID: "not_a_sink", Attestor: "someone",
	}); err == nil {
		t.Error("an unknown sink must be refused")
	}
}

func TestRetentionController_ExternalAttestationOfAbsenceIsDistinguishable(t *testing.T) {
	spec, _ := SpecByID("redis_shared")
	h := newHarness(t, []Sink{NewExternalSink(spec)})

	receipt, err := h.ctrl.SubmitExternalReceipt(t.Context(), ExternalAttestation{
		TenantID: "tenant-a", SinkID: "redis_shared", Attestor: "platform-operator", Absent: true,
	})
	if err != nil {
		t.Fatalf("SubmitExternalReceipt: %v", err)
	}
	if receipt.Disposition != DispositionAlreadyAbsent {
		t.Fatalf("disposition = %q, want already_absent: 'we checked and there is nothing' must be distinguishable from 'nobody looked'", receipt.Disposition)
	}
	if receipt.RecordsRemoved != 0 {
		t.Errorf("an absence attestation claims %d records removed", receipt.RecordsRemoved)
	}
}

// ---------------------------------------------------------------------------
// Ledger
// ---------------------------------------------------------------------------

func TestRetentionLedger_UpsertsOnOperationID(t *testing.T) {
	l := NewMemoryLedger()
	r, err := validReceipt(t).Seal()
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	for range 3 {
		if err := l.Record(t.Context(), r); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}
	if got := l.Count("tenant-a"); got != 1 {
		t.Fatalf("recording one operation three times produced %d rows, want 1", got)
	}
}

func TestRetentionLedger_RefusesUnsealedAndTamperedReceipts(t *testing.T) {
	l := NewMemoryLedger()
	unsealed := validReceipt(t)
	if err := l.Record(t.Context(), unsealed); !errors.Is(err, ErrLedgerRefused) {
		t.Fatalf("an unsealed receipt must be refused, got %v", err)
	}
	tampered, _ := validReceipt(t).Seal()
	tampered.RecordsRemoved = 9999
	if err := l.Record(t.Context(), tampered); !errors.Is(err, ErrLedgerRefused) {
		t.Fatalf("a tampered receipt must be refused, got %v", err)
	}
}

func TestRetentionLedger_IsTenantScoped(t *testing.T) {
	l := NewMemoryLedger()
	a, _ := validReceipt(t).Seal()

	b := validReceipt(t)
	b.TenantID = "tenant-b"
	b.OperationID = NewOperationID("tenant-b", b.SinkID, b.DroppedBefore)
	bSealed, _ := b.Seal()

	if err := l.Record(t.Context(), a); err != nil {
		t.Fatalf("Record a: %v", err)
	}
	if err := l.Record(t.Context(), bSealed); err != nil {
		t.Fatalf("Record b: %v", err)
	}

	if _, found, _ := l.Get(t.Context(), "tenant-a", bSealed.OperationID); found {
		t.Fatal("tenant-a can read tenant-b's receipt")
	}
	if _, found, _ := l.Get(t.Context(), "tenant-b", a.OperationID); found {
		t.Fatal("tenant-b can read tenant-a's receipt")
	}
	if got := l.Count("tenant-a"); got != 1 {
		t.Errorf("tenant-a holds %d receipts, want 1", got)
	}
	// And a cross-tenant outstanding query does not see the other tenant's completion.
	specs := []SinkSpec{{ID: "postgres_actors", Class: ClassPrimary}}
	out, err := l.Outstanding(t.Context(), "tenant-c", specs, testNow)
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("tenant-c sees %d outstanding copies, want 1: another tenant's receipt must not discharge it", len(out))
	}
}

func TestRetentionLedger_OutstandingClassifiesEveryState(t *testing.T) {
	l := NewMemoryLedger()
	specs := []SinkSpec{
		{ID: "postgres_actors", Class: ClassPrimary},
		{ID: "postgres_aliases", Class: ClassPrimary},
		{ID: "postgres_delegations", Class: ClassPrimary},
		{ID: "postgres_subject_keys", Class: ClassPrimary},
	}

	// actors: complete.
	complete, _ := validReceipt(t).Seal()
	mustRecord(t, l, complete)

	// aliases: unreachable.
	unreachable := validReceipt(t)
	unreachable.SinkID = "postgres_aliases"
	unreachable.Disposition = DispositionUnreachable
	unreachable.RecordsRemoved, unreachable.PartitionsDropped = 0, 0
	unreachable.CompletedAt = time.Time{}
	unreachable.ResidualState = ResidualNotDemonstrated
	unreachable.ComplianceNote = ComplianceNoteUnreachable
	unreachable.OperationID = NewOperationID("tenant-a", "postgres_aliases", unreachable.DroppedBefore)
	sealedUnreachable, err := unreachable.Seal()
	if err != nil {
		t.Fatalf("Seal unreachable: %v", err)
	}
	mustRecord(t, l, sealedUnreachable)

	// delegations: held.
	held := validReceipt(t)
	held.SinkID = "postgres_delegations"
	held.Disposition = DispositionHeld
	held.HoldIDs = []string{"h1"}
	held.RecordsRemoved, held.PartitionsDropped = 0, 0
	held.CompletedAt = time.Time{}
	held.ResidualState = ResidualNotDemonstrated
	held.ComplianceNote = ComplianceNoteHeld
	held.OperationID = NewOperationID("tenant-a", "postgres_delegations", held.DroppedBefore)
	sealedHeld, err := held.Seal()
	if err != nil {
		t.Fatalf("Seal held: %v", err)
	}
	mustRecord(t, l, sealedHeld)

	// subject_keys: never evaluated.

	out, err := l.Outstanding(t.Context(), "tenant-a", specs, testNow)
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	got := make(map[string]Disposition)
	for _, o := range out {
		got[o.SinkID] = o.Disposition
	}
	if _, present := got["postgres_actors"]; present {
		t.Error("a complete copy must not be outstanding")
	}
	if got["postgres_aliases"] != DispositionUnreachable {
		t.Errorf("aliases outstanding as %q, want unreachable", got["postgres_aliases"])
	}
	if got["postgres_delegations"] != DispositionHeld {
		t.Errorf("delegations outstanding as %q, want held", got["postgres_delegations"])
	}
	if d, present := got["postgres_subject_keys"]; !present || d != "" {
		t.Errorf("a never-evaluated copy must be outstanding with an empty disposition, got present=%v d=%q", present, d)
	}
	// A never-evaluated copy must carry a real deadline, not the zero time — OverdueAge would read the
	// zero time as "not overdue" forever, so it would never be counted.
	for _, o := range out {
		if o.SinkID == "postgres_subject_keys" {
			if o.Deadline.IsZero() {
				t.Fatal("a never-evaluated copy has a zero deadline and could never go overdue")
			}
			if !o.Deadline.After(testNow) {
				t.Errorf("a never-evaluated copy's deadline %v is not in the future", o.Deadline)
			}
		}
	}
}

func TestRetentionLedger_CompletedDigestsIsOnePerSink(t *testing.T) {
	l := NewMemoryLedger()
	// Two complete receipts for the SAME sink at different boundaries. CompletedDigests must return one
	// digest for it, not two — otherwise a continuity sink's "len(digests) >= len(linkage)" precondition
	// could be satisfied by a single purged linkage copy counted twice.
	for _, offset := range []time.Duration{0, time.Hour} {
		r := validReceipt(t)
		r.DroppedBefore = r.DroppedBefore.Add(offset)
		r.PropagationDeadline = r.DroppedBefore.Add(MaxPropagationDelay)
		r.OperationID = NewOperationID("tenant-a", r.SinkID, r.DroppedBefore)
		sealed, err := r.Seal()
		if err != nil {
			t.Fatalf("Seal: %v", err)
		}
		mustRecord(t, l, sealed)
	}
	digests, err := l.CompletedDigests(t.Context(), "tenant-a", []string{"postgres_actors", "postgres_subject_keys"})
	if err != nil {
		t.Fatalf("CompletedDigests: %v", err)
	}
	if len(digests) != 1 {
		t.Fatalf("CompletedDigests returned %d digests for one purged sink, want 1: %v", len(digests), digests)
	}
}

func mustRecord(t *testing.T, l *MemoryLedger, r DeletionReceipt) {
	t.Helper()
	if err := l.Record(t.Context(), r); err != nil {
		t.Fatalf("Record %s: %v", r.SinkID, err)
	}
}

// ---------------------------------------------------------------------------
// Metrics — observed firing
// ---------------------------------------------------------------------------

func TestRetentionMetrics_RendersZeroNotAbsent(t *testing.T) {
	m := NewMetrics()
	out := m.Render()
	for _, want := range []string{
		"signalloom_retention_overdue_objects",
		"signalloom_retention_outstanding_objects",
		"signalloom_retention_receipts_total",
		"signalloom_retention_sweeps_total 0",
		"signalloom_retention_clock_untrusted_total 0",
		"signalloom_retention_last_successful_sweep_unix 0",
		"signalloom_retention_overdue_age_seconds_max 0",
		"signalloom_retention_state_unknown 0",
		`signalloom_retention_retained_past_period{sink=""} 0`,
		`signalloom_retention_receipts_total{disposition="unreachable"} 0`,
		"# TYPE signalloom_retention_overdue_objects gauge",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("zeroed metrics are missing %q; an absent series reads as 'this subsystem does not exist'", want)
		}
	}
	// Every disposition renders even at zero.
	for _, d := range allDispositions {
		if !strings.Contains(out, fmt.Sprintf(`disposition=%q`, string(d))) {
			t.Errorf("receipts_total does not render disposition %q at zero", d)
		}
	}
}

// TestRetentionMetrics_GaugeRisesFromLedgerAlone is the falsification of the most plausible way this
// control ships green and useless.
func TestRetentionMetrics_GaugeRisesFromLedgerAlone(t *testing.T) {
	m := NewMetrics()
	if got := m.OverdueCount(); got != 0 {
		t.Fatalf("a fresh gauge reads %d", got)
	}
	// NO SWEEP. The overdue entry is injected into the outstanding set the ledger would return, which is
	// the only input SetOutstanding takes. A gauge computed from the sweep's own working memory could
	// not move here, and would therefore pass every test while detecting nothing.
	deadline := testNow.Add(-6 * time.Hour)
	m.SetOutstanding("tenant-a", []Outstanding{{
		TenantID: "tenant-a", SinkID: "postgres_physical_backup", SinkClass: string(ClassBackup),
		Disposition: DispositionUnreachable, Deadline: deadline,
	}}, testNow)

	if got := m.OverdueCount(); got != 1 {
		t.Fatalf("overdue gauge = %d after injecting one overdue copy with no sweep, want 1", got)
	}
	if got := m.OverdueForSink("tenant-a", "postgres_physical_backup"); got != 1 {
		t.Fatalf("per-sink overdue = %d, want 1", got)
	}
	out := m.Render()
	if !strings.Contains(out, `signalloom_retention_overdue_objects{tenant="tenant-a",sink="postgres_physical_backup",disposition="unreachable",reach="external_attestation"} 1`) {
		t.Fatalf("the rendered gauge does not name the overdue sink:\n%s", out)
	}
	if !strings.Contains(out, "signalloom_retention_overdue_age_seconds_max 21600") {
		t.Errorf("the worst-breach gauge is wrong:\n%s", out)
	}

	// And it returns to zero once the copy is discharged — a gauge that never clears trains operators
	// to ignore it.
	m.SetOutstanding("tenant-a", nil, testNow)
	if got := m.OverdueCount(); got != 0 {
		t.Fatalf("overdue gauge = %d after the copy was discharged, want 0", got)
	}
	if !strings.Contains(m.Render(), `signalloom_retention_overdue_objects{tenant="",sink="",disposition="",reach=""} 0`) {
		t.Error("a cleared gauge must still render a zero series")
	}
}

// TestRetentionMetrics_ReachSeparatesDefectFromCoverageGap keeps the gauge alertable.
//
// Eleven of the thirty-five sinks have no in-process purger, so an unlabelled gauge has a permanent
// non-zero floor. An alert threshold set above that floor hides every real in-process failure
// underneath it, which is how a well-built control becomes ignored within a month.
func TestRetentionMetrics_ReachSeparatesDefectFromCoverageGap(t *testing.T) {
	m := NewMetrics()
	m.SetOutstanding("tenant-a", []Outstanding{
		{TenantID: "tenant-a", SinkID: "postgres_actors", Disposition: DispositionUnreachable, Deadline: testNow.Add(-time.Hour)},
		{TenantID: "tenant-a", SinkID: "postgres_physical_backup", Disposition: DispositionUnreachable, Deadline: testNow.Add(-time.Hour)},
	}, testNow)
	out := m.Render()
	if !strings.Contains(out, `sink="postgres_actors",disposition="unreachable",reach="in_process"`) {
		t.Errorf("an in-process failure must be labelled in_process — it is the alertable one:\n%s", out)
	}
	if !strings.Contains(out, `sink="postgres_physical_backup",disposition="unreachable",reach="external_attestation"`) {
		t.Errorf("a missing external attestation must be labelled external_attestation — it is a coverage gap, not a defect:\n%s", out)
	}
}

// TestRetentionMetrics_RetainedResidualStaysOnScreen closes the clean-gauge-with-live-bytes path.
//
// retained_unresolvable_token is a COMPLETE disposition, so those copies leave the outstanding set and
// the overdue gauge reads zero for them. A dashboard showing only the overdue gauge would therefore say
// "expired data remaining: 0" while the attested bytes are still on disk. This gauge is permanently
// non-zero once the attested plane is swept, by design.
func TestRetentionMetrics_RetainedResidualStaysOnScreen(t *testing.T) {
	m := NewMetrics()
	r := validReceipt(t)
	r.Disposition = DispositionRetainedUnresolvableToken
	r.SinkID = "parquet_segment_objects"
	r.LinkageReceipts = []string{"a", "b"}
	r.RecordsRemoved, r.PartitionsDropped = 0, 0
	m.ObserveReceipt(r)

	out := m.Render()
	if !strings.Contains(out, `signalloom_retention_retained_past_period{sink="parquet_segment_objects"} 1`) {
		t.Fatalf("the retained residual is invisible; a dashboard would read 'expired data remaining: 0':\n%s", out)
	}
	if m.OverdueCount() != 0 {
		t.Error("a retained token is not overdue — that is exactly why the separate gauge is needed")
	}
}

// TestRetentionMetrics_ClockRefusalDoesNotFreezeACleanGauge closes the fail-silent detection path.
func TestRetentionMetrics_ClockRefusalDoesNotFreezeACleanGauge(t *testing.T) {
	m := NewMetrics()
	// Matched on a whole line, not a substring. The first draft of this test asserted
	// Contains(render, "signalloom_retention_state_unknown 1") and failed, because the metric's own HELP
	// text contained that literal — prose satisfying a metric-value assertion. Both the wording and the
	// matcher were fixed; appeasing the guard by rewording alone would have left the guard wrong.
	m.ObserveSuccessfulSweep(testNow)
	if got := metricLine(m.Render(), "signalloom_retention_state_unknown"); got != "0" {
		t.Fatalf("state_unknown = %q after a successful sweep, want 0", got)
	}
	m.ObserveClockUntrusted()
	if got := metricLine(m.Render(), "signalloom_retention_state_unknown"); got != "1" {
		t.Fatalf("state_unknown = %q after a clock refusal, want 1: a clock refusal left the previous clean "+
			"gauge standing with no signal, and fail-closed on purging must not mean fail-silent on detection", got)
	}
	// And it clears on the next successful reconciliation, so the alert is actionable rather than sticky.
	m.ObserveSuccessfulSweep(testNow.Add(time.Hour))
	if got := metricLine(m.Render(), "signalloom_retention_state_unknown"); got != "0" {
		t.Errorf("state_unknown = %q after recovery, want 0", got)
	}
}

// TestRetentionReceipt_RetainedTokenNoteNamesItsPrecondition is the anti-euphemism guard.
//
// The segment pseudonym is a KEYED HMAC (identity.NewPseudonymKeyRing), not a random surrogate. While
// the epoch key exists, anyone holding it regenerates the map by enumerating a low-entropy actor-ID
// space, so purging the re-identification index destroys a convenience index and not the linkage.
// "Unresolvable" is therefore CONDITIONAL, and a compliance note that does not say so is the point at
// which a truthful disposition becomes a euphemism.
func TestRetentionReceipt_RetainedTokenNoteNamesItsPrecondition(t *testing.T) {
	for _, required := range []string{"keyed_hmac", "CONDITIONAL", "pseudonym_key_epoch", "pitr", "recital_26", "any_other_person"} {
		if !strings.Contains(ComplianceNoteRetainedToken, required) {
			t.Errorf("the retained-token compliance note does not name %q; an unnamed precondition is how this becomes a euphemism", required)
		}
	}
	if strings.Contains(ResidualAttestedBytes, "linkage_destroyed") {
		t.Error("the residual claims the linkage was destroyed; the key epoch and PITR window retain regenerable linkage")
	}
	if !strings.Contains(ResidualAttestedBytes, "regenerable") {
		t.Error("the residual must state that the linkage remains regenerable")
	}
}

func TestRetentionMetrics_NeverEvaluatedIsLabelledDistinctly(t *testing.T) {
	m := NewMetrics()
	m.SetOutstanding("tenant-a", []Outstanding{{
		TenantID: "tenant-a", SinkID: "postgres_subject_keys", Deadline: testNow.Add(-time.Hour),
	}}, testNow)
	if !strings.Contains(m.Render(), `disposition="never_evaluated"`) {
		t.Error("a copy with no receipt must be labelled never_evaluated, not lumped in with an empty label")
	}
}

func TestRetentionMetrics_ObservedFiringThroughTheRealController(t *testing.T) {
	// End to end: a deliberately held copy, reconciled past its deadline, raises the gauge served by the
	// controller's own registry. This is the card's required evidence that the metric fires.
	sink := inProcessSink("postgres_actors", 1)
	held := &fixedClock{at: testNow}
	h := newHarness(t, []Sink{sink}, func(c *Config) { c.Clock = held })
	h.evaluator.deletable = false
	h.evaluator.holdIDs = []string{"hold-deliberate"}

	if _, err := h.ctrl.Sweep(t.Context(), "tenant-a"); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if got := h.ctrl.Metrics().OverdueCount(); got != 0 {
		t.Fatalf("overdue = %d immediately after the hold; the deadline has not passed yet", got)
	}

	// Advance the clock past the deadline and reconcile — no sweep.
	held.at = testNow.Add(DefaultIdentityPeriod + MaxPropagationDelay + time.Hour)
	if _, err := h.ctrl.Reconcile(t.Context(), "tenant-a"); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if got := h.ctrl.Metrics().OverdueCount(); got != 1 {
		t.Fatalf("overdue = %d after the deadline passed, want 1: the gauge did not fire", got)
	}
	rendered := h.ctrl.Metrics().Render()
	if !strings.Contains(rendered, `sink="postgres_actors",disposition="held"`) {
		t.Errorf("the gauge does not attribute the breach:\n%s", rendered)
	}
	t.Logf("observed overdue gauge firing:\n%s", extractMetric(rendered, "signalloom_retention_overdue_objects"))
}

func TestRetentionController_OverdueIsLoggedWithSinkAndAge(t *testing.T) {
	var captured strings.Builder
	logger := slog.New(slog.NewTextHandler(&captured, &slog.HandlerOptions{Level: slog.LevelWarn}))

	sink := inProcessSink("postgres_actors", 1)
	clock := &fixedClock{at: testNow}
	h := newHarness(t, []Sink{sink}, func(c *Config) {
		c.Clock = clock
		c.Logger = logger
	})
	h.evaluator.deletable = false
	h.evaluator.holdIDs = []string{"hold-1"}

	if _, err := h.ctrl.Sweep(t.Context(), "tenant-a"); err != nil {
		t.Fatalf("first sweep: %v", err)
	}
	clock.at = testNow.Add(DefaultIdentityPeriod + MaxPropagationDelay + 5*time.Hour)
	// Past the deadline the same hold DOES fail the sweep, which is what stops a permanent hold from
	// becoming invisible indefinite retention.
	if _, err := h.ctrl.Sweep(t.Context(), "tenant-a"); err == nil {
		t.Fatal("a held copy past its deadline must fail the sweep")
	}

	logged := captured.String()
	for _, want := range []string{"retention deadline breached", "sink=postgres_actors", "overdue_age=", "disposition=held", "tenant=tenant-a"} {
		if !strings.Contains(logged, want) {
			t.Errorf("the breach log is missing %q; on-call needs a first move:\n%s", want, logged)
		}
	}
}

// metricLine returns the value of an unlabelled metric, matching a whole sample line rather than a
// substring so a HELP or TYPE comment mentioning the name cannot satisfy the assertion.
func metricLine(rendered, name string) string {
	for _, line := range strings.Split(rendered, "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		if fields := strings.Fields(line); len(fields) == 2 && fields[0] == name {
			return fields[1]
		}
	}
	return ""
}

// extractMetric pulls the lines for one metric family, for readable test logs.
func extractMetric(rendered, name string) string {
	var out []string
	for _, line := range strings.Split(rendered, "\n") {
		if strings.HasPrefix(line, name) {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// ---------------------------------------------------------------------------
// Acceptance gate — and its falsification
// ---------------------------------------------------------------------------

func TestRetentionAcceptanceGate_PassesOnACleanLedger(t *testing.T) {
	sinks := []Sink{inProcessSink("postgres_actors", 2), inProcessSink("postgres_aliases", 0)}
	h := newHarness(t, sinks)

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	report := AcceptanceGate(res.Outstanding, len(sinks), res.EvaluatedAt, "tenant-a")
	if err := report.Err(); err != nil {
		t.Fatalf("gate failed on a clean sweep: %v", err)
	}
	if report.Evaluated != 2 {
		t.Errorf("gate evaluated %d copies, want 2", report.Evaluated)
	}
	if report.OverdueCount != 0 {
		t.Errorf("overdue = %d", report.OverdueCount)
	}
	t.Logf("acceptance gate: evaluated=%d overdue=%d outstanding=%d summary=%s",
		report.Evaluated, report.OverdueCount, report.OutstandingCount, report.Summary())
}

// TestRetentionAcceptanceGate_FailsOnAnyOverdueObject proves the gate can fail.
//
// A gate that has never been observed failing is not a gate.
func TestRetentionAcceptanceGate_FailsOnAnyOverdueObject(t *testing.T) {
	overdue := []Outstanding{{
		TenantID: "tenant-a", SinkID: "application_container_logs", SinkClass: string(ClassExport),
		Disposition: DispositionUnreachable, Deadline: testNow.Add(-90 * time.Minute),
	}}
	report := AcceptanceGate(overdue, 35, testNow, "tenant-a")
	err := report.Err()
	if err == nil {
		t.Fatal("the gate passed with an overdue copy; it cannot fail and is therefore not a gate")
	}
	if !errors.Is(err, ErrGateOverdue) {
		t.Fatalf("error should wrap ErrGateOverdue: %v", err)
	}
	for _, want := range []string{"application_container_logs", "unreachable", "overdue by"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the gate failure should name %q: %v", want, err)
		}
	}
	t.Logf("gate falsification: %v", err)
}

// TestRetentionAcceptanceGate_RefusesToPassVacuously is the anti-criterion for the gate itself.
func TestRetentionAcceptanceGate_RefusesToPassVacuously(t *testing.T) {
	report := AcceptanceGate(nil, 0, testNow, "tenant-a")
	err := report.Err()
	if err == nil {
		t.Fatal("the gate passed having evaluated nothing; zero overdue out of zero copies is not a pass")
	}
	if !errors.Is(err, ErrGateVacuous) {
		t.Fatalf("error should wrap ErrGateVacuous: %v", err)
	}
}

// TestRetentionAcceptanceGate_FullInventoryHasZeroOverdueWhenAttested is the card's required evidence:
// zero overdue copies across EVERY sink.
func TestRetentionAcceptanceGate_FullInventoryHasZeroOverdueWhenAttested(t *testing.T) {
	ledger := NewMemoryLedger()
	specs := AllSinkSpecs()

	var sinks []Sink
	for _, spec := range specs {
		switch spec.Reach {
		case ReachInProcess:
			s, err := NewRowSink(spec, func(_ context.Context, _ string, _ time.Time) (int64, error) { return 2, nil })
			if err != nil {
				t.Fatalf("NewRowSink %s: %v", spec.ID, err)
			}
			sinks = append(sinks, s)
		case ReachContinuityBearing:
			s, err := NewContinuitySink(spec, LinkageSinksFor(spec.ID), LinkageLookup(ledger))
			if err != nil {
				t.Fatalf("NewContinuitySink %s: %v", spec.ID, err)
			}
			sinks = append(sinks, s)
		case ReachExternalAttestation:
			sinks = append(sinks, NewExternalSink(spec))
		}
	}
	if len(sinks) != len(specs) {
		t.Fatalf("built %d sinks for %d specs", len(sinks), len(specs))
	}

	clock := &fixedClock{at: testNow}
	ctrl, err := NewController(Config{
		Clock: clock, Ledger: ledger, Evaluator: &fakeEvaluator{deletable: true},
		Audit: &countingAudit{}, Policies: DefaultPolicySet("tenant-a"), Sinks: sinks, Logger: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewController over the full inventory: %v", err)
	}

	// Sweep 1: in-process sinks purge; continuity sinks satisfy their linkage; external sinks are
	// unreachable, exactly as designed.
	first, err := ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("the first sweep must be incomplete: eleven copies are only dischargeable by external attestation")
	}
	externalCount := 0
	for _, spec := range specs {
		if spec.Reach == ReachExternalAttestation {
			externalCount++
		}
	}
	if first.Dispositions[DispositionUnreachable] != externalCount {
		t.Errorf("unreachable = %d, want %d (every external sink)", first.Dispositions[DispositionUnreachable], externalCount)
	}
	t.Logf("sweep 1 over the full %d-sink inventory: purged=%d already_absent=%d retained_token=%d unreachable=%d records=%d",
		len(specs), first.Dispositions[DispositionPurged], first.Dispositions[DispositionAlreadyAbsent],
		first.Dispositions[DispositionRetainedUnresolvableToken], first.Dispositions[DispositionUnreachable], first.RecordsRemoved)

	// Attest every external copy, which is the deployment contract P6-2 inherits.
	for _, spec := range specs {
		if spec.Reach != ReachExternalAttestation {
			continue
		}
		if _, err := ctrl.SubmitExternalReceipt(t.Context(), ExternalAttestation{
			TenantID: "tenant-a", SinkID: spec.ID, Attestor: "retention-operator", Records: 1,
		}); err != nil {
			t.Fatalf("attest %s: %v", spec.ID, err)
		}
	}

	outstanding, err := ctrl.Reconcile(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	report := AcceptanceGate(outstanding, len(specs), testNow, "tenant-a")
	if err := report.Err(); err != nil {
		t.Fatalf("the acceptance gate failed over the fully-attested inventory: %v", err)
	}
	if got := ctrl.Metrics().OverdueCount(); got != 0 {
		t.Fatalf("overdue = %d across the full inventory, want 0", got)
	}
	t.Logf("ACCEPTANCE GATE over all %d sinks: evaluated=%d overdue=%d outstanding=%d",
		len(specs), report.Evaluated, report.OverdueCount, report.OutstandingCount)
	t.Logf("overdue gauge:\n%s", extractMetric(ctrl.Metrics().Render(), "signalloom_retention_overdue_objects"))

	// Now withhold ONE attestation and prove the gate turns red. Same fixture, one variable changed.
	freshLedger := NewMemoryLedger()
	ctrl2, err := NewController(Config{
		Clock: clock, Ledger: freshLedger, Evaluator: &fakeEvaluator{deletable: true},
		Audit: &countingAudit{}, Policies: DefaultPolicySet("tenant-a"), Sinks: sinks, Logger: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewController: %v", err)
	}
	if _, err := ctrl2.Sweep(t.Context(), "tenant-a"); err == nil {
		t.Fatal("expected incomplete")
	}
	withheld := "postgres_physical_backup"
	for _, spec := range specs {
		if spec.Reach != ReachExternalAttestation || spec.ID == withheld {
			continue
		}
		if _, err := ctrl2.SubmitExternalReceipt(t.Context(), ExternalAttestation{
			TenantID: "tenant-a", SinkID: spec.ID, Attestor: "retention-operator", Records: 1,
		}); err != nil {
			t.Fatalf("attest %s: %v", spec.ID, err)
		}
	}
	clock.at = testNow.Add(DefaultBackupPeriod + MaxPropagationDelay + 24*time.Hour)
	out2, err := ctrl2.Reconcile(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	report2 := AcceptanceGate(out2, len(specs), clock.at, "tenant-a")
	if err := report2.Err(); err == nil {
		t.Fatalf("withholding the %s attestation did not fail the gate", withheld)
	} else {
		t.Logf("gate falsification with one withheld attestation: %v", err)
	}
	if !strings.Contains(report2.Summary(), withheld) {
		t.Errorf("the gate summary does not name the withheld sink: %s", report2.Summary())
	}
	clock.at = testNow
}

// TestRetentionController_DefaultSinkSetIsTheRealInventory closes the fixture-only loophole.
func TestRetentionController_DefaultSinkSetIsTheRealInventory(t *testing.T) {
	// DefaultPolicySet must cover exactly AllSinkIDs, so a controller built from the defaults sweeps the
	// real inventory rather than whatever a test happened to pass.
	set := DefaultPolicySet("tenant-a")
	if len(set.Policies) != len(AllSinkSpecs()) {
		t.Fatalf("DefaultPolicySet has %d policies for %d sinks", len(set.Policies), len(AllSinkSpecs()))
	}
	if err := set.Validate(AllSinkIDs()); err != nil {
		t.Fatalf("DefaultPolicySet does not cover the inventory: %v", err)
	}
	// And a controller over a two-sink fixture must NOT validate against the full inventory, which is
	// what makes the check above meaningful rather than decorative.
	partial := PolicySet{TenantID: "tenant-a", Policies: set.Policies[:2]}
	if err := partial.Validate(AllSinkIDs()); err == nil {
		t.Fatal("a two-policy set validated against the full inventory; the completeness check is not working")
	}
}

// TestRetentionReaper_RefusesFailOpenConstruction covers the background worker.
func TestRetentionReaper_RefusesFailOpenConstruction(t *testing.T) {
	h := newHarness(t, []Sink{inProcessSink("postgres_actors", 1)})
	if _, err := NewReaper(nil, func() []string { return nil }, time.Minute, discardLogger()); err == nil {
		t.Error("a reaper with no controller must be refused")
	}
	if _, err := NewReaper(h.ctrl, nil, time.Minute, discardLogger()); err == nil {
		t.Error("a reaper with no tenant source must be refused: it would sweep nothing and report no error")
	}
	r, err := NewReaper(h.ctrl, func() []string { return []string{"tenant-a"} }, 0, discardLogger())
	if err != nil {
		t.Fatalf("NewReaper: %v", err)
	}
	// Start is idempotent and Stop is safe to call once.
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	r.Start(ctx)
	r.Start(ctx)
	r.Stop()
	r.Stop()
}
