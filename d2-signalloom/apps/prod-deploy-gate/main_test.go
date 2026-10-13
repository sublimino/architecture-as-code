package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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

		// POST rejected
		req = httptest.NewRequest(http.MethodPost, path, nil)
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("POST probe %s: want 405, got %d", path, w.Code)
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
}
