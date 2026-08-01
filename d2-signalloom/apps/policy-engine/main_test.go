package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	handleHealthz(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var body map[string]string
	json.NewDecoder(w.Body).Decode(&body)
	if body["status"] != "ok" {
		t.Fatalf("expected status ok, got %q", body["status"])
	}
}

func TestReadyz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	handleReadyz(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var body map[string]string
	json.NewDecoder(w.Body).Decode(&body)
	if body["status"] != "ready" {
		t.Fatalf("expected status ready, got %q", body["status"])
	}
}

func TestEvaluate_FullyCompliant(t *testing.T) {
	trueVal := true
	reqBody := EvaluateRequest{
		AgentID:   "cardvault-agent",
		Namespace: "fe-signalloom-agents",
		PodSpec: &PodSpec{
			SecurityContext: &SecurityContext{
				RunAsNonRoot: &trueVal,
			},
			Containers: []Container{
				{
					Name: "agent",
					SecurityContext: &SecurityContext{
						Capabilities: &Capabilities{
							Drop: []string{"ALL"},
						},
					},
				},
			},
		},
		Checks: []string{"security-context-present", "run-as-non-root", "drop-capabilities"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if !resp.Compliant {
		t.Fatal("expected compliant=true")
	}
	if resp.AgentID != "cardvault-agent" {
		t.Fatalf("expected agent_id cardvault-agent, got %q", resp.AgentID)
	}
	if len(resp.Results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(resp.Results))
	}
	for _, r := range resp.Results {
		if !r.Pass {
			t.Fatalf("expected all checks to pass, %q failed: %s", r.Check, r.Reason)
		}
	}
	if resp.EvaluatedAt == "" {
		t.Fatal("expected evaluated_at to be set")
	}
}

func TestEvaluate_EmptySecurityContext(t *testing.T) {
	reqBody := EvaluateRequest{
		AgentID:   "cardvault-agent",
		Namespace: "fe-signalloom-agents",
		PodSpec: &PodSpec{
			Containers: []Container{
				{Name: "agent"},
			},
		},
		Checks: []string{"security-context-present", "run-as-non-root", "drop-capabilities"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if resp.Compliant {
		t.Fatal("expected compliant=false")
	}
	for _, r := range resp.Results {
		if r.Pass {
			t.Fatalf("expected check %q to fail", r.Check)
		}
	}
}

func TestEvaluate_PartialCompliance(t *testing.T) {
	trueVal := true
	reqBody := EvaluateRequest{
		AgentID:   "cardvault-agent",
		Namespace: "fe-signalloom-agents",
		PodSpec: &PodSpec{
			SecurityContext: &SecurityContext{
				RunAsNonRoot: &trueVal,
			},
			Containers: []Container{
				{Name: "agent"},
			},
		},
		Checks: []string{"security-context-present", "run-as-non-root", "drop-capabilities"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if resp.Compliant {
		t.Fatal("expected compliant=false for partial compliance")
	}

	passMap := map[string]bool{}
	for _, r := range resp.Results {
		passMap[r.Check] = r.Pass
	}

	if !passMap["security-context-present"] {
		t.Fatal("security-context-present should pass")
	}
	if !passMap["run-as-non-root"] {
		t.Fatal("run-as-non-root should pass")
	}
	if passMap["drop-capabilities"] {
		t.Fatal("drop-capabilities should fail")
	}
}

func TestEvaluate_UnknownCheck(t *testing.T) {
	reqBody := EvaluateRequest{
		AgentID:   "test-agent",
		Namespace: "default",
		PodSpec: &PodSpec{
			Containers: []Container{{Name: "c1"}},
		},
		Checks: []string{"nonexistent-check"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if resp.Compliant {
		t.Fatal("expected compliant=false for unknown check")
	}
	if len(resp.Results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(resp.Results))
	}
	if resp.Results[0].Reason != "unknown check" {
		t.Fatalf("expected reason 'unknown check', got %q", resp.Results[0].Reason)
	}
}

func TestEvaluate_EmptyBody(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader([]byte{}))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestEvaluate_NoChecks(t *testing.T) {
	trueVal := true
	reqBody := EvaluateRequest{
		AgentID:   "test-agent",
		Namespace: "default",
		PodSpec: &PodSpec{
			SecurityContext: &SecurityContext{RunAsNonRoot: &trueVal},
			Containers:      []Container{{Name: "c1"}},
		},
		Checks: []string{},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if !resp.Compliant {
		t.Fatal("expected compliant=true with no checks")
	}
	if len(resp.Results) != 0 {
		t.Fatalf("expected 0 results, got %d", len(resp.Results))
	}
}

func TestEvaluate_NullPodSpec(t *testing.T) {
	body := []byte(`{"agent_id":"x","namespace":"y","checks":["run-as-non-root"]}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for null pod_spec, got %d", w.Code)
	}
}

func TestEvaluate_MethodNotAllowed(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/evaluate", nil)
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}

func TestEvaluate_RunAsNonRootFalse(t *testing.T) {
	falseVal := false
	reqBody := EvaluateRequest{
		AgentID:   "test-agent",
		Namespace: "default",
		PodSpec: &PodSpec{
			SecurityContext: &SecurityContext{RunAsNonRoot: &falseVal},
			Containers:      []Container{{Name: "c1"}},
		},
		Checks: []string{"run-as-non-root"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if resp.Compliant {
		t.Fatal("expected compliant=false when runAsNonRoot=false")
	}
	if resp.Results[0].Reason != "runAsNonRoot is set to false" {
		t.Fatalf("unexpected reason: %q", resp.Results[0].Reason)
	}
}

func TestEvaluate_SecurityContextEmptyStruct(t *testing.T) {
	reqBody := EvaluateRequest{
		AgentID:   "test-agent",
		Namespace: "default",
		PodSpec: &PodSpec{
			SecurityContext: &SecurityContext{},
			Containers:      []Container{{Name: "c1"}},
		},
		Checks: []string{"security-context-present"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if resp.Results[0].Pass {
		t.Fatal("expected security-context-present to fail for empty struct")
	}
	if resp.Results[0].Reason != "pod-level securityContext has no fields set" {
		t.Fatalf("unexpected reason: %q", resp.Results[0].Reason)
	}
}

func TestEvaluate_DropCapsLowercase(t *testing.T) {
	reqBody := EvaluateRequest{
		AgentID:   "test-agent",
		Namespace: "default",
		PodSpec: &PodSpec{
			Containers: []Container{
				{
					Name: "agent",
					SecurityContext: &SecurityContext{
						Capabilities: &Capabilities{Drop: []string{"all"}},
					},
				},
			},
		},
		Checks: []string{"drop-capabilities"},
	}

	body, _ := json.Marshal(reqBody)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/evaluate", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleEvaluate(w, req)

	var resp EvaluateResponse
	json.NewDecoder(w.Body).Decode(&resp)

	if !resp.Results[0].Pass {
		t.Fatal("expected drop-capabilities to pass with lowercase 'all'")
	}
}
