package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(b), nil
}

func (w *headResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func TestMockBaoServer_MethodGatesAndHEADBodySuppression(t *testing.T) {
	fake := newBaoFake(t, 300)

	// 1. POST /v1/auth/jwt/login should succeed
	postReq, _ := http.NewRequest(http.MethodPost, fake.srv.URL+"/v1/auth/jwt/login", strings.NewReader(`{"role":"test","jwt":"token"}`))
	postReq.Header.Set("Content-Type", "application/json")
	resp, err := fake.srv.Client().Do(postReq)
	if err != nil {
		t.Fatalf("POST login failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("POST login status = %d, want 200", resp.StatusCode)
	}

	// 2. HEAD /v1/auth/jwt/login should return 405 Method Not Allowed with Allow: POST and 0 body bytes
	headReq, _ := http.NewRequest(http.MethodHead, fake.srv.URL+"/v1/auth/jwt/login", nil)
	headResp, err := fake.srv.Client().Do(headReq)
	if err != nil {
		t.Fatalf("HEAD login failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD login status = %d, want 405", headResp.StatusCode)
	}
	if got := headResp.Header.Get("Allow"); got != http.MethodPost {
		t.Errorf("HEAD login Allow header = %q, want %q", got, http.MethodPost)
	}
	body, _ := io.ReadAll(headResp.Body)
	if len(body) != 0 {
		t.Errorf("HEAD login wrote %d body bytes, want 0", len(body))
	}

	// 3. GET /v1/auth/jwt/login should return 405 Method Not Allowed with Allow: POST
	getReq, _ := http.NewRequest(http.MethodGet, fake.srv.URL+"/v1/auth/jwt/login", nil)
	getResp, err := fake.srv.Client().Do(getReq)
	if err != nil {
		t.Fatalf("GET login failed: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET login status = %d, want 405", getResp.StatusCode)
	}
	if got := getResp.Header.Get("Allow"); got != http.MethodPost {
		t.Errorf("GET login Allow header = %q, want %q", got, http.MethodPost)
	}

	// 4. GET /v1/kv/data/signalloom/cardvault-agent with token should succeed
	kvReq, _ := http.NewRequest(http.MethodGet, fake.srv.URL+"/v1/kv/data/signalloom/cardvault-agent", nil)
	kvReq.Header.Set("X-Vault-Token", "s.token-1")
	kvResp, err := fake.srv.Client().Do(kvReq)
	if err != nil {
		t.Fatalf("GET KV failed: %v", err)
	}
	defer kvResp.Body.Close()
	if kvResp.StatusCode != http.StatusOK {
		t.Errorf("GET KV status = %d, want 200", kvResp.StatusCode)
	}

	// 5. HEAD /v1/kv/data/signalloom/cardvault-agent should return 200 with 0 body bytes
	headKVReq, _ := http.NewRequest(http.MethodHead, fake.srv.URL+"/v1/kv/data/signalloom/cardvault-agent", nil)
	headKVReq.Header.Set("X-Vault-Token", "s.token-1")
	headKVResp, err := fake.srv.Client().Do(headKVReq)
	if err != nil {
		t.Fatalf("HEAD KV failed: %v", err)
	}
	defer headKVResp.Body.Close()
	if headKVResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD KV status = %d, want 200", headKVResp.StatusCode)
	}
	kvBody, _ := io.ReadAll(headKVResp.Body)
	if len(kvBody) != 0 {
		t.Errorf("HEAD KV wrote %d body bytes, want 0", len(kvBody))
	}

	// 6. POST /v1/kv/data/signalloom/cardvault-agent should return 405 with Allow: GET, HEAD
	postKVReq, _ := http.NewRequest(http.MethodPost, fake.srv.URL+"/v1/kv/data/signalloom/cardvault-agent", nil)
	postKVResp, err := fake.srv.Client().Do(postKVReq)
	if err != nil {
		t.Fatalf("POST KV failed: %v", err)
	}
	defer postKVResp.Body.Close()
	if postKVResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST KV status = %d, want 405", postKVResp.StatusCode)
	}
	if got := postKVResp.Header.Get("Allow"); got != "GET, HEAD" {
		t.Errorf("POST KV Allow header = %q, want %q", got, "GET, HEAD")
	}
}

func TestMockCardvaultServer_MethodGatesAndHEADBodySuppression(t *testing.T) {
	fake := newBaoFake(t, 300)

	// 1. GET /api/v1/cards should return 200 with card payload
	getReq, _ := http.NewRequest(http.MethodGet, fake.cv.URL+"/api/v1/cards", nil)
	getResp, err := fake.cv.Client().Do(getReq)
	if err != nil {
		t.Fatalf("GET cards failed: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		t.Errorf("GET cards status = %d, want 200", getResp.StatusCode)
	}

	// 2. HEAD /api/v1/cards should return 200 with 0 body bytes
	headReq, _ := http.NewRequest(http.MethodHead, fake.cv.URL+"/api/v1/cards", nil)
	headResp, err := fake.cv.Client().Do(headReq)
	if err != nil {
		t.Fatalf("HEAD cards failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD cards status = %d, want 200", headResp.StatusCode)
	}
	body, _ := io.ReadAll(headResp.Body)
	if len(body) != 0 {
		t.Errorf("HEAD cards wrote %d body bytes, want 0", len(body))
	}

	// 3. POST /api/v1/cards should return 405 Method Not Allowed with Allow: GET, HEAD
	postReq, _ := http.NewRequest(http.MethodPost, fake.cv.URL+"/api/v1/cards", nil)
	postResp, err := fake.cv.Client().Do(postReq)
	if err != nil {
		t.Fatalf("POST cards failed: %v", err)
	}
	defer postResp.Body.Close()
	if postResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST cards status = %d, want 405", postResp.StatusCode)
	}
	if got := postResp.Header.Get("Allow"); got != "GET, HEAD" {
		t.Errorf("POST cards Allow header = %q, want %q", got, "GET, HEAD")
	}
}

func TestMockClaimServer_MethodGatesAndHEADBodySuppression(t *testing.T) {
	srv := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/api/v1/agents/claim" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		var req claimRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"status":"claimed","agent_id":"agent-001"}`))
	})))
	defer srv.Close()

	// 1. POST should succeed
	payload := `{"spiffe_id":"spiffe://test","agent_type":"cardvault","bao_token":"tok","claimed_at":"2026-10-13T12:00:00Z"}`
	resp, err := srv.Client().Post(srv.URL+"/api/v1/agents/claim", "application/json", strings.NewReader(payload))
	if err != nil {
		t.Fatalf("POST claim failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Errorf("POST claim status = %d, want 201", resp.StatusCode)
	}

	// 2. HEAD should return 405 with Allow: POST and 0 body bytes
	headReq, _ := http.NewRequest(http.MethodHead, srv.URL+"/api/v1/agents/claim", nil)
	headResp, err := srv.Client().Do(headReq)
	if err != nil {
		t.Fatalf("HEAD claim failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD claim status = %d, want 405", headResp.StatusCode)
	}
	if got := headResp.Header.Get("Allow"); got != http.MethodPost {
		t.Errorf("HEAD claim Allow = %q, want %q", got, http.MethodPost)
	}
	body, _ := io.ReadAll(headResp.Body)
	if len(body) != 0 {
		t.Errorf("HEAD claim wrote %d body bytes, want 0", len(body))
	}

	// 3. GET should return 405 with Allow: POST
	getReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/v1/agents/claim", nil)
	getResp, err := srv.Client().Do(getReq)
	if err != nil {
		t.Fatalf("GET claim failed: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET claim status = %d, want 405", getResp.StatusCode)
	}
	if got := getResp.Header.Get("Allow"); got != http.MethodPost {
		t.Errorf("GET claim Allow = %q, want %q", got, http.MethodPost)
	}
}
