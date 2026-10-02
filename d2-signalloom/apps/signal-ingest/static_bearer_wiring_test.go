package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
)

// stubAuthenticator stands in for the real JWT authenticator so these tests
// assert the wiring decision and nothing else.
type stubAuthenticator struct{ err error }

func (s stubAuthenticator) Authenticate(*http.Request) (api.Principal, error) {
	return api.Principal{Subject: "stub"}, s.err
}

// testBearerToken has the shape scripts/sldc-ingest-bearer.sh mints: 32 random
// bytes, base64url, 43 characters.
const testBearerToken = "qV3x9Lw2pN7cR1tY8kD4hF6jS0aZ5mE2uB7oG3iX1wQ"

const testSentinelKeySpec = `[{"name":"stun-sentinel","subject":"static-bearer/stun-sentinel-correlator","tenant":"kusari","permissions":["observations:write"],"expires":"` + api.StaticBearerSunset + `"}]`

func clearAuthEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{api.StaticKeysEnv, api.StaticKeysDirEnv, "SIGNAL_AUTH_AUDIENCE", "SIGNAL_AUTH_TRUST_DOMAIN",
		"SIGNAL_AUTH_JWKS", "SIGNAL_AUTH_JWKS_FILE", "SIGNAL_AUTH_JWKS_REFRESH", "SIGNAL_AUTH_BINDINGS"} {
		t.Setenv(k, "")
	}
}

// setStaticKeys configures the given specs, writing each value to <dir>/<name>.
func setStaticKeys(t *testing.T, specs string, values map[string]string) {
	t.Helper()
	dir := t.TempDir()
	for name, v := range values {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o400); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv(api.StaticKeysEnv, specs)
	t.Setenv(api.StaticKeysDirEnv, dir)
}

func bearer(token string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	return r
}

func TestHTTPAuthenticatorIsTheBareJWTWhenUnconfigured(t *testing.T) {
	clearAuthEnv(t)
	jwt := stubAuthenticator{}
	got, err := httpAuthenticator(jwt)
	if err != nil {
		t.Fatal(err)
	}
	if got != api.Authenticator(jwt) {
		t.Fatalf("no static keys must yield the JWT authenticator unchanged, got %T", got)
	}
}

// Without this, main could load the keys and then ignore them, and every test in the api
// package would still pass.
func TestHTTPAuthenticatorWrapsWhenConfigured(t *testing.T) {
	clearAuthEnv(t)
	setStaticKeys(t, testSentinelKeySpec, map[string]string{"stun-sentinel": testBearerToken})
	got, err := httpAuthenticator(stubAuthenticator{err: api.ErrMissingCredential})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got.(*api.StaticBearerAuthenticator); !ok {
		t.Fatalf("configured static keys not wired in: authenticator is %T", got)
	}
	p, err := got.Authenticate(bearer(testBearerToken))
	if err != nil {
		t.Fatalf("wired static key rejected: %v", err)
	}
	if p.TenantID != "kusari" || !p.Permissions[api.PermissionObservationWrite] {
		t.Fatalf("wired principal lacks the configured scope: %+v", p)
	}
}

func TestHTTPAuthenticatorRefusesInvalidStaticConfig(t *testing.T) {
	clearAuthEnv(t)
	setStaticKeys(t, `[{"name":"stun-sentinel"}]`, map[string]string{"stun-sentinel": testBearerToken})
	got, err := httpAuthenticator(stubAuthenticator{})
	if err == nil || got != nil {
		t.Fatalf("invalid static keys: (%T, %v), want (nil, error)", got, err)
	}
}

// Boot mode 1 (kind-osramp, Andy 2026-10-02: no SPIRE for callers): no JWKS configured. The
// binary boots on static keys alone, and every JWT — every non-static bearer — is refused with
// the same 401 an unknown token gets, never accepted.
func TestGatewayBootsOnStaticKeysAloneAndRefusesEveryJWT(t *testing.T) {
	clearAuthEnv(t)
	setStaticKeys(t, testSentinelKeySpec, map[string]string{"stun-sentinel": testBearerToken})
	gw, err := gatewayFromEnv(context.Background())
	if err != nil {
		t.Fatalf("static keys alone must boot: %v", err)
	}
	if _, err := gw.Authenticate(bearer(testBearerToken)); err != nil {
		t.Fatalf("static key refused in static-only mode: %v", err)
	}
	if _, err := gw.Authenticate(bearer("eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln")); !errors.Is(err, api.ErrInvalidCredential) {
		t.Fatalf("a JWT with no JWKS configured: err = %v, want ErrInvalidCredential", err)
	}
	if _, err := gw.Authenticate(bearer("")); !errors.Is(err, api.ErrMissingCredential) {
		t.Fatalf("no credential: err = %v, want ErrMissingCredential", err)
	}
}

// Nothing configured at all would boot a service that refuses everything: a misconfiguration,
// refused at startup rather than shipped as a silent 401 for every caller.
func TestGatewayRefusesToBootWithNoAuthenticationConfigured(t *testing.T) {
	clearAuthEnv(t)
	if gw, err := gatewayFromEnv(context.Background()); err == nil || gw != nil {
		t.Fatalf("no JWKS and no static keys: (%T, %v), want (nil, error)", gw, err)
	}
}

// A JWKS that IS configured keeps its fail-closed boot: an empty key set is a startup refusal,
// exactly as before JWKS became optional.
func TestGatewayStillRefusesAConfiguredButEmptyJWKS(t *testing.T) {
	clearAuthEnv(t)
	setStaticKeys(t, testSentinelKeySpec, map[string]string{"stun-sentinel": testBearerToken})
	jwks := filepath.Join(t.TempDir(), "jwks.json")
	if err := os.WriteFile(jwks, []byte(`{"keys":[]}`), 0o400); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SIGNAL_AUTH_AUDIENCE", "signal-ingest")
	t.Setenv("SIGNAL_AUTH_TRUST_DOMAIN", "osramp.local")
	t.Setenv("SIGNAL_AUTH_JWKS_FILE", jwks)
	t.Setenv("SIGNAL_AUTH_BINDINGS", "{}")
	if gw, err := gatewayFromEnv(context.Background()); err == nil || gw != nil {
		t.Fatalf("configured empty JWKS: (%T, %v), want (nil, error)", gw, err)
	}
}
