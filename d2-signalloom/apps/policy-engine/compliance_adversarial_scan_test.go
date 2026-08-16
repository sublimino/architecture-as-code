package main

// Adversarial tests for the compliance scan endpoint's framework handling.
//
// The unifying defect pattern: "two things that must agree, with nothing checking
// that they do." The scan endpoint silently skipped unknown frameworks and returned
// an empty 200 — the caller believed it asked for a scan, the server believed it
// ran one, and neither had any results.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestScanAllUnknownFrameworks_Returns400 verifies that requesting only
// frameworks that don't exist produces a 400, not an empty 200.
func TestScanAllUnknownFrameworks_Returns400(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nonexistent-framework"},
		Manifest:      map[string]any{},
	}

	body, _ := json.Marshal(scanReq)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for all-unknown frameworks, got %d: %s", w.Code, w.Body.String())
	}

	var errResp map[string]string
	json.NewDecoder(w.Body).Decode(&errResp)
	if errResp["error"] == "" {
		t.Fatal("expected error message in response")
	}
}

// TestScanMultipleAllUnknownFrameworks_Returns400 verifies the check works
// with multiple unknown framework IDs.
func TestScanMultipleAllUnknownFrameworks_Returns400(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"fake-fw-1", "fake-fw-2", "fake-fw-3"},
		Manifest:      map[string]any{},
	}

	body, _ := json.Marshal(scanReq)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for all-unknown frameworks, got %d: %s", w.Code, w.Body.String())
	}
}

// TestScanMixedKnownUnknown_Succeeds verifies that a mix of known and unknown
// frameworks still succeeds (partial results from known frameworks).
func TestScanMixedKnownUnknown_Succeeds(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53", "nonexistent-framework"},
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

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 for mixed known/unknown frameworks, got %d: %s", w.Code, w.Body.String())
	}

	var results []ComplianceScanResult
	json.NewDecoder(w.Body).Decode(&results)

	// Should have results from the known framework only.
	for _, r := range results {
		if r.Framework == "nonexistent-framework" {
			t.Fatal("should not have results from unknown framework")
		}
	}
	if len(results) == 0 {
		t.Fatal("expected at least one result from the known framework")
	}
}

// TestScanIdempotent verifies that calling scan twice with the same input
// produces identical results (deterministic FAIR seeds).
func TestScanIdempotent(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
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

	body1, _ := json.Marshal(scanReq)
	w1 := httptest.NewRecorder()
	h.handleScan(w1, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body1)))

	body2, _ := json.Marshal(scanReq)
	w2 := httptest.NewRecorder()
	h.handleScan(w2, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body2)))

	var results1, results2 []ComplianceScanResult
	json.NewDecoder(w1.Body).Decode(&results1)
	json.NewDecoder(w2.Body).Decode(&results2)

	if len(results1) != len(results2) {
		t.Fatalf("idempotency violation: first scan returned %d results, second returned %d",
			len(results1), len(results2))
	}

	for i := range results1 {
		if results1[i].Check != results2[i].Check {
			t.Fatalf("idempotency violation at index %d: check IDs differ (%s vs %s)",
				i, results1[i].Check, results2[i].Check)
		}
		if results1[i].ALE != results2[i].ALE {
			t.Fatalf("idempotency violation at index %d: ALE differs (%g vs %g)",
				i, results1[i].ALE, results2[i].ALE)
		}
		if results1[i].Passed != results2[i].Passed {
			t.Fatalf("idempotency violation at index %d: Passed differs (%v vs %v)",
				i, results1[i].Passed, results2[i].Passed)
		}
	}
}

// TestSummaryBeforeScan_ReturnsZeros verifies the summary endpoint returns
// zero-valued summary before any scan (not an error, but clearly empty).
func TestSummaryBeforeScan_ReturnsZeros(t *testing.T) {
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
	if summary.ScanTimestamp != "" {
		t.Fatalf("expected empty scan timestamp before any scan, got %q", summary.ScanTimestamp)
	}
}

// TestScanEmptyManifest_Succeeds verifies the scan handles a nil/empty manifest
// gracefully (CEL expressions evaluate against an empty object).
func TestScanEmptyManifest_Succeeds(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
		Manifest:      map[string]any{},
	}

	body, _ := json.Marshal(scanReq)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.handleScan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 for empty manifest, got %d: %s", w.Code, w.Body.String())
	}
}

// TestScanResultsHaveCurrency verifies every result carries the reporting
// currency — the contract the dashboard depends on.
func TestScanResultsHaveCurrency(t *testing.T) {
	h := testComplianceHandler(t)

	scanReq := ComplianceScanRequest{
		Namespace:     "test-ns",
		PolicyVersion: "v2.1.0",
		Frameworks:    []string{"nist-800-53"},
		Manifest: map[string]any{
			"spec": map[string]any{
				"containers": []any{
					map[string]any{"name": "agent", "image": "test:latest"},
				},
			},
		},
	}

	body, _ := json.Marshal(scanReq)
	w := httptest.NewRecorder()
	h.handleScan(w, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body)))

	var results []ComplianceScanResult
	json.NewDecoder(w.Body).Decode(&results)

	for i, r := range results {
		if r.Currency == "" {
			t.Fatalf("result %d (%s) has empty currency", i, r.Check)
		}
		if r.Currency != reportingCurrency {
			t.Fatalf("result %d (%s) has currency %q, expected %q",
				i, r.Check, r.Currency, reportingCurrency)
		}
		if r.Carried.Currency != reportingCurrency {
			t.Fatalf("result %d (%s) carried.currency is %q, expected %q",
				i, r.Check, r.Carried.Currency, reportingCurrency)
		}
	}
}
