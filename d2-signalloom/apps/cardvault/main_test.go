package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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

func TestHealth(t *testing.T) {
	srv := newTestServer("user", "pass")
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
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

func TestCardvaultMethodNotAllowed(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	endpoints := []string{
		"/healthz",
		"/readyz",
		"/health",
		"/api/v1/cards",
		"/api/v1/cards/card-001",
	}

	for _, ep := range endpoints {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req, err := http.NewRequest(method, srv.URL+ep, nil)
			if err != nil {
				t.Fatalf("NewRequest: %v", err)
			}
			req.SetBasicAuth("u", "p")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("%s %s: %v", method, ep, err)
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode != http.StatusMethodNotAllowed {
				t.Errorf("%s %s: expected 405 Method Not Allowed, got %d", method, ep, resp.StatusCode)
			}
			if allow := resp.Header.Get("Allow"); !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") {
				t.Errorf("%s %s: expected Allow header containing GET, HEAD, got %q", method, ep, allow)
			}
			if len(body) == 0 {
				t.Errorf("%s %s: expected non-empty error body", method, ep)
			}
		}
	}
}

func TestCardvaultHeadRequests(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	endpoints := []string{
		"/healthz",
		"/readyz",
		"/health",
		"/api/v1/cards",
		"/api/v1/cards/card-001",
	}

	for _, ep := range endpoints {
		req, err := http.NewRequest(http.MethodHead, srv.URL+ep, nil)
		if err != nil {
			t.Fatalf("NewRequest: %v", err)
		}
		req.SetBasicAuth("u", "p")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("HEAD %s: %v", ep, err)
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			t.Fatalf("HEAD %s read body: %v", ep, err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Errorf("HEAD %s: expected 200 OK, got %d", ep, resp.StatusCode)
		}
		if len(body) != 0 {
			t.Errorf("HEAD %s: expected empty body, got %d bytes: %q", ep, len(body), string(body))
		}
		if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD %s: expected Content-Type application/json, got %q", ep, ct)
		}
	}

	// Also check HEAD on not found card
	req, err := http.NewRequest(http.MethodHead, srv.URL+"/api/v1/cards/nonexistent", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.SetBasicAuth("u", "p")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("HEAD nonexistent card: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("HEAD nonexistent: expected 404, got %d", resp.StatusCode)
	}
	if len(body) != 0 {
		t.Errorf("HEAD nonexistent: expected empty body, got %d bytes", len(body))
	}
}

func TestCardvaultHeadUnauthenticated(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	for _, ep := range []string{"/api/v1/cards", "/api/v1/cards/card-001"} {
		req, err := http.NewRequest(http.MethodHead, srv.URL+ep, nil)
		if err != nil {
			t.Fatalf("NewRequest: %v", err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("HEAD %s: %v", ep, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("HEAD %s without auth: want 401, got %d", ep, resp.StatusCode)
		}
		if len(body) != 0 {
			t.Errorf("HEAD %s without auth: want empty body, got %d bytes: %q", ep, len(body), string(body))
		}
	}
}

func TestCardvaultHeadUnknownRoute(t *testing.T) {
	srv := newTestServer("u", "p")
	defer srv.Close()

	for _, ep := range []string{"/unknown", "/api/v1/unknown", "/health/subpath"} {
		req, err := http.NewRequest(http.MethodHead, srv.URL+ep, nil)
		if err != nil {
			t.Fatalf("NewRequest: %v", err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("HEAD %s: %v", ep, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("HEAD %s: want 404, got %d", ep, resp.StatusCode)
		}
		if len(body) != 0 {
			t.Errorf("HEAD %s: want empty body, got %d bytes: %q", ep, len(body), string(body))
		}
	}
}

func TestCardvaultWriteJSONDirectAndHEAD(t *testing.T) {
	statuses := []int{
		http.StatusOK,
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusNotFound,
		http.StatusMethodNotAllowed,
		http.StatusInternalServerError,
	}
	payload := map[string]string{"vault": "test-token"}

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
		if got["vault"] != payload["vault"] {
			t.Errorf("GET writeJSON vault = %q, want %q", got["vault"], payload["vault"])
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



