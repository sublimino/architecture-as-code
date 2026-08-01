package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer(username, password string) *httptest.Server {
	mux := newMux(username, password)
	return httptest.NewServer(mux)
}

func TestHealthz(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("expected status ok, got %q", body["status"])
	}
}

func TestReadyz(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/readyz")
	if err != nil {
		t.Fatalf("GET /readyz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["status"] != "ready" {
		t.Fatalf("expected status ready, got %q", body["status"])
	}
}

func TestCardsNoAuth(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/v1/cards")
	if err != nil {
		t.Fatalf("GET /api/v1/cards: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}

	if resp.Header.Get("WWW-Authenticate") == "" {
		t.Fatal("missing WWW-Authenticate header")
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["error"] != "unauthorized" {
		t.Fatalf("expected error unauthorized, got %q", body["error"])
	}
}

func TestCardsWrongAuth(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req.SetBasicAuth("wrong", "creds")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /api/v1/cards: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestCardsValidAuth(t *testing.T) {
	srv := newTestServer("vaultuser", "vaultpass")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards", nil)
	req.SetBasicAuth("vaultuser", "vaultpass")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /api/v1/cards: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	ct := resp.Header.Get("Content-Type")
	if ct != "application/json" {
		t.Fatalf("expected application/json, got %q", ct)
	}

	var cards []Card
	if err := json.NewDecoder(resp.Body).Decode(&cards); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(cards) != 3 {
		t.Fatalf("expected 3 cards, got %d", len(cards))
	}
}

func TestCardByID(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards/card-001", nil)
	req.SetBasicAuth("u", "p")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /api/v1/cards/card-001: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var card Card
	if err := json.NewDecoder(resp.Body).Decode(&card); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if card.ID != "card-001" {
		t.Fatalf("expected card-001, got %q", card.ID)
	}
	if card.Cardholder == "" {
		t.Fatal("cardholder should not be empty")
	}
}

func TestCardByIDNotFound(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/cards/nonexistent", nil)
	req.SetBasicAuth("u", "p")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /api/v1/cards/nonexistent: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["error"] != "card not found" {
		t.Fatalf("expected 'card not found', got %q", body["error"])
	}
}

func TestCardByIDNoAuth(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/v1/cards/card-001")
	if err != nil {
		t.Fatalf("GET /api/v1/cards/card-001: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestContentTypeOnAllResponses(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	endpoints := []string{"/healthz", "/readyz", "/api/v1/cards"}
	for _, ep := range endpoints {
		resp, err := http.Get(srv.URL + ep)
		if err != nil {
			t.Fatalf("GET %s: %v", ep, err)
		}
		ct := resp.Header.Get("Content-Type")
		if ct != "application/json" {
			t.Errorf("%s: expected application/json, got %q", ep, ct)
		}
		resp.Body.Close()
	}
}
