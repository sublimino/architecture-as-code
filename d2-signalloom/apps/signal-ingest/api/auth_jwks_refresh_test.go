package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// SLDC-P2-2: signal-ingest trusts the federated osramp.local JWT-SVID keys
// from a mounted file and re-reads it on an interval, so a SPIRE key rotation
// reaches the verifier without a restart and a bad refresh never fails open.

const refreshSubject = "spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"

func writeJWKSFile(t *testing.T, path string, keys map[string]*ecdsa.PrivateKey) {
	t.Helper()
	enc := base64.RawURLEncoding
	body := `{"keys":[`
	first := true
	for kid, k := range keys {
		if !first {
			body += ","
		}
		first = false
		body += fmt.Sprintf(`{"kty":"EC","kid":%q,"crv":"P-256","x":%q,"y":%q,"use":"jwt-svid"}`,
			kid, enc.EncodeToString(k.X.FillBytes(make([]byte, 32))), enc.EncodeToString(k.Y.FillBytes(make([]byte, 32))))
	}
	body += `]}`
	writeRaw(t, path, body)
}

// writeRaw replaces the file atomically, the way kubelet swaps a ConfigMap
// volume's ..data symlink.
func writeRaw(t *testing.T, path, body string) {
	t.Helper()
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func refreshToken(t *testing.T, key *ecdsa.PrivateKey, kid string) string {
	t.Helper()
	return signedTokenWithHeader(t, key, map[string]any{"alg": "ES256", "kid": kid, "typ": "JWT"}, map[string]any{
		"sub": refreshSubject, "aud": []string{"signal-ingest"}, "exp": time.Now().Add(5 * time.Minute).Unix(),
	})
}

func authWith(a *JWTAuthenticator, token string) error {
	r := httptest.NewRequest("POST", "/api/v1/observations", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	_, err := a.Authenticate(r)
	return err
}

func newFileAuthenticator(t *testing.T, path string, refresh time.Duration) *JWTAuthenticator {
	t.Helper()
	keys, err := LoadJWKSFile(path)
	if err != nil {
		t.Fatal(err)
	}
	a, err := NewJWTAuthenticator(AuthConfig{
		Audience: "signal-ingest", TrustDomain: "osramp.local", Keys: keys,
		Bindings:    map[string]PrincipalBinding{refreshSubject: {TenantID: "kusari", Permissions: []Permission{PermissionObservationWrite}}},
		JWKSFile:    path,
		JWKSRefresh: refresh,
	})
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func genKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestJWKSFileRotationSwapsKeySet(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwks.json")
	keyA, keyB := genKey(t), genKey(t)
	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA})
	a := newFileAuthenticator(t, path, time.Hour)
	if err := authWith(a, refreshToken(t, keyA, "a")); err != nil {
		t.Fatalf("key A before rotation: %v", err)
	}

	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"b": keyB})
	if err := a.RefreshKeys(); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if err := authWith(a, refreshToken(t, keyB, "b")); err != nil {
		t.Fatalf("rotated key B rejected: %v", err)
	}
	if err := authWith(a, refreshToken(t, keyA, "a")); !errors.Is(err, ErrInvalidCredential) {
		t.Fatalf("retired key A still accepted after rotation: %v", err)
	}
}

func TestJWKSFileBadRefreshKeepsLastGoodKeys(t *testing.T) {
	for name, body := range map[string]string{
		"garbage":    `{not json`,
		"empty":      `{"keys":[]}`,
		"weak-curve": `{"keys":[{"kty":"EC","kid":"p384","crv":"P-384","x":"AA","y":"AA"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "jwks.json")
			keyA := genKey(t)
			writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA})
			a := newFileAuthenticator(t, path, time.Hour)
			writeRaw(t, path, body)
			if err := a.RefreshKeys(); err == nil {
				t.Fatal("bad JWKS refresh reported success")
			}
			if err := authWith(a, refreshToken(t, keyA, "a")); err != nil {
				t.Fatalf("last-good key lost after bad refresh: %v", err)
			}
		})
	}
}

func TestJWKSFileMissingOnRefreshKeepsLastGoodKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwks.json")
	keyA := genKey(t)
	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA})
	a := newFileAuthenticator(t, path, time.Hour)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := a.RefreshKeys(); err == nil {
		t.Fatal("missing JWKS file refresh reported success")
	}
	if err := authWith(a, refreshToken(t, keyA, "a")); err != nil {
		t.Fatalf("last-good key lost: %v", err)
	}
}

func TestStartKeyRefreshPicksUpRotationOnInterval(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwks.json")
	keyA, keyB := genKey(t), genKey(t)
	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": keyA})
	a := newFileAuthenticator(t, path, 10*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	a.StartKeyRefresh(ctx)

	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"b": keyB})
	deadline := time.Now().Add(2 * time.Second)
	for authWith(a, refreshToken(t, keyB, "b")) != nil {
		if time.Now().After(deadline) {
			t.Fatal("refresh loop never loaded rotated key B")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestAuthConfigFromEnvJWKSSources(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwks.json")
	writeJWKSFile(t, path, map[string]*ecdsa.PrivateKey{"a": genKey(t)})
	bindings := fmt.Sprintf(`{%q:{"tenant_id":"kusari","permissions":["observations:write"]}}`, refreshSubject)
	base := func(t *testing.T) {
		t.Setenv("SIGNAL_AUTH_AUDIENCE", "signal-ingest")
		t.Setenv("SIGNAL_AUTH_TRUST_DOMAIN", "osramp.local")
		t.Setenv("SIGNAL_AUTH_BINDINGS", bindings)
		t.Setenv("SIGNAL_AUTH_JWKS", "")
		t.Setenv("SIGNAL_AUTH_JWKS_FILE", "")
		t.Setenv("SIGNAL_AUTH_JWKS_REFRESH", "")
	}

	t.Run("file source defaults to 15m refresh", func(t *testing.T) {
		base(t)
		t.Setenv("SIGNAL_AUTH_JWKS_FILE", path)
		cfg, err := AuthConfigFromEnv()
		if err != nil {
			t.Fatal(err)
		}
		if cfg.JWKSRefresh != 15*time.Minute || cfg.JWKSFile != path || len(cfg.Keys) != 1 {
			t.Fatalf("got refresh=%v file=%q keys=%d", cfg.JWKSRefresh, cfg.JWKSFile, len(cfg.Keys))
		}
	})
	t.Run("both sources rejected", func(t *testing.T) {
		base(t)
		t.Setenv("SIGNAL_AUTH_JWKS_FILE", path)
		t.Setenv("SIGNAL_AUTH_JWKS", `{"keys":[]}`)
		if _, err := AuthConfigFromEnv(); err == nil {
			t.Fatal("inline and file JWKS both accepted")
		}
	})
	t.Run("neither source rejected", func(t *testing.T) {
		base(t)
		if _, err := AuthConfigFromEnv(); err == nil {
			t.Fatal("no JWKS source accepted")
		}
	})
	for _, bad := range []string{"0s", "-1m", "500ms", "48h", "abc"} {
		t.Run("refresh "+bad+" rejected", func(t *testing.T) {
			base(t)
			t.Setenv("SIGNAL_AUTH_JWKS_FILE", path)
			t.Setenv("SIGNAL_AUTH_JWKS_REFRESH", bad)
			if _, err := AuthConfigFromEnv(); err == nil {
				t.Fatalf("refresh %q accepted", bad)
			}
		})
	}
	t.Run("empty file fails closed at boot", func(t *testing.T) {
		base(t)
		empty := filepath.Join(t.TempDir(), "empty.json")
		writeRaw(t, empty, `{"keys":[]}`)
		t.Setenv("SIGNAL_AUTH_JWKS_FILE", empty)
		if _, err := AuthConfigFromEnv(); err == nil {
			t.Fatal("empty JWKS file accepted at boot")
		}
	})
}

// TestLiveSPIREJWTSVID runs signal-ingest's real env loader and verifier
// against a JWT-SVID minted by a live SPIRE agent and the hub's federated
// JWKS. test/spire-federation-openbao-jwt.bats drives it with the values from
// deploy/jwt-auth-config.yaml and asserts it PASSED rather than skipped.
func TestLiveSPIREJWTSVID(t *testing.T) {
	bound, unbound, jwks := os.Getenv("SIGNAL_INGEST_LIVE_JWT"), os.Getenv("SIGNAL_INGEST_LIVE_UNBOUND_JWT"), os.Getenv("SIGNAL_INGEST_LIVE_JWKS")
	if bound == "" || unbound == "" || jwks == "" {
		t.Skip("live SPIRE lab not provided (set by test/spire-federation-openbao-jwt.bats)")
	}
	path := filepath.Join(t.TempDir(), "jwks.json")
	writeRaw(t, path, jwks)
	t.Setenv("SIGNAL_AUTH_JWKS_FILE", path)
	cfg, err := AuthConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	a, err := NewJWTAuthenticator(cfg)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", "/api/v1/observations", nil)
	r.Header.Set("Authorization", "Bearer "+bound)
	p, err := a.Authenticate(r)
	if err != nil {
		t.Fatalf("live SPIRE token rejected: %v", err)
	}
	if p.TenantID != "kusari" || !p.Permissions[PermissionObservationWrite] {
		t.Fatalf("principal %q tenant %q lacks observations:write", p.Subject, p.TenantID)
	}
	t.Logf("accepted %s tenant=%s", p.Subject, p.TenantID)
	r.Header.Set("Authorization", "Bearer "+unbound)
	if _, err := a.Authenticate(r); !errors.Is(err, ErrUnboundPrincipal) {
		t.Fatalf("unbound live SVID: want ErrUnboundPrincipal, got %v", err)
	}
}
