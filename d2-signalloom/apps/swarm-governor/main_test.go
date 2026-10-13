package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSwarmGovernorHTTPContracts(t *testing.T) {
	gov := NewGovernor("test-namespace", 250000)
	mux := newMux(gov)

	tests := []struct {
		name          string
		method        string
		path          string
		body          string
		wantStatus    int
		wantAllow     string
		wantBodyEmpty bool
		wantSubstr    string
	}{
		// Health & Ready Probes (GET and HEAD parity)
		{
			name:          "GET /health returns 200 with status ok",
			method:        http.MethodGet,
			path:          "/health",
			wantStatus:    http.StatusOK,
			wantSubstr:    `"status":"ok"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD /health returns 200 with empty body and json content-type",
			method:        http.MethodHead,
			path:          "/health",
			wantStatus:    http.StatusOK,
			wantBodyEmpty: true,
		},
		{
			name:          "GET /healthz returns 200 with status ok",
			method:        http.MethodGet,
			path:          "/healthz",
			wantStatus:    http.StatusOK,
			wantSubstr:    `"status":"ok"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD /healthz returns 200 with empty body",
			method:        http.MethodHead,
			path:          "/healthz",
			wantStatus:    http.StatusOK,
			wantBodyEmpty: true,
		},
		{
			name:          "GET /readyz returns 200 with status ready",
			method:        http.MethodGet,
			path:          "/readyz",
			wantStatus:    http.StatusOK,
			wantSubstr:    `"status":"ready"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD /readyz returns 200 with empty body",
			method:        http.MethodHead,
			path:          "/readyz",
			wantStatus:    http.StatusOK,
			wantBodyEmpty: true,
		},
		{
			name:          "POST /health returns 405 with Allow: GET, HEAD",
			method:        http.MethodPost,
			path:          "/health",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD disallowed method on probe returns empty body",
			method:        http.MethodHead,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST",
			wantBodyEmpty: true,
		},
		// Agent Card endpoint
		{
			name:          "GET /.well-known/agent-card.json returns 200",
			method:        http.MethodGet,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusOK,
			wantSubstr:    `"name":"swarm-governor"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD /.well-known/agent-card.json returns 200 with empty body",
			method:        http.MethodHead,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusOK,
			wantBodyEmpty: true,
		},
		{
			name:          "DELETE /.well-known/agent-card.json returns 405 Allow: GET, HEAD",
			method:        http.MethodDelete,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		// Tasks endpoint
		{
			name:          "GET /tasks/missing returns 404",
			method:        http.MethodGet,
			path:          "/tasks/missing",
			wantStatus:    http.StatusNotFound,
			wantSubstr:    `"error":"task not found"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD /tasks/missing returns 404 with empty body",
			method:        http.MethodHead,
			path:          "/tasks/missing",
			wantStatus:    http.StatusNotFound,
			wantBodyEmpty: true,
		},
		{
			name:          "POST /tasks/submit rejects GET with 405 Allow: POST",
			method:        http.MethodGet,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var bodyReader io.Reader
			if tt.body != "" {
				bodyReader = strings.NewReader(tt.body)
			}
			req := httptest.NewRequest(tt.method, tt.path, bodyReader)
			rec := httptest.NewRecorder()

			mux.ServeHTTP(rec, req)

			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}

			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}

			if tt.wantAllow != "" {
				if allow := rec.Header().Get("Allow"); allow != tt.wantAllow {
					t.Errorf("Allow = %q, want %q", allow, tt.wantAllow)
				}
			}

			bodyBytes := rec.Body.Bytes()
			if tt.wantBodyEmpty && len(bodyBytes) > 0 {
				t.Errorf("expected empty body for HEAD request, got %d bytes: %q", len(bodyBytes), string(bodyBytes))
			}

			if tt.wantSubstr != "" && !strings.Contains(string(bodyBytes), tt.wantSubstr) {
				t.Errorf("expected body to contain %q, got %q", tt.wantSubstr, string(bodyBytes))
			}
		})
	}
}

func TestSwarmGovernorHeadUnmatchedRoutes(t *testing.T) {
	gov := NewGovernor("test-namespace", 250000)
	mux := newMux(gov)

	for _, path := range []string{"/unknown", "/api/v1/invalid", "/health/subpath"} {
		req := httptest.NewRequest(http.MethodHead, path, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Errorf("HEAD %s status = %d, want 404", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s body length = %d, want 0", path, rec.Body.Len())
		}
	}
}

