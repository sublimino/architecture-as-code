package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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
	if allow := w.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("expected Allow: GET, HEAD, got %q", allow)
	}

	headReq := httptest.NewRequest(http.MethodHead, "/api/v1/fleet/topology", nil)
	headW := httptest.NewRecorder()
	s.handleTopology(headW, headReq)
	if headW.Code != http.StatusOK {
		t.Fatalf("HEAD expected 200, got %d", headW.Code)
	}
	if headW.Body.Len() != 0 {
		t.Fatalf("HEAD expected empty body, got %d bytes", headW.Body.Len())
	}
}

func TestHandleStun_Success(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"main_test: stun success"}`))
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
	if allow := w.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
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
	if allow := w.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
}

func TestHandlePolicies_HEADAndMethodNotAllowed(t *testing.T) {
	s := newTestServer(t)

	headReq := httptest.NewRequest(http.MethodHead, "/api/v1/fleet/policies", nil)
	headW := httptest.NewRecorder()
	s.handlePolicies(headW, headReq)
	if headW.Code != http.StatusOK {
		t.Fatalf("HEAD expected 200, got %d", headW.Code)
	}
	if headW.Body.Len() != 0 {
		t.Fatalf("HEAD expected empty body, got %d bytes", headW.Body.Len())
	}

	postReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/policies", nil)
	postW := httptest.NewRecorder()
	s.handlePolicies(postW, postReq)
	if postW.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST expected 405, got %d", postW.Code)
	}
	if allow := postW.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("expected Allow: GET, HEAD, got %q", allow)
	}
}

func TestHandleMutating_MethodNotAllowed(t *testing.T) {
	s := newTestServer(t)

	routes := []struct {
		name    string
		handler http.HandlerFunc
		path    string
	}{
		{"deploy", s.handleDeploy, "/api/v1/fleet/deploy"},
		{"stun", s.handleStun, "/api/v1/fleet/stun/agent-1"},
		{"recover", s.handleRecover, "/api/v1/fleet/recover"},
		{"resume", s.handleResume, "/api/v1/fleet/resume"},
		{"scan", s.handleScan, "/api/v1/fleet/scan"},
		{"reset", s.handleReset, "/api/v1/fleet/reset"},
		{"policyEvaluate", s.handlePolicyEvaluate, "/api/v1/fleet/policies/evaluate"},
		{"workloadReport", s.handleWorkloadReport, "/api/v1/fleet/workloads/report"},
		{"remoteStunAck", s.handleRemoteStunAck, "/api/v1/fleet/stun-state/ack"},
	}

	invalidMethods := []string{
		http.MethodGet,
		http.MethodPut,
		http.MethodDelete,
		http.MethodPatch,
		http.MethodHead,
	}

	for _, rt := range routes {
		t.Run(rt.name, func(t *testing.T) {
			for _, m := range invalidMethods {
				req := httptest.NewRequest(m, rt.path, nil)
				w := httptest.NewRecorder()
				rt.handler(w, req)
				if w.Code != http.StatusMethodNotAllowed {
					t.Fatalf("%s [%s] expected 405, got %d", rt.name, m, w.Code)
				}
				if allow := w.Header().Get("Allow"); allow != "POST" {
					t.Fatalf("%s [%s] expected Allow: POST, got %q", rt.name, m, allow)
				}
				if m == http.MethodHead && w.Body.Len() != 0 {
					t.Fatalf("%s [HEAD] expected 0 body bytes, got %d: %q", rt.name, w.Body.Len(), w.Body.String())
				}
			}
		})
	}
}

func TestHandleTopology_HEADAndMethodNotAllowed(t *testing.T) {
	s := newTestServer(t)

	headReq := httptest.NewRequest(http.MethodHead, "/api/v1/fleet/topology", nil)
	headW := httptest.NewRecorder()
	s.handleTopology(headW, headReq)
	if headW.Code != http.StatusOK {
		t.Fatalf("HEAD expected 200, got %d", headW.Code)
	}
	if headW.Body.Len() != 0 {
		t.Fatalf("HEAD expected empty body, got %d bytes", headW.Body.Len())
	}

	for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		postReq := httptest.NewRequest(m, "/api/v1/fleet/topology", nil)
		postW := httptest.NewRecorder()
		s.handleTopology(postW, postReq)
		if postW.Code != http.StatusMethodNotAllowed {
			t.Fatalf("[%s] expected 405, got %d", m, postW.Code)
		}
		if allow := postW.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Fatalf("[%s] expected Allow: GET, HEAD, got %q", m, allow)
		}
	}
}

func TestRoutes_HEADErrorBodySuppression(t *testing.T) {
	s := newTestServer(t)
	handler := s.routes()

	tests := []struct {
		name       string
		path       string
		wantStatus int
	}{
		{"health", "/health", http.StatusOK},
		{"healthz", "/healthz", http.StatusOK},
		{"readyz", "/readyz", http.StatusOK},
		{"topology", "/api/v1/fleet/topology", http.StatusOK},
		{"policies", "/api/v1/fleet/policies", http.StatusOK},
		{"audit_events", "/api/v1/fleet/audit/events", http.StatusOK},
		{"audit_stream", "/api/v1/fleet/audit/stream", http.StatusOK},
		{"unauth_deploy", "/api/v1/fleet/deploy", http.StatusUnauthorized},
		{"unauth_stun", "/api/v1/fleet/stun/agent-1", http.StatusUnauthorized},
		{"unauth_resume", "/api/v1/fleet/resume", http.StatusUnauthorized},
		{"unauth_scan", "/api/v1/fleet/scan", http.StatusUnauthorized},
		{"unauth_recover", "/api/v1/fleet/recover", http.StatusUnauthorized},
		{"unauth_reset", "/api/v1/fleet/reset", http.StatusUnauthorized},
		{"unauth_workloads", "/api/v1/fleet/workloads", http.StatusUnauthorized},
		{"unauth_workload_report", "/api/v1/fleet/workloads/report", http.StatusUnauthorized},
		{"unauth_stun_state", "/api/v1/fleet/stun-state", http.StatusUnauthorized},
		{"unauth_stun_state_ack", "/api/v1/fleet/stun-state/ack", http.StatusUnauthorized},
		{"not_found", "/api/v1/fleet/unknown-route-404", http.StatusNotFound},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodHead, tc.path, nil)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)

			if w.Code != tc.wantStatus {
				t.Errorf("HEAD %s: got status %d, want %d", tc.path, w.Code, tc.wantStatus)
			}
			if w.Body.Len() != 0 {
				t.Errorf("HEAD %s: got %d body bytes (%q), want 0 bytes", tc.path, w.Body.Len(), w.Body.String())
			}
		})
	}
}


