package privacy

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// ---------------------------------------------------------------------------------------------
// Shared test harness.
//
// Two rules govern every double in this file, both learned the hard way in this repository:
//
//  1. A double's failure value must never be a legal answer. fakeIncidentSource signals failure
//     ONLY by returning an error. It cannot signal failure with an empty slice, because an empty
//     slice is the wire encoding of "determined: no holds" and a failure that looks like one
//     permits the erasure it was meant to block.
//
//  2. Ordering is observed, not asserted from metadata. sequenceRecorder is shared between the
//     incident source and the key destroyer, so the test sees the real call order rather than a
//     trace field the production code could populate at any time. Asserting that a field exists is
//     not asserting that it measures anything.
// ---------------------------------------------------------------------------------------------

// sequenceRecorder records the order in which doubles were invoked.
type sequenceRecorder struct {
	events []string
}

func (s *sequenceRecorder) record(event string) {
	if s == nil {
		return
	}
	s.events = append(s.events, event)
}

// indexOf returns the position of event, or -1.
func (s *sequenceRecorder) indexOf(event string) int {
	for i, e := range s.events {
		if e == event {
			return i
		}
	}
	return -1
}

const (
	seqIncidentRead = "incident_source_read"
	seqKeyDestroyed = "key_destroyer_called"
)

// fakeIncidentSource is a controllable IncidentSource.
//
// Note the absence of any "return empty to simulate failure" switch. The only failure channel is
// err, by construction.
type fakeIncidentSource struct {
	holds        []Hold
	jurisdiction bool
	err          error
	seq          *sequenceRecorder
	calls        int
}

func (f *fakeIncidentSource) ActiveHolds(_ context.Context, _, _ string) (HoldQueryResult, error) {
	f.calls++
	f.seq.record(seqIncidentRead)
	if f.err != nil {
		return HoldQueryResult{}, f.err
	}
	return HoldQueryResult{Holds: f.holds, Jurisdiction: f.jurisdiction}, nil
}

// availableSource returns a source that answers authoritatively with the supplied holds.
func availableSource(seq *sequenceRecorder, holds ...Hold) *fakeIncidentSource {
	return &fakeIncidentSource{holds: holds, jurisdiction: true, seq: seq}
}

// unavailableSource returns a source that cannot determine incident state.
func unavailableSource(seq *sequenceRecorder) *fakeIncidentSource {
	return &fakeIncidentSource{err: errors.New("incident database connection refused"), seq: seq}
}

// tripwireDestroyer fails the test if it is ever called.
//
// It is the ordering and fail-closed assertion that cannot be satisfied by accident: any refusal
// path that reaches key material trips it, whether or not the test author thought to assert on the
// trace.
type tripwireDestroyer struct {
	t *testing.T
}

func (d tripwireDestroyer) DestroySubjectKeys(_ context.Context, tenantID, subjectID string) (KeyDestructionReceipt, error) {
	d.t.Helper()
	d.t.Fatalf("KEY DESTROYER REACHED on a path that must refuse: tenant=%q subject=%q. "+
		"The hold gate did not run before key material was touched.", tenantID, subjectID)
	return KeyDestructionReceipt{}, nil
}

// countingDestroyer records calls and participates in the shared sequence.
type countingDestroyer struct {
	seq      *sequenceRecorder
	calls    int
	failWith error
}

func (d *countingDestroyer) DestroySubjectKeys(_ context.Context, tenantID, subjectID string) (KeyDestructionReceipt, error) {
	d.calls++
	d.seq.record(seqKeyDestroyed)
	if d.failWith != nil {
		return KeyDestructionReceipt{}, d.failWith
	}
	return KeyDestructionReceipt{TenantID: tenantID, SubjectID: subjectID, KeysRemoved: 1, DestroyedAt: time.Unix(1700000000, 0).UTC()}, nil
}

// fakePseudonymiser produces a deterministic, obviously-not-cleartext pseudonym.
//
// The prefix matters for one assertion in particular: a test proving the audit trail does not carry
// the cleartext subject needs the pseudonym to be visibly distinct from the subject, or the
// assertion passes whether or not pseudonymisation happened.
type fakePseudonymiser struct {
	failWith error
}

func (p fakePseudonymiser) Pseudonym(tenantID, value string) (string, error) {
	if p.failWith != nil {
		return "", p.failWith
	}
	return fmt.Sprintf("pseudo(%s/%s)", tenantID, value), nil
}

// testOperator is a registered operator with a usable signing key.
type testOperator struct {
	id     string
	public ed25519.PublicKey
	secret ed25519.PrivateKey
}

func newTestOperator(t *testing.T, id string) testOperator {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate ed25519 key for %s: %v", id, err)
	}
	return testOperator{id: id, public: pub, secret: priv}
}

// registryOf builds an OperatorRegistry granting every supplied operator the override capability.
func registryOf(t *testing.T, ops ...testOperator) *OperatorRegistry {
	t.Helper()
	entries := make([]Operator, 0, len(ops))
	for _, op := range ops {
		entries = append(entries, Operator{
			ID:           op.id,
			PublicKey:    op.public,
			Capabilities: []OperatorCapability{CapabilityGrantErasureOverride},
		})
	}
	reg, err := NewOperatorRegistry(entries)
	if err != nil {
		t.Fatalf("build operator registry: %v", err)
	}
	return reg
}

// readMigration008 reads the SQL this card added, for the cross-artifact guards.
//
// It reads the file from disk rather than importing identity.Migration008RetentionLegalHolds
// because privacy must not depend on identity for a test convenience, and because reading the file
// is what proves the file on disk — the thing that actually runs — carries the constraint.
func readMigration008(t *testing.T) string {
	t.Helper()
	const path = "../identity/migrations/008_retention_legal_holds.sql"
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if len(body) == 0 {
		t.Fatalf("%s is empty; every constraint assertion would pass vacuously", path)
	}
	return string(body)
}

// newHealthyAudit returns a fail-closed-but-working audit writer.
func newHealthyAudit() *audit.FakeWriter { return audit.NewFakeWriter() }

// fixedClock returns a clock function pinned to t.
func fixedClock(at time.Time) func() time.Time {
	return func() time.Time { return at }
}

// testNow is the pinned decision-time instant used across the suite. A fixed clock is what makes
// the expiry-boundary assertions exact rather than flaky-adjacent.
var testNow = time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)

// containmentHold is the abuse case's hold: an actor under ACTIVE containment tied to a live
// incident.
func containmentHold(subject string) Hold {
	return Hold{
		ID:          "quarantine:" + subject,
		SubjectID:   subject,
		TenantID:    "tenant-a",
		Kind:        HoldActiveContainment,
		IncidentRef: "quarantine/forged_claim",
		OpenedAt:    testNow.Add(-2 * time.Hour),
	}
}

// serviceFixture bundles a Service with the doubles it was built from, so assertions can reach
// both.
type serviceFixture struct {
	svc       *Service
	incidents *fakeIncidentSource
	destroyer *countingDestroyer
	auditLog  *audit.FakeWriter
	registry  *OperatorRegistry
	seq       *sequenceRecorder
	operators []testOperator
}

// newServiceFixture builds a Service whose destroyer COUNTS calls. Use it for permitted paths and
// for ordering assertions.
func newServiceFixture(t *testing.T, source *fakeIncidentSource, seq *sequenceRecorder, ops ...testOperator) serviceFixture {
	t.Helper()
	if len(ops) == 0 {
		ops = []testOperator{newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")}
	}
	registry := registryOf(t, ops...)
	auditLog := audit.NewFakeWriter()
	destroyer := &countingDestroyer{seq: seq}
	svc, err := NewService(Config{
		Incidents:     source,
		Destroyer:     destroyer,
		Audit:         auditLog,
		Operators:     registry,
		Pseudonymiser: fakePseudonymiser{},
		Now:           fixedClock(testNow),
	})
	if err != nil {
		t.Fatalf("construct service: %v", err)
	}
	return serviceFixture{svc: svc, incidents: source, destroyer: destroyer, auditLog: auditLog, registry: registry, seq: seq, operators: ops}
}

// newTripwireFixture builds a Service whose destroyer FAILS THE TEST if reached. Use it for every
// refusal path.
func newTripwireFixture(t *testing.T, source *fakeIncidentSource, ops ...testOperator) serviceFixture {
	t.Helper()
	if len(ops) == 0 {
		ops = []testOperator{newTestOperator(t, "op-alice"), newTestOperator(t, "op-bob")}
	}
	registry := registryOf(t, ops...)
	auditLog := audit.NewFakeWriter()
	svc, err := NewService(Config{
		Incidents:     source,
		Destroyer:     tripwireDestroyer{t: t},
		Audit:         auditLog,
		Operators:     registry,
		Pseudonymiser: fakePseudonymiser{},
		Now:           fixedClock(testNow),
	})
	if err != nil {
		t.Fatalf("construct service: %v", err)
	}
	return serviceFixture{svc: svc, incidents: source, auditLog: auditLog, registry: registry, seq: source.seq, operators: ops}
}

// baseRequest is a structurally valid, fresh erasure request.
func baseRequest(subject string) ErasureRequest {
	return ErasureRequest{
		RequestID:   "req-001",
		TenantID:    "tenant-a",
		SubjectID:   subject,
		RequestedBy: "op-requester",
		RequestedAt: testNow.Add(-time.Hour),
	}
}

// validException builds a well-formed exception signed by the supplied operators.
func validException(t *testing.T, req ErasureRequest, ops ...testOperator) *RetentionException {
	t.Helper()
	e := RetentionException{
		SubjectID: req.SubjectID,
		TenantID:  req.TenantID,
		Ground:    GroundLegalClaims,
		RequestID: req.RequestID,
		IssuedAt:  testNow.Add(-time.Minute),
		ExpiresAt: testNow.Add(24 * time.Hour),
		ReviewBy:  testNow.Add(12 * time.Hour),
	}
	for _, op := range ops {
		approval, err := SignApproval(e, op.id, op.secret)
		if err != nil {
			t.Fatalf("sign approval as %s: %v", op.id, err)
		}
		e.Approvals = append(e.Approvals, approval)
	}
	return &e
}

// packageGoSources reads every NON-TEST .go file in this package.
//
// Test files are excluded deliberately. A guard that greps for a forbidden token will otherwise
// match the very test that forbids it — the assertion becomes self-satisfying and reports a
// violation that exists only in its own source. The count assertion at the call site is what stops
// this returning an empty map and passing vacuously.
func packageGoSources(t *testing.T) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package directory: %v", err)
	}
	out := map[string]string{}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		body, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		out[name] = string(body)
	}
	return out
}

// auditDetail decodes the nth audit event's detail into a map for field assertions.
func auditDetail(t *testing.T, w *audit.FakeWriter, n int) map[string]any {
	t.Helper()
	events := w.Events()
	if len(events) <= n {
		t.Fatalf("wanted audit event %d, only %d were written", n, len(events))
	}
	var out map[string]any
	if err := json.Unmarshal(events[n].Detail, &out); err != nil {
		t.Fatalf("decode audit detail: %v", err)
	}
	return out
}
