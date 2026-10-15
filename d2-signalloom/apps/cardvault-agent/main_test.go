package main

import (
	"bytes"
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
	bao := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/v1/auth/jwt/login" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"auth":{"client_token":"s.test-token-123","policies":["signalloom-cardvault-agent"]}}`))
	})))
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
	bao := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"errors":["permission denied"]}`))
	})))
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
	bao := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/v1/kv/data/signalloom/cardvault-agent" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if got := r.Header.Get("X-Vault-Token"); got != "s.test-token" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":{"data":{"username":"cardvault-svc","password":"s3cret!"}}}`))
	})))
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

	cv := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/api/v1/cards" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		user, pass, ok := r.BasicAuth()
		if !ok || user != "cardvault-svc" || pass != "s3cret!" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(cards)
	})))
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
	cv := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"error":"forbidden"}`))
	})))
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
	bao := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/jwt/login":
			if r.Method != http.MethodPost {
				w.Header().Set("Allow", http.MethodPost)
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"auth":{"client_token":"s.chain-token","policies":["signalloom-cardvault-agent"]}}`))
		case "/v1/kv/data/signalloom/cardvault-agent":
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				w.Header().Set("Allow", "GET, HEAD")
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			if r.Header.Get("X-Vault-Token") != "s.chain-token" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"data":{"data":{"username":"chain-user","password":"chain-pass"}}}`))
		default:
			t.Fatalf("unexpected bao path: %s", r.URL.Path)
		}
	})))
	defer bao.Close()

	// Mock cardvault
	cv := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		user, pass, ok := r.BasicAuth()
		if !ok || user != "chain-user" || pass != "chain-pass" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]card{
			{Cardholder: "Chain Test", PANMasked: "****-****-****-9999", Expiry: "06/28"},
		})
	})))
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

func TestCombinedOutputExecution(t *testing.T) {
	out, err := combinedOutput("echo", "agent-ok")
	if err != nil {
		t.Fatalf("combinedOutput failed: %v", err)
	}
	if !strings.Contains(string(out), "agent-ok") {
		t.Fatalf("expected agent-ok in output, got %q", string(out))
	}
}

func TestEndpointURLValidationAndEntryFlags(t *testing.T) {
	// 1. Direct validation of validateEndpointURL
	badURLs := []string{
		"",
		"   ",
		"ftp://openbao:8200",
		"file:///etc/passwd",
		"gopher://example.com",
		"http://",
		"https://",
		"://bad-url",
	}
	for _, bad := range badURLs {
		if err := validateEndpointURL(bad, "test endpoint"); err == nil {
			t.Errorf("expected validateEndpointURL(%q) to fail, got nil", bad)
		}
	}

	goodURLs := []string{
		"http://localhost:8200",
		"https://vault.corp.internal/v1",
		"http://10.96.0.1:8080",
	}
	for _, good := range goodURLs {
		if err := validateEndpointURL(good, "test endpoint"); err != nil {
			t.Errorf("expected validateEndpointURL(%q) to pass, got %v", good, err)
		}
	}

	// 2. entry() flag validation rejection
	var stdout, stderr bytes.Buffer
	code := entry([]string{"-bao-addr", "ftp://bad-vault"}, &stdout, &stderr)
	if code != 64 {
		t.Errorf("expected exit code 64 for bad bao-addr, got %d", code)
	}

	stderr.Reset()
	code = entry([]string{"-cardvault-url", "file:///bad-cardvault"}, &stdout, &stderr)
	if code != 64 {
		t.Errorf("expected exit code 64 for bad cardvault-url, got %d", code)
	}

	stderr.Reset()
	code = entry([]string{"-claim-url", "invalid-claim"}, &stdout, &stderr)
	if code != 64 {
		t.Errorf("expected exit code 64 for bad claim-url, got %d", code)
	}

	// 3. Method validation failure paths in agent
	a := &agent{
		baoAddr:      "file:///bad",
		cardvaultURL: "gopher://bad",
		claimURL:     "ftp://bad",
		client:       defaultHTTPClient(),
	}
	if _, _, err := a.login("jwt"); err == nil {
		t.Errorf("expected error on login with bad baoAddr, got nil")
	}
	if _, _, err := a.readCredentials("token"); err == nil {
		t.Errorf("expected error on readCredentials with bad baoAddr, got nil")
	}
	if _, err := a.accessCardvault("u", "p"); err == nil {
		t.Errorf("expected error on accessCardvault with bad cardvaultURL, got nil")
	}
	if err := a.autoClaim("spiffe", "token"); err == nil {
		t.Errorf("expected error on autoClaim with bad claimURL, got nil")
	}
}

func TestIsTransientHTTPStatus(t *testing.T) {
	transients := []int{
		http.StatusBadGateway,
		http.StatusServiceUnavailable,
		http.StatusGatewayTimeout,
	}
	for _, code := range transients {
		if !isTransientHTTPStatus(code) {
			t.Errorf("expected status %d to be transient, got false", code)
		}
	}

	nonTransients := []int{
		http.StatusOK,
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusForbidden,
		http.StatusNotFound,
		http.StatusInternalServerError,
	}
	for _, code := range nonTransients {
		if isTransientHTTPStatus(code) {
			t.Errorf("expected status %d to be non-transient, got true", code)
		}
	}
}

func TestEnvOr(t *testing.T) {
	key := "TEST_ENV_OR_VAR"
	t.Setenv(key, "custom-value")
	if v := envOr(key, "fallback"); v != "custom-value" {
		t.Errorf("expected custom-value, got %s", v)
	}

	t.Setenv(key, "")
	if v := envOr(key, "fallback"); v != "" {
		t.Errorf("expected empty string when env var is explicitly empty, got %s", v)
	}

	unsetKey := "TEST_ENV_OR_UNSET_VAR_XYZ"
	if v := envOr(unsetKey, "fallback"); v != "fallback" {
		t.Errorf("expected fallback when env var is unset, got %s", v)
	}
}

func TestLoginRetryOnTransientError(t *testing.T) {
	var attempts int
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("503 Service Unavailable"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"auth":{"client_token":"s.retry-success-token","lease_duration":3600}}`))
	}))
	defer bao.Close()

	app := &agent{
		baoAddr: bao.URL,
		baoRole: "signalloom-cardvault-agent",
		client:  bao.Client(),
		pause:   func(time.Duration) {},
	}

	token, lease, err := app.login("jwt")
	if err != nil {
		t.Fatalf("expected login to succeed after retry, got error: %v", err)
	}
	if token != "s.retry-success-token" {
		t.Errorf("expected s.retry-success-token, got %s", token)
	}
	if lease != 3600*time.Second {
		t.Errorf("expected 3600s lease, got %v", lease)
	}
	if attempts != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", attempts)
	}
}

func TestReadCredentialsRetryOnTransientError(t *testing.T) {
	var attempts int
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			w.WriteHeader(http.StatusBadGateway)
			w.Write([]byte("502 Bad Gateway"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":{"data":{"username":"alice","password":"secret"}}}`))
	}))
	defer bao.Close()

	app := &agent{
		baoAddr: bao.URL,
		client:  bao.Client(),
		pause:   func(time.Duration) {},
	}

	u, p, err := app.readCredentials("token")
	if err != nil {
		t.Fatalf("expected readCredentials to succeed after retry, got: %v", err)
	}
	if u != "alice" || p != "secret" {
		t.Errorf("expected alice/secret, got %s/%s", u, p)
	}
	if attempts != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", attempts)
	}
}

func TestAccessCardvaultRetryOnTransientError(t *testing.T) {
	var attempts int
	cv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			w.WriteHeader(http.StatusGatewayTimeout)
			w.Write([]byte("504 Gateway Timeout"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"cardholder":"Alice Smith","pan_masked":"****1234","expiry":"12/28"}]`))
	}))
	defer cv.Close()

	app := &agent{
		cardvaultURL: cv.URL,
		client:       cv.Client(),
		pause:        func(time.Duration) {},
	}

	cards, err := app.accessCardvault("u", "p")
	if err != nil {
		t.Fatalf("expected accessCardvault to succeed after retry, got: %v", err)
	}
	if len(cards) != 1 || cards[0].Cardholder != "Alice Smith" {
		t.Errorf("unexpected cards: %+v", cards)
	}
	if attempts != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", attempts)
	}
}

