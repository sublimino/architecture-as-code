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
		// Not "industry-indicative". That tag claimed an industry anchor no
		// shipped triple has. See the comment at the assignment in compliance.go
		// and policy/frameworks/README.md for the calibration statement.
		if r.CalibrationSource != "declared-estimate-unanchored" {
			t.Fatalf("expected calibrationSource 'declared-estimate-unanchored', got %q", r.CalibrationSource)
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
	if allow := w.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("expected Content-Type: application/json, got %q", ct)
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
	// Errored is its own bucket: an unevaluable check is not a failed one.
	if summary.Passed+summary.Failed+summary.Errored != summary.TotalControls {
		t.Fatalf("passed (%d) + failed (%d) + errored (%d) should equal total (%d)",
			summary.Passed, summary.Failed, summary.Errored, summary.TotalControls)
	}
}

// TestComplianceSummary_NoScan asserts the one distinction that matters most on
// this endpoint, and it is NOT simply "404 instead of 200".
//
// THERE ARE TWO DIFFERENT FACTS AND THEY MUST NOT BE CONFUSABLE:
//
//	A. no scan exists for this tenant        -> 404, no counts at all
//	B. a scan exists and priced nothing      -> 200, totalControls > 0,
//	                                            totalExposureGbp 0
//
// On this product (B) is a real, meaningful, reportable answer: zero exposure.
// (A) is the absence of an answer. Before fix 2 the endpoint answered (A) with
// a zero-valued 200 -- byte-compatible with (B) and with a genuinely clean
// posture -- so a client could not tell "we have no data for you" from "we
// looked and you are clean". That is the same fabrication class as the empty
// 200 of fix 1, one level up, and it is the reason the no-scan case is a 404
// carrying NO numeric field rather than a 200 carrying zeroes.
//
// Both directions are asserted here, against each other, in one test. Asserting
// them separately would let a future change make the 404 body carry zeroed
// counts "for client convenience" and still pass both.
func TestComplianceSummary_NoScan(t *testing.T) {
	h := testComplianceHandler(t)

	// (A) No scan.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	w := httptest.NewRecorder()
	h.handleSummary(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("no-scan summary: expected 404, got %d: %.300q", w.Code, w.Body.String())
	}
	var absent map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &absent); err != nil {
		t.Fatalf("no-scan body is not JSON: %v (%.300q)", err, w.Body.String())
	}
	if absent["error"] != "no_scan_for_tenant" {
		t.Errorf("no-scan error = %v, want no_scan_for_tenant", absent["error"])
	}
	// The load-bearing half: NOT ONE numeric summary field. A client defaulting
	// absent numbers to zero must get nothing to default.
	for _, numeric := range []string{
		"totalControls", "passed", "failed", "errored", "notEvaluated",
		"notInForce", "totalExposureGbp", "exposure", "currency",
	} {
		if _, present := absent[numeric]; present {
			t.Errorf("the no-scan refusal carries %q. That makes 'we have no scan for you' "+
				"readable as 'we scanned and you are clean', which are different facts "+
				"and only one of them is an answer.", numeric)
		}
	}

	// (B) A scan that exists. Same caller, same endpoint, and now a real
	// document -- whose shape must not be reachable from (A).
	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
		Manifest:      map[string]any{},
	}
	body, _ := json.Marshal(scanReq)
	sw := httptest.NewRecorder()
	h.handleScan(sw, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body)))
	if sw.Code != http.StatusOK {
		t.Fatalf("scan: got %d: %.300q", sw.Code, sw.Body.String())
	}

	w2 := httptest.NewRecorder()
	h.handleSummary(w2, httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil))
	if w2.Code != http.StatusOK {
		t.Fatalf("post-scan summary: expected 200, got %d: %.300q", w2.Code, w2.Body.String())
	}
	var present map[string]any
	if err := json.Unmarshal(w2.Body.Bytes(), &present); err != nil {
		t.Fatalf("summary body is not JSON: %v", err)
	}
	if _, isErr := present["error"]; isErr {
		t.Errorf("a real summary carries an %q field, so a refusal and an answer are no "+
			"longer distinguishable by shape: %.300q", "error", w2.Body.String())
	}
	tc, ok := present["totalControls"].(float64)
	if !ok || tc <= 0 {
		t.Errorf("post-scan totalControls = %#v, want > 0 -- (B) must be a real document "+
			"or this test cannot contrast it with (A)", present["totalControls"])
	}
}

func TestComplianceFrameworks_MethodsAndHEAD(t *testing.T) {
	h := testComplianceHandler(t)

	// POST returns 405 Method Not Allowed with Allow: GET, HEAD
	recPost := httptest.NewRecorder()
	h.handleFrameworks(recPost, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/frameworks", nil))
	if recPost.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST code=%d, want 405", recPost.Code)
	}
	if allow := recPost.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("POST Allow=%q, want 'GET, HEAD'", allow)
	}

	// HEAD returns 200 OK with empty body and Content-Type: application/json
	recHead := httptest.NewRecorder()
	h.handleFrameworks(recHead, httptest.NewRequest(http.MethodHead, "/api/v1/compliance/frameworks", nil))
	if recHead.Code != http.StatusOK {
		t.Fatalf("HEAD code=%d, want 200", recHead.Code)
	}
	if ct := recHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("HEAD Content-Type=%q, want application/json", ct)
	}
	if recHead.Body.Len() != 0 {
		t.Fatalf("HEAD body len=%d, want 0", recHead.Body.Len())
	}

	// HEAD subpath exists
	recSubHead := httptest.NewRecorder()
	h.handleFrameworks(recSubHead, httptest.NewRequest(http.MethodHead, "/api/v1/compliance/frameworks/nist-800-53", nil))
	if recSubHead.Code != http.StatusOK {
		t.Fatalf("HEAD subpath code=%d, want 200", recSubHead.Code)
	}
	if recSubHead.Body.Len() != 0 {
		t.Fatalf("HEAD subpath body len=%d, want 0", recSubHead.Body.Len())
	}

	// HEAD subpath non-existent returns 404 with empty body
	recNotFoundHead := httptest.NewRecorder()
	h.handleFrameworks(recNotFoundHead, httptest.NewRequest(http.MethodHead, "/api/v1/compliance/frameworks/non-existent-framework", nil))
	if recNotFoundHead.Code != http.StatusNotFound {
		t.Fatalf("HEAD not-found code=%d, want 404", recNotFoundHead.Code)
	}
	if recNotFoundHead.Body.Len() != 0 {
		t.Fatalf("HEAD not-found body len=%d, want 0", recNotFoundHead.Body.Len())
	}
}

func TestComplianceSummary_MethodsAndHEAD(t *testing.T) {
	h := testComplianceHandler(t)

	// POST returns 405 Method Not Allowed with Allow: GET, HEAD
	recPost := httptest.NewRecorder()
	h.handleSummary(recPost, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/summary", nil))
	if recPost.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST code=%d, want 405", recPost.Code)
	}
	if allow := recPost.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("POST Allow=%q, want 'GET, HEAD'", allow)
	}

	// HEAD without prior scan returns 404 with empty body
	recNoScanHead := httptest.NewRecorder()
	h.handleSummary(recNoScanHead, httptest.NewRequest(http.MethodHead, "/api/v1/compliance/summary", nil))
	if recNoScanHead.Code != http.StatusNotFound {
		t.Fatalf("HEAD no-scan code=%d, want 404", recNoScanHead.Code)
	}
	if recNoScanHead.Body.Len() != 0 {
		t.Fatalf("HEAD no-scan body len=%d, want 0", recNoScanHead.Body.Len())
	}

	// Run scan
	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
		Manifest:      map[string]any{},
	}
	body, _ := json.Marshal(scanReq)
	sw := httptest.NewRecorder()
	h.handleScan(sw, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body)))
	if sw.Code != http.StatusOK {
		t.Fatalf("scan code=%d, want 200", sw.Code)
	}

	// HEAD with prior scan returns 200 OK with empty body
	recScanHead := httptest.NewRecorder()
	h.handleSummary(recScanHead, httptest.NewRequest(http.MethodHead, "/api/v1/compliance/summary", nil))
	if recScanHead.Code != http.StatusOK {
		t.Fatalf("HEAD post-scan code=%d, want 200", recScanHead.Code)
	}
	if ct := recScanHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("HEAD post-scan Content-Type=%q, want application/json", ct)
	}
	if recScanHead.Body.Len() != 0 {
		t.Fatalf("HEAD post-scan body len=%d, want 0", recScanHead.Body.Len())
	}
}

func TestComplianceScan_HEADMethodNotAllowed(t *testing.T) {
	h := &complianceHandler{}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodHead, "/api/v1/compliance/scan", nil)
	h.handleScan(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("scan HEAD code=%d, want 405", rec.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("scan HEAD Allow=%q, want 'POST'", allow)
	}
	if rec.Body.Len() != 0 {
		t.Fatalf("scan HEAD body len=%d, want 0", rec.Body.Len())
	}
}

