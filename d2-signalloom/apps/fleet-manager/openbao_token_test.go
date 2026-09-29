package main

import (
	"context"
	"encoding/json"
	"errors"
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
		switch {
		case r.URL.Path == "/v1/auth/token/accessors" && r.Method == http.MethodGet && r.URL.Query().Get("list") == "true":
			_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"keys": order}})
		case r.URL.Path == "/v1/auth/token/lookup-accessor" && r.Method == http.MethodPost:
			var body struct {
				Accessor string `json:"accessor"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			tok := tokens[body.Accessor]
			if tok == nil {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"errors":["invalid accessor"]}`))
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
				"accessor":     body.Accessor,
				"display_name": tok.displayName,
				"meta":         tok.meta,
			}})
		case r.URL.Path == "/v1/auth/token/revoke-accessor" && r.Method == http.MethodPost:
			var body struct {
				Accessor string `json:"accessor"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			paths = append(paths, "REVOKE "+body.Accessor)
			mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/v1/sys/leases/revoke" && r.Method == http.MethodPost:
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
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
		http.NotFound(w, r)
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
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
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
			_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"keys": []string{"a1"}}})
		case "/v1/auth/token/lookup-accessor":
			_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"display_name": "jwt-" + sub}})
		default: // revoke-accessor
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
		}
	}))
	defer srv.Close()
	client := NewOpenBaoClient(OpenBaoConfig{Address: srv.URL, Token: "s.fleet"})
	revoked, err := client.RevokeTokensBySubject(context.Background(), sub)
	if !errors.Is(err, ErrEnforcementDenied) || revoked != 0 {
		t.Fatalf("revoked=%d err=%v, want 0 and ErrEnforcementDenied", revoked, err)
	}
}
