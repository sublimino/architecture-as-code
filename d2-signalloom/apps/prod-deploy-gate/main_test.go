package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)


func TestServer_GateLifecycle(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	// 1. Create a gate request
	reqBody, _ := json.Marshal(GateRequest{
		Description: "Deploy payment service v2.4",
		Requester:   "alice@corp.internal",
		Environment: "production",
	})
	req := httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("request gate: want 202, got %d: %s", w.Code, w.Body.String())
	}

	var gateResp GateResponse
	if err := json.Unmarshal(w.Body.Bytes(), &gateResp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if gateResp.RequestID == "" || gateResp.Status != "pending" {
		t.Fatalf("unexpected gate response: %+v", gateResp)
	}

	// 2. Query gate status via GET /gate/{id}
	req = httptest.NewRequest(http.MethodGet, "/gate/"+gateResp.RequestID, nil)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("get gate: want 200, got %d: %s", w.Code, w.Body.String())
	}

	// 3. Generate token for approval
	token, err := GenerateToken(secret, gateResp.RequestID, 10*time.Minute)
	if err != nil {
		t.Fatalf("generate token: %v", err)
	}

	// 4. Reject approval with empty approver
	emptyApproverBody, _ := json.Marshal(ApproveRequest{
		Token:    token,
		Approver: "   ",
	})
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader(emptyApproverBody))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("approve empty approver: want 400, got %d", w.Code)
	}

	// 5. Approve with valid approver
	validApproveBody, _ := json.Marshal(ApproveRequest{
		Token:    token,
		Approver: "bob@corp.internal",
	})
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader(validApproveBody))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("approve gate: want 200, got %d: %s", w.Code, w.Body.String())
	}

	var approveResp ApproveResponse
	_ = json.Unmarshal(w.Body.Bytes(), &approveResp)
	if approveResp.Status != "approved" || approveResp.Approver != "bob@corp.internal" {
		t.Errorf("unexpected approve response: %+v", approveResp)
	}

	// 6. Gate should no longer be pending
	req = httptest.NewRequest(http.MethodGet, "/gate/"+gateResp.RequestID, nil)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("get resolved gate: want 404, got %d", w.Code)
	}
}

func TestServer_PruneExpired(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 5*time.Millisecond)

	// Create gate that expires in 5ms
	reqBody, _ := json.Marshal(GateRequest{
		Description: "Short-lived deploy",
		Requester:   "charlie@corp.internal",
	})
	req := httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody))
	w := httptest.NewRecorder()
	mux := http.NewServeMux()
	srv.registerRoutes(mux)
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("request gate: want 202, got %d", w.Code)
	}

	time.Sleep(10 * time.Millisecond)

	pruned := srv.PruneExpired(time.Now())
	if pruned != 1 {
		t.Errorf("PruneExpired: want 1, got %d", pruned)
	}
}

func TestServer_HealthEndpoints(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		// GET
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("GET probe %s: want 200, got %d", path, w.Code)
		}

		// HEAD
		req = httptest.NewRequest(http.MethodHead, path, nil)
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("HEAD probe %s: want 200, got %d", path, w.Code)
		}
		if w.Body.Len() != 0 {
			t.Errorf("HEAD probe %s: want empty body, got %d bytes", path, w.Body.Len())
		}
		if ct := w.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD probe %s: want Content-Type application/json, got %q", path, ct)
		}

		// Disallowed methods rejected
		for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req = httptest.NewRequest(m, path, nil)
			w = httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s probe %s: want 405, got %d", m, path, w.Code)
			}
			if w.Header().Get("Allow") != "GET, HEAD" {
				t.Errorf("%s probe %s: want Allow: GET, HEAD, got %q", m, path, w.Header().Get("Allow"))
			}
			if w.Body.Len() == 0 {
				t.Errorf("%s probe %s: want non-empty error body", m, path)
			}
		}
	}
}

func TestServer_MethodGates(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := newMux(srv)

	for _, path := range []string{"/gate/request", "/gate/approve"} {
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req := httptest.NewRequest(method, path, nil)
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s: want 405, got %d", method, path, w.Code)
			}
			if w.Header().Get("Allow") != "POST" {
				t.Errorf("%s %s: want Allow: POST, got %q", method, path, w.Header().Get("Allow"))
			}
			if method == http.MethodHead && w.Body.Len() != 0 {
				t.Errorf("HEAD %s: want empty body, got %d bytes: %s", path, w.Body.Len(), w.Body.String())
			}
		}
	}

	// Read routes (/gate/ and /gate/{id}) reject mutating verbs with 405 and Allow: GET, HEAD
	for _, path := range []string{"/gate/", "/gate/gate-000001"} {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req := httptest.NewRequest(method, path, nil)
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s: want 405, got %d", method, path, w.Code)
			}
			if w.Header().Get("Allow") != "GET, HEAD" {
				t.Errorf("%s %s: want Allow: GET, HEAD, got %q", method, path, w.Header().Get("Allow"))
			}
			if w.Body.Len() == 0 {
				t.Errorf("%s %s: want non-empty error body on %s", method, path, method)
			}
		}
	}
}


func TestServer_GetGateHeadMethod(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	// Create gate request
	reqBody, _ := json.Marshal(GateRequest{
		Description: "Deploy v2",
		Requester:   "ops@test.local",
	})
	req := httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("request gate: want 202, got %d", w.Code)
	}
	var gateResp GateResponse
	_ = json.Unmarshal(w.Body.Bytes(), &gateResp)

	// HEAD on gate
	req = httptest.NewRequest(http.MethodHead, "/gate/"+gateResp.RequestID, nil)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("HEAD /gate/%s: want 200, got %d", gateResp.RequestID, w.Code)
	}
	if w.Body.Len() != 0 {
		t.Errorf("HEAD /gate/%s: want empty body, got %d bytes", gateResp.RequestID, w.Body.Len())
	}

	// POST rejected on /gate/{id}
	req = httptest.NewRequest(http.MethodPost, "/gate/"+gateResp.RequestID, nil)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /gate/%s: want 405, got %d", gateResp.RequestID, w.Code)
	}
}

func TestServer_RequesterValidation(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	for _, invalidRequester := range []string{"", "   ", "\t\n"} {
		reqBody, _ := json.Marshal(GateRequest{
			Description: "Deploy payment service v2.4",
			Requester:   invalidRequester,
			Environment: "production",
		})
		req := httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusBadRequest {
			t.Errorf("empty requester %q: want 400, got %d", invalidRequester, w.Code)
		}
	}

	// Requester exceeding 256 characters
	longReq := strings.Repeat("a", 257)
	reqBody, _ := json.Marshal(GateRequest{
		Description: "Deploy payment service",
		Requester:   longReq,
	})
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody)))
	if w.Code != http.StatusBadRequest {
		t.Errorf("long requester: want 400, got %d", w.Code)
	}

	// Description exceeding 4096 characters
	longDesc := strings.Repeat("d", 4097)
	reqBody, _ = json.Marshal(GateRequest{
		Description: longDesc,
		Requester:   "alice@corp.internal",
	})
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody)))
	if w.Code != http.StatusBadRequest {
		t.Errorf("long description: want 400, got %d", w.Code)
	}

	// Environment exceeding 64 characters
	longEnv := strings.Repeat("e", 65)
	reqBody, _ = json.Marshal(GateRequest{
		Description: "Deploy payment service",
		Requester:   "alice@corp.internal",
		Environment: longEnv,
	})
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody)))
	if w.Code != http.StatusBadRequest {
		t.Errorf("long environment: want 400, got %d", w.Code)
	}

	// Invalid request ID in get gate
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/gate/"+strings.Repeat("x", 129), nil))
	if w.Code != http.StatusBadRequest {
		t.Errorf("long request ID: want 400, got %d", w.Code)
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/gate/foo/bar", nil))
	if w.Code != http.StatusBadRequest {
		t.Errorf("slash in request ID: want 400, got %d", w.Code)
	}
}


func TestProdDeployGateHeadUnmatchedRoutes(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := newMux(srv)

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

func TestServer_ApproveValidationEdgeCases(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := newMux(srv)

	// Valid gate first
	reqBody, _ := json.Marshal(GateRequest{
		Description: "Deploy v3",
		Requester:   "ops@test.local",
	})
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader(reqBody)))
	if w.Code != http.StatusAccepted {
		t.Fatalf("request gate: want 202, got %d", w.Code)
	}
	var gateResp GateResponse
	_ = json.Unmarshal(w.Body.Bytes(), &gateResp)

	// 1. Malformed JSON
	req := httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader([]byte(`{bad-json`)))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("approve malformed JSON: want 400, got %d", w.Code)
	}

	// 2. Missing token
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader([]byte(`{"approver":"alice"}`)))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("approve missing token: want 400, got %d", w.Code)
	}

	// 3. Missing approver
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader([]byte(`{"token":"some-token"}`)))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("approve missing approver: want 400, got %d", w.Code)
	}

	// 4. Invalid token HMAC
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader([]byte(`{"token":"gate-999.12345.tamperedhmac","approver":"alice"}`)))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("approve tampered token: want 403, got %d", w.Code)
	}

	// 5. Valid token for nonexistent gate
	validTokenNonexistent, _ := GenerateToken(secret, "gate-999999", 10*time.Minute)
	approveNonexistent, _ := json.Marshal(ApproveRequest{
		Token:    validTokenNonexistent,
		Approver: "alice",
	})
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader(approveNonexistent))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("approve nonexistent gate: want 404, got %d", w.Code)
	}

	// 6. Request with malformed JSON
	req = httptest.NewRequest(http.MethodPost, "/gate/request", bytes.NewReader([]byte(`{bad-json`)))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("request malformed JSON: want 400, got %d", w.Code)
	}

	// 7. Approver exceeding 256 characters
	longApprover, _ := json.Marshal(ApproveRequest{
		Token:    srv.pending[gateResp.RequestID].Token,
		Approver: strings.Repeat("b", 257),
	})
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader(longApprover))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("long approver: want 400, got %d", w.Code)
	}

	// 8. Token exceeding 2048 characters
	longToken, _ := json.Marshal(ApproveRequest{
		Token:    strings.Repeat("t", 2049),
		Approver: "bob@corp.internal",
	})
	req = httptest.NewRequest(http.MethodPost, "/gate/approve", bytes.NewReader(longToken))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("long token: want 400, got %d", w.Code)
	}
}

func TestServer_OptionsMethodHandling(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := newMux(srv)

	tests := []struct {
		path      string
		wantAllow string
	}{
		{"/gate/request", "POST"},
		{"/gate/approve", "POST"},
		{"/gate/", "GET, HEAD"},
		{"/gate/gate-000001", "GET, HEAD"},
		{"/healthz", "GET, HEAD"},
		{"/readyz", "GET, HEAD"},
		{"/health", "GET, HEAD"},
	}

	for _, tt := range tests {
		req := httptest.NewRequest(http.MethodOptions, tt.path, nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)

		if w.Code != http.StatusNoContent {
			t.Errorf("OPTIONS %s: status = %d, want 204", tt.path, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != tt.wantAllow {
			t.Errorf("OPTIONS %s: Allow = %q, want %q", tt.path, allow, tt.wantAllow)
		}
		if w.Body.Len() != 0 {
			t.Errorf("OPTIONS %s: body len = %d, want 0", tt.path, w.Body.Len())
		}
	}
}


func TestServer_GateHeadErrorBodySuppression(t *testing.T) {
	secret := []byte("secret-key-32-bytes-long-here!!")
	srv := NewServer(secret, "", 10*time.Minute)
	mux := newMux(srv)

	tests := []struct {
		name       string
		path       string
		wantStatus int
	}{
		{"HEAD gate root missing ID returns 400", "/gate/", http.StatusBadRequest},
		{"HEAD nonexistent gate returns 404", "/gate/gate-999999", http.StatusNotFound},
		{"HEAD request endpoint returns 405", "/gate/request", http.StatusMethodNotAllowed},
		{"HEAD approve endpoint returns 405", "/gate/approve", http.StatusMethodNotAllowed},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodHead, tt.path, nil)
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Errorf("%s: status = %d, want %d", tt.name, w.Code, tt.wantStatus)
			}
			if w.Body.Len() != 0 {
				t.Errorf("%s: body len = %d, want 0", tt.name, w.Body.Len())
			}
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("%s: Content-Type = %q, want application/json", tt.name, ct)
			}
		})
	}
}

func TestWriteJSON_HEADBodySuppressionAcrossStatuses(t *testing.T) {
	statuses := []struct {
		code int
		name string
	}{
		{http.StatusOK, "OK"},
		{http.StatusCreated, "Created"},
		{http.StatusAccepted, "Accepted"},
		{http.StatusBadRequest, "Bad_Request"},
		{http.StatusUnauthorized, "Unauthorized"},
		{http.StatusForbidden, "Forbidden"},
		{http.StatusNotFound, "Not_Found"},
		{http.StatusMethodNotAllowed, "Method_Not_Allowed"},
		{http.StatusInternalServerError, "Internal_Server_Error"},
		{http.StatusBadGateway, "Bad_Gateway"},
		{http.StatusServiceUnavailable, "Service_Unavailable"},
	}

	for _, s := range statuses {
		t.Run(s.name, func(t *testing.T) {
			// HEAD must suppress body
			reqHead := httptest.NewRequest(http.MethodHead, "/test", nil)
			wHead := httptest.NewRecorder()
			writeJSON(wHead, reqHead, s.code, map[string]string{"status": s.name})

			if wHead.Code != s.code {
				t.Errorf("HEAD status = %d, want %d", wHead.Code, s.code)
			}
			if wHead.Body.Len() != 0 {
				t.Errorf("HEAD body length = %d, want 0", wHead.Body.Len())
			}
			if ct := wHead.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("HEAD Content-Type = %q, want application/json", ct)
			}

			// GET must preserve body
			reqGet := httptest.NewRequest(http.MethodGet, "/test", nil)
			wGet := httptest.NewRecorder()
			writeJSON(wGet, reqGet, s.code, map[string]string{"status": s.name})

			if wGet.Code != s.code {
				t.Errorf("GET status = %d, want %d", wGet.Code, s.code)
			}
			if wGet.Body.Len() == 0 {
				t.Errorf("GET body length is 0, want non-empty")
			}
		})
	}
}


