package privacy

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// =============================================================================================
// THE ABUSE CASE
//
// This is the test the card exists for. A compromised or coerced operator invokes Article 17
// erasure against an actor that is under ACTIVE CONTAINMENT because of a live security incident.
// Erasure destroys that actor's key and with it the forensic attribution for the incident.
//
// The destroyer is a tripwire: if any part of the gate touches key material on this path, the test
// fails with a message naming the failure, regardless of what the assertions below check.
// =============================================================================================

func TestErasureHold_ContainedActorErasureIsRefused(t *testing.T) {
	const subject = "spiffe://signalloom.test/ns/default/sa/compromised-agent"
	seq := &sequenceRecorder{}
	fx := newTripwireFixture(t, availableSource(seq, containmentHold(subject)))

	decision, err := fx.svc.Erase(context.Background(), baseRequest(subject))

	if err == nil {
		t.Fatal("erasure of an actor under active containment SUCCEEDED; the legal hold did not block it")
	}
	if !errors.Is(err, ErrLegalHold) {
		t.Fatalf("want ErrLegalHold, got %v", err)
	}
	if decision.Permitted {
		t.Error("decision reports permitted=true on a refused erasure")
	}
	if decision.Outcome != OutcomeRefusedLegalHold {
		t.Errorf("outcome = %q, want %q", decision.Outcome, OutcomeRefusedLegalHold)
	}

	// The refusal must be actionable, not merely negative. An operator reading it has to be able
	// to tell WHAT blocked them and WHAT would unblock them; otherwise a silent block is
	// indistinguishable from a broken feature and they route around the control.
	if len(decision.HoldIDs) != 1 || decision.HoldIDs[0] != "quarantine:"+subject {
		t.Errorf("refusal does not name the blocking hold: %v", decision.HoldIDs)
	}
	if decision.RequiredGround != GroundLegalClaims {
		t.Errorf("refusal does not name the Article 17(3) ground that would permit an override: %q", decision.RequiredGround)
	}
	if decision.Holds[0].Kind != HoldActiveContainment {
		t.Errorf("hold kind = %q, want %q", decision.Holds[0].Kind, HoldActiveContainment)
	}
	if decision.Holds[0].IncidentRef == "" {
		t.Error("refusal does not name the incident the hold derives from")
	}

	// The refusal reached the audit trail. A refusal that leaves no trace is indistinguishable from
	// a request that was never made, which is an Article 12 problem of its own.
	if !decision.AuditRecorded {
		t.Error("decision reports the refusal was not recorded")
	}
	if got := len(fx.auditLog.Events()); got != 1 {
		t.Fatalf("wrote %d audit events, want exactly 1", got)
	}

	// Nothing reached key material. The tripwire already guarantees this; the trace assertion is
	// the independent second witness, because a tripwire proves the destroyer was not CALLED while
	// the trace proves the code never reached the phase.
	if idx := decision.TraceIndex(TraceDestroyKeys); idx != -1 {
		t.Errorf("trace contains the key-destruction phase at index %d on a refused erasure: %v", idx, decision.Trace)
	}
	if seq.indexOf(seqKeyDestroyed) != -1 {
		t.Errorf("the key destroyer was observed being called on a refused erasure: %v", seq.events)
	}
}

// TestErasureHold_ContainedActorRefusalNamesRemediation asserts the discoverability half
// separately from the refusal half.
//
// These are split because they fail for different reasons: the refusal can be correct while the
// message is useless, and a single test asserting both would let a regression in the message hide
// behind a passing refusal.
func TestErasureHold_ContainedActorRefusalIsDiscoverable(t *testing.T) {
	const subject = "actor-contained"
	seq := &sequenceRecorder{}
	fx := newTripwireFixture(t, availableSource(seq, containmentHold(subject)))

	decision, _ := fx.svc.Erase(context.Background(), baseRequest(subject))

	detail := auditDetail(t, fx.auditLog, 0)
	for _, key := range []string{"category", "outcome", "reason", "hold_ids", "required_ground", "required_ground_description", "subject_pseudonym", "trace"} {
		if _, ok := detail[key]; !ok {
			t.Errorf("refusal audit detail is missing %q; an operator auditing refusals cannot act on it", key)
		}
	}
	if detail["outcome"] != string(OutcomeRefusedLegalHold) {
		t.Errorf("audit outcome = %v, want %q", detail["outcome"], OutcomeRefusedLegalHold)
	}
	if desc, _ := detail["required_ground_description"].(string); !strings.Contains(desc, "Article 17(3)(e)") {
		t.Errorf("audit does not spell out the Article 17(3) ground: %v", detail["required_ground_description"])
	}

	// The cleartext subject must NOT appear in the audit record. An audit trail of refused erasures
	// is a list of the exact identifiers people asked to have removed; storing them in the clear
	// turns the transparency mechanism into a re-identification corpus.
	//
	// Asserting the pseudonym is present is not enough on its own — a record carrying both would
	// satisfy it. This checks the cleartext is ABSENT from the whole serialised detail.
	raw := string(fx.auditLog.Events()[0].Detail)
	if strings.Contains(raw, `"`+subject+`"`) {
		t.Errorf("audit detail carries the cleartext subject %q: %s", subject, raw)
	}
	if !strings.Contains(decision.SubjectPseudonym, "pseudo(") {
		t.Errorf("decision subject is not pseudonymised: %q", decision.SubjectPseudonym)
	}
}

// =============================================================================================
// ORDERING — the hold check precedes any key operation
// =============================================================================================

// TestErasureHold_OrderingHoldCheckPrecedesKeyDestruction observes the real call sequence.
//
// The assertion is on a recorder SHARED between the incident source and the key destroyer, not on
// Decision.Trace. That distinction is the whole value of this test: Decision.Trace is populated by
// the code under test, so asserting on it proves the code says the phases ran in order. The shared
// recorder is populated by the doubles, so it proves they were CALLED in order. A trace field that
// is always correct and a call order that is always correct are different claims, and only the
// second one stops evidence being destroyed.
func TestErasureHold_OrderingHoldCheckPrecedesKeyDestruction(t *testing.T) {
	seq := &sequenceRecorder{}
	fx := newServiceFixture(t, availableSource(seq), seq)

	decision, err := fx.svc.Erase(context.Background(), baseRequest("actor-clean"))
	if err != nil {
		t.Fatalf("unheld erasure failed: %v", err)
	}
	if !decision.Permitted {
		t.Fatal("unheld erasure was not permitted")
	}

	incidentIdx := seq.indexOf(seqIncidentRead)
	destroyIdx := seq.indexOf(seqKeyDestroyed)
	if incidentIdx == -1 {
		t.Fatal("the incident source was never consulted; the hold gate did not run at all")
	}
	if destroyIdx == -1 {
		t.Fatal("the key destroyer was never called on a permitted erasure")
	}
	if incidentIdx >= destroyIdx {
		t.Fatalf("OBSERVED CALL ORDER IS WRONG: incident source at %d, key destroyer at %d (%v). "+
			"A hold check that runs at or after key destruction cannot prevent it.", incidentIdx, destroyIdx, seq.events)
	}

	// Second witness, from the production code's own trace.
	traceHold := decision.TraceIndex(TraceEvaluateHold)
	traceDestroy := decision.TraceIndex(TraceDestroyKeys)
	if traceHold == -1 || traceDestroy == -1 || traceHold >= traceDestroy {
		t.Errorf("decision trace does not place hold evaluation before key destruction: %v", decision.Trace)
	}

	// The audit write also precedes destruction, so a destruction can never go unrecorded.
	traceAudit := decision.TraceIndex(TraceWriteAudit)
	if traceAudit == -1 || traceAudit >= traceDestroy {
		t.Errorf("decision trace does not place the audit write before key destruction: %v", decision.Trace)
	}

	if fx.destroyer.calls != 1 {
		t.Errorf("key destroyer called %d times, want exactly 1", fx.destroyer.calls)
	}
	if decision.Receipt == nil {
		t.Error("permitted erasure carries no destruction receipt")
	}
}

// =============================================================================================
// FAIL CLOSED — unavailable incident state refuses
// =============================================================================================

func TestErasureHold_UnavailableIncidentStateRefuses(t *testing.T) {
	seq := &sequenceRecorder{}
	fx := newTripwireFixture(t, unavailableSource(seq))

	decision, err := fx.svc.Erase(context.Background(), baseRequest("actor-unknown"))

	if err == nil {
		t.Fatal("erasure PROCEEDED while incident state was unavailable; the hold failed open")
	}
	if !errors.Is(err, ErrIncidentStateUnavailable) {
		t.Fatalf("want ErrIncidentStateUnavailable, got %v", err)
	}
	// The refusal reasons must stay distinguishable. "We know you are held", "we do not know whether
	// you are held", and "nobody was configured to look" produce different HTTP statuses and demand
	// different operator action — get two signatures, page the incident-database owner, or fix the
	// deployment.
	if errors.Is(err, ErrLegalHold) {
		t.Error("unavailable incident state is reported as a legal hold; the two sentinels have collapsed")
	}
	// A source that ERRORED is not a source that DECLINED. This assertion is what makes the
	// error-handling arm independently provable: without it, deleting the error check lets control
	// fall through to the jurisdiction check, which refuses for the wrong reason and sends an
	// operator to fix a configuration problem that does not exist.
	if errors.Is(err, ErrNoJurisdiction) {
		t.Error("an incident-source OUTAGE is being reported as a missing-jurisdiction configuration problem; " +
			"the operator would be sent to fix the wrong thing")
	}
	if decision.Outcome != OutcomeRefusedIncidentStateUnavailable {
		t.Errorf("outcome = %q, want %q", decision.Outcome, OutcomeRefusedIncidentStateUnavailable)
	}
	if !decision.AuditRecorded {
		t.Error("the fail-closed refusal was not recorded")
	}
	if seq.indexOf(seqKeyDestroyed) != -1 {
		t.Error("the key destroyer was reached while incident state was unavailable")
	}
}

// TestErasureHold_NoJurisdictionRefuses covers the case the package's own doc comment identified as
// a defect one level up: a source that DECLINED to answer is not a source that found nothing.
func TestErasureHold_NoJurisdictionRefuses(t *testing.T) {
	seq := &sequenceRecorder{}
	// jurisdiction:false with zero holds and a nil error — the exact shape that, under a plain
	// ([]Hold, error) contract, would be indistinguishable from "determined: no holds".
	declining := &fakeIncidentSource{jurisdiction: false, seq: seq}
	fx := newTripwireFixture(t, declining)

	_, err := fx.svc.Erase(context.Background(), baseRequest("actor-other-tenant"))
	if err == nil {
		t.Fatal("erasure PROCEEDED although no incident source had jurisdiction; 'did not look' was read as 'found nothing'")
	}
	if !errors.Is(err, ErrNoJurisdiction) {
		t.Errorf("want ErrNoJurisdiction, got %v", err)
	}
	if !errors.Is(err, ErrIncidentStateUnavailable) {
		t.Errorf("no-jurisdiction must also present as unavailable to callers matching on it: %v", err)
	}
}

func TestErasureHold_ContextCancellationRefuses(t *testing.T) {
	seq := &sequenceRecorder{}
	source := &fakeIncidentSource{err: context.Canceled, seq: seq}
	fx := newTripwireFixture(t, source)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := fx.svc.Erase(ctx, baseRequest("actor-cancelled"))
	if err == nil {
		t.Fatal("erasure proceeded after context cancellation during the incident lookup")
	}
	if !errors.Is(err, ErrIncidentStateUnavailable) {
		t.Errorf("want ErrIncidentStateUnavailable, got %v", err)
	}
}

// =============================================================================================
// FAIL CLOSED — audit unavailable refuses, and never destroys
// =============================================================================================

func TestErasureHold_AuditFailureRefusesAndDoesNotDestroy(t *testing.T) {
	seq := &sequenceRecorder{}
	ops := []testOperator{newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")}
	auditLog := audit.NewFakeWriter()
	auditLog.FailWith = errors.New("audit database unreachable")

	// The audit writer must be healthy at construction, so build the service first, then break it.
	// Building it broken would test the constructor, not the runtime path.
	healthy := audit.NewFakeWriter()
	svc, err := NewService(Config{
		Incidents:     availableSource(seq),
		Destroyer:     tripwireDestroyer{t: t},
		Audit:         healthy,
		Operators:     registryOf(t, ops...),
		Pseudonymiser: fakePseudonymiser{},
		Now:           fixedClock(testNow),
	})
	if err != nil {
		t.Fatalf("construct service: %v", err)
	}
	healthy.FailWith = errors.New("audit database unreachable")

	decision, err := svc.Erase(context.Background(), baseRequest("actor-clean"))
	if err == nil {
		t.Fatal("erasure proceeded with the audit trail down; a destruction nobody recorded is worse than one that did not happen")
	}
	if !errors.Is(err, ErrAuditUnavailable) {
		t.Fatalf("want ErrAuditUnavailable, got %v", err)
	}
	if decision.Permitted {
		t.Error("decision reports permitted=true after the audit write failed")
	}
	if decision.AuditRecorded {
		t.Error("decision claims the audit was recorded after the audit write failed")
	}
	if decision.Receipt != nil {
		t.Error("decision carries a destruction receipt although nothing was destroyed")
	}
	// The tripwire destroyer covers the important half: reaching it would already have failed.
}

// TestErasureHold_RefusalThatCannotBeRecordedSaysSo covers the compound failure: a legitimate
// refusal whose own audit write fails.
//
// The refusal stands — nothing was destroyed — but the caller must learn that no trace exists,
// because a refusal nobody can see is indistinguishable from a request that was never made.
func TestErasureHold_RefusalThatCannotBeRecordedSaysSo(t *testing.T) {
	seq := &sequenceRecorder{}
	const subject = "actor-contained"
	healthy := audit.NewFakeWriter()
	svc, err := NewService(Config{
		Incidents:     availableSource(seq, containmentHold(subject)),
		Destroyer:     tripwireDestroyer{t: t},
		Audit:         healthy,
		Operators:     registryOf(t, newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")),
		Pseudonymiser: fakePseudonymiser{},
		Now:           fixedClock(testNow),
	})
	if err != nil {
		t.Fatalf("construct service: %v", err)
	}
	healthy.FailWith = errors.New("audit database unreachable")

	decision, err := svc.Erase(context.Background(), baseRequest(subject))
	if err == nil {
		t.Fatal("expected a refusal")
	}
	if !errors.Is(err, ErrRefusalNotRecorded) {
		t.Errorf("want ErrRefusalNotRecorded, got %v", err)
	}
	// The original cause must survive the wrapping. A caller that can no longer tell WHY it was
	// refused cannot act on the refusal.
	if !errors.Is(err, ErrLegalHold) {
		t.Errorf("the underlying refusal reason was lost when wrapping the audit failure: %v", err)
	}
	if decision.AuditRecorded {
		t.Error("decision claims the refusal was recorded when it was not")
	}
}

// =============================================================================================
// PENDING REQUESTS AND THE DECISION-TIME CLOCK
// =============================================================================================

func TestErasureHold_StaleRequestIsRefused(t *testing.T) {
	seq := &sequenceRecorder{}
	fx := newTripwireFixture(t, availableSource(seq))

	req := baseRequest("actor-clean")
	req.RequestedAt = testNow.Add(-MaxRequestAge - time.Minute)

	_, err := fx.svc.Erase(context.Background(), req)
	if err == nil {
		t.Fatal("a request older than MaxRequestAge was executed against an incident picture nobody re-examined")
	}
	if !errors.Is(err, ErrRequestStale) {
		t.Fatalf("want ErrRequestStale, got %v", err)
	}
}

// TestErasureHold_RequestExactlyAtMaxAgeIsAccepted pairs with the test above.
//
// Without this, a change making EVERY request stale would leave the staleness test green. A
// threshold test that only exercises the rejecting side passes for an unconditional rejection.
func TestErasureHold_RequestExactlyAtMaxAgeIsAccepted(t *testing.T) {
	seq := &sequenceRecorder{}
	fx := newServiceFixture(t, availableSource(seq), seq)

	req := baseRequest("actor-clean")
	req.RequestedAt = testNow.Add(-MaxRequestAge)

	if _, err := fx.svc.Erase(context.Background(), req); err != nil {
		t.Fatalf("a request exactly at MaxRequestAge was refused: %v", err)
	}
}

func TestErasureHold_ZeroAndFutureRequestTimesAreRefused(t *testing.T) {
	for name, mutate := range map[string]func(*ErasureRequest){
		"zero requested_at":   func(r *ErasureRequest) { r.RequestedAt = time.Time{} },
		"future requested_at": func(r *ErasureRequest) { r.RequestedAt = testNow.Add(time.Hour) },
	} {
		t.Run(name, func(t *testing.T) {
			seq := &sequenceRecorder{}
			fx := newTripwireFixture(t, availableSource(seq))
			req := baseRequest("actor-clean")
			mutate(&req)
			if _, err := fx.svc.Erase(context.Background(), req); !errors.Is(err, ErrInvalidRequest) {
				t.Fatalf("want ErrInvalidRequest, got %v", err)
			}
		})
	}
}

// TestErasureHold_HoldIsEvaluatedAtDecisionTimeNotRequestTime proves the stated policy.
//
// The hold was released BEFORE the decision instant but AFTER the request was made. Evaluating
// against request time would still see it as active; evaluating against decision time does not.
// The permitted result is what proves which clock was used.
func TestErasureHold_HoldIsEvaluatedAtDecisionTimeNotRequestTime(t *testing.T) {
	seq := &sequenceRecorder{}
	lapsed := containmentHold("actor-released")
	lapsed.ReleasedAt = testNow.Add(-30 * time.Minute) // released after the request, before the decision
	fx := newServiceFixture(t, availableSource(seq, lapsed), seq)

	req := baseRequest("actor-released")
	req.RequestedAt = testNow.Add(-2 * time.Hour) // made while the hold was still active

	decision, err := fx.svc.Erase(context.Background(), req)
	if err != nil {
		t.Fatalf("erasure refused although the hold had lapsed by decision time: %v", err)
	}
	if len(decision.HoldIDs) != 0 {
		t.Errorf("a released hold is still being counted as active: %v", decision.HoldIDs)
	}
}

// TestErasureHold_FutureReleaseStillBlocks is the discriminating pair for the test above: a hold
// whose release is scheduled but has not arrived must still block. Without it, code that treated
// ANY non-zero ReleasedAt as "released" would pass the previous test.
func TestErasureHold_FutureReleaseStillBlocks(t *testing.T) {
	seq := &sequenceRecorder{}
	pending := containmentHold("actor-pending-release")
	pending.ReleasedAt = testNow.Add(30 * time.Minute)
	fx := newTripwireFixture(t, availableSource(seq, pending))

	if _, err := fx.svc.Erase(context.Background(), baseRequest("actor-pending-release")); !errors.Is(err, ErrLegalHold) {
		t.Fatalf("a hold with a future release date did not block: %v", err)
	}
}

// =============================================================================================
// CONSTRUCTOR — no permissive default is reachable
// =============================================================================================

func TestErasureHold_ServiceRefusesIncompleteConfiguration(t *testing.T) {
	ops := []testOperator{newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")}
	complete := func() Config {
		return Config{
			Incidents:     availableSource(&sequenceRecorder{}),
			Destroyer:     &countingDestroyer{seq: &sequenceRecorder{}},
			Audit:         audit.NewFakeWriter(),
			Operators:     registryOf(t, ops...),
			Pseudonymiser: fakePseudonymiser{},
		}
	}
	// Sanity: the complete configuration must succeed, or every case below passes vacuously.
	if _, err := NewService(complete()); err != nil {
		t.Fatalf("the complete configuration was rejected, so every negative case below is vacuous: %v", err)
	}

	for name, break_ := range map[string]func(*Config){
		"nil incident source": func(c *Config) { c.Incidents = nil },
		"nil destroyer":       func(c *Config) { c.Destroyer = nil },
		"nil audit":           func(c *Config) { c.Audit = nil },
		"nil operators":       func(c *Config) { c.Operators = nil },
		"nil pseudonymiser":   func(c *Config) { c.Pseudonymiser = nil },
		"unhealthy audit": func(c *Config) {
			w := audit.NewFakeWriter()
			w.FailWith = errors.New("down")
			c.Audit = w
		},
		"discarding nop audit": func(c *Config) { c.Audit = audit.NewNopWriter(true) },
	} {
		t.Run(name, func(t *testing.T) {
			cfg := complete()
			break_(&cfg)
			if _, err := NewService(cfg); err == nil {
				t.Fatalf("NewService accepted a configuration with %s; a permissive default is constructable", name)
			}
		})
	}
}

// TestErasureHold_NilClockStillProducesARealDecisionTime guards the one dependency that DOES have a
// safe default. A nil clock defaulting to time.Now is fine; a nil clock defaulting to the zero time
// would make every hold comparison and every staleness check nonsense.
func TestErasureHold_NilClockStillProducesARealDecisionTime(t *testing.T) {
	seq := &sequenceRecorder{}
	svc, err := NewService(Config{
		Incidents:     availableSource(seq),
		Destroyer:     &countingDestroyer{seq: seq},
		Audit:         audit.NewFakeWriter(),
		Operators:     registryOf(t, newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")),
		Pseudonymiser: fakePseudonymiser{},
		Now:           nil,
	})
	if err != nil {
		t.Fatalf("construct service with nil clock: %v", err)
	}
	req := baseRequest("actor-clean")
	req.RequestedAt = time.Now().UTC().Add(-time.Minute)
	decision, err := svc.Erase(context.Background(), req)
	if err != nil {
		t.Fatalf("erase with default clock: %v", err)
	}
	if decision.DecidedAt.IsZero() {
		t.Fatal("a nil clock produced a zero decision time; every hold and staleness comparison would be meaningless")
	}
}

// =============================================================================================
// PERMITTED PATHS
// =============================================================================================

func TestErasureHold_UnheldSubjectIsErasedAndRecorded(t *testing.T) {
	seq := &sequenceRecorder{}
	fx := newServiceFixture(t, availableSource(seq), seq)

	decision, err := fx.svc.Erase(context.Background(), baseRequest("actor-clean"))
	if err != nil {
		t.Fatalf("unheld erasure failed: %v", err)
	}
	if decision.Outcome != OutcomeErased {
		t.Errorf("outcome = %q, want %q", decision.Outcome, OutcomeErased)
	}
	events := fx.auditLog.EventsByType(audit.EventPartitionDropped)
	if len(events) != 1 {
		t.Fatalf("permitted erasure wrote %d partition_dropped events, want 1", len(events))
	}
}

func TestErasureHold_ValidDualOperatorOverridePermitsErasurePastAHold(t *testing.T) {
	const subject = "actor-contained"
	seq := &sequenceRecorder{}
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")
	fx := newServiceFixture(t, availableSource(seq, containmentHold(subject)), seq, alice, bob)

	req := baseRequest(subject)
	req.Exception = validException(t, req, alice, bob)

	decision, err := fx.svc.Erase(context.Background(), req)
	if err != nil {
		t.Fatalf("a valid dual-operator override was refused: %v", err)
	}
	if decision.Outcome != OutcomeErasedUnderException {
		t.Errorf("outcome = %q, want %q", decision.Outcome, OutcomeErasedUnderException)
	}
	// BOTH identities recorded. An override attributable to nobody is not attributable.
	if len(decision.Approvers) != 2 {
		t.Fatalf("decision records %d approvers, want 2: %v", len(decision.Approvers), decision.Approvers)
	}
	if decision.Approvers[0] != "op-alice" || decision.Approvers[1] != "op-bob" {
		t.Errorf("approvers are not recorded in deterministic sorted order: %v", decision.Approvers)
	}
	if decision.Ground != GroundLegalClaims {
		t.Errorf("decision does not record the ground relied upon: %q", decision.Ground)
	}
	if decision.ExceptionExpiresAt.IsZero() || decision.ExceptionReviewBy.IsZero() {
		t.Error("decision does not record the override's time bounds")
	}

	detail := auditDetail(t, fx.auditLog, 0)
	approvers, ok := detail["approvers"].([]any)
	if !ok || len(approvers) != 2 {
		t.Fatalf("audit detail does not record both approver identities: %v", detail["approvers"])
	}
	if detail["ground"] != string(GroundLegalClaims) {
		t.Errorf("audit detail does not record the ground: %v", detail["ground"])
	}
}

// TestErasureHold_DestructionFailureIsReportedNotSwallowed covers the last phase. The gates all
// passed and the destroyer itself failed; that must surface rather than reporting success.
func TestErasureHold_DestructionFailureIsReportedNotSwallowed(t *testing.T) {
	seq := &sequenceRecorder{}
	fx := newServiceFixture(t, availableSource(seq), seq)
	fx.destroyer.failWith = ErrDestructionNotImplemented

	decision, err := fx.svc.Erase(context.Background(), baseRequest("actor-clean"))
	if err == nil {
		t.Fatal("a failed destruction reported success; a false 'erased' is a misstatement to the data subject")
	}
	if !errors.Is(err, ErrDestructionNotImplemented) {
		t.Errorf("destruction error was not propagated: %v", err)
	}
	if decision.Permitted {
		t.Error("decision reports permitted=true although destruction failed")
	}
	if decision.Outcome != OutcomeRefusedDestructionFailed {
		t.Errorf("outcome = %q, want %q", decision.Outcome, OutcomeRefusedDestructionFailed)
	}
}

// TestErasureHold_UnimplementedDestroyerRefuses pins the production wiring choice: until SLDP-P4-1
// lands, an authorised erasure must fail loudly rather than return a plausible receipt.
func TestErasureHold_UnimplementedDestroyerRefuses(t *testing.T) {
	receipt, err := UnimplementedKeyDestroyer{}.DestroySubjectKeys(context.Background(), "tenant-a", "actor-clean")
	if err == nil {
		t.Fatal("UnimplementedKeyDestroyer returned success; a stub that reports a destruction it did not perform is a lie to a regulator")
	}
	if !errors.Is(err, ErrDestructionNotImplemented) {
		t.Errorf("want ErrDestructionNotImplemented, got %v", err)
	}
	if receipt.KeysRemoved != 0 {
		t.Errorf("refusing destroyer reported %d keys removed", receipt.KeysRemoved)
	}
}

// TestErasureHold_NoDevelopmentOptInRelaxesAnyGate is a static guard over this package's own source.
//
// identity and audit both ship an explicit insecure development mode (identity.DevOptInEnvVars,
// audit.NewNopWriter(true)). This package must not, because a development passthrough on an
// irreversible act is a lie in whichever direction it points. The guard is static because the
// failure it prevents is someone ADDING such a switch later, which no behavioural test would
// notice until it was used.
//
// It asserts on the MECHANISM — os.Getenv calls — rather than on forbidden name substrings, for
// two reasons. A substring guard would match this package's own doc comment, which names
// INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR while explaining why there is no equivalent here; and a
// substring list only catches names somebody already thought of, whereas "exactly one environment
// variable is consulted, and it is the operator registry" catches every name.
func TestErasureHold_NoDevelopmentOptInRelaxesAnyGate(t *testing.T) {
	sources := packageGoSources(t)
	if len(sources) == 0 {
		t.Fatal("no non-test source files were read; this guard would pass vacuously")
	}
	total := 0
	for name, body := range sources {
		n := strings.Count(body, "os.Getenv(")
		total += n
		if n == 0 {
			continue
		}
		if name != "operator.go" {
			t.Errorf("%s reads an environment variable; only operator.go may, and only for the registry", name)
		}
		if !strings.Contains(body, "os.Getenv(OperatorRegistryEnvVar)") {
			t.Errorf("%s calls os.Getenv with something other than OperatorRegistryEnvVar", name)
		}
	}
	if total != 1 {
		t.Errorf("this package makes %d os.Getenv calls, want exactly 1 (the operator registry). "+
			"Any additional environment variable is a switch that can relax a gate on an irreversible act.", total)
	}
}
