package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// SLER-P1-5 — the cascade must not fabricate success.
//
// Before this card, cascade.go swallowed three distinct failures and then
// asserted the outcome anyway:
//
//	:90-91  currentState = StateRunning  // assume running if we can't read
//	:96     slog.Warn("failed to revoke credentials", ...)   // then continue
//	:101    slog.Warn("failed to set pod state", ...)        // then continue
//	:107    ToState: StateStunned, Success: true             // unconditionally
//
// and main.go's handleStun fell through to an implicit 200 on every path. A
// stun in which nothing at all was contained was byte-indistinguishable from
// one in which everything was.
//
// Every test below drives the defect through the EXISTING FleetClient
// interface with an injectable failing client. That is deliberate: the bug is
// in the orchestrator's swallow-and-continue logic, not in the client, so a
// real client (SLER-P1-1) returning these same errors would have hit the same
// three lines unchanged. This suite therefore neither depends on P1-1's real
// client nor on the noopFleetClient it retires — it is written against the
// interface both implement, so it survives either.

// failingClient is a FleetClient whose every method can be made to fail
// independently, and which records the namespace each call was routed to.
type failingClient struct {
	mu sync.Mutex

	getStateErr error
	setStateErr error
	revokeErr   error
	restoreErr  error

	states map[string]string

	// namespaces records ("op:agent") -> namespace for namespace-binding checks.
	namespaces map[string]string

	// beforeGetState runs before GetPodState returns. Used to mutate the DAG
	// mid-cascade.
	beforeGetState func(agentID string)
}

func newFailingClient() *failingClient {
	return &failingClient{
		states:     make(map[string]string),
		namespaces: make(map[string]string),
	}
}

func (c *failingClient) GetPodState(_ context.Context, namespace, agentID string) (string, error) {
	c.mu.Lock()
	c.namespaces["get:"+agentID] = namespace
	hook := c.beforeGetState
	err := c.getStateErr
	state, ok := c.states[agentID]
	c.mu.Unlock()

	if hook != nil {
		hook(agentID)
	}
	if err != nil {
		return "", err
	}
	if !ok {
		return StateRunning, nil
	}
	return state, nil
}

func (c *failingClient) SetPodState(_ context.Context, namespace, agentID, state string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.namespaces["set:"+agentID] = namespace
	if c.setStateErr != nil {
		return c.setStateErr
	}
	c.states[agentID] = state
	return nil
}

func (c *failingClient) RevokeCredentials(_ context.Context, _ string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.revokeErr
}

func (c *failingClient) RestoreCredentials(_ context.Context, _ string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.restoreErr
}

func (c *failingClient) namespaceFor(key string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.namespaces[key]
}

// singleAgentDAG builds a one-agent fleet so a test can isolate one target's
// behaviour without cascade fan-out noise.
func singleAgentDAG(t *testing.T, namespace string) *DAG {
	t.Helper()
	dag, err := BuildDAG([]Agent{{
		ID:        "agent-solo",
		Type:      "service",
		Namespace: namespace,
		State:     StateRunning,
	}})
	if err != nil {
		t.Fatalf("build single-agent DAG: %v", err)
	}
	return dag
}

// soleTarget returns the single TargetOutcome in a result, failing if there is
// not exactly one. Asserting the count first stops a test from silently
// checking the wrong target.
func soleTarget(t *testing.T, result *CascadeResult) TargetOutcome {
	t.Helper()
	if len(result.Targets) != 1 {
		t.Fatalf("expected exactly 1 target outcome, got %d: %+v", len(result.Targets), result.Targets)
	}
	return result.Targets[0]
}

// --- Swallow point 1: the unreadable pod state -------------------------------

func TestStun_UnreadableState_ReportsUnknownNotRunning(t *testing.T) {
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.getStateErr = fmt.Errorf("pods \"agent-solo\" is forbidden")

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)

	// The whole point of the card: the pre-fix code wrote StateRunning here.
	if got.FromState == StateRunning {
		t.Fatalf("regression: unreadable pod state reported as %q — this is the fabricated value the fix removed", StateRunning)
	}
	if got.FromState != StateUnknown {
		t.Fatalf("expected from_state %q, got %q", StateUnknown, got.FromState)
	}
	if got.StateRead.Succeeded {
		t.Fatal("state_read must not report success when GetPodState errored")
	}
	if !got.StateRead.Attempted {
		t.Fatal("state_read must record that it was attempted")
	}
	if !strings.Contains(got.StateRead.Error, "forbidden") {
		t.Fatalf("expected the read error to be carried on the result, got %q", got.StateRead.Error)
	}
}

func TestStun_UnreadableStateOnly_IsPartialNotContained(t *testing.T) {
	// GetPodState fails; revoke and set-state both succeed. Containment was
	// achieved, but we cannot say what the agent was beforehand. That is a
	// partial success and must collapse to neither full success nor full
	// failure.
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.getStateErr = fmt.Errorf("apiserver timeout")

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if got.Outcome != OutcomePartial {
		t.Fatalf("expected outcome %q, got %q", OutcomePartial, got.Outcome)
	}
	if !got.Credential.Succeeded || !got.StateWrite.Succeeded {
		t.Fatalf("premise broken: revoke and set-state were supposed to succeed, got %+v / %+v", got.Credential, got.StateWrite)
	}
	// The label write DID succeed, so stunned is the honest to_state here.
	if got.ToState != StateStunned {
		t.Fatalf("expected to_state %q after a successful label write, got %q", StateStunned, got.ToState)
	}
	if got.FromState != StateUnknown {
		t.Fatalf("expected from_state %q, got %q", StateUnknown, got.FromState)
	}
	if result.OverallOutcome != OutcomePartial {
		t.Fatalf("expected overall outcome %q, got %q", OutcomePartial, result.OverallOutcome)
	}
}

// --- Swallow point 2: the failed credential revoke ---------------------------

func TestStun_RevokeFailure_IsRecordedNotSwallowed(t *testing.T) {
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.revokeErr = fmt.Errorf("openbao unreachable")

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if got.Credential.Succeeded {
		t.Fatal("credential step must not report success when RevokeCredentials errored")
	}
	if !strings.Contains(got.Credential.Error, "openbao unreachable") {
		t.Fatalf("expected the revoke error on the result, got %q", got.Credential.Error)
	}
	if got.Outcome == OutcomeContained {
		t.Fatal("regression: a target whose credential revoke failed must not report contained")
	}
	if got.Outcome != OutcomePartial {
		t.Fatalf("expected outcome %q, got %q", OutcomePartial, got.Outcome)
	}
	if len(result.FailedTargets()) != 1 {
		t.Fatalf("expected 1 failed target, got %v", result.FailedTargets())
	}
	// The dashboard-facing event must agree with the target record.
	if len(result.Events) != 1 || result.Events[0].Success {
		t.Fatalf("event must not report success=true for a failed revoke: %+v", result.Events)
	}
}

// --- Swallow point 3: the failed label write ---------------------------------

func TestStun_SetStateFailure_DoesNotReportStunned(t *testing.T) {
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.states["agent-solo"] = StateRunning
	client.setStateErr = fmt.Errorf("conflict: object has been modified")

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if got.ToState == StateStunned {
		t.Fatalf("regression: to_state reported %q after the label write failed — this is the unconditional append the fix removed", StateStunned)
	}
	if got.ToState != StateRunning {
		t.Fatalf("expected to_state to stay at the read value %q, got %q", StateRunning, got.ToState)
	}
	if got.StateWrite.Succeeded {
		t.Fatal("state_write must not report success when SetPodState errored")
	}
	if got.Outcome != OutcomePartial {
		t.Fatalf("expected outcome %q (revoke succeeded, write did not), got %q", OutcomePartial, got.Outcome)
	}
}

// --- The exact defect this card exists to fix --------------------------------

func TestStun_AllThreeFailuresInjected_ReportsTotalFailure(t *testing.T) {
	// Read, revoke and set-state all fail. Pre-fix this produced:
	//   from_state "running" (fabricated), to_state "stunned" (fabricated),
	//   success: true, HTTP 200.
	// Nothing whatsoever was contained.
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.getStateErr = fmt.Errorf("get forbidden")
	client.revokeErr = fmt.Errorf("revoke refused")
	client.setStateErr = fmt.Errorf("patch refused")

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)

	if got.FromState == StateRunning {
		t.Fatal("regression: fabricated from_state=running")
	}
	if got.ToState == StateStunned {
		t.Fatal("regression: fabricated to_state=stunned after every step failed")
	}
	if got.Outcome != OutcomeUnavailable {
		t.Fatalf("expected outcome %q when nothing was contained, got %q", OutcomeUnavailable, got.Outcome)
	}
	if result.OverallOutcome != OutcomeUnavailable {
		t.Fatalf("expected overall outcome %q, got %q", OutcomeUnavailable, result.OverallOutcome)
	}
	if result.Events[0].Success {
		t.Fatal("regression: event reported success=true after every step failed")
	}

	// All three errors must be retrievable, not just the last one.
	errs := got.Errors()
	if len(errs) != 3 {
		t.Fatalf("expected 3 recorded errors, got %d: %v", len(errs), errs)
	}

	// And the HTTP surface must not answer 200.
	code := cascadeStatusCode(result.OverallOutcome)
	if code == http.StatusOK {
		t.Fatal("regression: total containment failure mapped to HTTP 200")
	}
	if code != http.StatusInternalServerError {
		t.Fatalf("expected 500 for a wholly failed containment, got %d", code)
	}
}

func TestStun_ReadSucceedsButBothEnforcementStepsFail_IsNeverContained(t *testing.T) {
	// The inverse of the read-only failure: we know exactly what the agent was,
	// and we changed nothing about it. Reading a label contains nothing, so the
	// honest verdict is unavailable — certainly never contained.
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.states["agent-solo"] = StateRunning
	client.revokeErr = fmt.Errorf("openbao 503")
	client.setStateErr = fmt.Errorf("apiserver 503")

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if !got.StateRead.Succeeded {
		t.Fatal("premise broken: the state read was supposed to succeed")
	}
	if got.Outcome == OutcomeContained {
		t.Fatal("a target with zero successful enforcement steps must never report contained")
	}
	if got.Outcome != OutcomeUnavailable && got.Outcome != OutcomePartial {
		t.Fatalf("expected partial or unavailable, got %q", got.Outcome)
	}
	if got.Outcome != OutcomeUnavailable {
		t.Fatalf("expected %q specifically: no containment was achieved, got %q", OutcomeUnavailable, got.Outcome)
	}
}

// --- 'not found' is a distinct outcome ---------------------------------------

func TestStun_TargetMissingFromDAG_ReportsNotFound(t *testing.T) {
	// A cascade target that vanishes from the topology between target
	// computation and its turn in the loop. Pre-fix this was a bare `continue`:
	// the agent simply disappeared from the result, so a caller could not tell
	// "no such agent" from "agent contained".
	dag := mustBuildTestDAG(t)
	client := newFailingClient()

	const vanishing = "agent-txn-pipeline"
	var once sync.Once
	client.beforeGetState = func(_ string) {
		once.Do(func() { delete(dag.agents, vanishing) })
	}

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-cardvault")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Premise check: the agent must actually have gone missing.
	if dag.GetAgent(vanishing) != nil {
		t.Fatal("premise broken: the target was supposed to be removed from the DAG mid-cascade")
	}

	var missing *TargetOutcome
	for i := range result.Targets {
		if result.Targets[i].AgentID == vanishing {
			missing = &result.Targets[i]
		}
	}
	if missing == nil {
		t.Fatalf("regression: the missing target was silently dropped from the result; got %v", result.AffectedAgents)
	}

	if missing.Outcome != OutcomeNotFound {
		t.Fatalf("expected outcome %q, got %q", OutcomeNotFound, missing.Outcome)
	}
	// The three coercions an operator must never be handed.
	if missing.Outcome == OutcomeContained {
		t.Fatal("'not found' must not be reported as success")
	}
	if missing.Outcome == OutcomeUnavailable {
		t.Fatal("'not found' must not be coerced into 'unavailable' — that sends the operator to check plane connectivity for a stale target ID")
	}
	if missing.Outcome == OutcomePartial {
		t.Fatal("'not found' must not be coerced into 'partial'")
	}

	if got := result.NotFoundTargets(); len(got) != 1 || got[0] != vanishing {
		t.Fatalf("expected NotFoundTargets to be [%s], got %v", vanishing, got)
	}
	// A not-found target is not a containment failure and must not be counted
	// as one.
	for _, id := range result.FailedTargets() {
		if id == vanishing {
			t.Fatal("'not found' must not appear in FailedTargets")
		}
	}
}

func TestPlaneOutcome_NotFoundIsADistinctValidValue(t *testing.T) {
	if !OutcomeNotFound.IsValid() {
		t.Fatal("OutcomeNotFound must be a recognised PlaneOutcome value")
	}
	for _, other := range []PlaneOutcome{OutcomeContained, OutcomePartial, OutcomeUnavailable} {
		if OutcomeNotFound == other {
			t.Fatalf("OutcomeNotFound must not alias %q", other)
		}
	}
	// And aggregation must not fold it into unavailable.
	all := AggregateOutcome([]PlaneResult{{Outcome: OutcomeNotFound}, {Outcome: OutcomeNotFound}})
	if all != OutcomeNotFound {
		t.Fatalf("an all-not-found set must aggregate to %q, got %q", OutcomeNotFound, all)
	}
	// Mixed with a real failure, nothing was contained, so the honest aggregate
	// is unavailable rather than partial.
	mixed := AggregateOutcome([]PlaneResult{{Outcome: OutcomeNotFound}, {Outcome: OutcomeUnavailable}})
	if mixed != OutcomeUnavailable {
		t.Fatalf("not_found mixed with unavailable must aggregate to %q, got %q", OutcomeUnavailable, mixed)
	}
	// Mixed with a success, some containment did happen.
	partial := AggregateOutcome([]PlaneResult{{Outcome: OutcomeNotFound}, {Outcome: OutcomeContained}})
	if partial != OutcomePartial {
		t.Fatalf("not_found mixed with contained must aggregate to %q, got %q", OutcomePartial, partial)
	}
}

// --- Idempotency under retry -------------------------------------------------

func TestStun_RetryOnAlreadyStunnedTarget_ReportsNoSpuriousFailure(t *testing.T) {
	// The mission's stopAndReport list makes a non-idempotent containment action
	// a hard blocker. A second stun of an already-stunned agent must be a clean
	// no-op-shaped success, not a new failure and not a new state claim.
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	first, err := orch.Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("first stun: %v", err)
	}
	if first.OverallOutcome != OutcomeContained {
		t.Fatalf("premise broken: first stun should have contained, got %q", first.OverallOutcome)
	}

	second, err := orch.Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("second stun: %v", err)
	}

	got := soleTarget(t, second)
	if got.Outcome != OutcomeContained {
		t.Fatalf("a retry against an already-stunned agent must still report %q, got %q (errors: %v)",
			OutcomeContained, got.Outcome, got.Errors())
	}
	if got.FromState != StateStunned {
		t.Fatalf("expected the retry to observe from_state %q, got %q", StateStunned, got.FromState)
	}
	if got.ToState != StateStunned {
		t.Fatalf("expected to_state %q, got %q", StateStunned, got.ToState)
	}
	if len(got.Errors()) != 0 {
		t.Fatalf("retry produced spurious errors: %v", got.Errors())
	}
	if len(second.FailedTargets()) != 0 {
		t.Fatalf("retry produced spurious failed targets: %v", second.FailedTargets())
	}
}

// --- DAG mutated concurrently with a running cascade -------------------------

func TestStun_DAGMutatedMidCascade_BindsToASingleObservation(t *testing.T) {
	// If a fleet topology refresh replaces an agent object while its containment
	// is in flight, the read and the write must not land in two different
	// namespaces. The orchestrator resolves the namespace once per target and
	// binds the whole attempt to that observation; this test fails if that
	// snapshot is ever replaced by a second o.dag.GetAgent(id) lookup at the
	// write site.
	const originalNS = "fe-signalloom-agents"
	const mutatedNS = "fe-signalloom-agents-v2"

	dag := singleAgentDAG(t, originalNS)
	before := dag.GetAgent("agent-solo")

	client := newFailingClient()
	client.beforeGetState = func(agentID string) {
		// Replace the agent object itself, not just a field, so a re-lookup
		// would genuinely observe a different object.
		dag.agents[agentID] = &Agent{
			ID:        agentID,
			Name:      agentID,
			Type:      "service",
			Namespace: mutatedNS,
			State:     StateRunning,
		}
	}

	result, err := NewCascadeOrchestrator(dag, client, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Premise checks: the mutation must really have happened, and GetAgent must
	// really return a different object now. Without these the test could pass
	// while blind.
	after := dag.GetAgent("agent-solo")
	if after == before {
		t.Fatal("premise broken: GetAgent returned the same object after the mid-cascade mutation")
	}
	if after.Namespace != mutatedNS {
		t.Fatalf("premise broken: expected mutated namespace %q, got %q", mutatedNS, after.Namespace)
	}

	readNS := client.namespaceFor("get:agent-solo")
	writeNS := client.namespaceFor("set:agent-solo")
	if readNS != writeNS {
		t.Fatalf("read and write split across namespaces: read %q, write %q", readNS, writeNS)
	}
	if writeNS != originalNS {
		t.Fatalf("expected the whole attempt bound to the namespace observed at lookup (%q), got %q", originalNS, writeNS)
	}
	if got := soleTarget(t, result); got.Namespace != originalNS {
		t.Fatalf("result must record the namespace actually used, expected %q got %q", originalNS, got.Namespace)
	}
}

// --- The HTTP surface --------------------------------------------------------

func serverWithClient(t *testing.T, dag *DAG, client FleetClient) *server {
	t.Helper()
	return &server{dag: dag, orchestrator: NewCascadeOrchestrator(dag, client, 0)}
}

func TestHandleStun_RevokeFailure_DoesNotReturn200(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newFailingClient()
	client.revokeErr = fmt.Errorf("openbao unreachable")
	s := serverWithClient(t, dag, client)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-llm-classifier", nil)
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code == http.StatusOK {
		t.Fatal("regression: a stun whose credential revoke failed answered HTTP 200")
	}
	if w.Code != http.StatusMultiStatus {
		t.Fatalf("expected 207 for partial containment, got %d", w.Code)
	}

	var result CascadeResult
	if err := json.NewDecoder(w.Body).Decode(&result); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if result.OverallOutcome != OutcomePartial {
		t.Fatalf("expected overall_outcome %q on the wire, got %q", OutcomePartial, result.OverallOutcome)
	}
	// The body must still carry the detail — a bare status code does not tell an
	// operator which plane failed on which agent.
	if len(result.Targets) == 0 {
		t.Fatal("expected per-target detail in the body of a non-200 response")
	}
}

func TestHandleStun_TotalFailure_Returns500(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newFailingClient()
	client.getStateErr = fmt.Errorf("get forbidden")
	client.revokeErr = fmt.Errorf("revoke refused")
	client.setStateErr = fmt.Errorf("patch refused")
	s := serverWithClient(t, dag, client)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-llm-classifier", nil)
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 when nothing was contained, got %d", w.Code)
	}

	var result CascadeResult
	if err := json.NewDecoder(w.Body).Decode(&result); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, ev := range result.Events {
		if ev.Success {
			t.Fatalf("regression: wire event claims success after total failure: %+v", ev)
		}
		if ev.ToState == StateStunned {
			t.Fatalf("regression: wire event claims to_state=stunned after total failure: %+v", ev)
		}
	}
}

func TestHandleRecover_RestoreFailure_DoesNotReturn200(t *testing.T) {
	// The mirror-image defect. Before this card handleRecover fell through to
	// 200 exactly as handleStun did, so a recovery that restored no credentials
	// at all told the operator their agents were back in service.
	dag := mustBuildTestDAG(t)
	client := newFailingClient()
	client.restoreErr = fmt.Errorf("spire entry create refused")
	s := serverWithClient(t, dag, client)

	body := strings.NewReader(`{"agent_ids":["agent-cardvault","agent-txn-pipeline"]}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", body)
	w := httptest.NewRecorder()
	s.handleRecover(w, req)

	if w.Code == http.StatusOK {
		t.Fatal("regression: a recovery whose credential restore failed answered HTTP 200")
	}
	if w.Code != http.StatusMultiStatus {
		t.Fatalf("expected 207 for partial recovery, got %d", w.Code)
	}

	var result CascadeResult
	if err := json.NewDecoder(w.Body).Decode(&result); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(result.FailedTargets()) != 2 {
		t.Fatalf("expected both targets recorded as failed, got %v", result.FailedTargets())
	}
	for _, tgt := range result.Targets {
		if tgt.Credential.Succeeded {
			t.Fatalf("credential step claimed success despite injected restore error: %+v", tgt)
		}
	}
}

func TestHandleRecover_TotalFailure_Returns500(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newFailingClient()
	client.restoreErr = fmt.Errorf("spire down")
	client.setStateErr = fmt.Errorf("apiserver down")
	s := serverWithClient(t, dag, client)

	body := strings.NewReader(`{"agent_ids":["agent-cardvault"]}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", body)
	w := httptest.NewRecorder()
	s.handleRecover(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 when nothing was recovered, got %d", w.Code)
	}
}

func TestRecover_DoesNotAssertFromStateStunned(t *testing.T) {
	// Recover previously hard-coded FromState: StateStunned, asserting the very
	// precondition a recovery should verify. With the agent actually running,
	// the honest from_state is "running".
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.states["agent-solo"] = StateRunning

	result, err := NewCascadeOrchestrator(dag, client, 0).Recover(context.Background(), []string{"agent-solo"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if got.FromState == StateStunned {
		t.Fatal("regression: recover asserted from_state=stunned without reading it")
	}
	if got.FromState != StateRunning {
		t.Fatalf("expected from_state %q, got %q", StateRunning, got.FromState)
	}
	if got.Operation != operationRecover {
		t.Fatalf("expected operation %q, got %q", operationRecover, got.Operation)
	}
}

func TestRecover_SetStateFailure_DoesNotReportRunning(t *testing.T) {
	// Found by the mutation sweep in docs/signalloom/sler-p1-5-proof.md: with
	// only the status-code tests covering the recovery path, hard-coding
	// Recover's to_state back to StateRunning survived every test in the suite.
	// The status code is derived from the step outcomes, so it cannot see a
	// fabricated to_state. This asserts the field itself.
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.states["agent-solo"] = StateStunned
	client.setStateErr = fmt.Errorf("apiserver conflict")

	result, err := NewCascadeOrchestrator(dag, client, 0).Recover(context.Background(), []string{"agent-solo"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if got.ToState == StateRunning {
		t.Fatalf("regression: recover reported to_state %q after the label write failed", StateRunning)
	}
	if got.ToState != StateStunned {
		t.Fatalf("expected to_state to stay at the read value %q, got %q", StateStunned, got.ToState)
	}
	if got.StateWrite.Succeeded {
		t.Fatal("state_write must not report success when SetPodState errored")
	}
	if got.Outcome == OutcomeContained {
		t.Fatal("a recovery whose label write failed must not report contained")
	}
}

func TestRecover_UnreadableState_ReportsUnknownNotStunned(t *testing.T) {
	// The recovery-side twin of the read fabrication. Guessing "stunned" here
	// would be exactly as wrong as guessing "running" on the stun side.
	dag := singleAgentDAG(t, "fe-signalloom-agents")
	client := newFailingClient()
	client.getStateErr = fmt.Errorf("pods is forbidden")

	result, err := NewCascadeOrchestrator(dag, client, 0).Recover(context.Background(), []string{"agent-solo"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := soleTarget(t, result)
	if got.FromState != StateUnknown {
		t.Fatalf("expected from_state %q, got %q", StateUnknown, got.FromState)
	}
	if got.StateRead.Succeeded {
		t.Fatal("state_read must not report success when GetPodState errored")
	}
	if got.Outcome != OutcomePartial {
		t.Fatalf("expected %q (both steps succeeded, state unknown), got %q", OutcomePartial, got.Outcome)
	}
}

func TestCascadeStatusCode_Mapping(t *testing.T) {
	cases := []struct {
		outcome PlaneOutcome
		want    int
	}{
		{OutcomeContained, http.StatusOK},
		{OutcomePartial, http.StatusMultiStatus},
		{OutcomeNotFound, http.StatusNotFound},
		{OutcomeUnavailable, http.StatusInternalServerError},
		// An outcome this build does not recognise must fail closed, never 200.
		{PlaneOutcome("something-new"), http.StatusInternalServerError},
	}
	for _, c := range cases {
		if got := cascadeStatusCode(c.outcome); got != c.want {
			t.Errorf("cascadeStatusCode(%q) = %d, want %d", c.outcome, got, c.want)
		}
	}
}

// --- Independence from SLER-P1-1 --------------------------------------------

func TestHonestyFix_IsIndependentOfTheClientImplementation(t *testing.T) {
	// The defect was in the orchestrator, not the client. This test states that
	// explicitly: the same orchestrator, driven through the same FleetClient
	// interface, reports contained when the client succeeds and unavailable when
	// it fails. Swapping in P1-1's real client changes which errors arrive, not
	// whether they are recorded.
	dag := singleAgentDAG(t, "fe-signalloom-agents")

	healthy := newFailingClient()
	ok, err := NewCascadeOrchestrator(dag, healthy, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("healthy client: %v", err)
	}
	if ok.OverallOutcome != OutcomeContained {
		t.Fatalf("a wholly successful client must report %q, got %q", OutcomeContained, ok.OverallOutcome)
	}

	broken := newFailingClient()
	broken.getStateErr = fmt.Errorf("x")
	broken.revokeErr = fmt.Errorf("y")
	broken.setStateErr = fmt.Errorf("z")
	bad, err := NewCascadeOrchestrator(singleAgentDAG(t, "fe-signalloom-agents"), broken, 0).Stun(context.Background(), "agent-solo")
	if err != nil {
		t.Fatalf("broken client: %v", err)
	}
	if bad.OverallOutcome != OutcomeUnavailable {
		t.Fatalf("a wholly failing client must report %q, got %q", OutcomeUnavailable, bad.OverallOutcome)
	}
}
