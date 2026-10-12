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
	case http.StatusNotFound:
		// CHARACTERISATION, not a skip. This used to be t.Skipf, and the skip
		// fired on 100% of runs: newServer registers exactly GET /health,
		// POST /tasks, GET /tasks/{id}, GET /tasks and
		// GET /.well-known/agent-card.json -- no /tui -- so Go's ServeMux
		// answers 404 every time and the test never asserted anything while
		// `go test` printed the package ok.
		//
		// Pinning the 404 explicitly is strictly better than skipping for two
		// reasons. The test now RUNS and asserts, so it appears in -v output as
		// a result rather than as an absence; and 405 or 400 would now fail,
		// which catches the route being half-registered or shadowed by a
		// catch-all. If /tui is ever implemented this returns 200 and the
		// content-type assertions above take over unchanged, so the real
		// coverage is already written and waiting.
		t.Logf("/tui is not registered; pinned as 404 (see newServer in main.go)")
	case http.StatusMethodNotAllowed:
		t.Errorf("GET /tui returned 405, so something registers the path but not the method; "+
			"newServer registers no /tui at all, so this is a routing change that needs a look")
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
	case http.StatusNotFound:
		// CHARACTERISATION, not a skip -- same reasoning as TestWebTUIEndpoint
		// above. newServer registers no /ws, so this skipped on 100% of runs
		// while the package reported ok. Pinned as 404 so the test asserts
		// something, and so a 405 or 400 (path registered but the upgrade
		// rejected) becomes a failure rather than another silent skip.
		t.Logf("/ws is not registered; pinned as 404 (see newServer in main.go)")
	case http.StatusMethodNotAllowed, http.StatusBadRequest:
		t.Errorf("WebSocket upgrade on /ws returned %d, so the path exists but the "+
			"handshake was refused; newServer registers no /ws at all, so this is a "+
			"routing or handshake change that needs a look", resp.StatusCode)
	default:
		t.Errorf("unexpected status %d for WebSocket upgrade on /ws", resp.StatusCode)
	}
}
