package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestContract_TopologySchemaMatchesTypeScriptInterfaces(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", w.Code)
	}

	contentType := w.Header().Get("Content-Type")
	if contentType != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", contentType)
	}

	var raw map[string]any
	if err := json.NewDecoder(w.Body).Decode(&raw); err != nil {
		t.Fatalf("failed to decode JSON response: %v", err)
	}

	// 1. Top-level keys matching FleetTopology TypeScript interface:
	// agents: AgentState[]
	// edges: Edge[]
	// aggregateRisk: RiskSummary
	// cascadeHistory: CascadeEvent[]
	requiredTopLevel := []string{"agents", "edges", "aggregateRisk", "cascadeHistory"}
	for _, k := range requiredTopLevel {
		if _, ok := raw[k]; !ok {
			t.Errorf("missing required top-level key: %q", k)
		}
	}

	// 2. Agents array validation:
	agentsList, ok := raw["agents"].([]any)
	if !ok || len(agentsList) == 0 {
		t.Fatalf("expected non-empty agents array")
	}

	requiredAgentFields := []string{"id", "name", "type", "team", "trustProfile", "state"}
	validStates := map[string]bool{
		"absent": true, "deploying": true, "active": true,
		"non-compliant": true, "grace-period": true, "stunned": true,
	}

	for i, item := range agentsList {
		agent, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("agent[%d] is not a JSON object", i)
		}
		for _, f := range requiredAgentFields {
			val, present := agent[f]
			if !present || val == "" {
				t.Errorf("agent[%d] missing or empty required field %q", i, f)
			}
		}
		state, _ := agent["state"].(string)
		if !validStates[state] {
			t.Errorf("agent[%d] invalid state: %q", i, state)
		}
	}

	// 3. Edges array validation:
	edgesList, ok := raw["edges"].([]any)
	if !ok {
		t.Fatalf("expected edges to be an array")
	}
	for i, item := range edgesList {
		edge, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("edge[%d] is not a JSON object", i)
		}
		if _, ok := edge["from"].(string); !ok {
			t.Errorf("edge[%d] missing 'from' string", i)
		}
		if _, ok := edge["to"].(string); !ok {
			t.Errorf("edge[%d] missing 'to' string", i)
		}
	}

	// 4. AggregateRisk validation:
	//
	// This block used to require ale and var95 to be NUMBERS, which made the contract
	// test the thing holding the fabrication in place: the only figures available to
	// satisfy it were authored in fleet.yaml, so a passing test certified that an
	// authored number reached a risk gauge. Nothing in this repository can compute a
	// fleet ALE -- see RiskSummary in topology.go for the four checks that establish
	// that -- so the contract is now that the response REFUSES, and carries the
	// estate's shared refusal object saying why.
	risk, ok := raw["aggregateRisk"].(map[string]any)
	if !ok {
		t.Fatalf("expected aggregateRisk to be an object")
	}
	for _, key := range []string{"ale", "var95", "previousAle", "trend"} {
		if v, present := risk[key]; present {
			t.Errorf("aggregateRisk.%s = %#v, want absent: no computation stands behind it", key, v)
		}
	}
	pricing, ok := risk["pricing"].(map[string]any)
	if !ok {
		t.Fatalf("expected aggregateRisk.pricing to be the shared refusal object, got %#v", risk["pricing"])
	}
	if got := pricing["status"]; got != string(PricingStatusAuthoredNotComputed) {
		t.Errorf("pricing.status = %#v, want %q", got, PricingStatusAuthoredNotComputed)
	}
	if available, _ := pricing["available"].(bool); available {
		t.Errorf("pricing.available = true while no figure is served")
	}
}

func TestContract_DeployEndpointInitializesState(t *testing.T) {
	s := newTestServer(t)

	// Set initial state to absent
	for _, a := range s.dag.AllAgents() {
		_ = s.dag.SetAgentState(a.ID, AgentStateAbsent)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/deploy", bytes.NewReader([]byte("{}")))
	w := httptest.NewRecorder()
	s.handleDeploy(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK from deploy, got %d", w.Code)
	}

	var resp DeployResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode deploy response: %v", err)
	}

	if resp.Status != "accepted" {
		t.Errorf("expected status 'accepted', got %q", resp.Status)
	}

	if len(resp.DeploymentOrder) != 5 {
		t.Errorf("expected 5 agents in deployment_order, got %d", len(resp.DeploymentOrder))
	}

	// Verify all agents transitioned to active state
	for _, a := range s.dag.AllAgents() {
		if a.State != AgentStateActive {
			t.Errorf("agent %s expected active state after deploy, got %q", a.ID, a.State)
		}
	}
}

func TestContract_DeployEndpointRejectsCyclesWith400(t *testing.T) {
	s := newTestServer(t)

	cyclicPayload := []byte(`{
		"agents": [
			{"id": "agent-a", "type": "data-vault", "team": "platform", "trustProfile": "high", "dependencies": ["agent-b"]},
			{"id": "agent-b", "type": "data-pipeline", "team": "payments", "trustProfile": "medium", "dependencies": ["agent-a"]}
		]
	}`)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/deploy", bytes.NewReader(cyclicPayload))
	w := httptest.NewRecorder()
	s.handleDeploy(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400 Bad Request on circular dependencies, got %d", w.Code)
	}

	var errResp ErrorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}

	if errResp.Error == "" {
		t.Errorf("expected error message describing cycle, got empty")
	}
}

func TestContract_HealthProbes(t *testing.T) {
	s := newTestServer(t)

	// Test /healthz (Liveness)
	{
		req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
		w := httptest.NewRecorder()
		s.handleHealthz(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK from /healthz, got %d", w.Code)
		}

		var body map[string]string
		if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
			t.Fatalf("failed to decode /healthz body: %v", err)
		}
		if body["status"] != "ok" {
			t.Errorf("expected status ok on /healthz, got %q", body["status"])
		}
	}

	// Test /readyz (Readiness)
	{
		req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
		w := httptest.NewRecorder()
		s.handleReadyz(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK from /readyz, got %d", w.Code)
		}

		var body map[string]string
		if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
			t.Fatalf("failed to decode /readyz body: %v", err)
		}
		if body["status"] != "ok" || body["ready"] != "true" {
			t.Errorf("expected status ok and ready true on /readyz, got %+v", body)
		}
	}
}
