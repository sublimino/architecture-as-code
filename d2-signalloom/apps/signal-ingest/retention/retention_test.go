// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

// testNow carries SUB-MICROSECOND digits on purpose.
//
// A whole-second test clock hides the entire microsecond-truncation defect class: a receipt digested
// in memory and re-digested after a timestamptz round trip would differ in digits no assertion using a
// round clock can see. subjectkey/receipt.go shipped with exactly that defect until an adversarial
// review caught it, and the note there says a fixed-second clock hides it completely.
var testNow = time.Date(2026, 9, 14, 12, 0, 0, 123456789, time.UTC)

// fixedClock is a trusted clock pinned to at.
type fixedClock struct {
	at     time.Time
	source string
	err    error
}

func (c fixedClock) Now() (time.Time, error) {
	if c.err != nil {
		return time.Time{}, c.err
	}
	return c.at.UTC().Truncate(time.Microsecond), nil
}
func (c fixedClock) Source() string {
	if c.source == "" {
		return ClockSourceTrustedSync
	}
	return c.source
}

// fakeEvaluator implements Evaluator without a quarantine engine.
type fakeEvaluator struct {
	deletable bool
	holdIDs   []string
	err       error
	calls     atomic.Int64
}

func (e *fakeEvaluator) Evaluate(_ context.Context, _, _ string, _ time.Time) (privacy.RetentionDecision, error) {
	e.calls.Add(1)
	if e.err != nil {
		return privacy.RetentionDecision{Reason: "incident state unavailable; retention deletion refused"}, e.err
	}
	return privacy.RetentionDecision{
		Due:         true,
		Deletable:   e.deletable,
		HoldIDs:     e.holdIDs,
		Reason:      "test",
		EvaluatedAt: testNow,
	}, nil
}

// countingAudit records events and can be made to fail.
type countingAudit struct {
	events atomic.Int64
	err    error
	last   audit.Event
}

func (a *countingAudit) WriteAuditEvent(_ context.Context, e audit.Event) error {
	a.events.Add(1)
	a.last = e
	return a.err
}

// fakeSink is a controllable in-process sink.
type fakeSink struct {
	id       string
	class    SinkClass
	reach    Reach
	removed  int64
	absent   bool
	err      error
	residual string
	calls    atomic.Int64
}

func (s *fakeSink) SinkID() string   { return s.id }
func (s *fakeSink) Class() SinkClass { return s.class }
func (s *fakeSink) Reach() Reach     { return s.reach }
func (s *fakeSink) Purge(_ context.Context, _ PurgeRequest) (PurgeOutcome, error) {
	s.calls.Add(1)
	if s.err != nil {
		return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, s.err
	}
	residual := s.residual
	if residual == "" {
		residual = ResidualNone
	}
	// AlreadyAbsent mirrors rowSink.Purge exactly: zero rows removed IS the already-absent signal. An
	// earlier version of this fake required the flag to be set explicitly, which made a zero-row purge
	// report as DispositionPurged and hid the already-absent path entirely — a fake whose semantics
	// diverge from the real sink tests the fake, not the code.
	return PurgeOutcome{
		RecordsRemoved: s.removed,
		AlreadyAbsent:  s.absent || s.removed == 0,
		ResidualState:  residual,
	}, nil
}

// harness builds a controller over an explicit sink list.
type harness struct {
	ctrl      *Controller
	ledger    *MemoryLedger
	audit     *countingAudit
	evaluator *fakeEvaluator
	clock     Clock
}

func newHarness(t *testing.T, sinks []Sink, opts ...func(*Config)) *harness {
	t.Helper()
	ledger := NewMemoryLedger()
	aw := &countingAudit{}
	ev := &fakeEvaluator{deletable: true}
	clock := fixedClock{at: testNow}

	ids := make([]string, 0, len(sinks))
	policies := PolicySet{TenantID: "tenant-a"}
	for _, s := range sinks {
		ids = append(ids, s.SinkID())
		period := DefaultCachePeriod
		if spec, ok := SpecByID(s.SinkID()); ok {
			period = spec.DefaultPeriod
		}
		policies.Policies = append(policies.Policies, Policy{TenantID: "tenant-a", SinkID: s.SinkID(), Period: period})
	}

	cfg := Config{
		Clock: clock, Ledger: ledger, Evaluator: ev, Audit: aw,
		Policies: policies, Sinks: sinks, Logger: discardLogger(),
	}
	for _, opt := range opts {
		opt(&cfg)
	}
	ctrl, err := NewController(cfg)
	if err != nil {
		t.Fatalf("NewController: %v", err)
	}
	return &harness{ctrl: ctrl, ledger: ledger, audit: aw, evaluator: ev, clock: cfg.Clock}
}

// inProcessSink returns a fakeSink bound to a real inventory sink ID.
func inProcessSink(id string, removed int64) *fakeSink {
	spec, _ := SpecByID(id)
	return &fakeSink{id: id, class: spec.Class, reach: ReachInProcess, removed: removed, residual: spec.Residual}
}

// ---------------------------------------------------------------------------
// Policy — bounded retention with an enforced maximum
// ---------------------------------------------------------------------------

func TestRetentionPolicy_RefusesUnboundedAndOutOfRange(t *testing.T) {
	cases := []struct {
		name   string
		policy Policy
		want   error
	}{
		{"zero period", Policy{TenantID: "t", SinkID: "s", Period: 0}, ErrPolicyUnbounded},
		{"negative period", Policy{TenantID: "t", SinkID: "s", Period: -time.Hour}, ErrPolicyUnbounded},
		{"below floor", Policy{TenantID: "t", SinkID: "s", Period: time.Second}, ErrPolicyUnbounded},
		{"over maximum", Policy{TenantID: "t", SinkID: "s", Period: MaxRetentionPeriod + time.Hour}, ErrPolicyUnbounded},
		{"empty tenant", Policy{SinkID: "s", Period: time.Hour}, ErrPolicyIncomplete},
		{"empty sink", Policy{TenantID: "t", Period: time.Hour}, ErrPolicyIncomplete},
		{"blank sink", Policy{TenantID: "t", SinkID: "   ", Period: time.Hour}, ErrPolicyIncomplete},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.policy.Validate()
			if !errors.Is(err, tc.want) {
				t.Fatalf("Validate() = %v, want %v", err, tc.want)
			}
		})
	}
	// And the boundary cases that must PASS, so the refusals above are not simply "refuse everything".
	for _, ok := range []time.Duration{MinRetentionPeriod, MaxRetentionPeriod, MaxRetentionPeriod - time.Hour} {
		if err := (Policy{TenantID: "t", SinkID: "s", Period: ok}).Validate(); err != nil {
			t.Errorf("period %s should be accepted, got %v", ok, err)
		}
	}
}

func TestRetentionPolicy_ParsePeriodRefusesEveryWayOfSayingUnlimited(t *testing.T) {
	for _, raw := range []string{"unlimited", "UNLIMITED", "never", "forever", "indefinite", "infinite", "none", "off", "disabled", "-1", "", "0s", "-5h", "99999h", "banana"} {
		if _, err := ParsePeriod(raw); !errors.Is(err, ErrPolicyUnbounded) {
			t.Errorf("ParsePeriod(%q) = %v, want ErrPolicyUnbounded", raw, err)
		}
	}
	got, err := ParsePeriod("720h")
	if err != nil {
		t.Fatalf("ParsePeriod(720h): %v", err)
	}
	if got != 720*time.Hour {
		t.Fatalf("ParsePeriod(720h) = %s", got)
	}
}

func TestRetentionPolicy_MaxIsNotRuntimeConfigurable(t *testing.T) {
	// Structural: MaxRetentionPeriod is a const, so nothing can assign to it. The compiler is the
	// assertion — this test exists to make the intent visible and to catch a future change from const
	// to var, which would silently make the maximum configurable.
	source := mustReadFile(t, "policy.go")
	if !strings.Contains(source, "MaxRetentionPeriod = 7 * 365 * 24 * time.Hour") {
		t.Fatal("MaxRetentionPeriod declaration changed; confirm it is still a const")
	}
	if strings.Contains(source, "var MaxRetentionPeriod") {
		t.Fatal("MaxRetentionPeriod became a var; a tenant-configurable maximum is not a maximum")
	}
	if strings.Contains(source, "MaxRetentionPeriod =") && strings.Count(source, "MaxRetentionPeriod =") > 1 {
		t.Fatal("MaxRetentionPeriod is assigned more than once")
	}
}

func TestRetentionPolicy_SetRefusesIncompleteAndDuplicate(t *testing.T) {
	full := DefaultPolicySet("tenant-a")
	if err := full.Validate(AllSinkIDs()); err != nil {
		t.Fatalf("DefaultPolicySet should cover every sink: %v", err)
	}

	// Missing one sink.
	short := PolicySet{TenantID: "tenant-a", Policies: full.Policies[1:]}
	err := short.Validate(AllSinkIDs())
	if !errors.Is(err, ErrPolicySetIncomplete) {
		t.Fatalf("a set missing a sink must be refused, got %v", err)
	}
	if !strings.Contains(err.Error(), full.Policies[0].SinkID) {
		t.Errorf("the error should name the missing sink %q: %v", full.Policies[0].SinkID, err)
	}

	// Duplicate sink.
	dup := PolicySet{TenantID: "tenant-a", Policies: append(append([]Policy(nil), full.Policies...), full.Policies[0])}
	if err := dup.Validate(AllSinkIDs()); !errors.Is(err, ErrPolicyDuplicate) {
		t.Fatalf("a duplicate sink must be refused, got %v", err)
	}

	// Cross-tenant policy inside a set.
	crossed := PolicySet{TenantID: "tenant-a", Policies: append([]Policy(nil), full.Policies...)}
	crossed.Policies[0].TenantID = "tenant-b"
	if err := crossed.Validate(AllSinkIDs()); !errors.Is(err, ErrPolicyIncomplete) {
		t.Fatalf("a foreign-tenant policy must be refused, got %v", err)
	}
}

func TestRetentionPolicy_BoundaryIsTruncatedToMicroseconds(t *testing.T) {
	p := Policy{TenantID: "t", SinkID: "s", Period: 24 * time.Hour}
	b := p.Boundary(testNow)
	if b.Nanosecond()%1000 != 0 {
		t.Fatalf("boundary %v carries sub-microsecond digits", b)
	}
	if want := testNow.Add(-24 * time.Hour).Truncate(time.Microsecond); !b.Equal(want) {
		t.Fatalf("boundary = %v, want %v", b, want)
	}
}

// ---------------------------------------------------------------------------
// Clock — trusted, fail closed
// ---------------------------------------------------------------------------

func TestRetentionClock_LocalSaysItIsUnverified(t *testing.T) {
	if got := (LocalClock{}).Source(); got != ClockSourceLocalUnverified {
		t.Fatalf("LocalClock.Source() = %q", got)
	}
	now, err := LocalClock{}.Now()
	if err != nil {
		t.Fatalf("LocalClock.Now(): %v", err)
	}
	if now.Nanosecond()%1000 != 0 {
		t.Fatalf("LocalClock.Now() = %v carries sub-microsecond digits; truncation must happen at the source", now)
	}
}

func TestRetentionClock_TrustedRefusesUntilSynced(t *testing.T) {
	c := NewTrustedClock(TrustedClockConfig{Host: func() time.Time { return testNow }})
	if _, err := c.Now(); !errors.Is(err, ErrClockUntrusted) {
		t.Fatalf("an unsynced clock must refuse, got %v", err)
	}
	c.Sync(testNow)
	if _, err := c.Now(); err != nil {
		t.Fatalf("a freshly synced clock must answer: %v", err)
	}
}

func TestRetentionClock_TrustedRefusesStaleSync(t *testing.T) {
	host := testNow
	c := NewTrustedClock(TrustedClockConfig{Freshness: time.Hour, Host: func() time.Time { return host }})
	c.Sync(testNow)

	host = testNow.Add(59 * time.Minute)
	if _, err := c.Now(); err != nil {
		t.Fatalf("inside the freshness window the clock must answer: %v", err)
	}
	host = testNow.Add(61 * time.Minute)
	err := c.Now
	if _, e := err(); !errors.Is(e, ErrClockUntrusted) {
		t.Fatalf("past the freshness window the clock must refuse, got %v", e)
	}
}

func TestRetentionClock_TrustedRefusesDrift(t *testing.T) {
	host := testNow
	c := NewTrustedClock(TrustedClockConfig{MaxDrift: 5 * time.Second, Host: func() time.Time { return host }})
	c.Sync(testNow)

	// Host advances 10 minutes; upstream would also be 10 minutes later, so drift is zero.
	host = testNow.Add(10 * time.Minute)
	if _, err := c.Now(); err != nil {
		t.Fatalf("matched rates must not read as drift: %v", err)
	}

	// Now re-sync with an upstream that disagrees by a minute.
	host = testNow
	c.Sync(testNow.Add(-time.Minute))
	if _, err := c.Now(); !errors.Is(err, ErrClockUntrusted) {
		t.Fatalf("a minute of drift against a 5s tolerance must refuse, got %v", err)
	}
}

func TestRetentionClock_TrustedRefusesBackwardsStep(t *testing.T) {
	host := testNow
	c := NewTrustedClock(TrustedClockConfig{Host: func() time.Time { return host }})
	c.Sync(testNow)
	host = testNow.Add(-time.Hour)
	if _, err := c.Now(); !errors.Is(err, ErrClockUntrusted) {
		t.Fatalf("a backwards step must refuse, got %v", err)
	}
}

func TestRetentionClock_ControllerRefusesUnverifiedClockWhenEnforcing(t *testing.T) {
	sinks := []Sink{inProcessSink("postgres_actors", 1)}
	policies := PolicySet{TenantID: "tenant-a", Policies: []Policy{{TenantID: "tenant-a", SinkID: "postgres_actors", Period: time.Hour}}}
	cfg := Config{
		Clock: LocalClock{}, Ledger: NewMemoryLedger(), Evaluator: &fakeEvaluator{deletable: true},
		Audit: &countingAudit{}, Policies: policies, Sinks: sinks, Logger: discardLogger(),
	}
	if _, err := NewController(cfg); !errors.Is(err, ErrControllerMisconfigured) {
		t.Fatalf("an enforcing controller must refuse a local_unverified clock, got %v", err)
	}
	cfg.NonEnforcing = true
	if _, err := NewController(cfg); err != nil {
		t.Fatalf("a non-enforcing controller may accept it: %v", err)
	}
}

func TestRetentionClock_UntrustedSweepPurgesNothingAndDoesNotReadClean(t *testing.T) {
	sink := inProcessSink("postgres_actors", 5)
	h := newHarness(t, []Sink{sink}, func(c *Config) {
		c.Clock = fixedClock{at: testNow, err: fmt.Errorf("%w: injected", ErrClockUntrusted)}
	})

	res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("a sweep on an untrusted clock must return an error, not a clean result")
	}
	if !errors.Is(err, ErrClockUntrusted) {
		t.Fatalf("error should wrap ErrClockUntrusted: %v", err)
	}
	if res.OK() {
		t.Fatal("SweepResult.OK() must be false after a clock abort")
	}
	if got := sink.calls.Load(); got != 0 {
		t.Fatalf("the sink was touched %d times; a clock abort must purge nothing", got)
	}
	if got := h.ledger.Count("tenant-a"); got != 0 {
		t.Fatalf("%d receipts written after a clock abort; nothing was demonstrated", got)
	}
	if got := h.ctrl.Metrics().ReceiptCount(DispositionPurged); got != 0 {
		t.Fatalf("purged receipts counted after a clock abort: %d", got)
	}
	// And the failure is visible in the metric rather than silent.
	if !strings.Contains(h.ctrl.Metrics().Render(), "signalloom_retention_clock_untrusted_total 1") {
		t.Error("clock_untrusted_total was not incremented; the abort would be invisible")
	}
}

// ---------------------------------------------------------------------------
// Receipt
// ---------------------------------------------------------------------------

func validReceipt(t *testing.T) DeletionReceipt {
	t.Helper()
	nonce, err := NewReceiptNonce()
	if err != nil {
		t.Fatalf("NewReceiptNonce: %v", err)
	}
	boundary := testNow.Add(-24 * time.Hour).Truncate(time.Microsecond)
	return DeletionReceipt{
		Schema:              ReceiptSchema,
		OperationID:         NewOperationID("tenant-a", "postgres_actors", boundary),
		TenantID:            "tenant-a",
		SinkID:              "postgres_actors",
		SinkClass:           string(ClassPrimary),
		DroppedBefore:       boundary,
		PropagationDeadline: boundary.Add(MaxPropagationDelay),
		Disposition:         DispositionPurged,
		RecordsRemoved:      7,
		PartitionsDropped:   1,
		EvaluatedAt:         testNow.Truncate(time.Microsecond),
		CompletedAt:         testNow.Truncate(time.Microsecond),
		ClockSource:         ClockSourceTrustedSync,
		ReceiptNonce:        nonce,
		ResidualState:       ResidualPostgresMVCC,
		ComplianceNote:      ComplianceNotePurged,
	}
}

func TestRetentionReceipt_SchemaAndFieldSetMatchP6PRE(t *testing.T) {
	if ReceiptSchema != "signalloom.retention-deletion-receipt/v1" {
		t.Fatalf("ReceiptSchema = %q; P6-PRE §6 pins this literal", ReceiptSchema)
	}
	// The P6-PRE field set, by JSON tag, plus the four this card adds.
	source := mustReadFile(t, "receipt.go")
	for _, tag := range []string{
		`json:"schema"`, `json:"operation_id"`, `json:"tenant_id"`, `json:"sink_id"`,
		`json:"dropped_before"`, `json:"records_removed"`, `json:"partitions_dropped"`,
		`json:"evaluated_at"`, `json:"completed_at"`, `json:"receipt_nonce"`,
		`json:"receipt_digest"`, `json:"residual_state"`, `json:"compliance_note"`,
		`json:"propagation_deadline"`, `json:"disposition"`, `json:"sink_class"`, `json:"clock_source"`,
	} {
		if !strings.Contains(source, tag) {
			t.Errorf("DeletionReceipt is missing field tag %s", tag)
		}
	}
}

func TestRetentionReceipt_OperationIDIsDeterministicAndNonceFree(t *testing.T) {
	boundary := testNow.Add(-time.Hour).Truncate(time.Microsecond)
	a := NewOperationID("tenant-a", "postgres_actors", boundary)
	b := NewOperationID("tenant-a", "postgres_actors", boundary)
	if a != b {
		t.Fatalf("operation IDs differ for identical inputs: %s vs %s", a, b)
	}
	if len(a) != 64 {
		t.Fatalf("operation ID %q is not 64 hex chars", a)
	}
	// Any input change must change the ID, or two distinct operations would collide onto one ledger row.
	for _, other := range []string{
		NewOperationID("tenant-b", "postgres_actors", boundary),
		NewOperationID("tenant-a", "postgres_aliases", boundary),
		NewOperationID("tenant-a", "postgres_actors", boundary.Add(time.Microsecond)),
	} {
		if other == a {
			t.Error("operation ID collided across distinct inputs")
		}
	}
	// Field separation: length-prefixed encoding means concatenation cannot be gamed.
	if NewOperationID("ab", "c", boundary) == NewOperationID("a", "bc", boundary) {
		t.Error("operation ID is vulnerable to field-boundary ambiguity; the length prefix is not working")
	}
}

func TestRetentionReceipt_NonceIs32CSPRNGBytes(t *testing.T) {
	seen := make(map[string]struct{})
	for range 64 {
		n, err := NewReceiptNonce()
		if err != nil {
			t.Fatalf("NewReceiptNonce: %v", err)
		}
		if len(n) != 64 {
			t.Fatalf("nonce %q is not 32 bytes hex", n)
		}
		if _, dup := seen[n]; dup {
			t.Fatal("nonce repeated across 64 draws")
		}
		seen[n] = struct{}{}
	}
}

func TestRetentionReceipt_DigestIsStableAndChangesOnEveryField(t *testing.T) {
	base := validReceipt(t)
	want, err := base.Digest()
	if err != nil {
		t.Fatalf("Digest: %v", err)
	}
	again, _ := base.Digest()
	if want != again {
		t.Fatal("digest is not stable across calls")
	}
	// Setting ReceiptDigest must not change the digest, or Seal would invalidate its own output.
	sealed, err := base.Seal()
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if sealed.ReceiptDigest != want {
		t.Fatalf("Seal wrote %s, Digest returned %s", sealed.ReceiptDigest, want)
	}
	if err := sealed.VerifyDigest(); err != nil {
		t.Fatalf("a sealed receipt must verify: %v", err)
	}

	mutations := map[string]func(*DeletionReceipt){
		"tenant":     func(r *DeletionReceipt) { r.TenantID = "tenant-b" },
		"sink":       func(r *DeletionReceipt) { r.SinkID = "postgres_aliases" },
		"class":      func(r *DeletionReceipt) { r.SinkClass = string(ClassCache) },
		"boundary":   func(r *DeletionReceipt) { r.DroppedBefore = r.DroppedBefore.Add(time.Microsecond) },
		"deadline":   func(r *DeletionReceipt) { r.PropagationDeadline = r.PropagationDeadline.Add(time.Microsecond) },
		"records":    func(r *DeletionReceipt) { r.RecordsRemoved = 8 },
		"partitions": func(r *DeletionReceipt) { r.PartitionsDropped = 2 },
		"evaluated":  func(r *DeletionReceipt) { r.EvaluatedAt = r.EvaluatedAt.Add(time.Microsecond) },
		"completed":  func(r *DeletionReceipt) { r.CompletedAt = r.CompletedAt.Add(time.Microsecond) },
		"clock":      func(r *DeletionReceipt) { r.ClockSource = ClockSourceLocalUnverified },
		"residual":   func(r *DeletionReceipt) { r.ResidualState = ResidualNone },
		"note":       func(r *DeletionReceipt) { r.ComplianceNote = ComplianceNoteAlreadyAbsent },
		"nonce":      func(r *DeletionReceipt) { r.ReceiptNonce = strings.Repeat("a", 64) },
		"linkage":    func(r *DeletionReceipt) { r.LinkageReceipts = []string{"abc"} },
		"disposition": func(r *DeletionReceipt) {
			r.Disposition = DispositionRetainedUnresolvableToken
			r.LinkageReceipts = []string{"x"}
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			mutated := base
			mutate(&mutated)
			got, err := mutated.Digest()
			if err != nil {
				t.Fatalf("Digest after mutating %s: %v", name, err)
			}
			if got == want {
				t.Fatalf("mutating %s did not change the digest; the canonical encoding does not cover it", name)
			}
		})
	}
}

func TestRetentionReceipt_DigestSurvivesMicrosecondRoundTrip(t *testing.T) {
	// This is the defect subjectkey/receipt.go records: nanoseconds in memory, microseconds in
	// timestamptz. Because the clock truncates at the source, a receipt built from it digests the same
	// as one round-tripped through a microsecond-resolution store.
	base := validReceipt(t)
	nanosecondish := base
	nanosecondish.EvaluatedAt = base.EvaluatedAt.Add(750 * time.Nanosecond)
	nanosecondish.CompletedAt = base.CompletedAt.Add(750 * time.Nanosecond)

	a, err := base.Digest()
	if err != nil {
		t.Fatalf("Digest: %v", err)
	}
	b, err := nanosecondish.Digest()
	if err != nil {
		t.Fatalf("Digest: %v", err)
	}
	if a != b {
		t.Fatalf("sub-microsecond digits changed the digest (%s vs %s); encodeInstant is not truncating", a, b)
	}
	// And assert the mechanism rather than only the effect.
	if !strings.Contains(mustReadFile(t, "clock.go"), "UnixMicro()") {
		t.Error("encodeInstant no longer uses UnixMicro; the round-trip guarantee is gone")
	}
}

func TestRetentionReceipt_ValidateRefusesEveryIncompleteAndContradictoryShape(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*DeletionReceipt)
		want   error
	}{
		{"wrong schema", func(r *DeletionReceipt) { r.Schema = "other/v1" }, ErrReceiptIncomplete},
		{"no operation id", func(r *DeletionReceipt) { r.OperationID = "" }, ErrReceiptIncomplete},
		{"no tenant", func(r *DeletionReceipt) { r.TenantID = "" }, ErrReceiptIncomplete},
		{"no sink", func(r *DeletionReceipt) { r.SinkID = "" }, ErrReceiptIncomplete},
		{"no class", func(r *DeletionReceipt) { r.SinkClass = "" }, ErrReceiptIncomplete},
		{"no nonce", func(r *DeletionReceipt) { r.ReceiptNonce = "" }, ErrReceiptIncomplete},
		{"unknown disposition", func(r *DeletionReceipt) { r.Disposition = "vanished" }, ErrReceiptIncomplete},
		{"no residual", func(r *DeletionReceipt) { r.ResidualState = "" }, ErrReceiptIncomplete},
		{"no compliance note", func(r *DeletionReceipt) { r.ComplianceNote = "" }, ErrReceiptIncomplete},
		{"no clock source", func(r *DeletionReceipt) { r.ClockSource = "" }, ErrReceiptIncomplete},
		{"zero boundary", func(r *DeletionReceipt) { r.DroppedBefore = time.Time{} }, ErrReceiptIncomplete},
		{"zero deadline", func(r *DeletionReceipt) { r.PropagationDeadline = time.Time{} }, ErrReceiptIncomplete},
		{"zero evaluated", func(r *DeletionReceipt) { r.EvaluatedAt = time.Time{} }, ErrReceiptIncomplete},
		{"negative records", func(r *DeletionReceipt) { r.RecordsRemoved = -1 }, ErrReceiptInvalid},
		{"complete without completed_at", func(r *DeletionReceipt) { r.CompletedAt = time.Time{} }, ErrReceiptInvalid},
		{
			"unreachable claiming removals",
			func(r *DeletionReceipt) {
				r.Disposition = DispositionUnreachable
				r.ResidualState = ResidualNotDemonstrated
				r.RecordsRemoved = 5
			},
			ErrReceiptInvalid,
		},
		{
			"held claiming removals",
			func(r *DeletionReceipt) {
				r.Disposition = DispositionHeld
				r.HoldIDs = []string{"h1"}
				r.RecordsRemoved = 5
			},
			ErrReceiptInvalid,
		},
		{
			"already absent claiming removals",
			func(r *DeletionReceipt) {
				r.Disposition = DispositionAlreadyAbsent
				r.RecordsRemoved = 5
			},
			ErrReceiptInvalid,
		},
		{
			"held naming no holds",
			func(r *DeletionReceipt) {
				r.Disposition = DispositionHeld
				r.RecordsRemoved = 0
				r.PartitionsDropped = 0
			},
			ErrReceiptInvalid,
		},
		{
			"unreachable claiming a residual it cannot know",
			func(r *DeletionReceipt) {
				r.Disposition = DispositionUnreachable
				r.RecordsRemoved = 0
				r.PartitionsDropped = 0
				r.ResidualState = ResidualPostgresMVCC
			},
			ErrReceiptInvalid,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := validReceipt(t)
			tc.mutate(&r)
			if err := r.Validate(); !errors.Is(err, tc.want) {
				t.Fatalf("Validate() = %v, want %v", err, tc.want)
			}
			// A receipt that cannot validate must not be digestible either, or an invalid receipt could
			// be sealed and recorded.
			if _, err := r.Digest(); err == nil {
				t.Error("an invalid receipt produced a digest")
			}
		})
	}
}

func TestRetentionReceipt_CompleteExcludesHeldAndUnreachable(t *testing.T) {
	complete := map[Disposition]bool{
		DispositionPurged:                    true,
		DispositionAlreadyAbsent:             true,
		DispositionRetainedUnresolvableToken: true,
		DispositionHeld:                      false,
		DispositionUnreachable:               false,
	}
	for d, want := range complete {
		if got := d.Complete(); got != want {
			t.Errorf("%q.Complete() = %v, want %v", d, got, want)
		}
		if !d.Valid() {
			t.Errorf("%q is not Valid()", d)
		}
	}
	if Disposition("vanished").Valid() {
		t.Error("an unknown disposition must not be Valid()")
	}
	if len(allDispositions) != 5 {
		t.Fatalf("allDispositions has %d entries; the four-outcome-plus-token contract expects 5", len(allDispositions))
	}
}

func TestRetentionReceipt_CanonicalIsNotJSON(t *testing.T) {
	source := mustReadFile(t, "receipt.go")
	start := strings.Index(source, "func (r DeletionReceipt) canonical()")
	if start < 0 {
		t.Fatal("canonical() not found; this guard has lost its subject")
	}
	end := strings.Index(source[start:], "\n}\n")
	body := source[start : start+end]
	if strings.Contains(body, "json.Marshal") {
		t.Fatal("canonical() uses json.Marshal; adding a field later would silently change every stored digest")
	}
	if !strings.Contains(body, "binary.BigEndian.AppendUint32") {
		t.Fatal("canonical() no longer length-prefixes its fields")
	}
	// Order independence for the two slice fields.
	a := validReceipt(t)
	a.Disposition = DispositionHeld
	a.RecordsRemoved, a.PartitionsDropped, a.CompletedAt = 0, 0, time.Time{}
	a.HoldIDs = []string{"h1", "h2"}
	b := a
	b.HoldIDs = []string{"h2", "h1"}
	da, err := a.Digest()
	if err != nil {
		t.Fatalf("Digest: %v", err)
	}
	db, _ := b.Digest()
	if da != db {
		t.Fatal("hold ID order changed the digest; the canonical encoding must sort slices")
	}
}

func mustReadFile(t *testing.T, name string) string {
	t.Helper()
	raw, err := readFile(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return raw
}
