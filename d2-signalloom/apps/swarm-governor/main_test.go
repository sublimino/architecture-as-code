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
			name:          "POST /health returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPost,
			path:          "/health",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PUT /health returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPut,
			path:          "/health",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "DELETE /health returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodDelete,
			path:          "/health",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PATCH /health returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPatch,
			path:          "/health",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PUT /healthz returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPut,
			path:          "/healthz",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "DELETE /healthz returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodDelete,
			path:          "/healthz",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PATCH /healthz returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPatch,
			path:          "/healthz",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PUT /readyz returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPut,
			path:          "/readyz",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "DELETE /readyz returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodDelete,
			path:          "/readyz",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PATCH /readyz returns 405 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPatch,
			path:          "/readyz",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "HEAD disallowed method on probe returns empty body",
			method:        http.MethodHead,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST, OPTIONS",
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
			name:          "POST /.well-known/agent-card.json returns 405 Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPost,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PUT /.well-known/agent-card.json returns 405 Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPut,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "DELETE /.well-known/agent-card.json returns 405 Allow: GET, HEAD, OPTIONS",
			method:        http.MethodDelete,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "PATCH /.well-known/agent-card.json returns 405 Allow: GET, HEAD, OPTIONS",
			method:        http.MethodPatch,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "GET, HEAD, OPTIONS",
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
			name:          "POST /tasks/submit rejects GET with 405 Allow: POST, OPTIONS",
			method:        http.MethodGet,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "POST /tasks/submit rejects PUT with 405 Allow: POST, OPTIONS",
			method:        http.MethodPut,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "POST /tasks/submit rejects DELETE with 405 Allow: POST, OPTIONS",
			method:        http.MethodDelete,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		{
			name:          "POST /tasks/submit rejects PATCH with 405 Allow: POST, OPTIONS",
			method:        http.MethodPatch,
			path:          "/tasks/submit",
			wantStatus:    http.StatusMethodNotAllowed,
			wantAllow:     "POST, OPTIONS",
			wantSubstr:    `"error":"method not allowed"`,
			wantBodyEmpty: false,
		},
		// OPTIONS method parity
		{
			name:          "OPTIONS /health returns 204 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodOptions,
			path:          "/health",
			wantStatus:    http.StatusNoContent,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantBodyEmpty: true,
		},
		{
			name:          "OPTIONS /healthz returns 204 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodOptions,
			path:          "/healthz",
			wantStatus:    http.StatusNoContent,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantBodyEmpty: true,
		},
		{
			name:          "OPTIONS /readyz returns 204 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodOptions,
			path:          "/readyz",
			wantStatus:    http.StatusNoContent,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantBodyEmpty: true,
		},
		{
			name:          "OPTIONS /.well-known/agent-card.json returns 204 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodOptions,
			path:          "/.well-known/agent-card.json",
			wantStatus:    http.StatusNoContent,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantBodyEmpty: true,
		},
		{
			name:          "OPTIONS /tasks/submit returns 204 with Allow: POST, OPTIONS",
			method:        http.MethodOptions,
			path:          "/tasks/submit",
			wantStatus:    http.StatusNoContent,
			wantAllow:     "POST, OPTIONS",
			wantBodyEmpty: true,
		},
		{
			name:          "OPTIONS /tasks/missing returns 204 with Allow: GET, HEAD, OPTIONS",
			method:        http.MethodOptions,
			path:          "/tasks/missing",
			wantStatus:    http.StatusNoContent,
			wantAllow:     "GET, HEAD, OPTIONS",
			wantBodyEmpty: true,
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

			if rec.Code != http.StatusNoContent {
				if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
					t.Errorf("Content-Type = %q, want application/json", ct)
				}
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

	// 7. Query task with invalid methods (POST, PUT, DELETE, PATCH) -> 405 Method Not Allowed with Allow: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req = httptest.NewRequest(method, "/tasks/"+taskID, nil)
		rec = httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /tasks/%s: want 405, got %d", method, taskID, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s /tasks/%s Allow header = %q, want 'GET, HEAD, OPTIONS'", method, taskID, allow)
		}
		var errResp map[string]string
		if err := json.Unmarshal(rec.Body.Bytes(), &errResp); err != nil {
			t.Errorf("%s /tasks/%s invalid JSON error response: %v", method, taskID, err)
		}
		if errResp["error"] != "method not allowed" {
			t.Errorf("%s /tasks/%s error = %q, want 'method not allowed'", method, taskID, errResp["error"])
		}
	}

	// 8. Submit with invalid agent URLs (SSRF defense) -> 400 Bad Request
	for _, badURL := range []string{"ftp://evil.com/card", "http://", "invalid-url", "http:///no-host"} {
		badBody, _ := json.Marshal(SubmitRequest{
			Description: "Scan container image",
			AgentURLs:   []string{badURL},
		})
		req = httptest.NewRequest(http.MethodPost, "/tasks/submit", bytes.NewReader(badBody))
		rec = httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("submit invalid agent URL %q: want 400, got %d", badURL, rec.Code)
		}
	}
}

func TestSwarmGovernorWriteJSONDirectAndHEAD(t *testing.T) {
	statuses := []int{
		http.StatusOK,
		http.StatusBadRequest,
		http.StatusNotFound,
		http.StatusMethodNotAllowed,
		http.StatusInternalServerError,
	}
	payload := map[string]string{"message": "swarm-governor test payload"}

	for _, status := range statuses {
		// 1. GET writes full JSON body and sets Content-Type
		recGet := httptest.NewRecorder()
		reqGet := httptest.NewRequest(http.MethodGet, "/unit-test", nil)
		writeJSON(recGet, reqGet, status, payload)
		if recGet.Code != status {
			t.Errorf("GET writeJSON status = %d, want %d", recGet.Code, status)
		}
		if ct := recGet.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("GET writeJSON Content-Type = %q, want application/json", ct)
		}
		var got map[string]string
		if err := json.Unmarshal(recGet.Body.Bytes(), &got); err != nil {
			t.Errorf("GET writeJSON decode failed: %v", err)
		}
		if got["message"] != payload["message"] {
			t.Errorf("GET writeJSON message = %q, want %q", got["message"], payload["message"])
		}

		// 2. HEAD sets status and Content-Type but suppresses body bytes (0 bytes)
		recHead := httptest.NewRecorder()
		reqHead := httptest.NewRequest(http.MethodHead, "/unit-test", nil)
		writeJSON(recHead, reqHead, status, payload)
		if recHead.Code != status {
			t.Errorf("HEAD writeJSON status = %d, want %d", recHead.Code, status)
		}
		if ct := recHead.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD writeJSON Content-Type = %q, want application/json", ct)
		}
		if recHead.Body.Len() != 0 {
			t.Errorf("HEAD writeJSON wrote %d body bytes (%q), want 0", recHead.Body.Len(), recHead.Body.String())
		}
	}

	// 3. nil request writes body
	recNil := httptest.NewRecorder()
	writeJSON(recNil, nil, http.StatusOK, payload)
	if recNil.Code != http.StatusOK {
		t.Errorf("nil req writeJSON status = %d, want 200", recNil.Code)
	}
	if recNil.Body.Len() == 0 {
		t.Errorf("nil req writeJSON wrote empty body, want JSON payload")
	}
}

