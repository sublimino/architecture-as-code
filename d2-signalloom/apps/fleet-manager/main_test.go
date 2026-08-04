package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer(t *testing.T) *server {
	t.Helper()
	dag := mustBuildTestDAG(t)
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)
	return &server{dag: dag, orchestrator: orch}
}

func TestHandleHealth(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	s.handleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var body map[string]string
	json.NewDecoder(w.Body).Decode(&body)
	if body["status"] != "ok" {
		t.Fatalf("expected status ok, got %q", body["status"])
	}
}

func TestHandleTopology(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp TopologyResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(resp.Agents) != 5 {
		t.Fatalf("expected 5 agents, got %d", len(resp.Agents))
	}

	// Verify edges exist
	if len(resp.Edges) == 0 {
		t.Fatal("expected edges in topology response")
	}

	// Check a specific edge: agent-txn-pipeline -> agent-cardvault
	found := false
	for _, e := range resp.Edges {
		if e.From == "agent-txn-pipeline" && e.To == "agent-cardvault" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected edge from agent-txn-pipeline to agent-cardvault")
	}
}

func TestHandleTopology_MethodNotAllowed(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/topology", nil)
	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}

func TestHandleStun_Success(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", nil)
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var result CascadeResult
	if err := json.NewDecoder(w.Body).Decode(&result); err != nil {
		t.Fatalf("failed to decode: %v", err)
	}

	if result.TargetAgent != "agent-cardvault" {
		t.Fatalf("expected target agent-cardvault, got %q", result.TargetAgent)
	}

	// Should cascade to 4 agents (not monitor)
	if len(result.AffectedAgents) != 4 {
		t.Fatalf("expected 4 affected agents, got %d: %v", len(result.AffectedAgents), result.AffectedAgents)
	}

	if len(result.RecoveryOrder) == 0 {
		t.Fatal("expected recovery order in result")
	}
}

func TestHandleStun_UnknownAgent(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/nonexistent", nil)
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestHandleStun_NoAgentID(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/", nil)
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestHandleStun_MethodNotAllowed(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/stun/agent-cardvault", nil)
	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}

func TestHandleRecover_WithBody(t *testing.T) {
	s := newTestServer(t)
	body, _ := json.Marshal(map[string][]string{
		"agent_ids": {"agent-cardvault", "agent-txn-pipeline"},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", bytes.NewReader(body))
	w := httptest.NewRecorder()
	s.handleRecover(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var result CascadeResult
	json.NewDecoder(w.Body).Decode(&result)

	if len(result.RecoveryOrder) != 2 {
		t.Fatalf("expected 2 in recovery order, got %d", len(result.RecoveryOrder))
	}
	// cardvault should come first (no deps among stunned set)
	if result.RecoveryOrder[0] != "agent-cardvault" {
		t.Fatalf("expected agent-cardvault first, got %q", result.RecoveryOrder[0])
	}
}

func TestHandleRecover_NoStunned(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", bytes.NewReader([]byte("{}")))
	w := httptest.NewRecorder()
	s.handleRecover(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestHandleDeploy(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/deploy", nil)
	w := httptest.NewRecorder()
	s.handleDeploy(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var body map[string]string
	json.NewDecoder(w.Body).Decode(&body)
	if body["status"] != "accepted" {
		t.Fatalf("expected status accepted, got %q", body["status"])
	}
}

func TestHandleScan(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/scan", nil)
	w := httptest.NewRecorder()
	s.handleScan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
}

func TestHandleReset(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/reset", nil)
	w := httptest.NewRecorder()
	s.handleReset(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
}

func TestHandleDeploy_MethodNotAllowed(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/deploy", nil)
	w := httptest.NewRecorder()
	s.handleDeploy(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}
