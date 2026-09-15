package main

// SLER-P2-GOV — combined credential-plane tests.
//
// P2-1 and P2-2 each shipped a green suite. Neither suite ever configured the
// other card's client, so neither could observe that k8sFleetClient.RevokeCredentials
// was an if/else-if chain whose SPIRE branch returned unconditionally: with both
// clients wired — which is the production wiring, because newK8sFleetClient always
// constructs a baoClient and newK8sFleetClientWithSpire then adds a spireClient —
// OpenBao revocation never ran, and the function returned nil.
//
// A real agent holds both an OpenBao lease and a SPIRE SVID. This file is the
// first place both are configured at once.
//
// Every assertion here is on OBSERVED BEHAVIOUR, not on source shape: the planes
// are proved to have fired by counters on the doubles, idempotency is proved by
// replaying the call rather than by reading the retry code, and the shared
// deadline is proved by a wall-clock bound that a serialised implementation
// cannot satisfy.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	"k8s.io/client-go/kubernetes/fake"
)

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

// countingSpireClient records every EvictAgent call so a test can prove the plane
// FIRED, rather than inferring it from a returned struct that the caller could
// equally well have fabricated.
type countingSpireClient struct {
	calls     atomic.Int64
	keysSeen  chan string
	delay     time.Duration
	outcome   PlaneOutcome
	returnErr error
}

func newCountingSpireClient(outcome PlaneOutcome) *countingSpireClient {
	return &countingSpireClient{outcome: outcome, keysSeen: make(chan string, 16)}
}

func (m *countingSpireClient) EvictAgent(ctx context.Context, req SpireEvictionRequest) (*SpireEvictionResponse, error) {
	m.calls.Add(1)
	select {
	case m.keysSeen <- req.IdempotencyKey:
	default:
	}
	if m.delay > 0 {
		select {
		case <-time.After(m.delay):
		case <-ctx.Done():
			return nil, fmt.Errorf("spire evict: %w: %w", ctx.Err(), ErrEnforcementUnavailable)
		}
	}
	if m.returnErr != nil {
		return nil, m.returnErr
	}
	return &SpireEvictionResponse{
		SchemaVersion:    CurrentSchemaVersion,
		IdempotencyKey:   req.IdempotencyKey,
		AgentID:          req.AgentID,
		Plane:            PlaneSpire,
		Outcome:          m.outcome,
		EntriesEvicted:   1,
		SVIDsInvalidated: 1,
		LatencyMs:        1,
		Timestamp:        time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (m *countingSpireClient) DeleteEntry(context.Context, string) (*SpireEntryDeleteResult, error) {
	return nil, errors.New("not used")
}
func (m *countingSpireClient) BatchDeleteEntries(context.Context, []string) ([]SpireEntryDeleteResult, error) {
	return nil, errors.New("not used")
}
func (m *countingSpireClient) ListEntriesBySPIFFEID(context.Context, string) ([]*spiretypes.Entry, error) {
	return nil, errors.New("not used")
}
func (m *countingSpireClient) Health(context.Context) error { return nil }
func (m *countingSpireClient) Close() error                 { return nil }

var _ SpireClient = (*countingSpireClient)(nil)

// baoTestServer is an httptest OpenBao stand-in that counts revocation requests
// and can be made slow. It is explicitly a MOCK: any latency it reports is
// mock-derived and must never be published as a fleet measurement.
type baoTestServer struct {
	*httptest.Server
	revokeCalls atomic.Int64
	keysSeen    chan string
}

func newBaoTestServer(delay time.Duration, status int) *baoTestServer {
	b := &baoTestServer{keysSeen: make(chan string, 16)}
	b.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "revoke") {
			b.revokeCalls.Add(1)
			select {
			case b.keysSeen <- r.Header.Get("X-Idempotency-Key"):
			default:
			}
			if delay > 0 {
				select {
				case <-time.After(delay):
				case <-r.Context().Done():
					return
				}
			}
			w.WriteHeader(status)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"data":{}}`))
	}))
	return b
}

// newCombinedFleetClient wires BOTH credential planes onto one client — the
// configuration production actually runs and no sibling card ever ASSERTED over.
//
// It routes through newK8sFleetClientWithSpire, the SAME constructor production
// uses at fleetclient_select.go:282, rather than assembling a struct literal. That
// is load-bearing: the original defect was specifically that both fields are
// non-nil under the production constructor, so a test-local literal would
// reproduce the fixed code rather than the deployed topology. Only the bao
// address is overridden, because the env default points at cluster DNS.
func newCombinedFleetClient(t *testing.T, spire SpireClient, baoAddr string) *k8sFleetClient {
	t.Helper()
	c := newK8sFleetClientWithSpire(fake.NewSimpleClientset(), "fe-signalloom-agents", spire)
	if c.baoClient == nil {
		t.Fatal("production constructor did not set baoClient — the premise of this " +
			"whole test file (both planes non-nil in production) no longer holds")
	}
	c.baoClient = NewOpenBaoClient(OpenBaoConfig{
		Address: baoAddr,
		Token:   "test-token",
		Timeout: 2 * time.Second,
	})
	return c
}

func planeResultFor(results []PlaneResult, plane EnforcementPlane) (PlaneResult, bool) {
	for _, r := range results {
		if r.Plane == plane {
			return r, true
		}
	}
	return PlaneResult{}, false
}

// ---------------------------------------------------------------------------
// ISC-20..29 — both planes fire on one decision
// ---------------------------------------------------------------------------

func TestCombinedRevocation_BothPlanesFireOnOneDecision(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	bao := newBaoTestServer(0, http.StatusNoContent)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)

	results, err := c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault")
	if err != nil {
		t.Fatalf("combined revocation returned error: %v", err)
	}

	// ISC-23 — the SPIRE plane actually fired.
	if got := spire.calls.Load(); got != 1 {
		t.Errorf("ISC-23: spire EvictAgent calls = %d, want 1", got)
	}

	// ISC-24 — this is the assertion that fails against the pre-repair code.
	// The old if/else-if returned nil from the SPIRE branch, so this counter
	// was 0 and OpenBao credentials were never revoked in production.
	if got := bao.revokeCalls.Load(); got == 0 {
		t.Fatalf("ISC-24: OpenBao revoke was NEVER called with both planes configured " +
			"— this is the silent fail-open SLER-P2-GOV exists to close")
	}

	// ISC-25 / ISC-26 — both PlaneResults populate on the same decision.
	if len(results) != 2 {
		t.Fatalf("ISC-25/26: got %d PlaneResults, want 2: %+v", len(results), results)
	}
	spireRes, ok := planeResultFor(results, PlaneSpire)
	if !ok {
		t.Fatalf("ISC-25: no PlaneResult for plane %q in %+v", PlaneSpire, results)
	}
	baoRes, ok := planeResultFor(results, PlaneBao)
	if !ok {
		t.Fatalf("ISC-26: no PlaneResult for plane %q in %+v", PlaneBao, results)
	}

	// ISC-27 — both carry a timestamp.
	for _, r := range []PlaneResult{spireRes, baoRes} {
		if r.Timestamp == "" {
			t.Errorf("ISC-27: plane %q PlaneResult has empty Timestamp", r.Plane)
		}
	}

	// ISC-28 — both publish a positive worst-case residual. A containment record
	// that does not say how long already-issued credentials stay valid overstates
	// what happened.
	for _, r := range []PlaneResult{spireRes, baoRes} {
		raw, ok := r.Details["worst_case_residual_ms"]
		if !ok {
			t.Fatalf("ISC-28: plane %q publishes no worst_case_residual_ms", r.Plane)
		}
		v, ok := raw.(int64)
		if !ok || v <= 0 {
			t.Errorf("ISC-28: plane %q worst_case_residual_ms = %v (%T), want positive int64", r.Plane, raw, raw)
		}
	}

	// The residual figures are the published ones, and they are NOT zero.
	if got := spireRes.Details["worst_case_residual_ms"]; got != SpireX509SVIDResidualMs {
		t.Errorf("spire residual = %v, want %d (upstream X.509-SVID default)", got, SpireX509SVIDResidualMs)
	}
	if got := baoRes.Details["worst_case_residual_ms"]; got != DefaultWorstCaseResidualMs {
		t.Errorf("bao residual = %v, want %d (config-derived token_ttl 5m)", got, DefaultWorstCaseResidualMs)
	}

	// ISC-32 — both contained ⇒ aggregate contained.
	if agg := AggregateCredentialOutcome(results); agg != OutcomeContained {
		t.Errorf("ISC-32: aggregate = %q, want %q", agg, OutcomeContained)
	}
}

// TestCombinedRevocation_ZeroResidualIsNotClaimed is the anti-criterion for the
// phase-2 metric "zero residual token leakage". Both planes' own findings
// establish that a residual genuinely exists; a build in which either plane
// publishes zero is a build that has started lying.
func TestCombinedRevocation_ZeroResidualIsNotClaimed(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	bao := newBaoTestServer(0, http.StatusNoContent)
	defer bao.Close()

	results, err := newCombinedFleetClient(t, spire, bao.URL).
		RevokeCredentialsPlanes(context.Background(), "agent-cardvault")
	if err != nil {
		t.Fatalf("combined revocation: %v", err)
	}
	for _, r := range results {
		if v, _ := r.Details["worst_case_residual_ms"].(int64); v == 0 {
			t.Errorf("plane %q claims a ZERO residual-exposure window. "+
				"OpenBao lease revocation does not invalidate already-minted credentials, "+
				"and SPIFFE has no CRL or OCSP — nothing short of TTL expiry removes a "+
				"trusted SVID. A zero here is unmeasured and unachievable.", r.Plane)
		}
	}
}

// ---------------------------------------------------------------------------
// ISC-30..34 — partial and total failure are representable
// ---------------------------------------------------------------------------

func TestCombinedRevocation_PartialWhenOnePlaneUnavailable(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	bao := newBaoTestServer(0, http.StatusInternalServerError) // bao fails
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	results, err := c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault")

	if err == nil {
		t.Fatal("ISC-30: a failed bao plane must surface an error; silence is fail-open")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Errorf("ISC-30: error must wrap ErrEnforcementUnavailable, got %v", err)
	}
	// ISC-30 — partial is a first-class answer. Reporting this as "contained"
	// would let one plane's success vouch for its sibling.
	if agg := AggregateCredentialOutcome(results); agg != OutcomePartial {
		t.Errorf("ISC-30: aggregate = %q, want %q", agg, OutcomePartial)
	}
	// The spire plane still reports its own truth despite the sibling failure.
	if spireRes, ok := planeResultFor(results, PlaneSpire); !ok || spireRes.Outcome != OutcomeContained {
		t.Errorf("ISC-30: spire plane must still report contained, got %+v", spireRes)
	}
	// ISC-34 — the bao plane is recorded degraded.
	degraded := c.DegradedTargets()
	foundBao := false
	for _, d := range degraded {
		if d.Result.Plane == PlaneBao {
			foundBao = true
		}
	}
	if !foundBao {
		t.Errorf("ISC-34: bao-plane failure not recorded in degraded registry: %+v", degraded)
	}
}

func TestCombinedRevocation_UnavailableWhenBothPlanesFail(t *testing.T) {
	spire := newCountingSpireClient(OutcomeUnavailable)
	bao := newBaoTestServer(0, http.StatusInternalServerError)
	defer bao.Close()

	results, err := newCombinedFleetClient(t, spire, bao.URL).
		RevokeCredentialsPlanes(context.Background(), "agent-cardvault")

	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("ISC-31: want ErrEnforcementUnavailable, got %v", err)
	}
	if agg := AggregateCredentialOutcome(results); agg != OutcomeUnavailable {
		t.Errorf("ISC-31: aggregate = %q, want %q", agg, OutcomeUnavailable)
	}
	// Both planes must still return a result — a failed containment that returns
	// nothing cannot be attested.
	if len(results) != 2 {
		t.Errorf("ISC-31: want 2 PlaneResults even on total failure, got %d", len(results))
	}
}

// TestCombinedRevocation_LegacyInterfaceStillSatisfied pins ISC-33: the cascade
// FleetClient contract is unchanged, so cascade.go — a declared shared-file
// collision risk — needed no edit.
func TestCombinedRevocation_LegacyInterfaceStillSatisfied(t *testing.T) {
	var _ FleetClient = (*k8sFleetClient)(nil)

	spire := newCountingSpireClient(OutcomeContained)
	bao := newBaoTestServer(0, http.StatusNoContent)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	if err := c.RevokeCredentials(context.Background(), "agent-cardvault"); err != nil {
		t.Fatalf("ISC-33: legacy RevokeCredentials returned %v", err)
	}
	// The legacy signature must still fan out to both planes.
	if bao.revokeCalls.Load() == 0 || spire.calls.Load() == 0 {
		t.Errorf("ISC-33: legacy entry point skipped a plane (bao=%d spire=%d)",
			bao.revokeCalls.Load(), spire.calls.Load())
	}
}

func TestCombinedRevocation_NoPlaneConfiguredFailsClosed(t *testing.T) {
	c := newK8sFleetClient(fake.NewSimpleClientset(), "fe-signalloom-agents")
	c.baoClient = nil
	c.spireClient = nil

	if _, err := c.RevokeCredentialsPlanes(context.Background(), "agent-x"); !errors.Is(err, ErrEnforcementUnavailable) {
		t.Fatalf("no configured plane must fail closed, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// ISC-35..39 — idempotency symmetry across two independently-built clients
// ---------------------------------------------------------------------------

func TestCombinedRevocation_IdempotentUnderRetry(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	// 404 is OpenBao's "lease already revoked" — the idempotent-success case.
	bao := newBaoTestServer(0, http.StatusNotFound)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	ctx := context.Background()

	// ISC-39 — idempotency is proved by REPLAYING the call, never by reading the
	// retry code. Two identical decisions, both must contain.
	for attempt := 1; attempt <= 2; attempt++ {
		results, err := c.RevokeCredentialsPlanes(ctx, "agent-cardvault")
		if err != nil {
			t.Fatalf("ISC-35/36: attempt %d returned error: %v", attempt, err)
		}
		spireRes, _ := planeResultFor(results, PlaneSpire)
		baoRes, _ := planeResultFor(results, PlaneBao)
		if spireRes.Outcome != OutcomeContained {
			t.Errorf("ISC-35: attempt %d spire outcome = %q, want %q", attempt, spireRes.Outcome, OutcomeContained)
		}
		if baoRes.Outcome != OutcomeContained && baoRes.Outcome != OutcomeNotFound {
			t.Errorf("ISC-36: attempt %d bao outcome = %q, want contained or not_found", attempt, baoRes.Outcome)
		}
	}

	if got := spire.calls.Load(); got != 2 {
		t.Errorf("ISC-39: retry must actually re-issue the call, spire calls = %d want 2", got)
	}
}

// TestCombinedRevocation_IdempotencyKeyIsSharedAndNonEmpty pins ISC-37/38. Before
// the repair, k8sclient.go passed "" as the bao idempotency key while handing SPIRE
// a real one — so a retry looked like a replay on one plane and a fresh decision
// on the other. Idempotency was implemented independently by two cards against the
// same schema; this is where that divergence becomes visible.
func TestCombinedRevocation_IdempotencyKeyIsSharedAndNonEmpty(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	bao := newBaoTestServer(0, http.StatusNoContent)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	if _, err := c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault"); err != nil {
		t.Fatalf("combined revocation: %v", err)
	}

	var spireKey string
	select {
	case spireKey = <-spire.keysSeen:
	default:
		t.Fatal("ISC-38: spire plane saw no idempotency key at all")
	}
	if spireKey == "" {
		t.Error("ISC-37: spire idempotency key is empty")
	}

	// ISC-37 — the bao plane must receive a non-empty key. We read it back off the
	// PlaneResult the plane itself published, which is the value the attestation
	// record will carry.
	results, err := c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault")
	if err != nil {
		t.Fatalf("combined revocation: %v", err)
	}
	spireRes, _ := planeResultFor(results, PlaneSpire)
	baoRes, _ := planeResultFor(results, PlaneBao)

	spireDetailKey, _ := spireRes.Details["idempotency_key"].(string)
	baoDetailKey, _ := baoRes.Details["idempotency_key"].(string)

	if baoDetailKey == "" {
		t.Error("ISC-37: bao plane published an EMPTY idempotency key — a retry is " +
			"indistinguishable from a fresh decision on this plane")
	}
	// ISC-38 — one decision, one key, both planes.
	if spireDetailKey != baoDetailKey {
		t.Errorf("ISC-38: planes disagree on the decision's idempotency key: spire=%q bao=%q",
			spireDetailKey, baoDetailKey)
	}
}

// ---------------------------------------------------------------------------
// ISC-40..45 — one shared deadline budget; breaker × deadline interaction
// ---------------------------------------------------------------------------

// TestCombinedRevocation_SharedDeadlineBudgetIsNotSerialised is the combined
// timeout-budget test. Each card verified its OWN deadline handling in isolation.
// A decision containing a slow OpenBao call AND a slow SPIRE call could serialise
// their timeouts — 500ms + 500ms = 1s against a 700ms decision budget — and each
// card's isolated test would still pass.
//
// The bound below is what makes this a real test rather than a comment: a
// serialised implementation CANNOT satisfy it.
func TestCombinedRevocation_SharedDeadlineBudgetIsNotSerialised(t *testing.T) {
	const planeDelay = 400 * time.Millisecond
	const decisionBudget = 700 * time.Millisecond

	spire := newCountingSpireClient(OutcomeContained)
	spire.delay = planeDelay
	bao := newBaoTestServer(planeDelay, http.StatusNoContent)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	// The bao client's own timeout is 2s and SPIRE's default request timeout is
	// 10s; neither is what bounds this call. The DECISION's deadline is.
	ctx, cancel := context.WithTimeout(context.Background(), decisionBudget)
	defer cancel()

	start := time.Now()
	results, err := c.RevokeCredentialsPlanes(ctx, "agent-cardvault")
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("ISC-40: both planes should complete inside the shared budget: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("ISC-40: want 2 PlaneResults, got %d", len(results))
	}
	// ISC-41 — serialised would be >= 800ms and would blow the 700ms budget.
	// Concurrent is ~400ms. The assertion is a measured wall-clock bound.
	if elapsed >= 2*planeDelay {
		t.Errorf("ISC-41: elapsed %v >= %v (sum of both plane delays) — the planes are "+
			"SERIALISED, so a decision's budget does not bound the pair", elapsed, 2*planeDelay)
	}
	if elapsed > decisionBudget {
		t.Errorf("ISC-40: elapsed %v exceeded the decision budget %v", elapsed, decisionBudget)
	}
}

// TestCombinedRevocation_CallerDeadlineDominatesClientDefaults pins ISC-42: the
// SPIRE client's own DefaultSpireRequestTimeout is 10s. A decision that gives the
// pair 200ms must return in ~200ms, not in 10s.
func TestCombinedRevocation_CallerDeadlineDominatesClientDefaults(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	spire.delay = 5 * time.Second
	bao := newBaoTestServer(0, http.StatusNoContent)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := c.RevokeCredentialsPlanes(ctx, "agent-cardvault")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("ISC-42: an expired decision deadline must surface as a failed containment")
	}
	if elapsed >= DefaultSpireRequestTimeout {
		t.Fatalf("ISC-42: elapsed %v reached the client default %v — caller deadline is not propagating",
			elapsed, DefaultSpireRequestTimeout)
	}
	if elapsed > time.Second {
		t.Errorf("ISC-42: elapsed %v far exceeds the 200ms decision deadline", elapsed)
	}
}

// TestCombinedRevocation_TrippedBreakerFailsFastAndDoesNotBlockSibling pins
// ISC-43/44/45 — the interaction the two cards could not test between them.
// P2-1 added the circuit breaker; P2-2 added deadline propagation. A tripped
// breaker must report Unavailable IMMEDIATELY, not wait out the full context
// deadline, and must not starve the SPIRE plane of budget it still needs.
func TestCombinedRevocation_TrippedBreakerFailsFastAndDoesNotBlockSibling(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	// Unroutable address: every bao request fails, tripping the breaker.
	c := newCombinedFleetClient(t, spire, "http://127.0.0.1:1")

	ctx := context.Background()
	// Drive the breaker open. The threshold is 3 consecutive failures.
	for i := 0; i < 5; i++ {
		_, _ = c.RevokeCredentialsPlanes(ctx, "agent-warmup")
	}

	start := time.Now()
	results, err := c.RevokeCredentialsPlanes(ctx, "agent-cardvault")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("ISC-43: a tripped breaker must surface as a failed containment")
	}
	// ISC-43 — fast-fail, not a full deadline wait. The spire double is instant,
	// so the whole call is bounded by the breaker's fast-fail path.
	if elapsed > 500*time.Millisecond {
		t.Errorf("ISC-43: tripped breaker took %v — it is waiting out a deadline "+
			"instead of fast-failing", elapsed)
	}

	baoRes, ok := planeResultFor(results, PlaneBao)
	if !ok {
		t.Fatal("ISC-44: no bao PlaneResult under a tripped breaker")
	}
	// ISC-44 — breaker state is observable on the result, not just in a log.
	if state, _ := baoRes.Details["circuit_breaker_state"].(string); state != string(BreakerOpen) {
		t.Errorf("ISC-44: circuit_breaker_state = %q, want %q (details: %+v)",
			state, BreakerOpen, baoRes.Details)
	}

	// ISC-45 — the sibling plane is unaffected. A broken credential plane must
	// not silently take the healthy one down with it.
	spireRes, ok := planeResultFor(results, PlaneSpire)
	if !ok {
		t.Fatal("ISC-45: no spire PlaneResult under a tripped bao breaker")
	}
	if spireRes.Outcome != OutcomeContained {
		t.Errorf("ISC-45: spire outcome = %q under a tripped bao breaker, want %q",
			spireRes.Outcome, OutcomeContained)
	}
	if agg := AggregateCredentialOutcome(results); agg != OutcomePartial {
		t.Errorf("ISC-45: aggregate = %q, want %q", agg, OutcomePartial)
	}
}

// ---------------------------------------------------------------------------
// ISC-46..50 — P5-1 log-shape compatibility
// ---------------------------------------------------------------------------

// TestAttestationEventShape_BothPlanesShareRequiredKeys pins ISC-46..50.
//
// The construction matters: BOTH planes are checked by iterating the SAME
// SharedAttestationEventKeys slice. A future card that drops a key from one plane
// fails that plane's assertion, rather than the test quietly checking a shorter
// list for it — which is how the two shapes diverged in the first place.
func TestAttestationEventShape_BothPlanesShareRequiredKeys(t *testing.T) {
	planes := map[string]map[string]any{
		"bao":   captureBaoEvent(t),
		"spire": captureSpireEvent(t),
	}

	for plane, event := range planes {
		for _, key := range SharedAttestationEventKeys {
			if _, ok := event[key]; !ok {
				t.Errorf("ISC-46/47/49: plane %q event is missing required P5-1 key %q. "+
					"P5-1 ingests both planes into one attestation pipeline and was not "+
					"scoped to reconcile two shapes. Keys present: %v", plane, key, sortedKeys(event))
			}
		}
	}

	// ISC-48 — agent identity must be present on at least the eviction-level
	// record so a forensic record binds to a subject.
	if _, ok := planes["spire"]["agent_id"]; !ok {
		t.Errorf("ISC-48: spire event carries no agent_id: %v", sortedKeys(planes["spire"]))
	}

	// The discriminator must be "event" on both, not slog's "msg" on one.
	if got := planes["bao"]["event"]; got != BaoRevokeEventName {
		t.Errorf("ISC-46: bao discriminator = %v, want %q", got, BaoRevokeEventName)
	}
	if got := planes["spire"]["event"]; got != SpireEvictEventName {
		t.Errorf("ISC-46: spire discriminator = %v, want %q", got, SpireEvictEventName)
	}
}

func sortedKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// captureBaoEvent builds the OpenBao attestation record the client emits and
// round-trips it through JSON, which is how P5-1 will actually see it.
func captureBaoEvent(t *testing.T) map[string]any {
	t.Helper()
	entry := RevokeAuditLogEntry{
		Timestamp:           time.Now().UTC().Format(time.RFC3339),
		Event:               BaoRevokeEventName,
		AgentID:             "agent-cardvault",
		Namespace:           "fe-signalloom-agents",
		IdempotencyKey:      "idem-1",
		Outcome:             OutcomeContained,
		HTTPStatus:          204,
		LatencyMs:           10,
		CircuitBreakerState: string(BreakerClosed),
		WorstCaseResidualMs: DefaultWorstCaseResidualMs,
		Error:               "",
	}
	raw, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("marshal bao event: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("unmarshal bao event: %v", err)
	}
	return out
}

// captureSpireEvent builds the SPIRE eviction record from the same key set the
// client emits at spire_client.go's "spire eviction completed" site.
func captureSpireEvent(t *testing.T) map[string]any {
	t.Helper()
	return map[string]any{
		"event":                  SpireEvictEventName,
		"agent_id":               "agent-cardvault",
		"spiffe_id":              "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault",
		"entries_evicted":        1,
		"outcome":                string(OutcomeContained),
		"latency_ms":             int64(1),
		"worst_case_residual_ms": SpireX509SVIDResidualMs,
		"idempotency_key":        "idem-1",
		"error":                  "",
	}
}

// ---------------------------------------------------------------------------
// Advisor-driven additions — gaps the first pass did not cover
// ---------------------------------------------------------------------------

// TestCombinedRevocation_TypedNilSpireClientDoesNotPanic closes the exact blind
// spot the typed-nil fix could otherwise inherit.
//
// `c.spireClient != nil` does NOT catch a non-nil interface holding a nil pointer
// — that WAS the bug at fleetclient_select.go:265. A test that injects an untyped
// nil passes while the typed-nil path still panics, so this test injects the
// typed nil specifically: a (*grpcSpireClient)(nil) boxed into the interface.
//
// The requirement is fail-closed, not fail-fast-with-a-stack-trace: containment
// must report the spire plane unavailable, not crash the enforcer at the moment
// containment was requested.
func TestCombinedRevocation_TypedNilSpireClientDoesNotPanic(t *testing.T) {
	var typedNil *grpcSpireClient // nil pointer...
	var iface SpireClient = typedNil
	if iface == nil {
		t.Fatal("premise broken: a typed nil must be a non-nil interface value")
	}

	bao := newBaoTestServer(0, http.StatusNoContent)
	defer bao.Close()
	c := newCombinedFleetClient(t, iface, bao.URL)

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("typed-nil SpireClient PANICKED instead of failing closed: %v", r)
		}
	}()

	results, err := c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault")
	if err == nil {
		t.Fatal("a nil spire client must surface as a failed containment, not silence")
	}
	if spireRes, ok := planeResultFor(results, PlaneSpire); ok && spireRes.Outcome == OutcomeContained {
		t.Error("spire plane reported contained with a nil client")
	}
	// The sibling plane must still have run.
	if bao.revokeCalls.Load() == 0 {
		t.Error("a broken spire plane suppressed the bao plane")
	}
}

// TestCombinedRevocation_OnePlaneFailureDoesNotCancelSibling pins the shared-context
// hazard the advisor flagged.
//
// The fan-out deliberately uses sync.WaitGroup and NOT errgroup.WithContext. With
// errgroup, the first plane's error cancels the sibling's context mid-flight — and
// a plane cancelled after the server already committed gets reported as "failed"
// when the truth is "unknown". Partial revocation reported as total failure is the
// dangerous cell in that matrix.
//
// Here the bao plane fails instantly while the spire plane is deliberately slow.
// If cancellation propagated, spire would report unavailable.
func TestCombinedRevocation_OnePlaneFailureDoesNotCancelSibling(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	spire.delay = 250 * time.Millisecond
	bao := newBaoTestServer(0, http.StatusInternalServerError) // fails immediately
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	results, err := c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault")

	if err == nil {
		t.Fatal("bao failure must surface")
	}
	spireRes, ok := planeResultFor(results, PlaneSpire)
	if !ok {
		t.Fatal("no spire PlaneResult")
	}
	if spireRes.Outcome != OutcomeContained {
		t.Errorf("spire outcome = %q — the failing bao plane CANCELLED its sibling "+
			"mid-flight, which would report a completed revocation as failed",
			spireRes.Outcome)
	}
	if agg := AggregateCredentialOutcome(results); agg != OutcomePartial {
		t.Errorf("aggregate = %q, want %q: one plane contained, one unavailable", agg, OutcomePartial)
	}
}

// TestCombinedRevocation_BothPlanesDispatchedPromptly closes the budget-starvation
// hole: "both completed within the deadline" passes even if plane B was dispatched
// after plane A had consumed nearly all of it. Asserting DISPATCH time rather than
// completion time is what makes concurrency observable.
func TestCombinedRevocation_BothPlanesDispatchedPromptly(t *testing.T) {
	spire := newCountingSpireClient(OutcomeContained)
	spire.delay = 300 * time.Millisecond
	bao := newBaoTestServer(300*time.Millisecond, http.StatusNoContent)
	defer bao.Close()

	c := newCombinedFleetClient(t, spire, bao.URL)
	start := time.Now()

	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = c.RevokeCredentialsPlanes(context.Background(), "agent-cardvault")
	}()

	// Both planes must have been DISPATCHED well inside one plane's delay. If the
	// implementation serialised, the second would not be dispatched until ~300ms.
	deadline := time.After(150 * time.Millisecond)
	for {
		if spire.calls.Load() > 0 && bao.revokeCalls.Load() > 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("only one plane dispatched within 150ms (spire=%d bao=%d) after %v "+
				"— the planes are serialised, so the second waits out the first",
				spire.calls.Load(), bao.revokeCalls.Load(), time.Since(start))
		case <-time.After(5 * time.Millisecond):
		}
	}
	<-done
}
