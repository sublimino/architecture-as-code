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

	// Test healthz
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("healthz: want 200, got %d", w.Code)
	}

	// Test status
	req = httptest.NewRequest(http.MethodGet, "/api/v1/workspace/status", nil)
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("status: want 200, got %d", w.Code)
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
