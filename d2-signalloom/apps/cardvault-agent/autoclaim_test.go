package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Auto-claim lifecycle hook tests.
// ─────────────────────────────────────────────────────────────────────────────

func TestAutoClaimSuccess(t *testing.T) {
	var captured claimRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("expected POST, got %s", r.Method)
		}
		if r.URL.Path != "/api/v1/agents/claim" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		ct := r.Header.Get("Content-Type")
		if ct != "application/json" {
			t.Fatalf("expected application/json, got %s", ct)
		}
		if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"status":"claimed","agent_id":"agent-001"}`))
	}))
	defer srv.Close()

	app := &agent{
		claimURL: srv.URL,
		client:   srv.Client(),
	}

	err := app.autoClaim("spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent", "s.test-token")
	if err != nil {
		t.Fatalf("autoClaim failed: %v", err)
	}

	if captured.SpiffeID != "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent" {
		t.Errorf("unexpected spiffe_id: %q", captured.SpiffeID)
	}
	if captured.AgentType != "cardvault" {
		t.Errorf("unexpected agent_type: %q", captured.AgentType)
	}
	if captured.BaoToken != "s.test-token" {
		t.Errorf("unexpected bao_token: %q", captured.BaoToken)
	}
}

func TestAutoClaimRejects500(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(`{"error":"internal error"}`))
	}))
	defer srv.Close()

	app := &agent{
		claimURL: srv.URL,
		client:   srv.Client(),
	}

	err := app.autoClaim("spiffe://test", "token")
	if err == nil {
		t.Fatal("expected error on 500")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("error should mention 500: %v", err)
	}
}

func TestAutoClaimRejects409(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusConflict)
		w.Write([]byte(`{"error":"already claimed"}`))
	}))
	defer srv.Close()

	app := &agent{
		claimURL: srv.URL,
		client:   srv.Client(),
	}

	err := app.autoClaim("spiffe://test", "token")
	if err == nil {
		t.Fatal("expected error on 409")
	}
	if !strings.Contains(err.Error(), "409") {
		t.Errorf("error should mention 409: %v", err)
	}
}

func TestAutoClaimSendsCorrectPayload(t *testing.T) {
	var body map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&body)
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"status":"claimed"}`))
	}))
	defer srv.Close()

	app := &agent{
		claimURL: srv.URL,
		client:   srv.Client(),
	}

	app.autoClaim("spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent", "tok")

	// Verify all expected fields are present.
	for _, key := range []string{"spiffe_id", "agent_type", "bao_token", "claimed_at"} {
		if _, ok := body[key]; !ok {
			t.Errorf("missing field %q in claim payload", key)
		}
	}
}

func TestAutoClaimNetworkError(t *testing.T) {
	app := &agent{
		claimURL: "http://127.0.0.1:1", // nothing listening
		client:   &http.Client{Timeout: 100 * time.Millisecond},
	}

	err := app.autoClaim("spiffe://test", "token")
	if err == nil {
		t.Fatal("expected error on network failure")
	}
}
