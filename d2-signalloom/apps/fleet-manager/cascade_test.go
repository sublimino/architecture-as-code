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

	stunned := []string{"agent-cardvault", "agent-txn-pipeline", "agent-llm-classifier", "agent-api-gateway"}
	result, err := orch.Recover(context.Background(), stunned)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// All should now be running
	for _, id := range stunned {
		if client.getState(id) != StateRunning {
			t.Fatalf("expected %s to be running, got %q", id, client.getState(id))
		}
	}

	// Recovery order should have root first
	if result.RecoveryOrder[0] != "agent-cardvault" {
		t.Fatalf("expected agent-cardvault first in recovery, got %q", result.RecoveryOrder[0])
	}

	// Restore calls should be in topological order
	calls := client.getCalls()
	var restoreCalls []string
	for _, c := range calls {
		if len(c) > 19 && c[:19] == "RestoreCredentials:" {
			restoreCalls = append(restoreCalls, c[19:])
		}
	}

	// cardvault must come before txn-pipeline
	cardvaultPos, txnPos := -1, -1
	for i, id := range restoreCalls {
		if id == "agent-cardvault" {
			cardvaultPos = i
		}
		if id == "agent-txn-pipeline" {
			txnPos = i
		}
	}
	if cardvaultPos >= txnPos {
		t.Fatal("agent-cardvault must be restored before agent-txn-pipeline")
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
// one event — both of which a wholly-failed containment also does. It was green
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
