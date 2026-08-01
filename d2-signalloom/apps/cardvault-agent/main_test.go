package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestBaoTokenExchange(t *testing.T) {
	var captured struct {
		Role string `json:"role"`
		JWT  string `json:"jwt"`
	}
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/auth/jwt/login" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(`{"auth":{"client_token":"s.test-token-123","policies":["signalloom-cardvault-agent"]}}`))
	}))
	defer bao.Close()

	app := &agent{
		baoAddr:     bao.URL,
		baoRole:     "signalloom-cardvault-agent",
		client:      bao.Client(),
		cardvaultURL: "http://unused",
	}

	token, err := app.exchangeForBaoToken("header.payload.signature")
	if err != nil {
		t.Fatalf("exchange failed: %v", err)
	}
	if token != "s.test-token-123" {
		t.Fatalf("unexpected token: %q", token)
	}
	if captured.Role != "signalloom-cardvault-agent" {
		t.Fatalf("unexpected role: %q", captured.Role)
	}
	if captured.JWT != "header.payload.signature" {
		t.Fatalf("unexpected jwt: %q", captured.JWT)
	}
}

func TestBaoTokenExchangeRejects403(t *testing.T) {
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"errors":["permission denied"]}`))
	}))
	defer bao.Close()

	app := &agent{
		baoAddr: bao.URL,
		baoRole: "signalloom-cardvault-agent",
		client:  bao.Client(),
	}

	_, err := app.exchangeForBaoToken("jwt")
	if err == nil {
		t.Fatal("expected error on 403")
	}
	if !strings.Contains(err.Error(), "403") {
		t.Fatalf("error should mention 403: %v", err)
	}
}

func TestBaoKVRead(t *testing.T) {
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/kv/data/signalloom/cardvault-agent" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if got := r.Header.Get("X-Vault-Token"); got != "s.test-token" {
			t.Fatalf("unexpected token header: %q", got)
		}
		w.Write([]byte(`{"data":{"data":{"username":"cardvault-svc","password":"s3cret!"}}}`))
	}))
	defer bao.Close()

	app := &agent{
		baoAddr: bao.URL,
		client:  bao.Client(),
	}

	user, pass, err := app.readCredentials("s.test-token")
	if err != nil {
		t.Fatalf("read credentials failed: %v", err)
	}
	if user != "cardvault-svc" {
		t.Fatalf("unexpected username: %q", user)
	}
	if pass != "s3cret!" {
		t.Fatalf("unexpected password: %q", pass)
	}
}

func TestCardvaultAccess(t *testing.T) {
	cards := []card{
		{Cardholder: "Alice Smith", PANMasked: "****-****-****-4242", Expiry: "12/27"},
		{Cardholder: "Bob Jones", PANMasked: "****-****-****-1234", Expiry: "03/26"},
	}

	cv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/cards" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		user, pass, ok := r.BasicAuth()
		if !ok || user != "cardvault-svc" || pass != "s3cret!" {
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}
		json.NewEncoder(w).Encode(cards)
	}))
	defer cv.Close()

	app := &agent{
		cardvaultURL: cv.URL,
		client:       cv.Client(),
	}

	got, err := app.accessCardvault("cardvault-svc", "s3cret!")
	if err != nil {
		t.Fatalf("access failed: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 cards, got %d", len(got))
	}
	if got[0].Cardholder != "Alice Smith" {
		t.Fatalf("unexpected cardholder: %q", got[0].Cardholder)
	}
}

func TestCardvaultAccessFailsOnBadAuth(t *testing.T) {
	cv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"error":"forbidden"}`))
	}))
	defer cv.Close()

	app := &agent{
		cardvaultURL: cv.URL,
		client:       cv.Client(),
	}

	_, err := app.accessCardvault("wrong", "wrong")
	if err == nil {
		t.Fatal("expected error on forbidden")
	}
	if !strings.Contains(err.Error(), "403") {
		t.Fatalf("error should mention 403: %v", err)
	}
}

func TestSPIREFetchWithRetry(t *testing.T) {
	calls := 0
	runner := func(name string, args ...string) ([]byte, error) {
		calls++
		if calls < 3 {
			return []byte("agent unavailable"), errors.New("exit status 1")
		}
		return []byte(`{"svids":[{"svid":"header.payload.signature","spiffeID":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"}]}`), nil
	}

	app := &agent{
		spireSocket: "/run/spire/sockets/agent.sock",
		audience:    "openbao",
		invoke:      runner,
		pause:       func(time.Duration) {},
	}

	jwt, err := app.fetchSPIFFEIdentity()
	if err != nil {
		t.Fatalf("fetch failed: %v", err)
	}
	if jwt != "header.payload.signature" {
		t.Fatalf("unexpected jwt: %q", jwt)
	}
	if calls != 3 {
		t.Fatalf("expected 3 calls, got %d", calls)
	}
}

func TestSPIREFetchExhaustsRetries(t *testing.T) {
	runner := func(string, ...string) ([]byte, error) {
		return []byte("agent not ready"), errors.New("exit status 1")
	}

	app := &agent{
		spireSocket: "/run/spire/sockets/agent.sock",
		audience:    "openbao",
		invoke:      runner,
		pause:       func(time.Duration) {},
	}

	_, err := app.fetchSPIFFEIdentity()
	if err == nil {
		t.Fatal("expected error after exhausted retries")
	}
}

func TestFullChain(t *testing.T) {
	// Mock SPIRE
	runner := func(string, ...string) ([]byte, error) {
		return []byte(`{"svids":[{"svid":"chain-jwt","spiffeID":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"}]}`), nil
	}

	// Mock OpenBao: login + KV read
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/jwt/login":
			w.Write([]byte(`{"auth":{"client_token":"s.chain-token","policies":["signalloom-cardvault-agent"]}}`))
		case "/v1/kv/data/signalloom/cardvault-agent":
			if r.Header.Get("X-Vault-Token") != "s.chain-token" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Write([]byte(`{"data":{"data":{"username":"chain-user","password":"chain-pass"}}}`))
		default:
			t.Fatalf("unexpected bao path: %s", r.URL.Path)
		}
	}))
	defer bao.Close()

	// Mock cardvault
	cv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != "chain-user" || pass != "chain-pass" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		json.NewEncoder(w).Encode([]card{
			{Cardholder: "Chain Test", PANMasked: "****-****-****-9999", Expiry: "06/28"},
		})
	}))
	defer cv.Close()

	var stdout, stderr strings.Builder
	app := &agent{
		baoAddr:      bao.URL,
		baoRole:      "signalloom-cardvault-agent",
		cardvaultURL: cv.URL,
		spireSocket:  "/run/spire/sockets/agent.sock",
		audience:     "openbao",
		invoke:       runner,
		pause:        func(time.Duration) {},
		client:       bao.Client(),
	}
	// For the full chain, cardvault uses a different httptest server, so we need
	// a client that can reach both. Use http.DefaultClient for test simplicity
	// since httptest servers listen on localhost.
	app.client = &http.Client{Timeout: 5 * time.Second}

	code := app.runDemo(&stdout, &stderr)
	if code != 0 {
		t.Fatalf("full chain failed (exit %d): stderr=%s", code, stderr.String())
	}

	output := stdout.String()
	for _, want := range []string{
		"[step-1]",
		"[step-2]",
		"[step-3]",
		"[step-4]",
		"[complete]",
		"Chain Test",
		"****-****-****-9999",
	} {
		if !strings.Contains(output, want) {
			t.Errorf("output missing %q", want)
		}
	}
}

func TestHTTPClientTimeout(t *testing.T) {
	c := defaultHTTPClient()
	if c.Timeout != 30*time.Second {
		t.Fatalf("unexpected timeout: %s", c.Timeout)
	}
}
