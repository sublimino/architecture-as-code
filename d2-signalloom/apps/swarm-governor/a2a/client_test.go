package a2a

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// headResponseWriter suppresses response bodies on HEAD requests (RFC 9110 Section 6.4.1).
type headResponseWriter struct {
	http.ResponseWriter
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	return len(b), nil
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w = &headResponseWriter{ResponseWriter: w}
		}
		next.ServeHTTP(w, r)
	})
}

func TestClient_DiscoverCard(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(AgentCard{
			Name:        "test-agent",
			Description: "A test agent",
			Version:     "1.0.0",
		})
	})

	server := httptest.NewServer(headBodySuppressingMiddleware(mux))
	defer server.Close()

	client := NewClient()
	card, err := client.DiscoverCard(context.Background(), server.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if card.Name != "test-agent" {
		t.Errorf("expected test-agent, got %s", card.Name)
	}
	if card.URL != server.URL {
		t.Errorf("expected URL to default to %s, got %s", server.URL, card.URL)
	}
}

func TestClient_DiscoverCard_Non200(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "agent card not found"})
	})

	server := httptest.NewServer(headBodySuppressingMiddleware(mux))
	defer server.Close()

	client := NewClient()
	_, err := client.DiscoverCard(context.Background(), server.URL)
	if err == nil {
		t.Fatal("expected error on 404, got nil")
	}
	if !strings.Contains(err.Error(), "status 404") {
		t.Errorf("expected status 404 in error, got: %v", err)
	}
}

func TestClient_SendTask_HTTPError(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		if r.Method == http.MethodHead {
			return
		}
		_, _ = w.Write([]byte("internal server error"))
	})))
	defer server.Close()

	client := NewClient()
	_, err := client.SendTask(context.Background(), server.URL, Task{ID: "task-1"})
	if err == nil {
		t.Fatal("expected error on 500, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP status 500") {
		t.Errorf("expected HTTP status 500 in error, got: %v", err)
	}
}

func TestClient_GetTask_HTTPError(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		if r.Method == http.MethodHead {
			return
		}
		_, _ = w.Write([]byte("bad gateway"))
	})))
	defer server.Close()

	client := NewClient()
	_, err := client.GetTask(context.Background(), server.URL, "task-1")
	if err == nil {
		t.Fatal("expected error on 502, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP status 502") {
		t.Errorf("expected HTTP status 502 in error, got: %v", err)
	}
}

func TestClient_SendTask_Success(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      "task-1",
			Result: TaskResult{
				TaskID: "task-1",
				Status: "completed",
			},
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(resp)
	})))
	defer server.Close()

	client := NewClient()
	res, err := client.SendTask(context.Background(), server.URL, Task{ID: "task-1"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Status != "completed" {
		t.Errorf("expected completed, got %s", res.Status)
	}
}

func TestClient_DiscoverCard_MethodGatesAndHEADBodySuppression(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(AgentCard{
			Name:        "test-agent",
			Description: "A test agent",
			Version:     "1.0.0",
		})
	})

	server := httptest.NewServer(headBodySuppressingMiddleware(mux))
	defer server.Close()

	// 1. HEAD request returns 200 with matching Content-Type and 0 body bytes
	headReq, err := http.NewRequestWithContext(context.Background(), http.MethodHead, server.URL+"/.well-known/agent-card.json", nil)
	if err != nil {
		t.Fatalf("create HEAD request: %v", err)
	}
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	defer headResp.Body.Close()

	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD status = %d, want 200", headResp.StatusCode)
	}
	if ct := headResp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD Content-Type = %q, want 'application/json'", ct)
	}
	body, err := io.ReadAll(headResp.Body)
	if err != nil {
		t.Fatalf("read HEAD body: %v", err)
	}
	if len(body) != 0 {
		t.Errorf("HEAD body length = %d, want 0", len(body))
	}

	// 2. Unsupported methods return 405 Method Not Allowed with Allow: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req, err := http.NewRequestWithContext(context.Background(), method, server.URL+"/.well-known/agent-card.json", nil)
		if err != nil {
			t.Fatalf("create %s request: %v", method, err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s request failed: %v", method, err)
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s status = %d, want 405", method, resp.StatusCode)
		}
		if allow := resp.Header.Get("Allow"); allow != "GET, HEAD" {
			t.Errorf("%s Allow header = %q, want 'GET, HEAD'", method, allow)
		}
	}
}

func TestClient_SendTask_MethodGatesAndHEADBodySuppression(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})))
	defer server.Close()

	// 1. GET returns 405 Method Not Allowed with Allow: POST
	getReq, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL, nil)
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("GET request failed: %v", err)
	}
	getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET status = %d, want 405", getResp.StatusCode)
	}
	if allow := getResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("GET Allow header = %q, want 'POST'", allow)
	}

	// 2. HEAD returns 405 Method Not Allowed with Allow: POST and 0-byte body
	headReq, _ := http.NewRequestWithContext(context.Background(), http.MethodHead, server.URL, nil)
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD status = %d, want 405", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("HEAD Allow header = %q, want 'POST'", allow)
	}
	body, err := io.ReadAll(headResp.Body)
	if err != nil {
		t.Fatalf("read HEAD body: %v", err)
	}
	if len(body) != 0 {
		t.Errorf("HEAD body length = %d, want 0", len(body))
	}
}

func TestClient_GetTask_Success(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      "task-1",
			Result: TaskResult{
				TaskID: "task-1",
				Status: "completed",
			},
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(resp)
	})))
	defer server.Close()

	client := NewClient()
	res, err := client.GetTask(context.Background(), server.URL, "task-1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Status != "completed" {
		t.Errorf("expected completed, got %s", res.Status)
	}
	if res.TaskID != "task-1" {
		t.Errorf("expected task-1, got %s", res.TaskID)
	}
}

func TestClient_GetTask_MethodGatesAndHEADBodySuppression(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})))
	defer server.Close()

	// 1. GET returns 405 Method Not Allowed with Allow: POST
	getReq, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL, nil)
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("GET request failed: %v", err)
	}
	getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET status = %d, want 405", getResp.StatusCode)
	}
	if allow := getResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("GET Allow header = %q, want 'POST'", allow)
	}

	// 2. HEAD returns 405 Method Not Allowed with Allow: POST and 0-byte body
	headReq, _ := http.NewRequestWithContext(context.Background(), http.MethodHead, server.URL, nil)
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD status = %d, want 405", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("HEAD Allow header = %q, want 'POST'", allow)
	}
	body, err := io.ReadAll(headResp.Body)
	if err != nil {
		t.Fatalf("read HEAD body: %v", err)
	}
	if len(body) != 0 {
		t.Errorf("HEAD body length = %d, want 0", len(body))
	}
}

func TestClient_MockServersHEADBodySuppressionAcrossStatuses(t *testing.T) {
	statusCodes := []int{
		http.StatusOK,
		http.StatusBadRequest,
		http.StatusNotFound,
		http.StatusMethodNotAllowed,
		http.StatusInternalServerError,
		http.StatusBadGateway,
	}

	for _, status := range statusCodes {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(status)
				_ = json.NewEncoder(w).Encode(map[string]any{"status": status, "msg": "response text"})
			})))
			defer server.Close()

			req, err := http.NewRequestWithContext(context.Background(), http.MethodHead, server.URL, nil)
			if err != nil {
				t.Fatalf("create HEAD request: %v", err)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("HEAD request failed: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != status {
				t.Errorf("status = %d, want %d", resp.StatusCode, status)
			}
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatalf("read body: %v", err)
			}
			if len(body) != 0 {
				t.Errorf("status %d HEAD body length = %d, want 0", status, len(body))
			}
		})
	}
}

func TestValidateHTTPURL(t *testing.T) {
	valid := []string{
		"http://localhost:8080",
		"http://127.0.0.1:9090",
		"https://agent.example.com/api",
		"http://agent-svc.default.svc.cluster.local:8080",
	}
	for _, u := range valid {
		if err := validateHTTPURL(u); err != nil {
			t.Errorf("validateHTTPURL(%q) unexpected error: %v", u, err)
		}
	}

	invalid := []struct {
		url string
		err string
	}{
		{"", "invalid URL"},
		{"ftp://agent.example.com", "invalid URL scheme"},
		{"file:///etc/passwd", "invalid URL scheme"},
		{"gopher://evil.com", "invalid URL scheme"},
		{"http://", "missing host"},
		{"://foo", "missing protocol scheme"},
	}
	for _, tc := range invalid {
		err := validateHTTPURL(tc.url)
		if err == nil {
			t.Errorf("validateHTTPURL(%q) expected error, got nil", tc.url)
		} else if !strings.Contains(err.Error(), tc.err) {
			t.Errorf("validateHTTPURL(%q) error = %q, want substring %q", tc.url, err.Error(), tc.err)
		}
	}
}

func TestClient_URLValidation(t *testing.T) {
	client := NewClient()
	ctx := context.Background()

	// DiscoverCard rejects invalid URLs
	if _, err := client.DiscoverCard(ctx, "ftp://agent.com"); err == nil {
		t.Error("DiscoverCard should reject ftp scheme")
	}

	// SendTask rejects invalid URLs
	if _, err := client.SendTask(ctx, "ftp://agent.com", Task{ID: "t-1"}); err == nil {
		t.Error("SendTask should reject ftp scheme")
	}

	// GetTask rejects invalid URLs
	if _, err := client.GetTask(ctx, "ftp://agent.com", "t-1"); err == nil {
		t.Error("GetTask should reject ftp scheme")
	}
}

