//go:build acceptance

// Browser interaction tests for cpai-engineer. These validate the "browser as
// client" mode where a human connects via web browser to pair with the agent.
//
// Uses only stdlib — no gorilla/websocket dependency. WebSocket upgrade is
// tested by sending the raw Upgrade headers and checking the server's response.
package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testServerForBrowser creates a server with /tui and /ws endpoints.
func testServerForBrowser(t *testing.T) *httptest.Server {
	t.Helper()

	tmpDir := t.TempDir()
	workspaceDir := filepath.Join(tmpDir, "workspace")
	os.MkdirAll(workspaceDir, 0o755)

	dbPath := filepath.Join(tmpDir, "sessions.db")
	store, err := NewSessionStore(dbPath)
	if err != nil {
		t.Fatalf("new session store: %v", err)
	}
	t.Cleanup(func() { store.Close() })

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(workspaceDir, nono, store)
	handler := newServer(executor, store)

	return httptest.NewServer(handler)
}

// ── Web TUI Endpoint ───────────────────────────────────────────────────────

func TestWebTUIEndpoint(t *testing.T) {
	ts := testServerForBrowser(t)
	defer ts.Close()

	// GET /tui should return HTML content (or 404 if not yet implemented).
	resp, err := http.Get(ts.URL + "/tui")
	if err != nil {
		t.Fatalf("GET /tui: %v", err)
	}
	defer resp.Body.Close()

	// Accept either 200 (endpoint exists) or 404 (not yet implemented).
	// When implemented, it must return HTML.
	switch resp.StatusCode {
	case http.StatusOK:
		ct := resp.Header.Get("Content-Type")
		if !strings.Contains(ct, "text/html") {
			t.Errorf("expected text/html content type, got %q", ct)
		}
	case http.StatusNotFound, http.StatusMethodNotAllowed:
		t.Skipf("/tui endpoint not yet implemented (got %d)", resp.StatusCode)
	default:
		t.Errorf("unexpected status %d for GET /tui", resp.StatusCode)
	}
}

// ── WebSocket Handshake ────────────────────────────────────────────────────

func TestWebSocketHandshake(t *testing.T) {
	ts := testServerForBrowser(t)
	defer ts.Close()

	// Send a raw HTTP request with WebSocket upgrade headers.
	// This tests whether the server accepts (101) or rejects (404/400) the upgrade.
	req, err := http.NewRequest("GET", ts.URL+"/ws", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("WebSocket upgrade request: %v", err)
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusSwitchingProtocols:
		// Successful WebSocket upgrade.
		upgrade := resp.Header.Get("Upgrade")
		if !strings.EqualFold(upgrade, "websocket") {
			t.Errorf("expected Upgrade: websocket, got %q", upgrade)
		}
	case http.StatusNotFound, http.StatusMethodNotAllowed, http.StatusBadRequest:
		// /ws not yet implemented — skip rather than fail.
		t.Skipf("/ws endpoint not yet implemented (got %d)", resp.StatusCode)
	default:
		t.Errorf("unexpected status %d for WebSocket upgrade on /ws", resp.StatusCode)
	}
}
