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
		if w.Body.Len() != 0 {
			t.Errorf("HEAD %s: expected 0 body bytes, got %d: %q", path, w.Body.Len(), w.Body.String())
		}
	}

	// 2. Direct handler invocation with HEAD on invalid JSON body for handleStun
	badReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/stun", bytes.NewBufferString(`{bad-json`))
	w := httptest.NewRecorder()
	srv.handleStun(w, badReq)
	if w.Code != http.StatusBadRequest {
		t.Errorf("handleStun HEAD bad json: want 400, got %d", w.Code)
	}
	if w.Body.Len() != 0 {
		t.Errorf("handleStun HEAD bad json: expected 0 body bytes, got %d: %q", w.Body.Len(), w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("handleStun HEAD: want Content-Type application/json, got %q", ct)
	}

	// 3. Direct handler invocation with HEAD when handlePoll fails (simulated by 500 ingest)
	fakeIngest := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
	})))
	defer fakeIngest.Close()

	errSrv := &Server{
		client:    client.NewMockReportsClient(),
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: fakeIngest.URL,
	}
	pollReq := httptest.NewRequest(http.MethodHead, "/api/v1/workspace/poll", nil)
	pollW := httptest.NewRecorder()
	errSrv.handlePoll(pollW, pollReq)
	if pollW.Code != http.StatusInternalServerError {
		t.Errorf("handlePoll HEAD error: want 500, got %d", pollW.Code)
	}
	if pollW.Body.Len() != 0 {
		t.Errorf("handlePoll HEAD error: expected 0 body bytes, got %d: %q", pollW.Body.Len(), pollW.Body.String())
	}
	if ct := pollW.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("handlePoll HEAD error: want Content-Type application/json, got %q", ct)
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


