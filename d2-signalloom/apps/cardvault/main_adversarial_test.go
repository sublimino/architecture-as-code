package main

// Adversarial tests for the cardvault service.
//
// Focus: auth bypass vectors, path handling edge cases, input validation gaps.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Auth bypass attempts.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestAuthEmptyCredentials checks that empty username/password in the request is rejected
// even if the server is configured with empty credentials (which main() prevents, but
// newMux doesn't).
func TestAuthEmptyCredentials(t *testing.T) {
	// Server with empty credentials — main() would reject this, but newMux allows it.
	srv := newTestServer("", "")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req.SetBasicAuth("", "")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// An empty Basic Auth header with empty creds SHOULD match empty server creds.
	// This is technically correct but dangerous — the real protection is in main().
	// This test documents the behavior.
	if resp.StatusCode == http.StatusOK {
		t.Log("NOTE: empty credentials on both sides grants access — main() prevents this " +
			"configuration, but newMux does not enforce non-empty credentials")
	}
}

// TestAuthTimingLeak checks whether wrong username vs wrong password produce
// distinguishable responses (a timing oracle is harder to test, but response shape is easy).
func TestAuthTimingLeak(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	// Wrong username
	req1, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req1.SetBasicAuth("wrong-user", "pass")
	resp1, err := http.DefaultClient.Do(req1)
	if err != nil {
		t.Fatal(err)
	}
	defer resp1.Body.Close()

	// Wrong password
	req2, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req2.SetBasicAuth("user", "wrong-pass")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()

	// Both should produce identical response shapes.
	if resp1.StatusCode != resp2.StatusCode {
		t.Errorf("wrong-username gave %d, wrong-password gave %d; an attacker can "+
			"distinguish between the two failure modes", resp1.StatusCode, resp2.StatusCode)
	}
}

// TestAuthWithNullByteInCredentials checks that null bytes in credentials don't cause issues.
func TestAuthWithNullByteInCredentials(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req.SetBasicAuth("user\x00admin", "pass")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("null byte in username should not grant access, got %d", resp.StatusCode)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Path handling edge cases.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestPathTraversalInCardID checks that path traversal attempts in the card ID don't cause
// unexpected behavior.
func TestPathTraversalInCardID(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	paths := []string{
		"/api/v1/cards/../../../etc/passwd",
		"/api/v1/cards/card-001/../../cards",
		"/api/v1/cards/..%2f..%2f",
		"/api/v1/cards/%00",
	}

	for _, path := range paths {
		req, _ := http.NewRequest("GET", srv.URL+path, nil)
		req.SetBasicAuth("u", "p")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Logf("Path %q: connection error (expected): %v", path, err)
			continue
		}
		resp.Body.Close()

		if resp.StatusCode == http.StatusOK {
			// Check if it returned card data or something unexpected.
			t.Logf("Path %q returned %d (should be 404 for unknown card IDs)", path, resp.StatusCode)
		}
	}
}

// TestCardIDWithSpecialCharacters checks that special characters in card IDs are handled.
func TestCardIDWithSpecialCharacters(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	specialIDs := []string{
		"card-001; DROP TABLE cards;--",
		"<script>alert(1)</script>",
		strings.Repeat("A", 10000), // Very long ID
	}

	for _, id := range specialIDs {
		req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards/"+id, nil)
		req.SetBasicAuth("u", "p")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			// Very long IDs may cause HTTP issues
			continue
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("special card ID %q should return 404, got %d",
				id[:min(len(id), 50)], resp.StatusCode)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// HTTP method enforcement.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestMethodsOnCardEndpoints checks that non-GET methods are handled reasonably.
func TestMethodsOnCardEndpoints(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	methods := []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch}
	endpoints := []string{"/api/v1/cards", "/api/v1/cards/card-001"}

	for _, method := range methods {
		for _, ep := range endpoints {
			req, _ := http.NewRequest(method, srv.URL+ep, nil)
			req.SetBasicAuth("u", "p")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("%s %s: %v", method, ep, err)
			}
			resp.Body.Close()

			// The handlers don't check methods — they respond 200 to anything.
			// This is a design choice but worth documenting.
			if resp.StatusCode == http.StatusOK {
				t.Logf("NOTE: %s %s returns 200 — no method enforcement on card endpoints", method, ep)
			}
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Response shape validation.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestCardResponseContainsNoSensitiveData ensures PAN masking is consistent.
func TestCardResponseContainsNoSensitiveData(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req.SetBasicAuth("u", "p")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var cards []Card
	json.NewDecoder(resp.Body).Decode(&cards)

	for _, c := range cards {
		// Every PAN should be masked (only last 4 visible).
		if !strings.HasPrefix(c.PANMasked, "****") {
			t.Errorf("card %s PAN %q does not appear properly masked", c.ID, c.PANMasked)
		}
		// No card should have a full PAN field.
		unmasked := strings.ReplaceAll(c.PANMasked, "*", "")
		unmasked = strings.ReplaceAll(unmasked, "-", "")
		if len(unmasked) > 4 {
			t.Errorf("card %s PAN %q exposes more than 4 digits", c.ID, c.PANMasked)
		}
	}
}

// TestLoggingResponseWriterDefaultStatus verifies the logging wrapper default.
func TestLoggingResponseWriterDefaultStatus(t *testing.T) {
	w := httptest.NewRecorder()
	lrw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}

	// Before any WriteHeader call, status should be the default.
	if lrw.status != http.StatusOK {
		t.Errorf("default status = %d, want %d", lrw.status, http.StatusOK)
	}

	// After WriteHeader, it should reflect the new status.
	lrw.WriteHeader(http.StatusNotFound)
	if lrw.status != http.StatusNotFound {
		t.Errorf("status after WriteHeader(404) = %d, want %d", lrw.status, http.StatusNotFound)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
