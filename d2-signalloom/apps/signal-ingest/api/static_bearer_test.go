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
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// A token of the shape scripts/sldc-ingest-bearer.sh generates (32 random bytes,
// base64url). The value on the wire is no longer a literal in the correlator's
// source: it is minted at bootstrap into Secret signal-ingest-static-bearer and
// its twin stun-sentinel-ingest-token, and never committed.
const testSentinelToken = "qV3x9Lw2pN7cR1tY8kD4hF6jS0aZ5mE2uB7oG3iX1wQ"

// retiredPublicToken was DefaultBearerToken in the correlator's source, so it is
// in git and in every image ever built. It must never authenticate again.
const retiredPublicToken = "sentinel-in-cluster-token"

const testStaticSubject = "static-bearer/stun-sentinel-correlator"

func testStaticConfig() StaticBearerConfig {
	return StaticBearerConfig{
		Name:        "stun-sentinel",
		Token:       testSentinelToken,
		Subject:     testStaticSubject,
		TenantID:    "kusari",
		Permissions: []Permission{PermissionObservationWrite, PermissionCollectorWrite},
		ExpiresAt:   time.Now().UTC().Add(30 * 24 * time.Hour).Truncate(24 * time.Hour),
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
		{name: "31-byte token", mutate: func(c *StaticBearerConfig) { c.Token = strings.Repeat("k", 31) }}, {name: "no subject", mutate: func(c *StaticBearerConfig) { c.Subject = "" }},
		{name: "no name", mutate: func(c *StaticBearerConfig) { c.Name = "" }},
		{name: "name with a path separator", mutate: func(c *StaticBearerConfig) { c.Name = "../stun-sentinel" }},
		{name: "upper-case name", mutate: func(c *StaticBearerConfig) { c.Name = "Stun-Sentinel" }},
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
	tok := testSentinelToken
	for _, token := range []string{
		tok[:len(tok)-1],       // one byte short
		tok + "Q",              // one byte long
		tok[:len(tok)-1] + "R", // same length, last byte differs
		strings.ToLower(tok),   // case
		tok + " ",              // trailing space
		" " + tok,              // leading space
		tok + "\n",
		strings.ReplaceAll(tok, "x", "_"),
		retiredPublicToken, // the old public literal no longer opens anything
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
		router.ServeHTTP(w, observationRequest(testSentinelToken[:len(testSentinelToken)-1]+"R"))
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

// Review M3, carried into the per-key lifetime (Andy/lead 2026-10-02): the deadline is enforced by
// the binary, not only by whatever a Secret says. No key may be valid for more than
// MaxStaticKeyLifetime from now, so an issued key cannot be made effectively permanent, and the
// fixed global sunset that would have 401'd every caller on one day is gone.
func TestStaticKeyLifetimeIsBoundedByTheBinary(t *testing.T) {
	cfg := testStaticConfig()
	cfg.ExpiresAt = time.Now().Add(MaxStaticKeyLifetime + 24*time.Hour)
	if err := cfg.validate(); err == nil || !strings.Contains(err.Error(), "90 days") {
		t.Fatalf("validate() = %v, want a refusal naming the 90-day lifetime", err)
	}
	cfg.ExpiresAt = time.Now().Add(MaxStaticKeyLifetime - 24*time.Hour)
	if err := cfg.validate(); err != nil {
		t.Fatalf("an expiry inside the lifetime must be accepted: %v", err)
	}
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
	for _, want := range []string{testStaticSubject, testStaticConfig().ExpiresAt.Format(time.DateOnly)} {
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
		observationRequest(testSentinelToken[:len(testSentinelToken)-1] + "R"),  // 401
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

// TestStaticBearerIngestsTheSentinelsRealPayloads drives the correlator's golden
// wire payload through the real router with the static credential, both as
// attributed (tenant_id kusari) and as the sentinel posts an unmapped workload
// (tenant_id identity.QuarantineTenant). Observation tenancy is a label, not a
// claim bound to the principal, so the quarantine marker must land rather than
// be refused by the tenant gate meant for principals.
func TestStaticBearerIngestsTheSentinelsRealPayloads(t *testing.T) {
	raw, err := os.ReadFile("../../stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json")
	if err != nil {
		t.Fatal(err)
	}
	delegate, _, _ := testJWTDelegate(t)
	cfg := testStaticConfig()
	// The sentinel watches every workload, so its key carries the cross-tenant write grant.
	cfg.Permissions = append(cfg.Permissions, PermissionCrossTenantWrite)
	a, err := NewStaticBearerAuthenticator(cfg, delegate)
	if err != nil {
		t.Fatal(err)
	}
	for _, tenant := range []string{"kusari", identity.QuarantineTenant} {
		t.Run(tenant, func(t *testing.T) {
			var batch []map[string]any
			if err := json.Unmarshal(raw, &batch); err != nil {
				t.Fatal(err)
			}
			for _, o := range batch {
				o["labels"].(map[string]any)["tenant_id"] = tenant
			}
			body, _ := json.Marshal(batch)
			router, _ := newStaticBearerRouter(t, a)
			r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
			r.Header.Set("Authorization", "Bearer "+testSentinelToken)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, r)
			want := fmt.Sprintf(`{"ingested":%d}`, len(batch))
			if w.Code != http.StatusCreated || strings.TrimSpace(w.Body.String()) != want {
				t.Fatalf("sentinel payload with tenant_id %q: %d %s, want 201 %s", tenant, w.Code, w.Body.String(), want)
			}
		})
	}
}
