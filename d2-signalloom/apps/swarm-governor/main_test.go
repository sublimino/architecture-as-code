package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/swarm-governor/a2a"
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

func TestSwarmGovernor_SubmitTaskLifecycleAndEdgeCases(t *testing.T) {
	gov := NewGovernor("test-namespace", 250000)
	mux := newMux(gov)

	// 1. Submit invalid JSON -> 400 Bad Request
	req := httptest.NewRequest(http.MethodPost, "/tasks/submit", strings.NewReader("{invalid-json"))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("submit invalid JSON: want 400, got %d", rec.Code)
	}

	// 2. Submit empty description -> 400 Bad Request
	emptyDescBody, _ := json.Marshal(SubmitRequest{
		Description: "   ",
		AgentURLs:   []string{"http://127.0.0.1:9999"},
	})
	req = httptest.NewRequest(http.MethodPost, "/tasks/submit", bytes.NewReader(emptyDescBody))
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("submit empty description: want 400, got %d", rec.Code)
	}

	// 3. Submit with no agents available -> 502 Bad Gateway
	noAgentsBody, _ := json.Marshal(SubmitRequest{
		Description: "Perform security scan",
		AgentURLs:   []string{},
	})
	req = httptest.NewRequest(http.MethodPost, "/tasks/submit", bytes.NewReader(noAgentsBody))
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadGateway {
		t.Errorf("submit with no agents: want 502, got %d", rec.Code)
	}

	// 4. Mock agent server returning agent card
	agentServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/.well-known/agent-card.json" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			if r.Method == http.MethodHead {
				return
			}
			_ = json.NewEncoder(w).Encode(a2a.AgentCard{
				Name:        "cve-scanner",
				Description: "Container scanner",
				Capabilities: []a2a.Capability{
					{Name: "scan", Description: "vulnerability scanner"},
				},
			})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer agentServer.Close()

	// Submit valid task
	validBody, _ := json.Marshal(SubmitRequest{
		Description:  "Scan container image for CVEs",
		Requirements: []string{"scan"},
		AgentURLs:    []string{agentServer.URL},
	})
	req = httptest.NewRequest(http.MethodPost, "/tasks/submit", bytes.NewReader(validBody))
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("submit valid task: want 202, got %d: %s", rec.Code, rec.Body.String())
	}

	var plan DispatchPlan
	if err := json.Unmarshal(rec.Body.Bytes(), &plan); err != nil {
		t.Fatalf("unmarshal plan: %v", err)
	}
	taskID := plan.OriginalTask.ID
	if taskID == "" {
		t.Fatal("expected non-empty TaskID in plan.OriginalTask.ID")
	}

	// 5. Query task via GET /tasks/{id}
	req = httptest.NewRequest(http.MethodGet, "/tasks/"+taskID, nil)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("get task %s: want 200, got %d", taskID, rec.Code)
	}

	// 6. Query task via HEAD /tasks/{id} -> 200 OK with empty body
	req = httptest.NewRequest(http.MethodHead, "/tasks/"+taskID, nil)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /tasks/%s: want 200, got %d", taskID, rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /tasks/%s body length = %d, want 0", taskID, rec.Body.Len())
	}

	// 7. Query task with invalid method (POST) -> 405 Method Not Allowed with Allow: GET, HEAD
	req = httptest.NewRequest(http.MethodPost, "/tasks/"+taskID, nil)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /tasks/%s: want 405, got %d", taskID, rec.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("POST /tasks/%s Allow header = %q, want 'GET, HEAD'", taskID, allow)
	}
}

