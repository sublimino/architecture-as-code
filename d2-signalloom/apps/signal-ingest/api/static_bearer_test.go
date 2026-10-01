package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// The real correlator token, so these tests exercise the value actually on the
// wire (stun-sentinel pkg/correlator/ebpf_correlator.go DefaultBearerToken).
const testSentinelToken = "sentinel-in-cluster-token"

const testStaticSubject = "static-bearer/stun-sentinel-correlator"

func testStaticConfig() StaticBearerConfig {
	return StaticBearerConfig{
		Token:       testSentinelToken,
		Subject:     testStaticSubject,
		TenantID:    "kusari",
		Permissions: []Permission{PermissionObservationWrite, PermissionCollectorWrite},
		ExpiresAt:   time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC),
	}
}

// testJWTDelegate returns a JWT authenticator whose single binding deliberately
// holds a permission the static principal must never acquire.
func testJWTDelegate(t *testing.T) (*JWTAuthenticator, *ecdsa.PrivateKey, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sub := "spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"
	a, err := NewJWTAuthenticator(AuthConfig{
		Audience:    "signal-ingest",
		TrustDomain: "osramp.local",
		Keys:        map[string]any{"test": &key.PublicKey},
		Bindings: map[string]PrincipalBinding{sub: {
			TenantID: "kusari",
			// actors:list is the canary: the JWT binding has it, the static
			// principal must not inherit it.
			Permissions: []Permission{PermissionObservationWrite, PermissionActorList},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return a, key, sub
}

func bearerRequest(method, target, token string) *http.Request {
	r := httptest.NewRequest(method, target, nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	return r
}

// clearStaticBearerEnv blanks every static-bearer variable so a test starts
// from the shipped default (feature absent). An empty value and an unset
// variable are the same thing to the loader, which is itself asserted by
// TestStaticBearerAbsentFromEnvYieldsNoConfig.
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

// --- Off by default -------------------------------------------------------

// TestStaticBearerAbsentFromEnvYieldsNoConfig proves the opt-in: with none of
// the variables set, the loader reports "no static bearer" rather than an
// error and rather than a permissive default.
func TestStaticBearerAbsentFromEnvYieldsNoConfig(t *testing.T) {
	clearStaticBearerEnv(t)
	cfg, err := StaticBearerConfigFromEnv()
	if err != nil {
		t.Fatalf("absent static bearer config must not be an error: %v", err)
	}
	if cfg != nil {
		t.Fatalf("absent static bearer config must yield nil, got %+v", cfg)
	}
}

// TestStaticBearerOffByDefaultIsStill401 proves behaviour is byte-identical to
// today when the feature is not configured: the correlator's static token is
// rejected by the bare JWT authenticator with 401 and the generic body.
func TestStaticBearerOffByDefaultIsStill401(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	router, aw := newStaticBearerRouter(t, delegate)

	w := httptest.NewRecorder()
	router.ServeHTTP(w, bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unconfigured static bearer: want 401, got %d body %s", w.Code, w.Body.String())
	}
	if got := strings.TrimSpace(w.Body.String()); got != `{"error":"authentication_failed"}` {
		t.Fatalf("unconfigured static bearer body = %s", got)
	}
	assertNoTokenLeak(t, aw, w.Body.String())
}

// --- Explicit opt-in: hard startup refusals -------------------------------

// TestStaticBearerConfigFromEnvRefusesPartialConfig proves a partially
// configured credential is a startup refusal, never a silent accept-anything.
func TestStaticBearerConfigFromEnvRefusesPartialConfig(t *testing.T) {
	full := map[string]string{
		"SIGNAL_AUTH_STATIC_BEARER_TOKEN":       testSentinelToken,
		"SIGNAL_AUTH_STATIC_BEARER_SUBJECT":     testStaticSubject,
		"SIGNAL_AUTH_STATIC_BEARER_TENANT":      "kusari",
		"SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS": "observations:write,collectors:write",
		"SIGNAL_AUTH_STATIC_BEARER_EXPIRES":     StaticBearerSunset,
	}
	tests := []struct {
		name     string
		override map[string]string
	}{
		{"no subject", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_SUBJECT": ""}},
		{"no tenant", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_TENANT": ""}},
		{"no permissions", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS": ""}},
		{"no expiry", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_EXPIRES": ""}},
		{"empty token with a principal named", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_TOKEN": ""}},
		{"whitespace token", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_TOKEN": "        \t   "}},
		{"token too short to resist guessing", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_TOKEN": "short"}},
		{"unknown permission", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS": "telemetry:write"}},
		{"one unknown permission among known ones", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS": "observations:write,violations:publish"}},
		{"expiry not a date", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_EXPIRES": "soon"}},
		{"subject impersonating a SPIFFE ID", map[string]string{"SIGNAL_AUTH_STATIC_BEARER_SUBJECT": "spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			clearStaticBearerEnv(t)
			for k, v := range full {
				t.Setenv(k, v)
			}
			for k, v := range tc.override {
				t.Setenv(k, v)
			}
			cfg, err := StaticBearerConfigFromEnv()
			if err == nil {
				t.Fatalf("partial static bearer config accepted: %+v", cfg)
			}
			if cfg != nil {
				t.Fatalf("refused config must be nil, got %+v", cfg)
			}
			if strings.Contains(err.Error(), testSentinelToken) {
				t.Fatalf("refusal error leaks the token: %v", err)
			}
		})
	}
}

// TestStaticBearerConfigFromEnvLoadsCompleteConfig pins the happy path of the
// loader, including the permission and actor list parsing.
func TestStaticBearerConfigFromEnvLoadsCompleteConfig(t *testing.T) {
	clearStaticBearerEnv(t)
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_TOKEN", testSentinelToken)
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_SUBJECT", testStaticSubject)
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_TENANT", "kusari")
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_PERMISSIONS", " observations:write , collectors:write ")
	t.Setenv("SIGNAL_AUTH_STATIC_BEARER_EXPIRES", StaticBearerSunset)

	cfg, err := StaticBearerConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg == nil {
		t.Fatal("complete static bearer config not loaded")
	}
	if cfg.Token != testSentinelToken || cfg.Subject != testStaticSubject || cfg.TenantID != "kusari" {
		t.Fatalf("loaded config mismatch: subject=%q tenant=%q", cfg.Subject, cfg.TenantID)
	}
	want := []Permission{PermissionObservationWrite, PermissionCollectorWrite}
	if fmt.Sprint(cfg.Permissions) != fmt.Sprint(want) {
		t.Fatalf("permissions = %v, want %v", cfg.Permissions, want)
	}
	if !cfg.ExpiresAt.Equal(time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("expiry = %s, want %s", cfg.ExpiresAt, StaticBearerSunset)
	}
}

// TestNewStaticBearerAuthenticatorRefusesInvalidConfig covers the constructor
// directly, so a programmatic caller cannot bypass the env loader's gates.
func TestNewStaticBearerAuthenticatorRefusesInvalidConfig(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tests := []struct {
		name        string
		mutate      func(*StaticBearerConfig)
		nilDelegate bool
	}{
		{name: "nil delegate", mutate: func(*StaticBearerConfig) {}, nilDelegate: true},
		{name: "empty token", mutate: func(c *StaticBearerConfig) { c.Token = "" }},
		{name: "short token", mutate: func(c *StaticBearerConfig) { c.Token = "abc" }},
		{name: "no subject", mutate: func(c *StaticBearerConfig) { c.Subject = "" }},
		{name: "no tenant", mutate: func(c *StaticBearerConfig) { c.TenantID = "" }},
		{name: "no permissions", mutate: func(c *StaticBearerConfig) { c.Permissions = nil }},
		{name: "unknown permission", mutate: func(c *StaticBearerConfig) {
			c.Permissions = []Permission{"telemetry:write"}
		}},
		{name: "no expiry", mutate: func(c *StaticBearerConfig) { c.ExpiresAt = time.Time{} }},
		{name: "spiffe subject", mutate: func(c *StaticBearerConfig) {
			c.Subject = "spiffe://osramp.local/ns/x/sa/y"
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := testStaticConfig()
			tc.mutate(&cfg)
			var d Authenticator = delegate
			if tc.nilDelegate {
				d = nil
			}
			a, err := NewStaticBearerAuthenticator(cfg, d)
			if err == nil {
				t.Fatal("invalid static bearer config accepted")
			}
			if a != nil {
				t.Fatalf("refused constructor must return nil, got %+v", a)
			}
		})
	}
}

// --- Scoped exactly, and no inheritance from the JWT bindings -------------

// TestStaticBearerGrantsExactlyTheConfiguredPermissions proves the static
// principal carries its configured scope and nothing else.
func TestStaticBearerGrantsExactlyTheConfiguredPermissions(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	p, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
	if err != nil {
		t.Fatalf("configured static token rejected: %v", err)
	}
	if p.Subject != testStaticSubject {
		t.Fatalf("subject = %q, want %q", p.Subject, testStaticSubject)
	}
	if p.TenantID != "kusari" {
		t.Fatalf("tenant = %q, want kusari", p.TenantID)
	}
	granted := map[Permission]bool{PermissionObservationWrite: true, PermissionCollectorWrite: true}
	for permission := range KnownPermissions {
		if p.Permissions[permission] != granted[permission] {
			t.Errorf("permission %q: granted=%v, want %v", permission, p.Permissions[permission], granted[permission])
		}
	}
}

// TestStaticBearerDoesNotInheritJWTBindings proves the static principal is
// built only from its own config: actors:list sits in the delegate's binding
// for the same workload and must not reach the static principal.
func TestStaticBearerDoesNotInheritJWTBindings(t *testing.T) {
	delegate, key, sub := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	static, err := a.Authenticate(bearerRequest(http.MethodGet, "/api/v1/actors", testSentinelToken))
	if err != nil {
		t.Fatal(err)
	}
	if static.Permissions[PermissionActorList] {
		t.Fatal("static principal inherited actors:list from the JWT binding")
	}
	if len(static.ActorIDs) != 0 {
		t.Fatalf("static principal gained actor IDs: %v", static.ActorIDs)
	}

	// The same workload's real SVID still gets its own, larger scope.
	jwt := signedToken(t, key, map[string]any{"sub": sub, "aud": "signal-ingest", "exp": time.Now().Add(time.Hour).Unix()})
	viaJWT, err := a.Authenticate(bearerRequest(http.MethodGet, "/api/v1/actors", jwt))
	if err != nil {
		t.Fatal(err)
	}
	if !viaJWT.Permissions[PermissionActorList] {
		t.Fatal("JWT binding lost actors:list once the static bearer was enabled")
	}
}

// TestStaticBearerPrincipalMapsAreNotShared proves each call builds fresh
// permission and actor maps, so one request cannot mutate another's scope.
func TestStaticBearerPrincipalMapsAreNotShared(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	cfg := testStaticConfig()
	cfg.ActorIDs = []string{"agent-1"}
	a, err := NewStaticBearerAuthenticator(cfg, delegate)
	if err != nil {
		t.Fatal(err)
	}
	first, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
	if err != nil {
		t.Fatal(err)
	}
	first.Permissions[PermissionActorWrite] = true
	first.ActorIDs["*"] = true

	second, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
	if err != nil {
		t.Fatal(err)
	}
	if second.Permissions[PermissionActorWrite] {
		t.Fatal("permission map shared between requests: a handler widened a later principal's scope")
	}
	if second.ActorIDs["*"] {
		t.Fatal("actor map shared between requests: a handler widened a later principal's actor scope")
	}
}

// --- Token comparison -----------------------------------------------------

// TestStaticBearerRejectsNearMissTokens proves the comparison is exact: no
// prefix, suffix, case or whitespace variant of the token authenticates.
func TestStaticBearerRejectsNearMissTokens(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{
		"sentinel-in-cluster-toke",   // one byte short
		"sentinel-in-cluster-tokenn", // one byte long
		"sentinel-in-cluster-tokem",  // same length, last byte differs
		"Sentinel-In-Cluster-Token",  // case
		"sentinel-in-cluster-token ", // trailing space
		" sentinel-in-cluster-token", // leading space
		"sentinel-in-cluster-token\n",
		"sentinel_in_cluster_token",
		"",
	} {
		t.Run(fmt.Sprintf("%q", token), func(t *testing.T) {
			if _, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", token)); err == nil {
				t.Fatal("near-miss token authenticated")
			}
		})
	}
}

// TestStaticBearerDoesNotRetainPlaintextToken proves the authenticator holds a
// digest, not the secret: a struct dump cannot disclose it, and a naive
// (timing-variable) string comparison is therefore not even possible.
func TestStaticBearerDoesNotRetainPlaintextToken(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	for _, dump := range []string{fmt.Sprintf("%+v", a), fmt.Sprintf("%#v", *a)} {
		if strings.Contains(dump, testSentinelToken) {
			t.Fatalf("authenticator retains the plaintext token: %s", dump)
		}
	}
}

// --- Precedence against the JWT path --------------------------------------

// TestStaticBearerPrecedence defines and pins the precedence rule: an exact
// static-token match wins; every other Authorization header, including a
// malformed JWT and duplicate headers, is handled by the JWT path verbatim.
func TestStaticBearerPrecedence(t *testing.T) {
	delegate, key, sub := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	validJWT := signedToken(t, key, map[string]any{"sub": sub, "aud": "signal-ingest", "exp": time.Now().Add(time.Hour).Unix()})

	t.Run("exact static token wins", func(t *testing.T) {
		p, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
		if err != nil || p.Subject != testStaticSubject {
			t.Fatalf("static token not honoured: principal=%+v err=%v", p, err)
		}
	})
	t.Run("valid JWT still wins its own binding", func(t *testing.T) {
		p, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", validJWT))
		if err != nil || p.Subject != sub {
			t.Fatalf("valid JWT not honoured: principal=%+v err=%v", p, err)
		}
	})
	t.Run("malformed JWT keeps the JWT path verdict", func(t *testing.T) {
		if _, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", "not.a.jwt")); !errors.Is(err, ErrInvalidCredential) {
			t.Fatalf("want ErrInvalidCredential, got %v", err)
		}
	})
	t.Run("no header keeps the JWT path verdict", func(t *testing.T) {
		if _, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", "")); !errors.Is(err, ErrMissingCredential) {
			t.Fatalf("want ErrMissingCredential, got %v", err)
		}
	})
	t.Run("static token does not rescue duplicate headers", func(t *testing.T) {
		r := bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken)
		r.Header.Add("Authorization", "Bearer "+validJWT)
		if _, err := a.Authenticate(r); !errors.Is(err, ErrInvalidCredential) {
			t.Fatalf("duplicate Authorization headers: want ErrInvalidCredential, got %v", err)
		}
	})
	t.Run("static token alongside a malformed JWT does not rescue it", func(t *testing.T) {
		r := bearerRequest(http.MethodPost, "/api/v1/observations", "not.a.jwt")
		r.Header.Add("Authorization", "Bearer "+testSentinelToken)
		if _, err := a.Authenticate(r); !errors.Is(err, ErrInvalidCredential) {
			t.Fatalf("want ErrInvalidCredential, got %v", err)
		}
	})
	t.Run("static token in a non-Bearer scheme is refused", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", nil)
		r.Header.Set("Authorization", "Basic "+testSentinelToken)
		if _, err := a.Authenticate(r); err == nil {
			t.Fatal("non-Bearer scheme accepted the static token")
		}
	})
	t.Run("static token in a custom header is refused", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", nil)
		r.Header.Set("X-Sentinel-Token", testSentinelToken)
		if _, err := a.Authenticate(r); !errors.Is(err, ErrMissingCredential) {
			t.Fatalf("want ErrMissingCredential, got %v", err)
		}
	})
}

// --- Exact status codes through the real router ----------------------------

// TestStaticBearerRouterStatusCodes pins the status code and body for each
// outcome through the production ProtectedRouter.
func TestStaticBearerRouterStatusCodes(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	router, aw := newStaticBearerRouter(t, a)

	t.Run("correct token on a permitted route is 201", func(t *testing.T) {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, observationRequest(testSentinelToken))
		if w.Code != http.StatusCreated {
			t.Fatalf("want 201, got %d body %s", w.Code, w.Body.String())
		}
		assertNoTokenLeak(t, aw, w.Body.String())
	})
	t.Run("wrong token is 401", func(t *testing.T) {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, observationRequest("sentinel-in-cluster-tokem"))
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("want 401, got %d body %s", w.Code, w.Body.String())
		}
		if got := strings.TrimSpace(w.Body.String()); got != `{"error":"authentication_failed"}` {
			t.Fatalf("401 body = %s", got)
		}
		assertNoTokenLeak(t, aw, w.Body.String())
	})
	t.Run("correct token on a route it lacks permission for is 403", func(t *testing.T) {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, bearerRequest(http.MethodGet, "/api/v1/actors", testSentinelToken))
		if w.Code != http.StatusForbidden {
			t.Fatalf("want 403, got %d body %s", w.Code, w.Body.String())
		}
		if got := strings.TrimSpace(w.Body.String()); got != `{"error":"authorization_denied"}` {
			t.Fatalf("403 body = %s", got)
		}
		assertNoTokenLeak(t, aw, w.Body.String())
	})
	t.Run("correct token on an unregistered route is 403", func(t *testing.T) {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, bearerRequest(http.MethodGet, "/api/v1/nonexistent", testSentinelToken))
		if w.Code != http.StatusForbidden {
			t.Fatalf("want 403, got %d body %s", w.Code, w.Body.String())
		}
		if got := strings.TrimSpace(w.Body.String()); got != `{"error":"unregistered_route"}` {
			t.Fatalf("unregistered route body = %s", got)
		}
	})
}

// --- Expiry is structural -------------------------------------------------

// TestStaticBearerRefusedAfterExpiry proves the credential stops working once
// its configured deadline passes, and that the JWT path is untouched by it.
func TestStaticBearerRefusedAfterExpiry(t *testing.T) {
	delegate, key, sub := testJWTDelegate(t)
	cfg := testStaticConfig()
	a, err := NewStaticBearerAuthenticator(cfg, delegate)
	if err != nil {
		t.Fatal(err)
	}
	a.now = func() time.Time { return cfg.ExpiresAt.Add(time.Second) }

	if _, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken)); !errors.Is(err, ErrStaticBearerExpired) {
		t.Fatalf("want ErrStaticBearerExpired after the deadline, got %v", err)
	}
	// A real SVID must still authenticate after the static credential lapses.
	jwt := signedToken(t, key, map[string]any{"sub": sub, "aud": "signal-ingest", "exp": time.Now().Add(time.Hour).Unix()})
	if _, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", jwt)); err != nil {
		t.Fatalf("JWT path broken by static bearer expiry: %v", err)
	}
}

// TestStaticBearerExpiredCredentialIs401 proves the lapsed credential presents
// as an ordinary authentication failure: the same status and the same generic
// body as any other bad credential.
func TestStaticBearerExpiredCredentialIs401(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	cfg := testStaticConfig()
	a, err := NewStaticBearerAuthenticator(cfg, delegate)
	if err != nil {
		t.Fatal(err)
	}
	a.now = func() time.Time { return cfg.ExpiresAt.Add(24 * time.Hour) }
	router, aw := newStaticBearerRouter(t, a)

	w := httptest.NewRecorder()
	router.ServeHTTP(w, observationRequest(testSentinelToken))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expired static bearer: want 401, got %d body %s", w.Code, w.Body.String())
	}
	if got := strings.TrimSpace(w.Body.String()); got != `{"error":"authentication_failed"}` {
		t.Fatalf("expired static bearer body = %s", got)
	}
	assertNoTokenLeak(t, aw, w.Body.String())
}

// TestStaticBearerAcceptedUpToTheDeadline pins the boundary: valid strictly
// before the deadline, refused at and after it.
func TestStaticBearerAcceptedUpToTheDeadline(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	cfg := testStaticConfig()
	a, err := NewStaticBearerAuthenticator(cfg, delegate)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		at     time.Time
		accept bool
	}{
		{"one second before", cfg.ExpiresAt.Add(-time.Second), true},
		{"exactly at the deadline", cfg.ExpiresAt, false},
		{"one second after", cfg.ExpiresAt.Add(time.Second), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			a.now = func() time.Time { return tc.at }
			_, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
			if tc.accept && err != nil {
				t.Fatalf("token refused before its deadline: %v", err)
			}
			if !tc.accept && !errors.Is(err, ErrStaticBearerExpired) {
				t.Fatalf("want ErrStaticBearerExpired, got %v", err)
			}
		})
	}
}

// TestStaticBearerPrincipalCarriesTheDeadline proves the principal's ExpiresAt
// is the credential's configured sunset, so the router's request deadline and
// the credential's lifetime cannot disagree.
func TestStaticBearerPrincipalCarriesTheDeadline(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	cfg := testStaticConfig()
	a, err := NewStaticBearerAuthenticator(cfg, delegate)
	if err != nil {
		t.Fatal(err)
	}
	a.now = func() time.Time { return cfg.ExpiresAt.Add(-time.Hour) }
	p, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
	if err != nil {
		t.Fatal(err)
	}
	if !p.ExpiresAt.Equal(cfg.ExpiresAt) {
		t.Fatalf("principal ExpiresAt = %s, want the configured sunset %s", p.ExpiresAt, cfg.ExpiresAt)
	}
}

// TestStaticBearerSunsetHasNotPassed is a deliberate time bomb. It is the one
// test in this file designed to start failing on its own, and the failure is
// the deliverable: it means the temporary credential has outlived its agreed
// window and must now be removed.
func TestStaticBearerSunsetHasNotPassed(t *testing.T) {
	deadline, err := time.Parse(time.DateOnly, StaticBearerSunset)
	if err != nil {
		t.Fatalf("StaticBearerSunset %q is not a YYYY-MM-DD date: %v", StaticBearerSunset, err)
	}
	if time.Now().UTC().Before(deadline) {
		return
	}
	t.Fatalf(`the signal-ingest static bearer credential expired on %s and must now be removed.

This test is not broken. It is the sunset gate for the temporary shared secret
that lets the stun-sentinel correlator POST observations without a JWT-SVID.

To fix it, do the work the credential was deferring:
  1. Give the correlator a real JWT-SVID. It already runs as
     spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel, which is
     already bound in deploy/jwt-auth-config.yaml with
     ["observations:write","collectors:write"] — so no new binding is needed.
     Replace DefaultBearerToken in
     d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go with a
     token read from the mounted SPIRE JWT-SVID.
  2. Delete the SIGNAL_AUTH_STATIC_BEARER_* keys from
     d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml and the
     signalloom.ai/expires annotation with them.
  3. Delete api/static_bearer.go, this file, and the main.go wiring block.

Do NOT extend StaticBearerSunset to make this pass. Extending it is a decision
for Andy, not for whoever is holding the failing build.`, StaticBearerSunset)
}

// --- The secret never leaks -----------------------------------------------

// TestStaticBearerEnabledWarningOmitsTheToken proves the startup warning names
// the credential's scope and deadline but never its value.
func TestStaticBearerEnabledWarningOmitsTheToken(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	var buf bytes.Buffer
	restore := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(restore) })

	if _, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate); err != nil {
		t.Fatal(err)
	}
	logged := buf.String()
	if strings.Contains(logged, testSentinelToken) {
		t.Fatalf("startup log leaks the token: %s", logged)
	}
	for _, want := range []string{testStaticSubject, StaticBearerSunset} {
		if !strings.Contains(logged, want) {
			t.Errorf("startup log omits %q: %s", want, logged)
		}
	}
}

// TestStaticBearerTokenNeverReachesAuditOrBody sweeps every refusal path
// through the router and asserts the secret appears in no audit record and no
// response body.
func TestStaticBearerTokenNeverReachesAuditOrBody(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(testStaticConfig(), delegate)
	if err != nil {
		t.Fatal(err)
	}
	router, aw := newStaticBearerRouter(t, a)

	var bodies strings.Builder
	for _, r := range []*http.Request{
		observationRequest(testSentinelToken),                                   // accepted
		observationRequest("sentinel-in-cluster-tokem"),                         // 401
		bearerRequest(http.MethodGet, "/api/v1/actors", testSentinelToken),      // 403
		bearerRequest(http.MethodGet, "/api/v1/nonexistent", testSentinelToken), // 403 unregistered
		bearerRequest(http.MethodPost, "/api/v1/observations", ""),              // 401 missing
	} {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		bodies.WriteString(w.Body.String())
	}
	assertNoTokenLeak(t, aw, bodies.String())
	if len(aw.Events()) == 0 {
		t.Fatal("no audit records written; the leak sweep asserted nothing")
	}
}

// --- Helpers --------------------------------------------------------------

func newStaticBearerRouter(t *testing.T, authn Authenticator) (*ProtectedRouter, *audit.FakeWriter) {
	t.Helper()
	aw := audit.NewFakeWriter()
	h, _ := newTestHandlersWithAudit(t, aw)
	router, err := NewProtectedRouter(h, authn, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return router, aw
}

func observationRequest(token string) *http.Request {
	body, _ := json.Marshal([]model.Observation{{
		ID: "static-bearer-1", Layer: model.LayerNetworkEgress, Source: "stun-sentinel",
		Description: "correlated egress", Fidelity: model.FidelitySuggestive,
		Timestamp: time.Now().UTC(), Confidence: 0.5, RawEvidenceRef: "ref",
	}})
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	return r
}

// assertNoTokenLeak fails if the shared secret appears in any audit record or
// in the supplied response bodies.
func assertNoTokenLeak(t *testing.T, aw *audit.FakeWriter, bodies string) {
	t.Helper()
	if strings.Contains(bodies, testSentinelToken) {
		t.Errorf("response body leaks the static bearer token: %s", bodies)
	}
	for i, e := range aw.Events() {
		raw, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(raw), testSentinelToken) {
			t.Errorf("audit record %d leaks the static bearer token: %s", i, raw)
		}
	}
}
