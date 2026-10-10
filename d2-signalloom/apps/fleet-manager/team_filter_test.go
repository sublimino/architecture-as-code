package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// helper to create an unsigned test JWT containing arbitrary claims
func makeTestJWT(claims map[string]any) string {
	headerJSON := `{"alg":"none","typ":"JWT"}`
	headerB64 := base64.RawURLEncoding.EncodeToString([]byte(headerJSON))
	claimsBytes, _ := json.Marshal(claims)
	claimsB64 := base64.RawURLEncoding.EncodeToString(claimsBytes)
	return headerB64 + "." + claimsB64 + ".sig"
}

func testFleetWithTwoPaymentsAgentsYAML() []byte {
	return []byte(`
agents:
  - id: agent-cardvault
    type: data-vault
    team: platform
    trustProfile: high
    riskClass: high
    gracePeriod: 0h
    dependencies: []
    namespace: fe-signalloom-agents
  - id: agent-txn-pipeline
    type: data-pipeline
    team: payments
    trustProfile: medium
    riskClass: medium
    gracePeriod: 72h
    dependencies: [agent-cardvault]
    namespace: fe-signalloom-agents
  - id: agent-llm-classifier
    type: llm-inference
    team: payments
    trustProfile: high
    riskClass: high
    gracePeriod: 0h
    dependencies: [agent-txn-pipeline]
    namespace: fe-signalloom-agents
  - id: agent-api-gateway
    type: api-gateway
    team: platform
    trustProfile: medium
    riskClass: medium
    gracePeriod: 24h
    dependencies: [agent-cardvault]
    namespace: fe-signalloom-agents
  - id: agent-monitor
    type: observability
    team: sre
    trustProfile: low
    riskClass: low
    gracePeriod: 0h
    dependencies: [agent-cardvault, agent-txn-pipeline, agent-llm-classifier, agent-api-gateway]
    namespace: fe-signalloom-agents
`)
}

func newCustomTestServer(t *testing.T, fleetYAML []byte) *server {
	t.Helper()
	dag, err := ParseFleet(fleetYAML)
	if err != nil {
		t.Fatalf("failed to parse test fleet: %v", err)
	}
	client := newMockClient()
	orch := NewCascadeOrchestrator(dag, client, 0)
	return &server{dag: dag, orchestrator: orch}
}

// Test case asserting payments team lead receives only payments team agents on GET /api/v1/fleet/topology.
func TestTeamFilter_PaymentsTeamLead_ReceivesOnlyPaymentsAgents(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	req.Header.Set("X-User-Role", "team-lead")
	req.Header.Set("X-User-Team", "payments")

	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", w.Code, w.Body.String())
	}

	var resp TopologyResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(resp.Agents) == 0 {
		t.Fatal("expected at least one payments team agent, got 0")
	}

	for _, a := range resp.Agents {
		if !strings.EqualFold(a.Team, "payments") {
			t.Errorf("expected only payments team agents, but agent %s has team %s", a.ID, a.Team)
		}
	}

	// Verify edges connect only visible agents
	visibleIDs := make(map[string]bool)
	for _, a := range resp.Agents {
		visibleIDs[a.ID] = true
	}
	for _, e := range resp.Edges {
		if !visibleIDs[e.From] || !visibleIDs[e.To] {
			t.Errorf("edge from %s to %s connects non-visible agent", e.From, e.To)
		}
	}
}

// Test case asserting multi-agent team filtering retains internal edges and strips external edges.
func TestTeamFilter_PaymentsTeamLead_EdgeFiltering(t *testing.T) {
	s := newCustomTestServer(t, testFleetWithTwoPaymentsAgentsYAML())

	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	req.Header.Set("X-User-Role", "team-lead")
	req.Header.Set("X-User-Team", "payments")

	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", w.Code)
	}

	var resp TopologyResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(resp.Agents) != 2 {
		t.Fatalf("expected 2 payments team agents, got %d", len(resp.Agents))
	}

	// In testFleetWithTwoPaymentsAgentsYAML:
	// agent-txn-pipeline depends on agent-cardvault (platform: filtered out)
	// agent-llm-classifier depends on agent-txn-pipeline (payments: preserved)
	if len(resp.Edges) != 1 {
		t.Fatalf("expected exactly 1 internal edge between visible payments agents, got %d", len(resp.Edges))
	}

	if resp.Edges[0].From != "agent-llm-classifier" || resp.Edges[0].To != "agent-txn-pipeline" {
		t.Errorf("expected edge agent-llm-classifier -> agent-txn-pipeline, got %s -> %s", resp.Edges[0].From, resp.Edges[0].To)
	}
}

// Test case asserting compliance officer receives all 5 agents.
func TestTeamFilter_ComplianceOfficer_ReceivesAll5Agents(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	req.Header.Set("X-User-Role", "compliance")

	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", w.Code, w.Body.String())
	}

	var resp TopologyResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(resp.Agents) != 5 {
		t.Fatalf("expected compliance officer to receive all 5 agents, got %d", len(resp.Agents))
	}

	if len(resp.Edges) == 0 {
		t.Fatal("expected full edges for compliance officer, got 0")
	}
}

// Test case asserting admin receives all 5 agents.
func TestTeamFilter_Admin_ReceivesAll5Agents(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	req.Header.Set("X-User-Role", "admin")

	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", w.Code, w.Body.String())
	}

	var resp TopologyResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(resp.Agents) != 5 {
		t.Fatalf("expected admin to receive all 5 agents, got %d", len(resp.Agents))
	}

	if len(resp.Edges) == 0 {
		t.Fatal("expected full edges for admin, got 0")
	}
}

// Test case asserting team-lead receives HTTP 403 on POST /api/v1/fleet/stun/{agentId}.
func TestTeamFilter_Stun_ForbiddenForTeamLead(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"test stun"}`))
	req.Header.Set("X-User-Role", "team-lead")
	req.Header.Set("X-User-Team", "payments")

	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403 Forbidden for team-lead on stun, got %d: %s", w.Code, w.Body.String())
	}

	var errResp ErrorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}

	expectedMsg := `caller role "team-lead" is forbidden from action: requires admin`
	if errResp.Error != expectedMsg {
		t.Fatalf("expected error message %q, got %q", expectedMsg, errResp.Error)
	}
}

// Test case asserting compliance receives HTTP 403 on POST /api/v1/fleet/stun/{agentId}.
func TestTeamFilter_Stun_ForbiddenForCompliance(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"test stun"}`))
	req.Header.Set("X-User-Role", "compliance")

	w := httptest.NewRecorder()
	s.handleStun(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403 Forbidden for compliance on stun, got %d: %s", w.Code, w.Body.String())
	}

	var errResp ErrorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}

	expectedMsg := `caller role "compliance" is forbidden from action: requires admin`
	if errResp.Error != expectedMsg {
		t.Fatalf("expected error message %q, got %q", expectedMsg, errResp.Error)
	}
}

// Test case asserting compliance and team-lead receive HTTP 403 on POST /api/v1/fleet/recover.
func TestTeamFilter_Recover_ForbiddenForTeamLeadAndCompliance(t *testing.T) {
	s := newTestServer(t)

	// Subtest 1: team-lead
	{
		body := bytes.NewReader([]byte(`{"agent_ids":["agent-cardvault"]}`))
		req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", body)
		req.Header.Set("X-User-Role", "team-lead")
		req.Header.Set("X-User-Team", "payments")

		w := httptest.NewRecorder()
		s.handleRecover(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden for team-lead on recover, got %d: %s", w.Code, w.Body.String())
		}

		var errResp ErrorResponse
		if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
			t.Fatalf("failed to decode error response: %v", err)
		}

		expectedMsg := `caller role "team-lead" is forbidden from action: requires admin`
		if errResp.Error != expectedMsg {
			t.Fatalf("expected error message %q, got %q", expectedMsg, errResp.Error)
		}
	}

	// Subtest 2: compliance
	{
		body := bytes.NewReader([]byte(`{"agent_ids":["agent-cardvault"]}`))
		req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", body)
		req.Header.Set("X-User-Role", "compliance")

		w := httptest.NewRecorder()
		s.handleRecover(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden for compliance on recover, got %d: %s", w.Code, w.Body.String())
		}

		var errResp ErrorResponse
		if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
			t.Fatalf("failed to decode error response: %v", err)
		}

		expectedMsg := `caller role "compliance" is forbidden from action: requires admin`
		if errResp.Error != expectedMsg {
			t.Fatalf("expected error message %q, got %q", expectedMsg, errResp.Error)
		}
	}
}

// Test case asserting admin role is permitted to perform stun and recover.
func TestTeamFilter_StunAndRecover_AllowedForAdmin(t *testing.T) {
	s := newTestServer(t)

	// Admin on stun
	{
		req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"admin stun"}`))
		req.Header.Set("X-User-Role", "admin")

		w := httptest.NewRecorder()
		s.handleStun(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK for admin on stun, got %d: %s", w.Code, w.Body.String())
		}
	}

	// Admin on recover
	{
		body := bytes.NewReader([]byte(`{"agent_ids":["agent-cardvault"]}`))
		req := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", body)
		req.Header.Set("X-User-Role", "admin")

		w := httptest.NewRecorder()
		s.handleRecover(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK for admin on recover, got %d: %s", w.Code, w.Body.String())
		}
	}
}

// Test case asserting Dex JWT claims in Bearer Authorization header drive role and team filtering.
func TestTeamFilter_DexJWTClaims(t *testing.T) {
	s := newTestServer(t)

	// Case 1: Dex JWT with team:payments group claim
	{
		token := makeTestJWT(map[string]any{
			"sub":    "lead@payments.signalloom.local",
			"groups": []string{"team:payments"},
		})
		req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
		req.Header.Set("Authorization", "Bearer "+token)

		w := httptest.NewRecorder()
		s.handleTopology(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK, got %d", w.Code)
		}

		var resp TopologyResponse
		json.NewDecoder(w.Body).Decode(&resp)

		if len(resp.Agents) == 0 {
			t.Fatal("expected payments agents from JWT claim")
		}
		for _, a := range resp.Agents {
			if !strings.EqualFold(a.Team, "payments") {
				t.Errorf("expected only payments agents, got %s (team %s)", a.ID, a.Team)
			}
		}

		// Also assert stun is 403 Forbidden with this JWT
		stunReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"test"}`))
		stunReq.Header.Set("Authorization", "Bearer "+token)
		stunW := httptest.NewRecorder()
		s.handleStun(stunW, stunReq)

		if stunW.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden on stun for team-lead JWT, got %d", stunW.Code)
		}
	}

	// Case 2: Dex JWT with compliance group claim
	{
		token := makeTestJWT(map[string]any{
			"sub":    "officer@compliance.signalloom.local",
			"groups": []string{"compliance"},
		})
		req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
		req.Header.Set("Authorization", "Bearer "+token)

		w := httptest.NewRecorder()
		s.handleTopology(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK, got %d", w.Code)
		}

		var resp TopologyResponse
		json.NewDecoder(w.Body).Decode(&resp)

		if len(resp.Agents) != 5 {
			t.Fatalf("expected all 5 agents for compliance JWT, got %d", len(resp.Agents))
		}

		// Also assert recover is 403 Forbidden with this compliance JWT
		recReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/recover", strings.NewReader(`{"agent_ids":["agent-cardvault"]}`))
		recReq.Header.Set("Authorization", "Bearer "+token)
		recW := httptest.NewRecorder()
		s.handleRecover(recW, recReq)

		if recW.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden on recover for compliance JWT, got %d", recW.Code)
		}
	}

	// Case 3: Dex JWT with admin group claim
	{
		token := makeTestJWT(map[string]any{
			"sub":    "admin@signalloom.local",
			"groups": []string{"admin"},
		})
		req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
		req.Header.Set("Authorization", "Bearer "+token)

		w := httptest.NewRecorder()
		s.handleTopology(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK, got %d", w.Code)
		}

		var resp TopologyResponse
		json.NewDecoder(w.Body).Decode(&resp)

		if len(resp.Agents) != 5 {
			t.Fatalf("expected all 5 agents for admin JWT, got %d", len(resp.Agents))
		}

		// Also assert stun is permitted with admin JWT
		stunReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"test"}`))
		stunReq.Header.Set("Authorization", "Bearer "+token)
		stunW := httptest.NewRecorder()
		s.handleStun(stunW, stunReq)

		if stunW.Code != http.StatusOK {
			t.Fatalf("expected 200 OK on stun for admin JWT, got %d: %s", stunW.Code, stunW.Body.String())
		}
	}
}

// Test case asserting backward compatibility when caller context is unset.
func TestTeamFilter_UnsetCallerContext_BackwardCompatible(t *testing.T) {
	s := newTestServer(t)

	// GET /topology with no headers returns all agents
	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", w.Code)
	}

	var resp TopologyResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.Agents) != 5 {
		t.Fatalf("expected 5 agents when context is unset, got %d", len(resp.Agents))
	}

	// POST /stun with no role header is not blocked by role check
	stunReq := httptest.NewRequest(http.MethodPost, "/api/v1/fleet/stun/agent-cardvault", strings.NewReader(`{"reason":"backward compat"}`))
	stunW := httptest.NewRecorder()
	s.handleStun(stunW, stunReq)

	if stunW.Code != http.StatusOK {
		t.Fatalf("expected 200 OK for backward compatible stun, got %d: %s", stunW.Code, stunW.Body.String())
	}
}
