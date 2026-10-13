package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// ── Token source ─────────────────────────────────────────────────────────────
//
// On kind the token is written by an openbao-agent sidecar AFTER fleet-manager
// starts, and is replaced on every re-auth (token_ttl 5m). A token read once at
// construction is therefore either empty for the life of the process or stale
// five minutes in. These tests pin that the file is re-read per request.

func TestOpenBaoClient_TokenFile_ReReadOnEveryRequest(t *testing.T) {
	var mu sync.Mutex
	var seen []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost && r.Method != http.MethodPut && r.Method != http.MethodHead {
			w.Header().Set("Allow", "PUT, POST, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
			}
			return
		}
		mu.Lock()
		seen = append(seen, r.Header.Get("X-Vault-Token"))
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	tokenPath := filepath.Join(t.TempDir(), "token")
	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, TokenFile: tokenPath})

	if client.TokenConfigured() {
		t.Fatalf("TokenConfigured() = true before the sink file exists; want false")
	}

	if err := os.WriteFile(tokenPath, []byte("s.first\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !client.TokenConfigured() {
		t.Fatalf("TokenConfigured() = false after the sink file was written; want true")
	}
	if err := client.RevokeTokenAccessor(context.Background(), "acc"); err != nil {
		t.Fatalf("first request: %v", err)
	}
	if err := os.WriteFile(tokenPath, []byte("s.second"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := client.RevokeTokenAccessor(context.Background(), "acc"); err != nil {
		t.Fatalf("second request: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 2 || seen[0] != "s.first" || seen[1] != "s.second" {
		t.Fatalf("tokens sent = %q, want [s.first s.second] (file must be re-read and trimmed per request)", seen)
	}
}

func TestOpenBaoClient_StaticTokenWinsOverFile(t *testing.T) {
	tokenPath := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenPath, []byte("s.file"), 0o600); err != nil {
		t.Fatal(err)
	}
	var got string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost && r.Method != http.MethodPut && r.Method != http.MethodHead {
			w.Header().Set("Allow", "PUT, POST, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
			}
			return
		}
		got = r.Header.Get("X-Vault-Token")
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: server.URL, Token: "s.static", TokenFile: tokenPath})
	if err := client.RevokeTokenAccessor(context.Background(), "acc"); err != nil {
		t.Fatal(err)
	}
	if got != "s.static" {
		t.Fatalf("token sent = %q, want s.static", got)
	}
}

func TestOpenBaoConfigFromEnv_TokenFile(t *testing.T) {
	t.Setenv("BAO_TOKEN", "")
	t.Setenv("VAULT_TOKEN", "")

	t.Setenv("BAO_TOKEN_FILE", "")
	if got := OpenBaoConfigFromEnv().TokenFile; got != DefaultOpenBaoTokenFile {
		t.Fatalf("default TokenFile = %q, want %q", got, DefaultOpenBaoTokenFile)
	}
	if DefaultOpenBaoTokenFile != "/var/run/secrets/openbao/token" {
		t.Fatalf("DefaultOpenBaoTokenFile = %q; the pre-existing default path must be preserved", DefaultOpenBaoTokenFile)
	}

	t.Setenv("BAO_TOKEN_FILE", "/custom/sink")
	if got := OpenBaoConfigFromEnv().TokenFile; got != "/custom/sink" {
		t.Fatalf("TokenFile = %q, want /custom/sink", got)
	}
}

// ── Active token enumeration ─────────────────────────────────────────────────

type fakeBaoToken struct {
	displayName string
	meta        map[string]string
}

// newFakeBaoAccessorServer serves LIST auth/token/accessors and
// lookup-accessor. An accessor mapped to nil answers 400 "invalid accessor",
// which is what OpenBao returns for a token that expired between the LIST and
// the lookup.
// Also serves revoke-accessor (recorded in the returned path log as
// "REVOKE <accessor>") and sys/leases/revoke (204), so the bao plane can be
// driven end to end.
func newFakeBaoAccessorServer(t *testing.T, tokens map[string]*fakeBaoToken, order []string) (*httptest.Server, *[]string) {
	t.Helper()
	var mu sync.Mutex
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery)
		mu.Unlock()
		switch r.URL.Path {
		case "/v1/auth/token/accessors":
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				w.Header().Set("Allow", "GET, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			if r.URL.Query().Get("list") != "true" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["not found"]}`))
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			if r.Method != http.MethodHead {
				_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"keys": order}})
			}
		case "/v1/auth/token/lookup-accessor":
			if r.Method != http.MethodPost && r.Method != http.MethodHead {
				w.Header().Set("Allow", "POST, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			var body struct {
				Accessor string `json:"accessor"`
			}
			if r.Body != nil {
				_ = json.NewDecoder(r.Body).Decode(&body)
			}
			tok := tokens[body.Accessor]
			if tok == nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["invalid accessor"]}`))
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			if r.Method != http.MethodHead {
				_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
					"accessor":     body.Accessor,
					"display_name": tok.displayName,
					"meta":         tok.meta,
				}})
			}
		case "/v1/auth/token/revoke-accessor":
			if r.Method != http.MethodPost && r.Method != http.MethodHead {
				w.Header().Set("Allow", "POST, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			var body struct {
				Accessor string `json:"accessor"`
			}
			if r.Body != nil {
				_ = json.NewDecoder(r.Body).Decode(&body)
			}
			mu.Lock()
			paths = append(paths, "REVOKE "+body.Accessor)
			mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
		case "/v1/sys/leases/revoke":
			if r.Method != http.MethodPost && r.Method != http.MethodPut && r.Method != http.MethodHead {
				w.Header().Set("Allow", "PUT, POST, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["not found"]}`))
			}
		}
	}))
	return srv, &paths
}

func TestOpenBaoClient_ActiveTokensBySubject(t *testing.T) {
	const cardvault = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault"
	const other = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent"
	tokens := map[string]*fakeBaoToken{
		"acc-meta":    {displayName: "jwt-" + cardvault, meta: map[string]string{"sub": cardvault, "role": "signalloom-agent-generic"}},
		"acc-display": {displayName: "jwt-" + cardvault}, // per-agent role without claim_mappings: no meta.sub
		"acc-other":   {displayName: "jwt-payments-" + other},
		"acc-root":    {displayName: "root"},
		"acc-expired": nil,
	}
	srv, paths := newFakeBaoAccessorServer(t, tokens, []string{"acc-meta", "acc-display", "acc-other", "acc-root", "acc-expired"})
	defer srv.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet"})
	counts, err := client.ActiveTokensBySubject(context.Background())
	if err != nil {
		t.Fatalf("ActiveTokensBySubject: %v (an expired accessor must be skipped, not fail the count)", err)
	}
	if counts[cardvault] != 2 {
		t.Fatalf("counts[cardvault] = %d, want 2 (meta.sub and display_name both identify the subject); all=%v", counts[cardvault], counts)
	}
	if counts[other] != 1 {
		t.Fatalf("counts[other] = %d, want 1 (mount-prefixed display_name); all=%v", counts[other], counts)
	}
	if len(counts) != 2 {
		t.Fatalf("len(counts) = %d, want 2 (tokens with no SPIFFE subject are not agent tokens); all=%v", len(counts), counts)
	}
	if (*paths)[0] != "GET /v1/auth/token/accessors?list=true" {
		t.Fatalf("first call = %q, want the accessor LIST", (*paths)[0])
	}
}

func TestOpenBaoClient_ActiveTokensBySubject_EmptyListIsZeroNotError(t *testing.T) {
	// OpenBao answers LIST with 404 when there are no keys.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		if r.Method != http.MethodHead {
			_, _ = w.Write([]byte(`{"errors":["not found"]}`))
		}
	}))
	defer srv.Close()
	client := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet"})
	counts, err := client.ActiveTokensBySubject(context.Background())
	if err != nil {
		t.Fatalf("err = %v, want nil for an empty accessor list", err)
	}
	if len(counts) != 0 {
		t.Fatalf("counts = %v, want empty", counts)
	}
}

func TestOpenBaoClient_ActiveTokensBySubject_DeniedIsAnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		if r.Method != http.MethodHead {
			_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
		}
	}))
	defer srv.Close()
	client := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet"})
	counts, err := client.ActiveTokensBySubject(context.Background())
	if !errors.Is(err, ErrEnforcementDenied) {
		t.Fatalf("err = %v, want ErrEnforcementDenied: an unqueryable plane must never read as zero tokens", err)
	}
	if counts != nil {
		t.Fatalf("counts = %v, want nil on error", counts)
	}
}

// ── Token revocation by subject ──────────────────────────────────────────────

func revokedAccessors(paths []string) []string {
	var out []string
	for _, p := range paths {
		if strings.HasPrefix(p, "REVOKE ") {
			out = append(out, strings.TrimPrefix(p, "REVOKE "))
		}
	}
	return out
}

func TestOpenBaoClient_RevokeTokensBySubject(t *testing.T) {
	const cardvault = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault"
	tokens := map[string]*fakeBaoToken{
		"acc-meta":    {displayName: "jwt-" + cardvault, meta: map[string]string{"sub": cardvault}},
		"acc-display": {displayName: "jwt-" + cardvault},
		"acc-other":   {displayName: "jwt-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent"},
		"acc-expired": nil,
	}
	srv, paths := newFakeBaoAccessorServer(t, tokens, []string{"acc-meta", "acc-other", "acc-expired", "acc-display"})
	defer srv.Close()

	client := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet"})
	revoked, err := client.RevokeTokensBySubject(context.Background(), cardvault)
	if err != nil {
		t.Fatalf("RevokeTokensBySubject: %v", err)
	}
	if revoked != 2 {
		t.Fatalf("revoked = %d, want 2", revoked)
	}
	got := revokedAccessors(*paths)
	if len(got) != 2 || got[0] != "acc-meta" || got[1] != "acc-display" {
		t.Fatalf("revoke-accessor calls = %q, want exactly [acc-meta acc-display]; another agent's token must never be revoked", got)
	}
}

func TestOpenBaoClient_RevokeTokensBySubject_DeniedFailsClosed(t *testing.T) {
	const sub = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/token/accessors":
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				w.Header().Set("Allow", "GET, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			if r.Method != http.MethodHead {
				_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"keys": []string{"a1"}}})
			}
		case "/v1/auth/token/lookup-accessor":
			if r.Method != http.MethodPost && r.Method != http.MethodHead {
				w.Header().Set("Allow", "POST, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			if r.Method != http.MethodHead {
				_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"display_name": "jwt-" + sub}})
			}
		default: // revoke-accessor
			if r.Method != http.MethodPost && r.Method != http.MethodHead {
				w.Header().Set("Allow", "POST, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
			}
		}
	}))
	defer srv.Close()
	client := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet"})
	revoked, err := client.RevokeTokensBySubject(context.Background(), sub)
	if !errors.Is(err, ErrEnforcementDenied) || revoked != 0 {
		t.Fatalf("revoked=%d err=%v, want 0 and ErrEnforcementDenied", revoked, err)
	}
}

func TestOpenBaoTokenMockServerMethodGatingAndHEAD(t *testing.T) {
	tokens := map[string]*fakeBaoToken{
		"acc-1": {displayName: "jwt-test", meta: map[string]string{"sub": "test"}},
	}
	srv, _ := newFakeBaoAccessorServer(t, tokens, []string{"acc-1"})
	defer srv.Close()

	// 1. Verify HEAD on /v1/auth/token/accessors?list=true returns 200 with 0 body bytes
	headResp, err := http.Head(srv.URL + "/v1/auth/token/accessors?list=true")
	if err != nil {
		t.Fatalf("HEAD accessors error: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD accessors status = %d, want 200", headResp.StatusCode)
	}
	headBytes, _ := io.ReadAll(headResp.Body)
	if len(headBytes) != 0 {
		t.Errorf("HEAD accessors body length = %d, want 0", len(headBytes))
	}

	// 2. Verify POST on /v1/auth/token/accessors returns 405 with Allow: GET, HEAD
	postResp, err := http.Post(srv.URL+"/v1/auth/token/accessors", "application/json", nil)
	if err != nil {
		t.Fatalf("POST accessors error: %v", err)
	}
	defer postResp.Body.Close()
	if postResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST accessors status = %d, want 405", postResp.StatusCode)
	}
	if allow := postResp.Header.Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("POST accessors Allow = %q, want 'GET, HEAD'", allow)
	}

	// 3. Verify GET on /v1/auth/token/lookup-accessor returns 405 with Allow: POST, HEAD
	getResp, err := http.Get(srv.URL + "/v1/auth/token/lookup-accessor")
	if err != nil {
		t.Fatalf("GET lookup-accessor error: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET lookup-accessor status = %d, want 405", getResp.StatusCode)
	}
	if allow := getResp.Header.Get("Allow"); allow != "POST, HEAD" {
		t.Errorf("GET lookup-accessor Allow = %q, want 'POST, HEAD'", allow)
	}

	// 4. Verify HEAD on 400 invalid accessor path returns 400 with 0 body bytes
	req, err := http.NewRequestWithContext(context.Background(), http.MethodHead, srv.URL+"/v1/auth/token/lookup-accessor", nil)
	if err != nil {
		t.Fatalf("NewRequest error: %v", err)
	}
	head400Resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("HEAD lookup-accessor error: %v", err)
	}
	defer head400Resp.Body.Close()
	if head400Resp.StatusCode != http.StatusBadRequest {
		t.Errorf("HEAD lookup-accessor status = %d, want 400", head400Resp.StatusCode)
	}
	head400Bytes, _ := io.ReadAll(head400Resp.Body)
	if len(head400Bytes) != 0 {
		t.Errorf("HEAD lookup-accessor body length = %d, want 0", len(head400Bytes))
	}
}
