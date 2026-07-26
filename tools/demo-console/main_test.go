package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestHandleProxyADKRewritesPathStripsFramingHeaders(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got, want := r.URL.Path, "/nested/path"; got != want {
			t.Errorf("upstream path = %q, want %q", got, want)
		}
		if got, want := r.URL.RawQuery, "keep=me"; got != want {
			t.Errorf("upstream query = %q, want %q", got, want)
		}
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "frame-ancestors 'none'")
		w.Header().Set("X-Upstream", "reached")
		w.WriteHeader(http.StatusCreated)
	}))
	defer backend.Close()

	backendURL, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	_, port, found := strings.Cut(backendURL.Host, ":")
	if !found {
		t.Fatalf("backend host %q lacks a port", backendURL.Host)
	}
	t.Setenv("ADK_PORT", port)

	req := httptest.NewRequest(http.MethodGet, "/proxy/adk/nested/path?keep=me", nil)
	// The proxy deliberately does not impose its own authentication or origin
	// check; local binding is the current access boundary.
	req.Header.Set("Origin", "https://unrelated.example")
	response := httptest.NewRecorder()
	(&console{}).handleProxy(response, req)

	if got, want := response.Code, http.StatusCreated; got != want {
		t.Fatalf("status = %d, want %d", got, want)
	}
	if got := response.Header().Get("X-Frame-Options"); got != "" {
		t.Errorf("X-Frame-Options = %q, want removed", got)
	}
	if got := response.Header().Get("Content-Security-Policy"); got != "" {
		t.Errorf("Content-Security-Policy = %q, want removed", got)
	}
	if got, want := response.Header().Get("X-Upstream"), "reached"; got != want {
		t.Errorf("X-Upstream = %q, want %q", got, want)
	}
}

func TestHandleProxyRejectsUnknownService(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/proxy/not-allowlisted/metrics", nil)
	response := httptest.NewRecorder()
	(&console{pf: newPForward(t.TempDir())}).handleProxy(response, req)

	if got, want := response.Code, http.StatusServiceUnavailable; got != want {
		t.Fatalf("status = %d, want %d", got, want)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(body["detail"], `unknown service "not-allowlisted"`) {
		t.Errorf("detail = %q, want unknown-service error", body["detail"])
	}
}

func TestGrafanaProxyServiceIsExplicitlyAllowlisted(t *testing.T) {
	ref, ok := services["grafana"]
	if !ok {
		t.Fatal("grafana is not allowlisted")
	}
	if got, want := ref.ns, namespace; got != want {
		t.Errorf("namespace = %q, want %q", got, want)
	}
	if got, want := ref.svc, "eye-in-the-sky-grafana"; got != want {
		t.Errorf("service = %q, want %q", got, want)
	}
	if got, want := ref.port, 80; got != want {
		t.Errorf("port = %d, want %d", got, want)
	}
}
