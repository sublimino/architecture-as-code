package main

import (
	"bytes"
	"encoding/json"
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
	fakeIngest := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"internal ingest failure"}`))
	}))
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
	fakeIngest := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
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

