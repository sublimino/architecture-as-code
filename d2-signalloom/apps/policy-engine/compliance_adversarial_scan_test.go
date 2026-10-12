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

// TestSummaryBeforeScan_Is404AndNotAZeroedSummary pins the CONTRACT CHANGE made
// by fix 2, and it is a deliberate change rather than a side effect.
//
// WHAT THIS TEST USED TO ASSERT. A summary requested before any scan returned
// HTTP 200 with a zero-valued ComplianceSummary -- "not an error, but clearly
// empty". That reading only held while there was one global slot: "nothing has
// been scanned" was a fact about the process and a zeroed document described it
// accurately.
//
// WHY IT NO LONGER HOLDS. The slot is now keyed by tenant, so the same request
// means "show me MY summary", and the honest answers to that are a summary or a
// refusal -- never a zeroed document. A zeroed summary is indistinguishable
// from a real one: totalControls 0, failed 0, totalExposureGbp 0 renders as a
// clean compliance posture, and a tenant whose scan has not run (or has been
// evicted from the bounded store) would be shown one. That is the same class of
// fabrication as the empty 200 fix 1 removed, which is why both go the same way.
//
// So: 404, with a body that says which tenant has no scan and what to do about
// it. Asserted on the status AND the body, because a 404 with no document is
// only marginally better than a 200 with none.
func TestSummaryBeforeScan_Is404AndNotAZeroedSummary(t *testing.T) {
	h := testComplianceHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	w := httptest.NewRecorder()
	h.handleSummary(w, req)

	if w.Code == http.StatusOK {
		t.Fatalf("expected 404, got 200 with %.300q. A zeroed summary is indistinguishable "+
			"from a real clean one and must never be served for a tenant that has not "+
			"scanned.", w.Body.String())
	}
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %.300q", w.Code, w.Body.String())
	}
	if w.Body.Len() == 0 {
		t.Fatal("404 carries no body: a refusal an operator cannot read is barely better " +
			"than a fabricated success")
	}

	// It is NOT a summary document. A client that unmarshals optimistically must
	// not find usable counts in the refusal.
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("404 body is not JSON: %v (%.300q)", err, w.Body.String())
	}
	if body["error"] != "no_scan_for_tenant" {
		t.Errorf("error = %v, want no_scan_for_tenant", body["error"])
	}
	for _, leaked := range []string{"totalControls", "totalExposureGbp", "passed", "failed"} {
		if _, present := body[leaked]; present {
			t.Errorf("refusal carries %q: no count may be reported for a scan that never ran", leaked)
		}
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
		if r.Currency != defaultReportingCurrency {
			t.Fatalf("result %d (%s) has currency %q, expected %q",
				i, r.Check, r.Currency, defaultReportingCurrency)
		}
		if r.Carried.Currency != defaultReportingCurrency {
			t.Fatalf("result %d (%s) carried.currency is %q, expected %q",
				i, r.Check, r.Carried.Currency, defaultReportingCurrency)
		}
	}
}
