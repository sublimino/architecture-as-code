package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
)

// stubAuthenticator stands in for the real JWT authenticator so these tests
// assert the wiring decision and nothing else.
type stubAuthenticator struct{ err error }

func (s stubAuthenticator) Authenticate(*http.Request) (api.Principal, error) {
	return api.Principal{Subject: "stub"}, s.err
}

func clearStaticBearerEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{
		"SIGNAL_AUTH_STATIC_BEARER_TOKEN",
		"SIGNAL_AUTH_STATIC_BEARER_SUBJECT",
		"SIGNAL_AUTH_STATIC_BEARER_TENANT",
		"SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS",
		"SIGNAL_AUTH_STATIC_BEARER_ACTORS",
		"SIGNAL_AUTH_STATIC_BEARER_EXPIRES",
	} {
		t.Setenv(k, "")
	}
}

func setCompleteStaticBearerEnv(t *testing.T) {
	t.Helper()
	clearStaticBearerEnv(t)
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_TOKEN", "sentinel-in-cluster-token")
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_SUBJECT", "static-bearer/stun-sentinel-correlator")
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_TENANT", "kusari")
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS", "observations:write,collectors:write")
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_EXPIRES", api.StaticBearerSunset)
}

// TestHTTPAuthenticatorIsTheBareJWTWhenUnconfigured proves the default wiring:
// with no static bearer configured, the authenticator handed to the router is
// the JWT one itself, not a wrapper.
func TestHTTPAuthenticatorIsTheBareJWTWhenUnconfigured(t *testing.T) {
	clearStaticBearerEnv(t)
	jwt := stubAuthenticator{}

	got, err := httpAuthenticator(jwt)
	if err != nil {
		t.Fatal(err)
	}
	if got != api.Authenticator(jwt) {
		t.Fatalf("unconfigured static bearer must yield the JWT authenticator unchanged, got %T", got)
	}
}

// TestHTTPAuthenticatorWrapsWhenConfigured proves the feature is actually
// wired: without this, main could load the config and then ignore it, and
// every test in the api package would still pass.
func TestHTTPAuthenticatorWrapsWhenConfigured(t *testing.T) {
	setCompleteStaticBearerEnv(t)
	jwt := stubAuthenticator{err: api.ErrMissingCredential}

	got, err := httpAuthenticator(jwt)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got.(*api.StaticBearerAuthenticator); !ok {
		t.Fatalf("configured static bearer not wired in: authenticator is %T", got)
	}

	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", nil)
	r.Header.Set("Authorization", "Bearer sentinel-in-cluster-token")
	p, err := got.Authenticate(r)
	if err != nil {
		t.Fatalf("wired static bearer rejected the correlator token: %v", err)
	}
	if p.TenantID != "kusari" || !p.Permissions[api.PermissionObservationWrite] {
		t.Fatalf("wired principal lacks the configured scope: %+v", p)
	}
}

// TestHTTPAuthenticatorRefusesInvalidStaticConfig proves main gets an error to
// exit on rather than a silently weaker gate.
func TestHTTPAuthenticatorRefusesInvalidStaticConfig(t *testing.T) {
	setCompleteStaticBearerEnv(t)
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_SUBJECT", "")

	got, err := httpAuthenticator(stubAuthenticator{})
	if err == nil {
		t.Fatalf("invalid static bearer config accepted, authenticator is %T", got)
	}
	if got != nil {
		t.Fatalf("refused wiring must return nil, got %T", got)
	}
}
