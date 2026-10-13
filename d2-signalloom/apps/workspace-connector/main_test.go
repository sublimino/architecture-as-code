package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/client"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/stun"
)

func TestServer_Routes(t *testing.T) {
	srv := &Server{
		client:    client.NewMockReportsClient(),
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: "http://localhost:8090/api/v1/observations",
	}

	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	// Test health, healthz, readyz with GET and HEAD
	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("%s GET: want 200, got %d", path, w.Code)
		}

		headReq := httptest.NewRequest(http.MethodHead, path, nil)
		headW := httptest.NewRecorder()
		mux.ServeHTTP(headW, headReq)
		if headW.Code != http.StatusOK {
			t.Errorf("%s HEAD: want 200, got %d", path, headW.Code)
		}
		if headW.Body.Len() != 0 {
			t.Errorf("%s HEAD: expected 0 body bytes, got %d", path, headW.Body.Len())
		}

		// Method rejection on probes (POST, PUT, DELETE, PATCH) -> 405 with Allow: GET, HEAD
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			mReq := httptest.NewRequest(method, path, nil)
			mW := httptest.NewRecorder()
			mux.ServeHTTP(mW, mReq)
			if mW.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s: want 405, got %d", method, path, mW.Code)
			}
			if allow := mW.Header().Get("Allow"); allow != "GET, HEAD" {
				t.Errorf("%s %s Allow: want 'GET, HEAD', got %q", method, path, allow)
			}
			if mW.Body.Len() == 0 {
				t.Errorf("%s %s: expected non-empty error body", method, path)
			}
		}
	}

	// Test status GET and HEAD
	req := httptest.NewRequest(http.MethodGet, "/api/v1/workspace/status", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("status: want 200, got %d", w.Code)
	}

	headStatusReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/status", nil)
	headStatusW := httptest.NewRecorder()
	mux.ServeHTTP(headStatusW, headStatusReq)
	if headStatusW.Code != http.StatusOK {
		t.Errorf("status HEAD: want 200, got %d", headStatusW.Code)
	}
	if headStatusW.Body.Len() != 0 {
		t.Errorf("status HEAD: expected 0 body bytes, got %d", headStatusW.Body.Len())
	}

	// Method rejection on status (POST, PUT, DELETE, PATCH) -> 405 with Allow: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		mReq := httptest.NewRequest(method, "/api/v1/workspace/status", nil)
		mW := httptest.NewRecorder()
		mux.ServeHTTP(mW, mReq)
		if mW.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /api/v1/workspace/status: want 405, got %d", method, mW.Code)
		}
		if allow := mW.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Errorf("%s /api/v1/workspace/status Allow: want 'GET, HEAD', got %q", method, allow)
		}
		if mW.Body.Len() == 0 {
			t.Errorf("%s /api/v1/workspace/status: expected non-empty error body", method)
		}
	}

	// Test stun cascade
	stunPayload, _ := json.Marshal(stun.StunRequest{
		AgentID:             "spiffe://osramp.local/ns/agents/sa/rogue-agent",
		ServiceAccountEmail: "agent-rogue@corp.internal",
		Reason:              "External OAuth token grant detected",
		RequestedAt:         time.Now().UTC(),
	})
	req = httptest.NewRequest(http.MethodPost, "/api/v1/workspace/stun", bytes.NewReader(stunPayload))
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("stun: want 200, got %d", w.Code)
	}

	var res stun.StunResult
	_ = json.Unmarshal(w.Body.Bytes(), &res)
	if res.Status != "STUNNED" || !res.ServiceAccountDisabled {
		t.Errorf("stun result unexpected: %+v", res)
	}
}

func TestServer_PollAndIngest_ErrorOn500(t *testing.T) {
	fakeIngest := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"internal ingest failure"}`))
	})))
	defer fakeIngest.Close()

	srv := &Server{
		client:    client.NewMockReportsClient(),
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: fakeIngest.URL,
	}

	_, err := srv.pollAndIngest(t.Context())
	if err == nil {
		t.Fatal("expected error on ingest 500, got nil")
	}
}

func TestServer_ConcurrentAccess(t *testing.T) {
	fakeIngest := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
	})))
	defer fakeIngest.Close()

	srv := &Server{
		client:    client.NewMockReportsClient(),
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: fakeIngest.URL,
	}

	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	done := make(chan struct{})
	for i := 0; i < 5; i++ {
		go func() {
			for {
				select {
				case <-done:
					return
				default:
					req := httptest.NewRequest(http.MethodGet, "/api/v1/workspace/status", nil)
					w := httptest.NewRecorder()
					mux.ServeHTTP(w, req)
				}
			}
		}()
	}

	for i := 0; i < 10; i++ {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/workspace/poll", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("poll: want 200, got %d", w.Code)
		}
	}
	close(done)
}

func TestHeadErrorBodySuppression(t *testing.T) {
	srv := &Server{
		client:    client.NewMockReportsClient(),
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: "http://localhost:8090/api/v1/observations",
	}

	handler := srv.routes()

	// 1. Mux-level: POST routes reject HEAD with 405 Method Not Allowed and 0 body bytes
	for _, path := range []string{"/api/v1/workspace/poll", "/api/v1/workspace/stun"} {
		req := httptest.NewRequest(http.MethodHead, path, nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("HEAD %s: want 405, got %d", path, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != "POST" {
			t.Errorf("HEAD %s Allow: want 'POST', got %q", path, allow)
		}
		if w.Body.Len() != 0 {
			t.Errorf("HEAD %s: expected 0 body bytes, got %d: %q", path, w.Body.Len(), w.Body.String())
		}

		// Disallowed methods (GET, PUT, DELETE, PATCH) return 405 with Allow: POST and non-empty body
		for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			mReq := httptest.NewRequest(method, path, nil)
			mW := httptest.NewRecorder()
			handler.ServeHTTP(mW, mReq)
			if mW.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s: want 405, got %d", method, path, mW.Code)
			}
			if allow := mW.Header().Get("Allow"); allow != "POST" {
				t.Errorf("%s %s Allow: want 'POST', got %q", method, path, allow)
			}
			if mW.Body.Len() == 0 {
				t.Errorf("%s %s: expected non-empty error body", method, path)
			}
		}
	}

	// 2. Direct handler invocation with HEAD on handleStun returns 405 with Allow: POST and 0 body bytes
	badReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/stun", bytes.NewBufferString(`{bad-json`))
	w := httptest.NewRecorder()
	srv.handleStun(w, badReq)
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("handleStun HEAD: want 405, got %d", w.Code)
	}
	if allow := w.Header().Get("Allow"); allow != "POST" {
		t.Errorf("handleStun HEAD Allow: want 'POST', got %q", allow)
	}
	if w.Body.Len() != 0 {
		t.Errorf("handleStun HEAD: expected 0 body bytes, got %d: %q", w.Body.Len(), w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("handleStun HEAD: want Content-Type application/json, got %q", ct)
	}

	// 3. Direct handler invocation with HEAD on handlePoll returns 405 with Allow: POST and 0 body bytes
	pollReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/poll", nil)
	pollW := httptest.NewRecorder()
	srv.handlePoll(pollW, pollReq)
	if pollW.Code != http.StatusMethodNotAllowed {
		t.Errorf("handlePoll HEAD: want 405, got %d", pollW.Code)
	}
	if allow := pollW.Header().Get("Allow"); allow != "POST" {
		t.Errorf("handlePoll HEAD Allow: want 'POST', got %q", allow)
	}
	if pollW.Body.Len() != 0 {
		t.Errorf("handlePoll HEAD: expected 0 body bytes, got %d: %q", pollW.Body.Len(), pollW.Body.String())
	}
	if ct := pollW.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("handlePoll HEAD: want Content-Type application/json, got %q", ct)
	}
}

func TestWorkspaceIngestMockServerMethodGatingAndHEAD(t *testing.T) {
	fakeIngest := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"received":1}`))
	})))
	defer fakeIngest.Close()

	client := fakeIngest.Client()

	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, err := http.NewRequest(method, fakeIngest.URL, nil)
		if err != nil {
			t.Fatalf("NewRequest(%s): %v", method, err)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Do(%s): %v", method, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s status = %d, want 405", method, resp.StatusCode)
		}
		if allow := resp.Header.Get("Allow"); allow != "POST" {
			t.Errorf("%s Allow = %q, want POST", method, allow)
		}
	}

	headReq, err := http.NewRequest(http.MethodHead, fakeIngest.URL, nil)
	if err != nil {
		t.Fatalf("NewRequest(HEAD): %v", err)
	}
	headResp, err := client.Do(headReq)
	if err != nil {
		t.Fatalf("Do(HEAD): %v", err)
	}
	body, _ := io.ReadAll(headResp.Body)
	headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD status = %d, want 405", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("HEAD Allow = %q, want POST", allow)
	}
	if len(body) != 0 {
		t.Errorf("HEAD body length = %d, want 0", len(body))
	}
}

func TestDirectHandlerMethodRejectionAndHead(t *testing.T) {
	srv := &Server{
		client:    client.NewMockReportsClient(),
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: "http://localhost:8090/api/v1/observations",
	}

	// 1. Direct handlePoll with disallowed methods (GET, PUT, DELETE, PATCH)
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/api/v1/workspace/poll", nil)
		w := httptest.NewRecorder()
		srv.handlePoll(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("direct handlePoll %s: want 405, got %d", m, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != "POST" {
			t.Errorf("direct handlePoll %s Allow: want 'POST', got %q", m, allow)
		}
		if w.Body.Len() == 0 {
			t.Errorf("direct handlePoll %s: expected non-empty error body", m)
		}
	}

	// Direct handlePoll with HEAD returns 405 with 0 body bytes and Allow: POST
	headPollReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/poll", nil)
	headPollW := httptest.NewRecorder()
	srv.handlePoll(headPollW, headPollReq)
	if headPollW.Code != http.StatusMethodNotAllowed {
		t.Errorf("direct handlePoll HEAD: want 405, got %d", headPollW.Code)
	}
	if allow := headPollW.Header().Get("Allow"); allow != "POST" {
		t.Errorf("direct handlePoll HEAD Allow: want 'POST', got %q", allow)
	}
	if headPollW.Body.Len() != 0 {
		t.Errorf("direct handlePoll HEAD: expected 0 body bytes, got %d", headPollW.Body.Len())
	}

	// 2. Direct handleStun with disallowed methods (GET, PUT, DELETE, PATCH)
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/api/v1/workspace/stun", nil)
		w := httptest.NewRecorder()
		srv.handleStun(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("direct handleStun %s: want 405, got %d", m, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != "POST" {
			t.Errorf("direct handleStun %s Allow: want 'POST', got %q", m, allow)
		}
		if w.Body.Len() == 0 {
			t.Errorf("direct handleStun %s: expected non-empty error body", m)
		}
	}

	// Direct handleStun with HEAD returns 405 with 0 body bytes and Allow: POST
	headStunReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/stun", nil)
	headStunW := httptest.NewRecorder()
	srv.handleStun(headStunW, headStunReq)
	if headStunW.Code != http.StatusMethodNotAllowed {
		t.Errorf("direct handleStun HEAD: want 405, got %d", headStunW.Code)
	}
	if allow := headStunW.Header().Get("Allow"); allow != "POST" {
		t.Errorf("direct handleStun HEAD Allow: want 'POST', got %q", allow)
	}
	if headStunW.Body.Len() != 0 {
		t.Errorf("direct handleStun HEAD: expected 0 body bytes, got %d", headStunW.Body.Len())
	}

	// 3. Direct handleStatus with disallowed methods (POST, PUT, DELETE, PATCH)
	for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/api/v1/workspace/status", nil)
		w := httptest.NewRecorder()
		srv.handleStatus(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("direct handleStatus %s: want 405, got %d", m, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Errorf("direct handleStatus %s Allow: want 'GET, HEAD', got %q", m, allow)
		}
		if w.Body.Len() == 0 {
			t.Errorf("direct handleStatus %s: expected non-empty error body", m)
		}
	}

	// Direct handleStatus with HEAD returns 200 with 0 body bytes
	headStatusReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/status", nil)
	headStatusW := httptest.NewRecorder()
	srv.handleStatus(headStatusW, headStatusReq)
	if headStatusW.Code != http.StatusOK {
		t.Errorf("direct handleStatus HEAD: want 200, got %d", headStatusW.Code)
	}
	if headStatusW.Body.Len() != 0 {
		t.Errorf("direct handleStatus HEAD: expected 0 body bytes, got %d", headStatusW.Body.Len())
	}
}

func TestWorkspaceConnectorHeadResponseWriterDirect(t *testing.T) {
	// Direct headResponseWriter Write discards bytes and returns length
	rec := httptest.NewRecorder()
	hw := &headResponseWriter{ResponseWriter: rec}
	payload := []byte("hello world payload")
	n, err := hw.Write(payload)
	if err != nil {
		t.Fatalf("unexpected Write error: %v", err)
	}
	if n != len(payload) {
		t.Errorf("Write returned %d, want %d", n, len(payload))
	}
	if rec.Body.Len() != 0 {
		t.Errorf("headResponseWriter leaked body bytes: %d", rec.Body.Len())
	}

	// Flush delegation
	hw.Flush()

	// Verify headBodySuppressingMiddleware with various statuses
	for _, status := range []int{http.StatusOK, http.StatusBadRequest, http.StatusNotFound, http.StatusMethodNotAllowed, http.StatusInternalServerError} {
		h := headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"status":"test"}`))
		}))

		// HEAD request
		headReq := httptest.NewRequest(http.MethodHead, "/test", nil)
		headRec := httptest.NewRecorder()
		h.ServeHTTP(headRec, headReq)
		if headRec.Code != status {
			t.Errorf("status %d: want code %d, got %d", status, status, headRec.Code)
		}
		if headRec.Body.Len() != 0 {
			t.Errorf("status %d HEAD: expected 0 body bytes, got %d: %q", status, headRec.Body.Len(), headRec.Body.String())
		}

		// GET request preserves body
		getReq := httptest.NewRequest(http.MethodGet, "/test", nil)
		getRec := httptest.NewRecorder()
		h.ServeHTTP(getRec, getReq)
		if getRec.Code != status {
			t.Errorf("status %d: want code %d, got %d", status, status, getRec.Code)
		}
		if getRec.Body.Len() == 0 {
			t.Errorf("status %d GET: expected non-empty body", status)
		}
	}
}



