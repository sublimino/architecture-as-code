package main

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

// mockFleetClient records calls for verification in tests.
type mockFleetClient struct {
	mu     sync.Mutex
	states map[string]string // agentID -> state
	calls  []string          // ordered call log
	// Set these to inject errors
	getStateErr error
	setStateErr error
	revokeErr   error
	restoreErr  error
	healthErr   error
}

// Health satisfies the FleetClient method added by SLER-P1-1. It records the
// call like every other method so an orchestrator that started probing health
// would show up in the call log rather than passing silently.
func (m *mockFleetClient) Health(_ context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, "Health")
	return m.healthErr
}

func newMockClient() *mockFleetClient {
	return &mockFleetClient{
		states: make(map[string]string),
	}
}

func (m *mockFleetClient) GetPodState(_ context.Context, _, agentID string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, fmt.Sprintf("GetPodState:%s", agentID))
	if m.getStateErr != nil {
		return "", m.getStateErr
	}
	state, ok := m.states[agentID]
	if !ok {
		return StateRunning, nil
	}
	return state, nil
}

func (m *mockFleetClient) SetPodState(_ context.Context, _, agentID, state string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, fmt.Sprintf("SetPodState:%s=%s", agentID, state))
	if m.setStateErr != nil {
		return m.setStateErr
	}
	m.states[agentID] = state
	return nil
}

// ReplaceContainedPod models a controller-owned pod (PodReplacer): a stunned
// agent is replaced, anything else is reported not contained so the
// orchestrator writes the running label instead. setStateErr is the release
// fault for both, and a dead context fails it as a real API call would.
func (m *mockFleetClient) ReplaceContainedPod(ctx context.Context, _, agentID string) PlaneResult {
	m.mu.Lock()
	defer m.mu.Unlock()
	res := PlaneResult{Plane: PlaneFreeze, Details: map[string]any{"agent_id": agentID, "action": replaceActionReplaced}}
	if m.states[agentID] != StateStunned {
		res.Details["action"] = replaceActionNotContained
		res.Outcome = OutcomeContained
		return res
	}
	m.calls = append(m.calls, fmt.Sprintf("ReplaceContainedPod:%s", agentID))
	err := m.setStateErr
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		res.Outcome, res.Error = OutcomeUnavailable, err.Error()
		return res
	}
	m.states[agentID] = StateReplaced
	res.Outcome = OutcomeContained
	return res
}

func (m *mockFleetClient) RevokeCredentials(_ context.Context, agentID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, fmt.Sprintf("RevokeCredentials:%s", agentID))
	return m.revokeErr
}

func (m *mockFleetClient) RestoreCredentials(_ context.Context, agentID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, fmt.Sprintf("RestoreCredentials:%s", agentID))
	return m.restoreErr
}

func (m *mockFleetClient) getCalls() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	cp := make([]string, len(m.calls))
	copy(cp, m.calls)
	return cp
}

func (m *mockFleetClient) getState(agentID string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.states[agentID]
}

func TestStun_CascadeFromRoot(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0) // no delay for tests

	result, err := orch.Stun(context.Background(), "agent-cardvault", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should affect cardvault + txn-pipeline + llm-classifier + api-gateway (not monitor)
	if len(result.AffectedAgents) != 4 {
		t.Fatalf("expected 4 affected agents, got %d: %v", len(result.AffectedAgents), result.AffectedAgents)
	}

	// All affected should now be stunned
	for _, id := range result.AffectedAgents {
		if client.getState(id) != StateStunned {
			t.Fatalf("expected %s to be stunned", id)
		}
	}

	// Monitor should NOT be stunned
	if client.getState("agent-monitor") == StateStunned {
		t.Fatal("agent-monitor should not be stunned")
	}

	// Events should match affected agents
	if len(result.Events) != 4 {
		t.Fatalf("expected 4 events, got %d", len(result.Events))
	}

	// Recovery order should be populated
	if len(result.RecoveryOrder) == 0 {
		t.Fatal("expected recovery order to be populated")
	}
}

func TestStun_LeafAgent(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	result, err := orch.Stun(context.Background(), "agent-llm-classifier", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result.AffectedAgents) != 1 {
		t.Fatalf("expected 1 affected agent, got %d", len(result.AffectedAgents))
	}
	if result.AffectedAgents[0] != "agent-llm-classifier" {
		t.Fatalf("expected agent-llm-classifier, got %q", result.AffectedAgents[0])
	}
}

func TestStun_UnknownAgent(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	_, err := orch.Stun(context.Background(), "nonexistent", "")
	if err == nil {
		t.Fatal("expected error for unknown agent")
	}
}

func TestStun_CallOrder(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	_, err := orch.Stun(context.Background(), "agent-llm-classifier", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	calls := client.getCalls()
	// For a single agent, expect: GetPodState, RevokeCredentials, SetPodState
	if len(calls) != 3 {
		t.Fatalf("expected 3 calls, got %d: %v", len(calls), calls)
	}
	if calls[0] != "GetPodState:agent-llm-classifier" {
		t.Fatalf("expected GetPodState first, got %q", calls[0])
	}
	if calls[1] != "RevokeCredentials:agent-llm-classifier" {
		t.Fatalf("expected RevokeCredentials second, got %q", calls[1])
	}
	if calls[2] != "SetPodState:agent-llm-classifier=stunned" {
		t.Fatalf("expected SetPodState third, got %q", calls[2])
	}
}

func TestRecover_TopologicalOrder(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	// Pre-set all as stunned
	client.states["agent-cardvault"] = StateStunned
	client.states["agent-txn-pipeline"] = StateStunned
	client.states["agent-llm-classifier"] = StateStunned
	client.states["agent-api-gateway"] = StateStunned

	orch := NewCascadeOrchestrator(dag, client, 0)

	// Pass stunned agents in reverse topological order to assert topological sorting
	stunned := []string{"agent-llm-classifier", "agent-api-gateway", "agent-txn-pipeline", "agent-cardvault"}
	result, err := orch.Recover(context.Background(), stunned)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// All should now be released: each stunned pod replaced.
	for _, id := range stunned {
		if client.getState(id) != StateReplaced {
			t.Fatalf("expected %s to be replaced, got %q", id, client.getState(id))
		}
	}

	// Recovery order should have root first
	if result.RecoveryOrder[0] != "agent-cardvault" {
		t.Fatalf("expected agent-cardvault first in recovery, got %q", result.RecoveryOrder[0])
	}

	pos := make(map[string]int)
	for i, id := range result.RecoveryOrder {
		pos[id] = i
	}
	if pos["agent-cardvault"] >= pos["agent-txn-pipeline"] {
		t.Fatalf("agent-cardvault must be ordered before agent-txn-pipeline: %v", result.RecoveryOrder)
	}
	if pos["agent-cardvault"] >= pos["agent-api-gateway"] {
		t.Fatalf("agent-cardvault must be ordered before agent-api-gateway: %v", result.RecoveryOrder)
	}
	if pos["agent-txn-pipeline"] >= pos["agent-llm-classifier"] {
		t.Fatalf("agent-txn-pipeline must be ordered before agent-llm-classifier: %v", result.RecoveryOrder)
	}

	// Restore calls should be in topological order
	calls := client.getCalls()
	var restoreCalls []string
	for _, c := range calls {
		if len(c) > 19 && c[:19] == "RestoreCredentials:" {
			restoreCalls = append(restoreCalls, c[19:])
		}
	}

	callPos := make(map[string]int)
	for i, id := range restoreCalls {
		callPos[id] = i
	}

	if callPos["agent-cardvault"] >= callPos["agent-txn-pipeline"] {
		t.Fatal("agent-cardvault must be restored before agent-txn-pipeline")
	}
	if callPos["agent-cardvault"] >= callPos["agent-api-gateway"] {
		t.Fatal("agent-cardvault must be restored before agent-api-gateway")
	}
	if callPos["agent-txn-pipeline"] >= callPos["agent-llm-classifier"] {
		t.Fatal("agent-txn-pipeline must be restored before agent-llm-classifier")
	}
}

func TestStun_ContextCancellation(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 100*time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	result, err := orch.Stun(ctx, "agent-cardvault", "")
	// Should have at least started (first agent before delay check)
	if result == nil {
		t.Fatal("expected partial result on cancellation")
	}
	// May or may not error depending on timing; at most 1 agent processed
	_ = err
}

// TestStun_ClientErrors_AreRecordedNotTolerated replaces
// TestStun_ClientErrors_AreTolerated, which asserted the defect SLER-P1-5 was
// raised to remove. That test's comment read "client failures are logged but
// tolerated" and it checked only that the cascade returned no error and emitted
// one event, both of which a wholly-failed containment also does. It was green
// throughout the entire lifetime of the bug.
//
// The contract kept: a per-target client failure is not a cascade-level error,
// because the cascade must go on to attempt the remaining targets.
// The contract added: "not a cascade-level error" is not "tolerated". The
// failure is now carried on the result.
func TestStun_ClientErrors_AreRecordedNotTolerated(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	client.revokeErr = fmt.Errorf("vault unavailable")
	orch := NewCascadeOrchestrator(dag, client, 0)

	// Still NOT a returned error -- one target's failure must not abort the
	// cascade for the others.
	result, err := orch.Stun(context.Background(), "agent-llm-classifier", "")
	if err != nil {
		t.Fatalf("expected cascade to continue despite client errors: %v", err)
	}
	if len(result.Events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(result.Events))
	}

	// ...but the failure must be visible on the result, not just in a log line.
	if result.OverallOutcome == OutcomeContained {
		t.Fatal("regression: a cascade whose credential revoke failed reported contained")
	}
	if len(result.FailedTargets()) != 1 {
		t.Fatalf("expected the failed target to be named, got %v", result.FailedTargets())
	}
	if result.Events[0].Success {
		t.Fatal("regression: event reported success=true after the revoke failed")
	}
	if !strings.Contains(result.Events[0].Error, "vault unavailable") {
		t.Fatalf("expected the client error on the event, got %q", result.Events[0].Error)
	}
}


func TestCascade_DownstreamIsolationOrder(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	start := time.Now()
	result, err := orch.Stun(context.Background(), "agent-cardvault", "cascade isolation order test")
	if err != nil {
		t.Fatalf("unexpected stun failure: %v", err)
	}
	elapsed := time.Since(start)

	// Sub-second SLA: must complete in <1000ms
	if elapsed >= 1000*time.Millisecond {
		t.Fatalf("cascade stun execution took %v, exceeding the 1000ms SLA", elapsed)
	}
	if !result.MeetsSLA() {
		t.Fatalf("result DurationMs=%d failed MeetsSLA check", result.DurationMs)
	}

	// Verify affected count: cardvault, txn-pipeline, api-gateway, llm-classifier
	if len(result.AffectedAgents) != 4 {
		t.Fatalf("expected 4 affected agents, got %d: %v", len(result.AffectedAgents), result.AffectedAgents)
	}

	// Order invariant:
	// 1. Target first (agent-cardvault)
	if result.AffectedAgents[0] != "agent-cardvault" {
		t.Fatalf("expected target first (agent-cardvault), got %s", result.AffectedAgents[0])
	}

	// 2. Direct dependants second (agent-txn-pipeline, agent-api-gateway)
	direct1 := result.AffectedAgents[1]
	direct2 := result.AffectedAgents[2]
	if !((direct1 == "agent-txn-pipeline" && direct2 == "agent-api-gateway") ||
		(direct1 == "agent-api-gateway" && direct2 == "agent-txn-pipeline")) {
		t.Fatalf("expected direct dependants second (txn-pipeline, api-gateway), got %s, %s", direct1, direct2)
	}

	// 3. Transitive dependants third (agent-llm-classifier)
	if result.AffectedAgents[3] != "agent-llm-classifier" {
		t.Fatalf("expected transitive dependant third (agent-llm-classifier), got %s", result.AffectedAgents[3])
	}

	// Observability agent (agent-monitor) strictly preserved and remains running
	for _, id := range result.AffectedAgents {
		if id == "agent-monitor" {
			t.Fatal("observability agent (agent-monitor) must not be included in cascade stun targets")
		}
	}
	if client.getState("agent-monitor") == StateStunned {
		t.Fatal("observability agent (agent-monitor) must not be stunned: it must remain running")
	}

	// All affected agents must be stunned
	for _, id := range result.AffectedAgents {
		if client.getState(id) != StateStunned {
			t.Fatalf("expected affected agent %s to be stunned", id)
		}
	}
}

func TestCascade_MultiTierTransitiveIsolation(t *testing.T) {
	fleetYAML := []byte(`
agents:
  - id: tier0-target
    type: data-vault
    team: platform
    dependencies: []
    namespace: fe-signalloom-agents
  - id: tier1-worker-a
    type: worker
    team: payments
    dependencies: [tier0-target]
    namespace: fe-signalloom-agents
  - id: tier1-worker-b
    type: worker
    team: edge
    dependencies: [tier0-target]
    namespace: fe-signalloom-agents
  - id: tier2-worker-a
    type: processing
    team: payments
    dependencies: [tier1-worker-a]
    namespace: fe-signalloom-agents
  - id: tier2-worker-b
    type: processing
    team: edge
    dependencies: [tier1-worker-b]
    namespace: fe-signalloom-agents
  - id: tier3-worker-c
    type: analytics
    team: data
    dependencies: [tier2-worker-a]
    namespace: fe-signalloom-agents
  - id: obs-global
    type: observability
    team: sre
    dependencies: [tier0-target, tier1-worker-a, tier2-worker-a, tier3-worker-c]
    namespace: fe-signalloom-agents
  - id: obs-local
    type: monitor
    team: sre
    dependencies: [tier1-worker-b]
    namespace: fe-signalloom-agents
`)

	dag, err := ParseFleet(fleetYAML)
	if err != nil {
		t.Fatalf("failed to parse multi-tier fleet YAML: %v", err)
	}

	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	start := time.Now()
	result, err := orch.Stun(context.Background(), "tier0-target", "multi-tier isolation test")
	if err != nil {
		t.Fatalf("unexpected stun failure: %v", err)
	}
	elapsed := time.Since(start)

	if elapsed >= 1000*time.Millisecond {
		t.Fatalf("multi-tier cascade stun took %v, exceeding 1000ms SLA", elapsed)
	}
	if !result.MeetsSLA() {
		t.Fatalf("result DurationMs=%d failed MeetsSLA check", result.DurationMs)
	}

	// Total non-observability agents: 6 (tier0 + 2 tier1 + 2 tier2 + 1 tier3)
	if len(result.AffectedAgents) != 6 {
		t.Fatalf("expected 6 affected agents, got %d: %v", len(result.AffectedAgents), result.AffectedAgents)
	}

	pos := make(map[string]int, len(result.AffectedAgents))
	for i, id := range result.AffectedAgents {
		pos[id] = i
	}

	// Tier 0 (Target first)
	if pos["tier0-target"] != 0 {
		t.Fatalf("expected tier0-target at position 0, got %d", pos["tier0-target"])
	}

	// Tier 1 (Direct dependants second)
	if pos["tier1-worker-a"] > 2 || pos["tier1-worker-b"] > 2 {
		t.Fatalf("expected tier1 workers at positions 1 and 2, got %d and %d", pos["tier1-worker-a"], pos["tier1-worker-b"])
	}

	// Tier 2 (Transitive level 2 third)
	if pos["tier2-worker-a"] < 3 || pos["tier2-worker-a"] > 4 || pos["tier2-worker-b"] < 3 || pos["tier2-worker-b"] > 4 {
		t.Fatalf("expected tier2 workers at positions 3 and 4, got %d and %d", pos["tier2-worker-a"], pos["tier2-worker-b"])
	}

	// Tier 3 (Transitive level 3 fourth)
	if pos["tier3-worker-c"] != 5 {
		t.Fatalf("expected tier3 worker at position 5, got %d", pos["tier3-worker-c"])
	}

	// Observability agents must be strictly preserved
	if _, exists := pos["obs-global"]; exists {
		t.Fatal("obs-global must not be in affected agents")
	}
	if _, exists := pos["obs-local"]; exists {
		t.Fatal("obs-local must not be in affected agents")
	}
	if client.getState("obs-global") == StateStunned {
		t.Fatal("obs-global must remain running, not stunned")
	}
	if client.getState("obs-local") == StateStunned {
		t.Fatal("obs-local must remain running, not stunned")
	}
}

func TestCascade_SubSecondSLA(t *testing.T) {
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)

	start := time.Now()
	result, err := orch.Stun(context.Background(), "agent-cardvault", "")
	if err != nil {
		t.Fatalf("stun failed: %v", err)
	}
	elapsed := time.Since(start)

	if elapsed >= 1000*time.Millisecond {
		t.Fatalf("cascade stun took %v, over the 1000ms SLA", elapsed)
	}
	if !result.MeetsSLA() {
		t.Fatalf("result.MeetsSLA() returned false with DurationMs=%d", result.DurationMs)
	}
}

func TestCascade_RootAgent(t *testing.T) {
	TestStun_CascadeFromRoot(t)
}

func TestCascade_LeafAgent(t *testing.T) {
	TestStun_LeafAgent(t)
}

func TestCascade_UnknownAgent(t *testing.T) {
	TestStun_UnknownAgent(t)
}

func TestCascade_CallOrder(t *testing.T) {
	TestStun_CallOrder(t)
}

func TestCascade_TopologicalRecovery(t *testing.T) {
	TestRecover_TopologicalOrder(t)
}
