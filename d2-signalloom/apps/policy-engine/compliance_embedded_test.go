package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEmbeddedComplianceHandler_Initialization(t *testing.T) {
	celEngine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed to create CEL engine: %v", err)
	}

	h, err := newComplianceHandler("", celEngine)
	if err != nil {
		t.Fatalf("newComplianceHandler with empty policyRoot should succeed in embedded mode, got error: %v", err)
	}
	if h == nil {
		t.Fatal("expected non-nil complianceHandler in embedded mode")
	}
}

func TestEmbeddedComplianceHandler_Frameworks(t *testing.T) {
	celEngine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed to create CEL engine: %v", err)
	}

	h, err := newComplianceHandler("", celEngine)
	if err != nil {
		t.Fatalf("newComplianceHandler failed: %v", err)
	}

	// 1. List all frameworks
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/frameworks", nil)
	w := httptest.NewRecorder()
	h.handleFrameworks(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("handleFrameworks returned status %d, want %d. Body: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var fws map[string][]string
	if err := json.Unmarshal(w.Body.Bytes(), &fws); err != nil {
		t.Fatalf("failed to decode frameworks response: %v", err)
	}

	expectedFrameworks := []string{
		"cis-kubernetes",
		"eu-ai-act",
		"nist-800-53",
		"finos-aigf",
		"dora",
		"cra",
		"nis2",
	}

	for _, ef := range expectedFrameworks {
		versions, ok := fws[ef]
		if !ok || len(versions) == 0 {
			t.Errorf("expected embedded framework %q with versions, got: %v", ef, versions)
		}
	}

	// 2. Query single framework details
	reqSingle := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/frameworks/cis-kubernetes", nil)
	wSingle := httptest.NewRecorder()
	h.handleFrameworks(wSingle, reqSingle)

	if wSingle.Code != http.StatusOK {
		t.Fatalf("handleFrameworks for cis-kubernetes returned %d: %s", wSingle.Code, wSingle.Body.String())
	}

	var singleResp struct {
		ID       string   `json:"id"`
		Versions []string `json:"versions"`
	}
	if err := json.Unmarshal(wSingle.Body.Bytes(), &singleResp); err != nil {
		t.Fatalf("failed to decode single framework response: %v", err)
	}
	if singleResp.ID != "cis-kubernetes" || len(singleResp.Versions) == 0 {
		t.Errorf("unexpected response for cis-kubernetes: %+v", singleResp)
	}
}

func TestEmbeddedComplianceHandler_ScanCisKubernetes(t *testing.T) {
	celEngine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed to create CEL engine: %v", err)
	}

	h, err := newComplianceHandler("", celEngine)
	if err != nil {
		t.Fatalf("newComplianceHandler failed: %v", err)
	}

	scanReq := ComplianceScanRequest{
		Namespace:  "test-ns",
		Frameworks: []string{"cis-kubernetes"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"securityContext": map[string]any{
					"runAsNonRoot": true,
				},
				"containers": []any{
					map[string]any{
						"name":  "agent",
						"image": "ghcr.io/controlplaneio/cardvault@sha256:abc123",
						"securityContext": map[string]any{
							"runAsNonRoot":             true,
							"allowPrivilegeEscalation": false,
							"privileged":               false,
							"readOnlyRootFilesystem":   true,
							"capabilities": map[string]any{
								"drop": []any{"ALL"},
							},
						},
					},
				},
				"automountServiceAccountToken": false,
			},
		},
	}

	raw, err := json.Marshal(scanReq)
	if err != nil {
		t.Fatalf("marshal scanReq failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("handleScan returned HTTP %d, want 200. Body: %s", w.Code, w.Body.String())
	}

	var results []ComplianceScanResult
	if err := json.Unmarshal(w.Body.Bytes(), &results); err != nil {
		t.Fatalf("failed to unmarshal scan results: %v", err)
	}

	if len(results) == 0 {
		t.Fatal("expected scan results for cis-kubernetes, got empty slice")
	}

	evaluatedCount := 0
	for _, r := range results {
		if r.Framework != "cis-kubernetes" {
			t.Errorf("expected framework cis-kubernetes, got %q", r.Framework)
		}
		if r.Status == VerdictPass || r.Status == VerdictFail {
			evaluatedCount++
		}
	}
	if evaluatedCount == 0 {
		t.Error("expected at least one check to evaluate to pass or fail")
	}
}

func TestEmbeddedComplianceHandler_ScanEuAiAct(t *testing.T) {
	celEngine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed to create CEL engine: %v", err)
	}

	h, err := newComplianceHandler("", celEngine)
	if err != nil {
		t.Fatalf("newComplianceHandler failed: %v", err)
	}

	scanReq := ComplianceScanRequest{
		Namespace:  "test-ns",
		Frameworks: []string{"eu-ai-act"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"containers": []any{
					map[string]any{
						"name":  "agent",
						"image": "ghcr.io/controlplaneio/cardvault@sha256:abc123",
					},
				},
			},
		},
	}

	raw, err := json.Marshal(scanReq)
	if err != nil {
		t.Fatalf("marshal scanReq failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("handleScan returned HTTP %d, want 200. Body: %s", w.Code, w.Body.String())
	}

	var results []ComplianceScanResult
	if err := json.Unmarshal(w.Body.Bytes(), &results); err != nil {
		t.Fatalf("failed to unmarshal scan results: %v", err)
	}

	if len(results) == 0 {
		t.Fatal("expected scan results for eu-ai-act, got empty slice")
	}
}

func TestEmbeddedComplianceHandler_Summary(t *testing.T) {
	celEngine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed to create CEL engine: %v", err)
	}

	h, err := newComplianceHandler("", celEngine)
	if err != nil {
		t.Fatalf("newComplianceHandler failed: %v", err)
	}

	scanReq := ComplianceScanRequest{
		Namespace:  "test-ns",
		Frameworks: []string{"cis-kubernetes"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"containers": []any{
					map[string]any{
						"name":  "agent",
						"image": "ghcr.io/controlplaneio/cardvault@sha256:abc123",
					},
				},
			},
		},
	}

	raw, err := json.Marshal(scanReq)
	if err != nil {
		t.Fatalf("marshal scanReq failed: %v", err)
	}

	// 1. Scan with tenant header
	reqScan := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw))
	reqScan.Header.Set("X-Tenant-ID", "tenant-alpha")
	wScan := httptest.NewRecorder()
	h.handleScan(wScan, reqScan)

	if wScan.Code != http.StatusOK {
		t.Fatalf("handleScan returned HTTP %d: %s", wScan.Code, wScan.Body.String())
	}

	// 2. Query summary for that tenant
	reqSum := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	reqSum.Header.Set("X-Tenant-ID", "tenant-alpha")
	wSum := httptest.NewRecorder()
	h.handleSummary(wSum, reqSum)

	if wSum.Code != http.StatusOK {
		t.Fatalf("handleSummary returned HTTP %d: %s", wSum.Code, wSum.Body.String())
	}

	var sum ComplianceSummary
	if err := json.Unmarshal(wSum.Body.Bytes(), &sum); err != nil {
		t.Fatalf("unmarshal summary failed: %v", err)
	}

	if sum.TotalControls == 0 {
		t.Error("expected non-zero TotalControls in summary")
	}
	if sum.TotalExposure <= 0 {
		t.Errorf("expected positive TotalExposure for failed controls, got %f", sum.TotalExposure)
	}
}
