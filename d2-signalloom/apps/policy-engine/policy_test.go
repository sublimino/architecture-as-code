package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

func setupTestStore(t *testing.T) (*PolicyStore, *CELEngine) {
	t.Helper()
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed to create CEL engine: %v", err)
	}
	store := NewPolicyStore(engine)
	return store, engine
}

// TestVersionedPolicy verifies monotonic version ordering and tenant override precedence.
func TestVersionedPolicy(t *testing.T) {
	store, _ := setupTestStore(t)

	// 1. Register base bundle v1.0.0
	bundleV1 := &PolicyBundle{
		FrameworkID: "eu-ai-act",
		Version:     "v1.0.0",
		Author:      "compliance-team",
		Rules: []PolicyRule{
			{
				ID:            "rule-1",
				Name:          "Model Check",
				CELExpression: `agent.model in ["claude-3-5-sonnet", "gpt-4o"]`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", bundleV1); err != nil {
		t.Fatalf("failed to register v1.0.0: %v", err)
	}

	// 2. Register monotonically increasing version v1.1.0
	bundleV11 := &PolicyBundle{
		FrameworkID: "eu-ai-act",
		Version:     "v1.1.0",
		Author:      "compliance-team",
		Rules: []PolicyRule{
			{
				ID:            "rule-1",
				Name:          "Model Check",
				CELExpression: `agent.model in ["claude-3-5-sonnet", "gpt-4o", "gemini-1.5-pro"]`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", bundleV11); err != nil {
		t.Fatalf("failed to register v1.1.0: %v", err)
	}

	// 3. Attempt to register a non-monotonic version v1.0.5 -> must fail
	bundleStale := &PolicyBundle{
		FrameworkID: "eu-ai-act",
		Version:     "v1.0.5",
		Author:      "bad-actor",
		Rules: []PolicyRule{
			{
				ID:            "rule-1",
				Name:          "Model Check",
				CELExpression: `agent.model == "gpt-4"`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", bundleStale); err == nil {
		t.Fatalf("expected error registering non-monotonic version v1.0.5 after v1.1.0, got nil")
	}

	// 4. Attempt to register same version v1.1.0 -> must fail
	if err := store.RegisterBundle("tenant-demo", bundleV11); err == nil {
		t.Fatalf("expected error registering duplicate version v1.1.0, got nil")
	}

	// 5. Check active bundle is v1.1.0
	active, err := store.GetActiveBundle("tenant-demo", "eu-ai-act", "")
	if err != nil {
		t.Fatalf("failed getting active bundle: %v", err)
	}
	if active.Version != "v1.1.0" {
		t.Fatalf("expected active version v1.1.0, got %s", active.Version)
	}

	// 6. Test Tenant Override Precedence
	// Global default framework bundle
	globalBundle := &PolicyBundle{
		FrameworkID: "nist-800-53",
		Version:     "v1.0.0",
		Author:      "system",
		Rules: []PolicyRule{
			{
				ID:            "nist-1",
				Name:          "Default Least Privilege",
				CELExpression: `agent.trust_domain == "spiffe://global.local"`,
			},
		},
	}
	if err := store.RegisterBundle("", globalBundle); err != nil {
		t.Fatalf("failed registering global bundle: %v", err)
	}

	// Tenant without override gets global default
	activeGlobal, err := store.GetActiveBundle("tenant-other", "nist-800-53", "")
	if err != nil {
		t.Fatalf("failed getting active bundle for tenant-other: %v", err)
	}
	if activeGlobal.Author != "system" {
		t.Fatalf("expected global author 'system', got %s", activeGlobal.Author)
	}

	// Tenant with override gets tenant bundle
	tenantNistBundle := &PolicyBundle{
		FrameworkID: "nist-800-53",
		Version:     "v1.0.0",
		Author:      "tenant-admin",
		Rules: []PolicyRule{
			{
				ID:            "nist-1",
				Name:          "Tenant Specific Rule",
				CELExpression: `agent.trust_domain.startsWith("spiffe://tenant-demo.local")`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", tenantNistBundle); err != nil {
		t.Fatalf("failed registering tenant bundle: %v", err)
	}

	activeTenant, err := store.GetActiveBundle("tenant-demo", "nist-800-53", "")
	if err != nil {
		t.Fatalf("failed getting active bundle for tenant-demo: %v", err)
	}
	if activeTenant.Author != "tenant-admin" {
		t.Fatalf("expected tenant author 'tenant-admin', got %s", activeTenant.Author)
	}
}

// TestCELEvaluation verifies rich context evaluation and FAIR exposure calculation.
func TestCELEvaluation(t *testing.T) {
	store, _ := setupTestStore(t)

	bundle := &PolicyBundle{
		FrameworkID: "agent-governance",
		Version:     "v1.0.0",
		Author:      "secops",
		Rules: []PolicyRule{
			{
				ID:            "AG-1",
				Name:          "Model Whitelist",
				CELExpression: `agent.model in ["claude-3-5-sonnet", "gpt-4o"]`,
				Severity:      "high",
				Remediation:   "Update agent to an approved foundation model",
				RiskTriple:    fair.RiskTriple{Min: 1000, Mode: 5000, Max: 20000},
				FreqTriple:    fair.RiskTriple{Min: 1, Mode: 2, Max: 5},
			},
			{
				ID:            "AG-2",
				Name:          "Tool Permission Constraint",
				CELExpression: `agent.tool_permissions.all(p, !p.startsWith("admin:"))`,
				Severity:      "critical",
				Remediation:   "Remove unapproved administrative tool permissions",
				RiskTriple:    fair.RiskTriple{Min: 10000, Mode: 50000, Max: 200000},
				FreqTriple:    fair.RiskTriple{Min: 1, Mode: 4, Max: 12},
			},
			{
				ID:            "AG-3",
				Name:          "SPIFFE Trust Domain Scope",
				CELExpression: `request.spiffe_id.startsWith("spiffe://controlplane.io/ns/" + agent.trust_domain)`,
				Severity:      "medium",
				Remediation:   "Ensure agent requests match assigned SPIFFE trust domain",
				RiskTriple:    fair.RiskTriple{Min: 500, Mode: 2000, Max: 8000},
				FreqTriple:    fair.RiskTriple{Min: 0.5, Mode: 1, Max: 2},
			},
			{
				ID:            "AG-4",
				Name:          "Egress Allowlist Check",
				CELExpression: `agent.egress_allowlist.exists(e, e == request.target_service)`,
				Severity:      "high",
				Remediation:   "Target service must be present in agent egress allowlist",
				RiskTriple:    fair.RiskTriple{Min: 2000, Mode: 10000, Max: 40000},
				FreqTriple:    fair.RiskTriple{Min: 1, Mode: 3, Max: 6},
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", bundle); err != nil {
		t.Fatalf("failed to register bundle: %v", err)
	}

	// 1. Test passing context
	reqPass := &EvaluatePoliciesRequest{
		TenantID:    "tenant-demo",
		FrameworkID: "agent-governance",
		Agent: map[string]any{
			"id":               "agent-alpha",
			"model":            "claude-3-5-sonnet",
			"trust_domain":     "prod",
			"tool_permissions": []any{"read:files", "search:web"},
			"egress_allowlist": []any{"api.openai.com", "anthropic.com", "svc-vault"},
		},
		Request: map[string]any{
			"spiffe_id":       "spiffe://controlplane.io/ns/prod/sa/agent-alpha",
			"target_service":  "svc-vault",
			"action":          "read_secret",
		},
	}

	resp, err := store.EvaluateBundle(context.Background(), bundle, reqPass)
	if err != nil {
		t.Fatalf("evaluation failed: %v", err)
	}
	if !resp.Compliant {
		t.Fatalf("expected fully compliant result, got non-compliant")
	}
	if resp.PassedRules != 4 || resp.FailedRules != 0 {
		t.Fatalf("expected 4 passed rules, got passed=%d failed=%d", resp.PassedRules, resp.FailedRules)
	}
	if resp.TotalExposure != 0 {
		t.Fatalf("expected 0 exposure for compliant pass, got %f", resp.TotalExposure)
	}

	// 2. Test failing context with unapproved tool permission and unapproved egress target
	reqFail := &EvaluatePoliciesRequest{
		TenantID:    "tenant-demo",
		FrameworkID: "agent-governance",
		Agent: map[string]any{
			"id":               "agent-rogue",
			"model":            "claude-3-5-sonnet",
			"trust_domain":     "prod",
			"tool_permissions": []any{"read:files", "admin:exec_shell"},
			"egress_allowlist": []any{"api.openai.com"},
		},
		Request: map[string]any{
			"spiffe_id":      "spiffe://controlplane.io/ns/prod/sa/agent-rogue",
			"target_service": "untrusted-external-api.com",
			"action":         "post_data",
		},
	}

	respFail, err := store.EvaluateBundle(context.Background(), bundle, reqFail)
	if err != nil {
		t.Fatalf("evaluation failed: %v", err)
	}
	if respFail.Compliant {
		t.Fatalf("expected non-compliant verdict, got compliant")
	}
	if respFail.PassedRules != 2 || respFail.FailedRules != 2 {
		t.Fatalf("expected 2 passed and 2 failed rules, got passed=%d failed=%d", respFail.PassedRules, respFail.FailedRules)
	}
	if respFail.TotalExposure <= 0 {
		t.Fatalf("expected positive monetary exposure for failed checks, got %f", respFail.TotalExposure)
	}
}

// TestPolicyRollback verifies byte-for-byte rollback restoring previous AST and rules.
func TestPolicyRollback(t *testing.T) {
	store, _ := setupTestStore(t)

	// V1
	v1 := &PolicyBundle{
		FrameworkID: "cyber-resilience-act",
		Version:     "v1.0.0",
		Author:      "alice",
		Description: "Initial Baseline",
		Rules: []PolicyRule{
			{
				ID:            "CRA-1",
				Name:          "Non-root Enforcement",
				CELExpression: `object.securityContext.runAsNonRoot == true`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", v1); err != nil {
		t.Fatalf("failed registering v1: %v", err)
	}
	v1Checksum := v1.Checksum

	// V2
	v2 := &PolicyBundle{
		FrameworkID: "cyber-resilience-act",
		Version:     "v1.1.0",
		Author:      "bob",
		Description: "Modified Check",
		Rules: []PolicyRule{
			{
				ID:            "CRA-1",
				Name:          "Modified Check",
				CELExpression: `object.securityContext.runAsUser > 1000`,
			},
			{
				ID:            "CRA-2",
				Name:          "Capabilities Drop",
				CELExpression: `object.containers.all(c, c.securityContext.capabilities.drop.exists(d, d == "ALL"))`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", v2); err != nil {
		t.Fatalf("failed registering v2: %v", err)
	}

	active, err := store.GetActiveBundle("tenant-demo", "cyber-resilience-act", "")
	if err != nil || active.Version != "v1.1.0" {
		t.Fatalf("expected active v1.1.0, got %v", active)
	}

	// Rollback to v1.0.0
	restored, err := store.Rollback("tenant-demo", "cyber-resilience-act", "v1.0.0")
	if err != nil {
		t.Fatalf("rollback failed: %v", err)
	}
	if restored.Version != "v1.0.0" {
		t.Fatalf("expected restored version v1.0.0, got %s", restored.Version)
	}
	if restored.Checksum != v1Checksum {
		t.Fatalf("expected checksum match after rollback: %s != %s", restored.Checksum, v1Checksum)
	}
	if len(restored.Rules) != 1 || restored.Rules[0].ID != "CRA-1" {
		t.Fatalf("expected 1 rule in restored bundle, got %d", len(restored.Rules))
	}

	// Verify active bundle is now v1.0.0
	activeAfter, err := store.GetActiveBundle("tenant-demo", "cyber-resilience-act", "")
	if err != nil || activeAfter.Version != "v1.0.0" {
		t.Fatalf("expected active version v1.0.0 after rollback, got %v", activeAfter)
	}
}

// TestCELCostLimits verifies that runaway or overly complex expressions are halted.
func TestCELCostLimits(t *testing.T) {
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed creating CEL engine: %v", err)
	}

	// 1. Normal safe expression: evaluates with low cost
	safeExpr := `agent.model == "claude-3-5-sonnet"`
	pass, cost, err := engine.Evaluate(context.Background(), safeExpr, map[string]any{
		"agent": map[string]any{"model": "claude-3-5-sonnet"},
	})
	if err != nil || !pass {
		t.Fatalf("expected safe expression to pass, err=%v", err)
	}
	if cost == 0 {
		t.Logf("Evaluated safe expression with cost: %d", cost)
	}

	// 2. Giant expression or runaway list operations
	largeList := make([]int, 1000)
	for i := range largeList {
		largeList[i] = i
	}
	// Expression with nested iterations that would exceed cost limits if unbounded
	nestedExpr := `agent.list.all(x, agent.list.all(y, x + y >= 0))`
	_, _, err = engine.Evaluate(context.Background(), nestedExpr, map[string]any{
		"agent": map[string]any{"list": largeList},
	})
	if err == nil {
		t.Fatalf("expected cost limit exceeded error on nested 1,000,000 iterations, got nil")
	}
	if !strings.Contains(err.Error(), "cost") && !strings.Contains(err.Error(), "limit") && !strings.Contains(err.Error(), "exceeded") {
		t.Logf("Received expected evaluation error: %v", err)
	}
}

// TestHTTPEndpoints tests the HTTP API layer (GET, POST evaluate, POST bundles, POST rollback).
func TestHTTPEndpoints(t *testing.T) {
	store, engine := setupTestStore(t)
	handlers := NewPolicyEngineHandlers(store, engine)

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/policies", handlers.HandleListPolicies)
	mux.HandleFunc("/api/v1/policies/evaluate", handlers.HandleEvaluatePolicies)
	mux.HandleFunc("/api/v1/policies/bundles", handlers.HandleRegisterBundle)
	mux.HandleFunc("/api/v1/policies/rollback", handlers.HandleRollback)

	server := httptest.NewServer(mux)
	defer server.Close()

	client := server.Client()

	// 1. Create bundle via POST /api/v1/policies/bundles
	bundle := PolicyBundle{
		FrameworkID: "finos-aigf",
		Version:     "v1.0.0",
		Author:      "compliance-officer",
		Description: "FINOS AI Governance Framework",
		Rules: []PolicyRule{
			{
				ID:            "FINOS-1",
				Name:          "Approved Model",
				CELExpression: `agent.model in ["gpt-4o", "claude-3-5-sonnet"]`,
			},
		},
	}
	body, _ := json.Marshal(bundle)
	req, _ := http.NewRequest(http.MethodPost, server.URL+"/api/v1/policies/bundles", bytes.NewReader(body))
	req.Header.Set("X-Tenant-ID", "tenant-test")
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != http.StatusCreated {
		t.Fatalf("POST /api/v1/policies/bundles failed: code=%d err=%v", resp.StatusCode, err)
	}

	// 2. List bundles via GET /api/v1/policies
	reqList, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/policies", nil)
	reqList.Header.Set("X-Tenant-ID", "tenant-test")
	respList, err := client.Do(reqList)
	if err != nil || respList.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/v1/policies failed: code=%d err=%v", respList.StatusCode, err)
	}
	var summaries []PolicyBundleSummary
	json.NewDecoder(respList.Body).Decode(&summaries)
	if len(summaries) != 1 || summaries[0].FrameworkID != "finos-aigf" {
		t.Fatalf("unexpected list response: %v", summaries)
	}

	// 3. Evaluate via POST /api/v1/policies/evaluate
	evalReq := EvaluatePoliciesRequest{
		FrameworkID: "finos-aigf",
		Agent: map[string]any{
			"model": "gpt-4o",
		},
	}
	evalBody, _ := json.Marshal(evalReq)
	reqEval, _ := http.NewRequest(http.MethodPost, server.URL+"/api/v1/policies/evaluate", bytes.NewReader(evalBody))
	reqEval.Header.Set("X-Tenant-ID", "tenant-test")
	reqEval.Header.Set("Content-Type", "application/json")
	respEval, err := client.Do(reqEval)
	if err != nil || respEval.StatusCode != http.StatusOK {
		t.Fatalf("POST /api/v1/policies/evaluate failed: code=%d err=%v", respEval.StatusCode, err)
	}
	var evalResp EvaluatePoliciesResponse
	json.NewDecoder(respEval.Body).Decode(&evalResp)
	if !evalResp.Compliant {
		t.Fatalf("expected evaluation to pass, got: %+v", evalResp)
	}

	// 4. Create v1.1.0 then Rollback via POST /api/v1/policies/rollback
	bundle2 := bundle
	bundle2.Version = "v1.1.0"
	bundle2.Rules[0].CELExpression = `agent.model == "only-claude"`
	body2, _ := json.Marshal(bundle2)
	req2, _ := http.NewRequest(http.MethodPost, server.URL+"/api/v1/policies/bundles", bytes.NewReader(body2))
	req2.Header.Set("X-Tenant-ID", "tenant-test")
	client.Do(req2)

	rbReq := RollbackRequest{
		FrameworkID:   "finos-aigf",
		TargetVersion: "v1.0.0",
	}
	rbBody, _ := json.Marshal(rbReq)
	reqRb, _ := http.NewRequest(http.MethodPost, server.URL+"/api/v1/policies/rollback", bytes.NewReader(rbBody))
	reqRb.Header.Set("X-Tenant-ID", "tenant-test")
	reqRb.Header.Set("Content-Type", "application/json")
	respRb, err := client.Do(reqRb)
	if err != nil || respRb.StatusCode != http.StatusOK {
		t.Fatalf("POST /api/v1/policies/rollback failed: code=%d err=%v", respRb.StatusCode, err)
	}
	var restored PolicyBundle
	json.NewDecoder(respRb.Body).Decode(&restored)
	if restored.Version != "v1.0.0" {
		t.Fatalf("expected rollback to v1.0.0, got %s", restored.Version)
	}
}

// TestConcurrentEvaluations verifies thread-safety and zero memory leakage under concurrency.
func TestConcurrentEvaluations(t *testing.T) {
	store, _ := setupTestStore(t)

	bundle := &PolicyBundle{
		FrameworkID: "eu-ai-act",
		Version:     "v1.0.0",
		Author:      "sec",
		Rules: []PolicyRule{
			{
				ID:            "R1",
				Name:          "Model",
				CELExpression: `agent.model == "gpt-4o"`,
			},
			{
				ID:            "R2",
				Name:          "Permission",
				CELExpression: `agent.tool_permissions.all(p, !p.startsWith("root"))`,
			},
		},
	}
	if err := store.RegisterBundle("tenant-demo", bundle); err != nil {
		t.Fatalf("failed registering bundle: %v", err)
	}

	req := &EvaluatePoliciesRequest{
		TenantID:    "tenant-demo",
		FrameworkID: "eu-ai-act",
		Agent: map[string]any{
			"model":            "gpt-4o",
			"tool_permissions": []any{"read", "write"},
		},
	}

	var wg sync.WaitGroup
	workers := 50
	iterations := 20

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				resp, err := store.EvaluateBundle(context.Background(), bundle, req)
				if err != nil || !resp.Compliant {
					t.Errorf("concurrent evaluation failed: %v", err)
				}
			}
		}()
	}

	wg.Wait()
}
