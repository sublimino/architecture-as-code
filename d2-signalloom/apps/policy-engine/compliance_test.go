package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func testPolicyRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "policy")
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find policy/ directory")
		}
		dir = parent
	}
}

func testComplianceHandler(t *testing.T) *complianceHandler {
	t.Helper()
	root := testPolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestComplianceScan_BasicPass(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
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
						"resources": map[string]any{
							"limits": map[string]any{
								"cpu": "500m",
							},
						},
					},
				},
				"automountServiceAccountToken": false,
			},
		},
	}

	body, _ := json.Marshal(scanReq)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var results []ComplianceScanResult
	if err := json.NewDecoder(w.Body).Decode(&results); err != nil {
		t.Fatal(err)
	}

	if len(results) == 0 {
		t.Fatal("expected at least one scan result")
	}

	// Verify wire format fields are present.
	for _, r := range results {
		if r.Framework == "" {
			t.Fatal("framework should not be empty")
		}
		if r.ControlSet == "" {
			t.Fatal("controlSet should not be empty")
		}
		if r.Check == "" {
			t.Fatal("check should not be empty")
		}
		if r.PolicyVersion == "" {
			t.Fatal("policyVersion should not be empty")
		}
		if r.ScanTimestamp == "" {
			t.Fatal("scanTimestamp should not be empty")
		}
		if r.CalibrationSource != "industry-indicative" {
			t.Fatalf("expected calibrationSource 'industry-indicative', got %q", r.CalibrationSource)
		}
	}
}

func TestComplianceScan_FailedChecks(t *testing.T) {
	h := testComplianceHandler(t)

	// Minimal manifest that fails most checks.
	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"containers": []any{
					map[string]any{
						"name":  "agent",
						"image": "docker.io/evil/image:latest",
					},
				},
			},
		},
	}

	body, _ := json.Marshal(scanReq)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var results []ComplianceScanResult
	json.NewDecoder(w.Body).Decode(&results)

	failCount := 0
	for _, r := range results {
		if !r.Passed {
			failCount++
			// Failed checks should still have FAIR metrics.
			if r.ALE == 0 && r.VaR95 == 0 {
				t.Fatalf("failed check %q should still have FAIR risk metrics", r.Check)
			}
		}
	}

	if failCount == 0 {
		t.Fatal("expected at least one failed check for insecure manifest")
	}
}

func TestComplianceScan_MultipleFrameworks(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53", "eu-ai-act"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"containers": []any{
					map[string]any{
						"name":  "agent",
						"image": "test:latest",
					},
				},
			},
		},
	}

	body, _ := json.Marshal(scanReq)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	var results []ComplianceScanResult
	json.NewDecoder(w.Body).Decode(&results)

	// Should have results from both frameworks.
	fwSeen := map[string]bool{}
	for _, r := range results {
		fwSeen[r.Framework] = true
	}
	if !fwSeen["nist-800-53"] {
		t.Fatal("expected results from nist-800-53")
	}
	if !fwSeen["eu-ai-act"] {
		t.Fatal("expected results from eu-ai-act")
	}
}

func TestComplianceScan_MethodNotAllowed(t *testing.T) {
	h := testComplianceHandler(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/scan", nil)
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}

func TestComplianceScan_EmptyBody(t *testing.T) {
	h := testComplianceHandler(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader([]byte{}))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestComplianceFrameworks(t *testing.T) {
	h := testComplianceHandler(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/frameworks", nil)
	w := httptest.NewRecorder()
	h.handleFrameworks(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var result map[string][]string
	json.NewDecoder(w.Body).Decode(&result)

	if _, ok := result["nist-800-53"]; !ok {
		t.Fatal("expected nist-800-53 in frameworks list")
	}
	if _, ok := result["eu-ai-act"]; !ok {
		t.Fatal("expected eu-ai-act in frameworks list")
	}
}

func TestComplianceSummary(t *testing.T) {
	h := testComplianceHandler(t)

	// Run a scan first to populate the last-scan cache.
	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"securityContext": map[string]any{
					"runAsNonRoot": true,
				},
				"containers": []any{
					map[string]any{
						"name":  "agent",
						"image": "zot.registry.svc.cluster.local:5000/acme/test@sha256:abc",
						"securityContext": map[string]any{
							"allowPrivilegeEscalation": false,
							"capabilities": map[string]any{
								"drop": []any{"ALL"},
							},
						},
					},
				},
			},
		},
	}
	body, _ := json.Marshal(scanReq)
	scanW := httptest.NewRecorder()
	h.handleScan(scanW, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body)))

	// Now get the summary.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	w := httptest.NewRecorder()
	h.handleSummary(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var summary ComplianceSummary
	json.NewDecoder(w.Body).Decode(&summary)

	if summary.TotalControls == 0 {
		t.Fatal("expected total controls > 0")
	}
	if summary.Passed+summary.Failed != summary.TotalControls {
		t.Fatalf("passed (%d) + failed (%d) should equal total (%d)",
			summary.Passed, summary.Failed, summary.TotalControls)
	}
}

func TestComplianceSummary_NoScan(t *testing.T) {
	h := testComplianceHandler(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	w := httptest.NewRecorder()
	h.handleSummary(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var summary ComplianceSummary
	json.NewDecoder(w.Body).Decode(&summary)

	if summary.TotalControls != 0 {
		t.Fatalf("expected 0 total controls before any scan, got %d", summary.TotalControls)
	}
}
