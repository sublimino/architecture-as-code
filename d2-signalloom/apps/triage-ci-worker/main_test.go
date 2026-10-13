package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthAndProbeEndpoints(t *testing.T) {
	mux := newMux()

	for _, endpoint := range []string{"/health", "/healthz", "/readyz"} {
		// GET
		req := httptest.NewRequest(http.MethodGet, endpoint, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s expected 200, got %d", endpoint, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("GET %s expected Content-Type text/plain; charset=utf-8, got %q", endpoint, ct)
		}
		if !strings.Contains(rec.Body.String(), "ok") {
			t.Fatalf("GET %s expected body containing ok, got %s", endpoint, rec.Body.String())
		}

		// HEAD
		reqHead := httptest.NewRequest(http.MethodHead, endpoint, nil)
		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, reqHead)

		if recHead.Code != http.StatusOK {
			t.Fatalf("HEAD %s expected 200, got %d", endpoint, recHead.Code)
		}
		if ct := recHead.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("HEAD %s expected Content-Type text/plain; charset=utf-8, got %q", endpoint, ct)
		}
		if recHead.Body.Len() != 0 {
			t.Fatalf("HEAD %s expected empty body, got %q", endpoint, recHead.Body.String())
		}

		// Disallowed methods -> 405
		for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			reqPost := httptest.NewRequest(m, endpoint, nil)
			recPost := httptest.NewRecorder()
			mux.ServeHTTP(recPost, reqPost)

			if recPost.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s expected 405 Method Not Allowed, got %d", m, endpoint, recPost.Code)
			}
			if recPost.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
				t.Fatalf("%s %s expected Allow: GET, HEAD, OPTIONS, got %q", m, endpoint, recPost.Header().Get("Allow"))
			}
			if recPost.Body.Len() == 0 {
				t.Fatalf("%s %s expected non-empty error body", m, endpoint)
			}
		}

		// OPTIONS -> 204 with Allow: GET, HEAD, OPTIONS and empty body
		reqOpts := httptest.NewRequest(http.MethodOptions, endpoint, nil)
		recOpts := httptest.NewRecorder()
		mux.ServeHTTP(recOpts, reqOpts)
		if recOpts.Code != http.StatusNoContent {
			t.Fatalf("OPTIONS %s expected 204, got %d", endpoint, recOpts.Code)
		}
		if recOpts.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
			t.Fatalf("OPTIONS %s expected Allow: GET, HEAD, OPTIONS, got %q", endpoint, recOpts.Header().Get("Allow"))
		}
		if recOpts.Body.Len() != 0 {
			t.Fatalf("OPTIONS %s expected empty body, got %q", endpoint, recOpts.Body.String())
		}
	}
}

func TestUnmatchedPathsReturn404(t *testing.T) {
	mux := newMux()

	unmatched := []string{
		"/unknown",
		"/api/v1/check",
		"/health/subpath",
		"/gate/request",
	}

	for _, path := range unmatched {
		// GET
		reqGet := httptest.NewRequest(http.MethodGet, path, nil)
		recGet := httptest.NewRecorder()
		mux.ServeHTTP(recGet, reqGet)

		if recGet.Code != http.StatusNotFound {
			t.Errorf("GET %s expected 404, got %d", path, recGet.Code)
		}

		// POST
		reqPost := httptest.NewRequest(http.MethodPost, path, bytes.NewReader([]byte(`{"test":true}`)))
		recPost := httptest.NewRecorder()
		mux.ServeHTTP(recPost, reqPost)

		if recPost.Code != http.StatusNotFound {
			t.Errorf("POST %s expected 404, got %d", path, recPost.Code)
		}

		// HEAD
		reqHead := httptest.NewRequest(http.MethodHead, path, nil)
		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, reqHead)

		if recHead.Code != http.StatusNotFound {
			t.Errorf("HEAD %s expected 404, got %d", path, recHead.Code)
		}
		if recHead.Body.Len() != 0 {
			t.Errorf("HEAD %s expected empty body, got %q", path, recHead.Body.String())
		}
	}
}

func TestRootMethodNotAllowed(t *testing.T) {
	mux := newMux()

	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/", nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s / expected 405 Method Not Allowed, got %d", m, rec.Code)
		}
		if rec.Header().Get("Allow") != "POST, OPTIONS" {
			t.Fatalf("%s / expected Allow: POST, OPTIONS, got %q", m, rec.Header().Get("Allow"))
		}
		if rec.Body.Len() == 0 {
			t.Fatalf("%s / expected non-empty error body", m)
		}
	}

	// HEAD -> 405 with Allow: POST, OPTIONS and empty body
	reqHead := httptest.NewRequest(http.MethodHead, "/", nil)
	recHead := httptest.NewRecorder()
	mux.ServeHTTP(recHead, reqHead)
	if recHead.Code != http.StatusMethodNotAllowed {
		t.Fatalf("HEAD / expected 405 Method Not Allowed, got %d", recHead.Code)
	}
	if recHead.Header().Get("Allow") != "POST, OPTIONS" {
		t.Fatalf("HEAD / expected Allow: POST, OPTIONS, got %q", recHead.Header().Get("Allow"))
	}
	if recHead.Body.Len() != 0 {
		t.Fatalf("HEAD / expected empty body, got %q", recHead.Body.String())
	}

	// OPTIONS -> 204 with Allow: POST, OPTIONS and empty body
	reqOpts := httptest.NewRequest(http.MethodOptions, "/", nil)
	recOpts := httptest.NewRecorder()
	mux.ServeHTTP(recOpts, reqOpts)
	if recOpts.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS / expected 204, got %d", recOpts.Code)
	}
	if recOpts.Header().Get("Allow") != "POST, OPTIONS" {
		t.Fatalf("OPTIONS / expected Allow: POST, OPTIONS, got %q", recOpts.Header().Get("Allow"))
	}
	if recOpts.Body.Len() != 0 {
		t.Fatalf("OPTIONS / expected empty body, got %q", recOpts.Body.String())
	}
}

func TestRootCloudEventFiltering(t *testing.T) {
	mux := newMux()

	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Ce-Type", "unrelated.event.type")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 No Content for unhandled Ce-Type, got %d", rec.Code)
	}
}

func TestRootInvalidJSON(t *testing.T) {
	mux := newMux()

	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(`{invalid-json`)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request, got %d", rec.Code)
	}
}

func TestRootNonFailureSkipped(t *testing.T) {
	mux := newMux()

	body := `{"check_run":{"id":123,"conclusion":"success"}}`
	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 No Content for non-failure check run, got %d", rec.Code)
	}
}

func TestRootSuccessfulTriage(t *testing.T) {
	mux := newMux()

	body := `{
		"action": "completed",
		"check_run": {
			"name": "unit-tests",
			"status": "completed",
			"conclusion": "failure",
			"output": {
				"title": "Build Failed",
				"summary": "Tests failed",
				"text": "--- FAIL: TestPaymentGateway (0.04s)\n    gateway_test.go:25: connection refused\n--- FAIL: TestFlaky (0.01s)\n"
			}
		}
	}`

	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK for successful triage, got %d: %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}

	var resp triageResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode triage response: %v", err)
	}

	if resp.RealFailures != 1 {
		t.Errorf("expected 1 real failure, got %d", resp.RealFailures)
	}
	if resp.FlakyFailures != 1 {
		t.Errorf("expected 1 flaky failure, got %d", resp.FlakyFailures)
	}
	if len(resp.Labels) == 0 {
		t.Errorf("expected at least one suggested label, got none")
	}
}

func TestMethodNotAllowed_DirectInvocationAndHEAD(t *testing.T) {
	// 1. GET with methodNotAllowed -> 405 with body and Allow header
	recGet := httptest.NewRecorder()
	reqGet := httptest.NewRequest(http.MethodGet, "/test", nil)
	methodNotAllowed(recGet, reqGet, "POST, PUT")

	if recGet.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET methodNotAllowed code = %d, want 405", recGet.Code)
	}
	if allow := recGet.Header().Get("Allow"); allow != "POST, PUT" {
		t.Errorf("GET methodNotAllowed Allow = %q, want POST, PUT", allow)
	}
	if recGet.Body.Len() == 0 {
		t.Errorf("GET methodNotAllowed body is empty, want non-empty")
	}

	// 2. HEAD with methodNotAllowed -> 405 with 0 body bytes and Allow header
	recHead := httptest.NewRecorder()
	reqHead := httptest.NewRequest(http.MethodHead, "/test", nil)
	methodNotAllowed(recHead, reqHead, "POST, PUT")

	if recHead.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD methodNotAllowed code = %d, want 405", recHead.Code)
	}
	if allow := recHead.Header().Get("Allow"); allow != "POST, PUT" {
		t.Errorf("HEAD methodNotAllowed Allow = %q, want POST, PUT", allow)
	}
	if recHead.Body.Len() != 0 {
		t.Errorf("HEAD methodNotAllowed body len = %d, want 0: %q", recHead.Body.Len(), recHead.Body.String())
	}
}

func TestOptionsEndpointsAndFlagInjectionDefense(t *testing.T) {
	mux := newMux()

	// 1. Root OPTIONS
	reqOptRoot := httptest.NewRequest(http.MethodOptions, "/", nil)
	recOptRoot := httptest.NewRecorder()
	mux.ServeHTTP(recOptRoot, reqOptRoot)

	if recOptRoot.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS / expected 204 No Content, got %d", recOptRoot.Code)
	}
	if allow := recOptRoot.Header().Get("Allow"); allow != "POST, OPTIONS" {
		t.Fatalf("OPTIONS / expected Allow: POST, OPTIONS, got %q", allow)
	}
	if recOptRoot.Body.Len() != 0 {
		t.Fatalf("OPTIONS / expected empty body, got %q", recOptRoot.Body.String())
	}

	// 2. Probe endpoints OPTIONS
	for _, endpoint := range []string{"/health", "/healthz", "/readyz"} {
		reqOpt := httptest.NewRequest(http.MethodOptions, endpoint, nil)
		recOpt := httptest.NewRecorder()
		mux.ServeHTTP(recOpt, reqOpt)

		if recOpt.Code != http.StatusNoContent {
			t.Fatalf("OPTIONS %s expected 204 No Content, got %d", endpoint, recOpt.Code)
		}
		if allow := recOpt.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Fatalf("OPTIONS %s expected Allow: GET, HEAD, OPTIONS, got %q", endpoint, allow)
		}
		if recOpt.Body.Len() != 0 {
			t.Fatalf("OPTIONS %s expected empty body, got %q", endpoint, recOpt.Body.String())
		}
	}

	// 3. Flag injection & validation in postGitHubComment
	// Non-positive PR numbers
	for _, badPR := range []int{0, -1, -99} {
		if postGitHubComment("owner/repo", badPR, "comment", []string{"label"}) {
			t.Errorf("expected postGitHubComment to return false for non-positive PR %d", badPR)
		}
	}

	// Invalid repos
	badRepos := []string{
		"--repo",
		"-R",
		"-owner/repo",
		"owner/-repo",
		"owner",
		"owner/repo/extra",
		"owner/repo;rm -rf /",
		"owner repo",
		"",
	}
	for _, br := range badRepos {
		if isValidRepo(br) {
			t.Errorf("expected isValidRepo(%q) to be false", br)
		}
		if postGitHubComment(br, 42, "comment", []string{"label"}) {
			t.Errorf("expected postGitHubComment to return false for bad repo %q", br)
		}
	}

	// Valid repos
	goodRepos := []string{
		"controlplaneio/osramp-demo",
		"foo-bar/baz.qux",
		"owner_123/repo_456",
	}
	for _, gr := range goodRepos {
		if !isValidRepo(gr) {
			t.Errorf("expected isValidRepo(%q) to be true", gr)
		}
	}

	// Label sanitization
	dirtyLabels := []string{"--injected-flag", "-f", "  valid-label  ", "triage:flaky", "invalid,comma", "safe_123"}
	cleaned := sanitizeLabels(dirtyLabels)
	expectedClean := []string{"valid-label", "triage:flaky", "safe_123"}
	if len(cleaned) != len(expectedClean) {
		t.Fatalf("expected %d sanitized labels, got %d: %v", len(expectedClean), len(cleaned), cleaned)
	}
	for i, l := range cleaned {
		if l != expectedClean[i] {
			t.Errorf("label %d: expected %q, got %q", i, expectedClean[i], l)
		}
	}
}
