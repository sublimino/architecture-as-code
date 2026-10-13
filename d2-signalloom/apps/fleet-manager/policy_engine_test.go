package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPolicyEngine_RiskThreshold(t *testing.T) {
	agents := []Agent{
		{ID: "cardvault", State: StateRunning, Namespace: "default"},
		{ID: "agent-txn-pipeline", State: StateRunning, Namespace: "default", Dependencies: []string{"cardvault"}},
	}
	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("BuildDAG failed: %v", err)
	}

	client := newMockClient()
	orchestrator := NewCascadeOrchestrator(dag, client, 0)
	engine := NewPolicyEngine(dag, orchestrator, nil)

	ctx := context.Background()

	// 1. Below threshold (£499,999 <= £500,000)
	inputBelow := PolicyEvaluationInput{
		CarriedGBP: 499999.0,
		DryRun:     true,
	}
	resBelow, err := engine.Evaluate(ctx, inputBelow)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resBelow.Triggered {
		t.Errorf("expected Triggered=false for £499,999, got true")
	}

	// 2. Above threshold (£500,001 > £500,000) in DryRun
	inputAbove := PolicyEvaluationInput{
		CarriedGBP: 500001.0,
		DryRun:     true,
	}
	resAbove, err := engine.Evaluate(ctx, inputAbove)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resAbove.Triggered {
		t.Fatalf("expected Triggered=true for £500,001, got false")
	}
	if len(resAbove.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(resAbove.Actions))
	}
	if resAbove.Actions[0].TargetAgentID != "cardvault" {
		t.Errorf("expected target cardvault, got %s", resAbove.Actions[0].TargetAgentID)
	}
	if !resAbove.DryRun {
		t.Errorf("expected DryRun=true in response")
	}
	// Verify target remained running in DryRun (client states not mutated)
	if client.states["cardvault"] == StateStunned {
		t.Errorf("expected cardvault to remain running in DryRun, got stunned")
	}

	// 3. Active execution (DryRun = false)
	inputActive := PolicyEvaluationInput{
		CarriedGBP: 847000.0,
		DryRun:     false,
	}
	resActive, err := engine.Evaluate(ctx, inputActive)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resActive.Triggered {
		t.Fatalf("expected Triggered=true for active run")
	}
	if len(resActive.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(resActive.Actions))
	}
	if resActive.Actions[0].CascadeResult == nil {
		t.Fatalf("expected non-nil CascadeResult for active execution")
	}
	if client.states["cardvault"] != StateStunned {
		t.Errorf("expected cardvault to transition to stunned, got %s", client.states["cardvault"])
	}
	if client.states["agent-txn-pipeline"] != StateStunned {
		t.Errorf("expected downstream agent-txn-pipeline to transition to stunned, got %s", client.states["agent-txn-pipeline"])
	}
}

func TestPolicyEngine_ComplianceFailureAndDebounce(t *testing.T) {
	agents := []Agent{
		{ID: "agent-llm-classifier", State: StateRunning, Namespace: "default"},
	}
	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("BuildDAG failed: %v", err)
	}

	client := newMockClient()
	orchestrator := NewCascadeOrchestrator(dag, client, 0)
	engine := NewPolicyEngine(dag, orchestrator, nil)

	ctx := context.Background()

	// 1. Compliant agent -> no trigger
	inputCompliant := PolicyEvaluationInput{
		Agents: map[string]AgentEvaluationProfile{
			"agent-llm-classifier": {
				ID:               "agent-llm-classifier",
				State:            StateRunning,
				ComplianceStatus: "compliant",
				RemainingHours:   0,
			},
		},
		DryRun: false,
	}
	res1, err := engine.Evaluate(ctx, inputCompliant)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res1.Triggered {
		t.Errorf("expected no trigger for compliant agent")
	}

	// 2. Non-compliant agent with zero grace period -> triggers stun
	inputNonCompliant := PolicyEvaluationInput{
		Agents: map[string]AgentEvaluationProfile{
			"agent-llm-classifier": {
				ID:               "agent-llm-classifier",
				State:            StateRunning,
				ComplianceStatus: "non-compliant",
				RemainingHours:   0,
			},
		},
		DryRun: false,
	}
	res2, err := engine.Evaluate(ctx, inputNonCompliant)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !res2.Triggered {
		t.Fatalf("expected trigger for non-compliant zero-grace agent")
	}
	if client.states["agent-llm-classifier"] != StateStunned {
		t.Errorf("expected agent-llm-classifier to be stunned in client, got %s", client.states["agent-llm-classifier"])
	}

	// 3. Re-evaluation when already stunned -> debounces
	res3, err := engine.Evaluate(ctx, inputNonCompliant)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res3.Actions) != 1 {
		t.Fatalf("expected 1 action result, got %d", len(res3.Actions))
	}
	if res3.Actions[0].Triggered {
		t.Errorf("expected action to be debounced (Triggered=false) when already stunned")
	}
}

func TestPolicyEngine_GracePeriodExpiry(t *testing.T) {
	agents := []Agent{
		{ID: "agent-txn-pipeline", State: StateRunning, Namespace: "default"},
	}
	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("BuildDAG failed: %v", err)
	}

	client := newMockClient()
	orchestrator := NewCascadeOrchestrator(dag, client, 0)
	engine := NewPolicyEngine(dag, orchestrator, nil)

	ctx := context.Background()

	// Remaining grace hours > 0 (e.g. 24h) -> not triggered
	inputActiveGrace := PolicyEvaluationInput{
		Agents: map[string]AgentEvaluationProfile{
			"agent-txn-pipeline": {
				ID:               "agent-txn-pipeline",
				State:            StateRunning,
				ComplianceStatus: "non-compliant",
				RemainingHours:   24,
			},
		},
		DryRun: false,
	}
	res1, err := engine.Evaluate(ctx, inputActiveGrace)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res1.Triggered {
		t.Errorf("expected no trigger for active grace period (24h remaining)")
	}

	// Remaining grace hours <= 0 -> triggers stun
	inputExpiredGrace := PolicyEvaluationInput{
		Agents: map[string]AgentEvaluationProfile{
			"agent-txn-pipeline": {
				ID:               "agent-txn-pipeline",
				State:            StateRunning,
				ComplianceStatus: "non-compliant",
				RemainingHours:   0,
			},
		},
		DryRun: false,
	}
	res2, err := engine.Evaluate(ctx, inputExpiredGrace)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !res2.Triggered {
		t.Fatalf("expected trigger for expired grace period")
	}
	if client.states["agent-txn-pipeline"] != StateStunned {
		t.Errorf("expected agent-txn-pipeline to be stunned, got %s", client.states["agent-txn-pipeline"])
	}
}

func TestPolicyEngine_PolicyManagement(t *testing.T) {
	engine := NewPolicyEngine(nil, nil, nil)
	policies := engine.Policies()
	if len(policies) != 3 {
		t.Fatalf("expected 3 default policies, got %d", len(policies))
	}

	customPolicies := []ResponsePolicy{
		{
			ID:            "custom-pol",
			Name:          "Custom Policy",
			Enabled:       true,
			ConditionType: ConditionRiskThreshold,
			Operator:      ">",
			Threshold:     1000000.0,
			TargetAgentID: "cardvault",
			Action:        ActionAlert,
		},
	}
	engine.SetPolicies(customPolicies)
	updated := engine.Policies()
	if len(updated) != 1 || updated[0].ID != "custom-pol" {
		t.Fatalf("failed to update custom policies")
	}
}

func TestPolicyRoutes_Endpoints(t *testing.T) {
	agents := []Agent{
		{ID: "cardvault", State: StateRunning, Namespace: "default"},
	}
	dag, err := BuildDAG(agents)
	if err != nil {
		t.Fatalf("BuildDAG failed: %v", err)
	}

	client := newMockClient()
	orchestrator := NewCascadeOrchestrator(dag, client, 0)
	s := &server{
		dag:          dag,
		orchestrator: orchestrator,
		policyEngine: NewPolicyEngine(dag, orchestrator, nil),
	}

	ts := httptest.NewServer(s.routes())
	defer ts.Close()

	// 1. GET /api/v1/fleet/policies
	resp, err := http.Get(ts.URL + "/api/v1/fleet/policies")
	if err != nil {
		t.Fatalf("GET /api/v1/fleet/policies failed: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}
	var polRes map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&polRes); err != nil {
		t.Fatalf("decode failed: %v", err)
	}
	resp.Body.Close()
	if count, ok := polRes["count"].(float64); !ok || count != 3 {
		t.Errorf("expected count=3, got %v", polRes["count"])
	}

	// 2. POST /api/v1/fleet/policies/evaluate (DryRun)
	body := bytes.NewBufferString(`{"carried_gbp": 750000, "dry_run": true}`)
	respEval, err := http.Post(ts.URL+"/api/v1/fleet/policies/evaluate", "application/json", body)
	if err != nil {
		t.Fatalf("POST /api/v1/fleet/policies/evaluate failed: %v", err)
	}
	if respEval.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", respEval.StatusCode)
	}
	var evalRes PolicyEvaluationResult
	if err := json.NewDecoder(respEval.Body).Decode(&evalRes); err != nil {
		t.Fatalf("decode failed: %v", err)
	}
	respEval.Body.Close()
	if !evalRes.Triggered {
		t.Errorf("expected Triggered=true for £750,000")
	}
	if !evalRes.DryRun {
		t.Errorf("expected DryRun=true")
	}

	// 3. POST /api/v1/fleet/policies/evaluate as non-admin role -> 403 Forbidden
	activeBody := bytes.NewBufferString(`{"carried_gbp": 750000, "dry_run": false}`)
	reqDenied, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/fleet/policies/evaluate", activeBody)
	reqDenied.Header.Set("X-User-Role", "team-lead")
	respDenied, err := http.DefaultClient.Do(reqDenied)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	respDenied.Body.Close()
	if respDenied.StatusCode != http.StatusForbidden {
		t.Errorf("expected status 403 for team-lead role, got %d", respDenied.StatusCode)
	}

	// 4. HEAD /api/v1/fleet/policies (RFC 9110 Section 6.4.1 body suppression)
	headReq, err := http.NewRequest(http.MethodHead, ts.URL+"/api/v1/fleet/policies", nil)
	if err != nil {
		t.Fatalf("HEAD /api/v1/fleet/policies failed to create: %v", err)
	}
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD /api/v1/fleet/policies failed: %v", err)
	}
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200 on HEAD, got %d", headResp.StatusCode)
	}
	if ct := headResp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("expected application/json Content-Type on HEAD, got %s", ct)
	}
	headBody, err := io.ReadAll(headResp.Body)
	headResp.Body.Close()
	if err != nil {
		t.Fatalf("failed to read HEAD body: %v", err)
	}
	if len(headBody) != 0 {
		t.Errorf("expected 0 body bytes on HEAD /api/v1/fleet/policies, got %d", len(headBody))
	}

	// 5. POST /api/v1/fleet/policies -> 405 Method Not Allowed (Allow: GET, HEAD)
	postReq, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/fleet/policies", bytes.NewBufferString(`{}`))
	if err != nil {
		t.Fatalf("POST /api/v1/fleet/policies request create failed: %v", err)
	}
	postResp, err := http.DefaultClient.Do(postReq)
	if err != nil {
		t.Fatalf("POST /api/v1/fleet/policies failed: %v", err)
	}
	postResp.Body.Close()
	if postResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected status 405 on POST /api/v1/fleet/policies, got %d", postResp.StatusCode)
	}
	if allow := postResp.Header.Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("expected Allow: GET, HEAD on POST /api/v1/fleet/policies, got %q", allow)
	}

	// 6. HEAD /api/v1/fleet/policies/evaluate -> 405 Method Not Allowed (Allow: POST, 0 body bytes)
	headEvalReq, err := http.NewRequest(http.MethodHead, ts.URL+"/api/v1/fleet/policies/evaluate", nil)
	if err != nil {
		t.Fatalf("HEAD /api/v1/fleet/policies/evaluate request create failed: %v", err)
	}
	headEvalResp, err := http.DefaultClient.Do(headEvalReq)
	if err != nil {
		t.Fatalf("HEAD /api/v1/fleet/policies/evaluate failed: %v", err)
	}
	if headEvalResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected status 405 on HEAD /api/v1/fleet/policies/evaluate, got %d", headEvalResp.StatusCode)
	}
	if allow := headEvalResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("expected Allow: POST on HEAD /api/v1/fleet/policies/evaluate, got %q", allow)
	}
	headEvalBody, _ := io.ReadAll(headEvalResp.Body)
	headEvalResp.Body.Close()
	if len(headEvalBody) != 0 {
		t.Errorf("expected 0 body bytes on HEAD /api/v1/fleet/policies/evaluate, got %d", len(headEvalBody))
	}

	// 7. GET /api/v1/fleet/policies/evaluate -> 405 Method Not Allowed (Allow: POST)
	getEvalReq, err := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/fleet/policies/evaluate", nil)
	if err != nil {
		t.Fatalf("GET /api/v1/fleet/policies/evaluate request create failed: %v", err)
	}
	getEvalResp, err := http.DefaultClient.Do(getEvalReq)
	if err != nil {
		t.Fatalf("GET /api/v1/fleet/policies/evaluate failed: %v", err)
	}
	getEvalResp.Body.Close()
	if getEvalResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected status 405 on GET /api/v1/fleet/policies/evaluate, got %d", getEvalResp.StatusCode)
	}
	if allow := getEvalResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("expected Allow: POST on GET /api/v1/fleet/policies/evaluate, got %q", allow)
	}
}
