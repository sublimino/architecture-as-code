package api

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair"
)

type staticAuthenticator struct {
	principal Principal
	err       error
}

func (s staticAuthenticator) Authenticate(*http.Request) (Principal, error) {
	return s.principal, s.err
}

func signedToken(t *testing.T, key *ecdsa.PrivateKey, claims map[string]any) string {
	t.Helper()
	return signedTokenWithHeader(t, key, map[string]any{"alg": "ES256", "kid": "test", "typ": "JWT"}, claims)
}

func signedTokenWithHeader(t *testing.T, key *ecdsa.PrivateKey, headers, claims map[string]any) string {
	t.Helper()
	header, _ := json.Marshal(headers)
	payload, _ := json.Marshal(claims)
	enc := base64.RawURLEncoding
	input := enc.EncodeToString(header) + "." + enc.EncodeToString(payload)
	digest := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
	return input + "." + enc.EncodeToString(sig)
}

func TestJWTAuthenticatorHostileCredentials(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	sub := "spiffe://cluster.local/ns/fe-signalloom/sa/dashboard"
	now := time.Now()
	base := map[string]any{"sub": sub, "aud": "signal-ingest", "exp": now.Add(time.Hour).Unix()}
	authn, err := NewJWTAuthenticator(AuthConfig{Audience: "signal-ingest", TrustDomain: "cluster.local", Keys: map[string]any{"test": &key.PublicKey}, Bindings: map[string]PrincipalBinding{sub: {TenantID: "tenant-a", Permissions: []Permission{PermissionHealth}}}})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct{ name, token string }{
		{"missing", ""},
		{"malformed", "not-a-jwt"},
		{"expired", signedToken(t, key, map[string]any{"sub": sub, "aud": "signal-ingest", "exp": now.Add(-time.Hour).Unix()})},
		{"wrong audience", signedToken(t, key, map[string]any{"sub": sub, "aud": "other", "exp": now.Add(time.Hour).Unix()})},
		{"unbound", signedToken(t, key, map[string]any{"sub": "spiffe://cluster.local/ns/x/sa/y", "aud": "signal-ingest", "exp": now.Add(time.Hour).Unix()})},
		{"not before", signedToken(t, key, map[string]any{"sub": sub, "aud": "signal-ingest", "exp": now.Add(time.Hour).Unix(), "nbf": now.Add(time.Minute).Unix()})},
		{"cross domain", signedToken(t, key, map[string]any{"sub": "spiffe://evil.example/ns/x/sa/y", "aud": "signal-ingest", "exp": now.Add(time.Hour).Unix()})},
	}
	valid := signedToken(t, key, base)
	parts := strings.Split(valid, ".")
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sig[0] ^= 1
	tests = append(tests, struct{ name, token string }{"tampered signature", parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(sig)})
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			if _, err := authn.Authenticate(req); err == nil {
				t.Fatal("expected authentication failure")
			}
		})
	}
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	req.Header.Set("Authorization", "Bearer "+valid)
	req.Header.Set("X-Tenant-ID", "attacker-tenant")
	principal, err := authn.Authenticate(req)
	if err != nil || principal.TenantID != "tenant-a" {
		t.Fatalf("trusted binding not applied: principal=%+v err=%v", principal, err)
	}
	req.Header.Add("Authorization", "Bearer "+valid)
	if _, err = authn.Authenticate(req); err == nil {
		t.Fatal("duplicate Authorization headers accepted")
	}
	if _, err = NewJWTAuthenticator(AuthConfig{Audience: "signal-ingest", TrustDomain: "cluster.local", Keys: map[string]any{"test": &key.PublicKey}, Bindings: map[string]PrincipalBinding{"spiffe://evil.example/ns/x/sa/y": {TenantID: "tenant-a"}}}); err == nil {
		t.Fatal("cross-domain binding accepted")
	}
	if _, err = NewJWTAuthenticator(AuthConfig{Audience: "signal-ingest", TrustDomain: "cluster.local", Keys: map[string]any{"test": &key.PublicKey}, Bindings: map[string]PrincipalBinding{"spiffe://attacker@cluster.local/ns/x/sa/y": {TenantID: "tenant-a"}}}); err == nil {
		t.Fatal("SPIFFE binding with userinfo accepted")
	}
	if _, err = NewJWTAuthenticator(AuthConfig{Audience: "signal-ingest", TrustDomain: "cluster.local/path", Keys: map[string]any{"test": &key.PublicKey}, Bindings: map[string]PrincipalBinding{sub: {TenantID: "tenant-a"}}}); err == nil {
		t.Fatal("malformed trust domain accepted")
	}
	crit := signedTokenWithHeader(t, key, map[string]any{"alg": "ES256", "kid": "test", "crit": []string{"unknown"}}, base)
	critReq := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	critReq.Header.Set("Authorization", "Bearer "+crit)
	if _, err = authn.Authenticate(critReq); err == nil {
		t.Fatal("critical JOSE extensions accepted")
	}
}

func TestProtectedRouterDeniesEveryRouteWithoutCredentials(t *testing.T) {
	h, _ := newTestHandlers(t)
	router, err := NewProtectedRouter(h, staticAuthenticator{err: ErrMissingCredential}, h.Audit, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, route := range router.Inventory() {
		path := strings.ReplaceAll(route.Path, "{id}", "actor-1")
		req := httptest.NewRequest(route.Method, path, nil)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: got %d", route.Method, path, w.Code)
		}
	}
}

func TestProtectedRouterPermissionUnknownAndPreflightDenials(t *testing.T) {
	h, _ := newTestHandlers(t)
	p := Principal{Subject: "spiffe://cluster.local/ns/x/sa/y", TenantID: "tenant-a", ExpiresAt: time.Now().Add(time.Hour), Permissions: map[Permission]bool{PermissionHealth: true}}
	router, _ := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	for _, tc := range []struct {
		method, path string
		want         int
	}{{"GET", "/api/v1/actors", 403}, {"GET", "/unknown", 403}, {"OPTIONS", "/healthz", 403}} {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.want {
			t.Errorf("%s %s: got %d want %d", tc.method, tc.path, w.Code, tc.want)
		}
	}
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/another-unknown", nil))
	if w.Code != http.StatusForbidden {
		t.Fatalf("authenticated unknown route got %d", w.Code)
	}
	unbound, _ := NewProtectedRouter(h, staticAuthenticator{principal: Principal{Subject: p.Subject}, err: ErrUnboundPrincipal}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	w = httptest.NewRecorder()
	unbound.ServeHTTP(w, httptest.NewRequest("GET", "/healthz", nil))
	if w.Code != http.StatusForbidden {
		t.Fatalf("unbound verified principal got %d", w.Code)
	}
}

func TestActorReadDoesNotGrantActorEnumeration(t *testing.T) {
	h, _ := newTestHandlers(t)
	p := Principal{Subject: "spiffe://cluster.local/ns/x/sa/y", TenantID: "tenant-a", ExpiresAt: time.Now().Add(time.Hour), Permissions: map[Permission]bool{PermissionActorRead: true}, ActorIDs: map[string]bool{"missing": true}}
	router, _ := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/actors", nil))
	if w.Code != http.StatusForbidden {
		t.Fatalf("actor read unexpectedly granted list: %d", w.Code)
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/authorization", nil))
	if w.Code != http.StatusForbidden {
		t.Fatalf("actor read unexpectedly granted authorization enumeration: %d", w.Code)
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/actors/missing", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("actor read did not reach handler: %d", w.Code)
	}
}

func TestProtectedRouterExportsTenantContext(t *testing.T) {
	h, _ := newTestHandlers(t)
	var received TenantContext
	h.AuditReady = func(ctx context.Context) error {
		received, _ = TenantContextFromContext(ctx)
		return nil
	}
	p := Principal{Subject: "spiffe://cluster.local/ns/x/sa/y", TenantID: "tenant-a", ExpiresAt: time.Now().Add(time.Hour), Permissions: map[Permission]bool{PermissionHealth: true}}
	router, _ := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/readyz", nil))
	if w.Code != 200 {
		t.Fatalf("got %d", w.Code)
	}
	if received.TenantID != "tenant-a" || received.Principal != p.Subject {
		t.Fatal("tenant context unavailable")
	}
}

func TestProtectedRouterSharedEnumerationBudget(t *testing.T) {
	h, _ := newTestHandlers(t)
	p := Principal{Subject: "spiffe://cluster.local/ns/x/sa/y", TenantID: "tenant-a", ExpiresAt: time.Now().Add(time.Hour), Permissions: map[Permission]bool{PermissionActorList: true, PermissionObservationRead: true}}
	router, _ := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{DefaultPageSize: 2, MaxPageSize: 3, PrincipalBudget: 3, BudgetWindow: time.Hour})
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/actors?limit=2", nil))
	if w.Code != 200 {
		t.Fatalf("first got %d", w.Code)
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/observations?limit=2", nil))
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("budget got %d", w.Code)
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/actors?limit=4", nil))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("max got %d", w.Code)
	}
}

func TestProtectedRouterSSEExpiresAndPreservesFlusher(t *testing.T) {
	h, _ := newTestHandlers(t)
	p := Principal{Subject: "spiffe://cluster.local/ns/x/sa/y", TenantID: "tenant-a", ExpiresAt: time.Now().Add(60 * time.Millisecond), Permissions: map[Permission]bool{PermissionStream: true}}
	router, _ := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/stream", nil))
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("SSE did not close at credential expiry")
	}
	events := h.Audit.(*audit.FakeWriter).Events()
	if len(events) != 1 || !strings.Contains(string(events[0].Detail), "credential_expired") {
		t.Fatalf("missing SSE expiry audit: %+v", events)
	}
}

func TestProtectedRouterFailsClosedWhenDenialAuditFails(t *testing.T) {
	h, _ := newTestHandlers(t)
	failed := audit.NewFakeWriter()
	router, _ := NewProtectedRouter(h, staticAuthenticator{err: ErrMissingCredential}, failed, http.NotFoundHandler(), RouterOptions{})
	failed.FailWith = errors.New("database unavailable")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/healthz", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("got %d", w.Code)
	}
}

func TestAuthenticationAuditIsPseudonymousAndExcludesCredential(t *testing.T) {
	h, _ := newTestHandlers(t)
	fake := audit.NewFakeWriter()
	router, _ := NewProtectedRouter(h, staticAuthenticator{err: ErrInvalidCredential}, fake, http.NotFoundHandler(), RouterOptions{})
	req := httptest.NewRequest("GET", "/secret/super-secret-token", nil)
	req.Header.Set("Authorization", "Bearer super-secret-token")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	events := fake.Events()
	if len(events) != 1 {
		t.Fatalf("events=%d", len(events))
	}
	detail := string(events[0].Detail)
	if strings.Contains(detail, "super-secret-token") || !strings.Contains(detail, "principal_pseudonym") || !strings.Contains(detail, "authentication_failed") || !strings.Contains(detail, `"route":"unmatched"`) || !strings.Contains(detail, `"method":"UNMATCHED"`) {
		t.Fatalf("unsafe audit detail: %s", detail)
	}
}

func TestAuthenticationFailureAuditUsesRegisteredRouteTemplate(t *testing.T) {
	h, _ := newTestHandlers(t)
	fake := audit.NewFakeWriter()
	router, _ := NewProtectedRouter(h, staticAuthenticator{err: ErrMissingCredential}, fake, http.NotFoundHandler(), RouterOptions{})
	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/v1/actors/secret-actor", nil))
	events := fake.Events()
	if len(events) != 1 {
		t.Fatalf("events=%d", len(events))
	}
	detail := string(events[0].Detail)
	if !strings.Contains(detail, `"route":"/api/v1/actors/{id}"`) || !strings.Contains(detail, `"method":"GET"`) || strings.Contains(detail, "secret-actor") {
		t.Fatalf("authentication audit did not use safe registered route: %s", detail)
	}
}

func TestRealJWTAuthenticatorProtectedRouterHTTPBoundary(t *testing.T) {
	h, _ := newTestHandlers(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subject := "spiffe://cluster.local/ns/fe-signalloom/sa/dashboard"
	authn, err := NewJWTAuthenticator(AuthConfig{
		Audience:    "signal-ingest",
		TrustDomain: "cluster.local",
		Keys:        map[string]any{"test": &key.PublicKey},
		Bindings: map[string]PrincipalBinding{subject: {
			TenantID:    "tenant-trusted",
			Permissions: []Permission{PermissionHealth},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	router, err := NewProtectedRouter(h, authn, h.Audit, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	claims := func(subject string, expiry time.Time) map[string]any {
		return map[string]any{"sub": subject, "aud": "signal-ingest", "exp": expiry.Unix()}
	}
	tests := []struct {
		name, token string
		want        int
	}{
		{"missing", "", http.StatusUnauthorized},
		{"malformed", "not-a-jwt", http.StatusUnauthorized},
		{"expired", signedToken(t, key, claims(subject, now.Add(-time.Hour))), http.StatusUnauthorized},
		{"wrong domain", signedToken(t, key, claims("spiffe://evil.example/ns/x/sa/y", now.Add(time.Hour))), http.StatusUnauthorized},
		{"unbound", signedToken(t, key, claims("spiffe://cluster.local/ns/x/sa/unbound", now.Add(time.Hour))), http.StatusForbidden},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)
			if w.Code != tc.want {
				t.Fatalf("status=%d want=%d body=%s", w.Code, tc.want, w.Body.String())
			}
		})
	}

	valid := signedToken(t, key, claims(subject, now.Add(time.Hour)))
	healthRequest := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	healthRequest.Header.Set("Authorization", "Bearer "+valid)
	healthResponse := httptest.NewRecorder()
	router.ServeHTTP(healthResponse, healthRequest)
	if healthResponse.Code != http.StatusOK {
		t.Fatalf("valid health status=%d body=%s", healthResponse.Code, healthResponse.Body.String())
	}
	var received TenantContext
	h.AuditReady = func(ctx context.Context) error {
		received, _ = TenantContextFromContext(ctx)
		return nil
	}
	readyRequest := httptest.NewRequest(http.MethodGet, "/readyz?tenant_id=tenant-attacker", nil)
	readyRequest.Header.Set("Authorization", "Bearer "+valid)
	readyRequest.Header.Set("X-Tenant-ID", "tenant-attacker")
	readyResponse := httptest.NewRecorder()
	router.ServeHTTP(readyResponse, readyRequest)
	if readyResponse.Code != http.StatusOK || received.TenantID != "tenant-trusted" || received.Principal != subject {
		t.Fatalf("trusted tenant context not enforced: status=%d context=%+v", readyResponse.Code, received)
	}
}

func TestRealHTTPServerSSEClosesAtJWTExpiry(t *testing.T) {
	h, _ := newTestHandlers(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subject := "spiffe://cluster.local/ns/fe-signalloom/sa/dashboard"
	authn, err := NewJWTAuthenticator(AuthConfig{Audience: "signal-ingest", TrustDomain: "cluster.local", Keys: map[string]any{"test": &key.PublicKey}, Bindings: map[string]PrincipalBinding{subject: {TenantID: "tenant-a", Permissions: []Permission{PermissionStream}}}})
	if err != nil {
		t.Fatal(err)
	}
	router, err := NewProtectedRouter(h, authn, h.Audit, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	server := tryNewHTTPTestServer(router)
	if server == nil {
		t.Skip("loopback sockets unavailable")
	}
	defer server.Close()

	expires := time.Now().Add(2 * time.Second)
	token := signedToken(t, key, map[string]any{"sub": subject, "aud": "signal-ingest", "exp": expires.Unix()})
	clientCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(clientCtx, http.MethodGet, server.URL+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	reader := bufio.NewReader(resp.Body)
	line, err := reader.ReadString('\n')
	if err != nil || line != "event: connected\n" {
		t.Fatalf("stream not established: line=%q err=%v", line, err)
	}
	if _, err = io.ReadAll(reader); err != nil && clientCtx.Err() != nil {
		t.Fatalf("stream ended only at client timeout: %v", err)
	}
	if clientCtx.Err() != nil {
		t.Fatal("stream remained open past credential expiry")
	}
	events := h.Audit.(*audit.FakeWriter).Events()
	if len(events) != 1 || !strings.Contains(string(events[0].Detail), "credential_expired") {
		t.Fatalf("missing real-stream expiry audit: %+v", events)
	}
}

func tryNewHTTPTestServer(handler http.Handler) (server *httptest.Server) {
	defer func() {
		if recover() != nil {
			server = nil
		}
	}()
	return httptest.NewServer(handler)
}

func TestNakedMuxNegativeControlDetectsMissingAuthenticationMiddleware(t *testing.T) {
	h, naked := newTestHandlers(t)
	nakedResponse := httptest.NewRecorder()
	naked.ServeHTTP(nakedResponse, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if nakedResponse.Code != http.StatusOK {
		t.Fatalf("test-only old behavior changed: status=%d", nakedResponse.Code)
	}
	protected, err := NewProtectedRouter(h, staticAuthenticator{err: ErrMissingCredential}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	protectedResponse := httptest.NewRecorder()
	protected.ServeHTTP(protectedResponse, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if protectedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("protected route did not detect missing middleware: status=%d", protectedResponse.Code)
	}
}

func TestRouterRejectsInvalidOptionsAndRedirectBypass(t *testing.T) {
	h, _ := newTestHandlers(t)
	if _, err := NewProtectedRouter(h, staticAuthenticator{}, h.Audit, http.NotFoundHandler(), RouterOptions{DefaultPageSize: 3, MaxPageSize: 2}); err == nil {
		t.Fatal("invalid page options accepted")
	}
	router, _ := NewProtectedRouter(h, staticAuthenticator{err: ErrMissingCredential}, h.Audit, http.NotFoundHandler(), RouterOptions{})
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/healthz/../healthz", nil))
	if w.Code != http.StatusUnauthorized || w.Header().Get("Location") != "" {
		t.Fatalf("redirect bypass: status=%d location=%q", w.Code, w.Header().Get("Location"))
	}
}

func TestJWKSRejectsWeakRSAAndDuplicateKids(t *testing.T) {
	weak, _ := rsa.GenerateKey(rand.Reader, 1024)
	enc := base64.RawURLEncoding
	n := enc.EncodeToString(weak.N.Bytes())
	e := enc.EncodeToString(big.NewInt(int64(weak.E)).Bytes())
	if _, err := parseJWKS(fmt.Sprintf(`{"keys":[{"kty":"RSA","kid":"weak","n":"%s","e":"%s"}]}`, n, e)); err == nil {
		t.Fatal("weak RSA accepted")
	}
	strong, _ := rsa.GenerateKey(rand.Reader, 2048)
	evenExponent := enc.EncodeToString(big.NewInt(4).Bytes())
	if _, err := parseJWKS(fmt.Sprintf(`{"keys":[{"kty":"RSA","kid":"even","n":"%s","e":"%s"}]}`, enc.EncodeToString(strong.N.Bytes()), evenExponent)); err == nil {
		t.Fatal("even RSA exponent accepted")
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	x := enc.EncodeToString(key.X.Bytes())
	y := enc.EncodeToString(key.Y.Bytes())
	if _, err := parseJWKS(fmt.Sprintf(`{"keys":[{"kty":"EC","kid":"dup","crv":"P-256","x":"%s","y":"%s"},{"kty":"EC","kid":"dup","crv":"P-256","x":"%s","y":"%s"}]}`, x, y, x, y)); err == nil {
		t.Fatal("duplicate kid accepted")
	}
}

func TestJWTPartsRejectDuplicateKeysAndTrailingJSON(t *testing.T) {
	enc := base64.RawURLEncoding
	for _, raw := range []string{`{"sub":"a","sub":"b"}`, `{"sub":"a"} {}`} {
		var out map[string]any
		if err := decodeJWTPart(enc.EncodeToString([]byte(raw)), &out); err == nil {
			t.Fatalf("accepted non-strict JSON: %s", raw)
		}
	}
}

func TestAuthConfigFromEnvFailsClosedWhenMissing(t *testing.T) {
	t.Setenv("SIGNAL_AUTH_AUDIENCE", "")
	t.Setenv("SIGNAL_AUTH_TRUST_DOMAIN", "")
	t.Setenv("SIGNAL_AUTH_JWKS", "")
	t.Setenv("SIGNAL_AUTH_BINDINGS", "")
	if _, err := AuthConfigFromEnv(); err == nil {
		t.Fatal("missing auth config accepted")
	}
}

func TestEnumerationLimitCapsActualResponses(t *testing.T) {
	h, _ := newTestHandlers(t)
	for i := 0; i < 6; i++ {
		_, err := h.Engine.Resolve(model.Observation{ID: fmt.Sprintf("card-%d", i), Timestamp: time.Now().Add(time.Duration(i) * time.Second), Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: fmt.Sprintf("source-%d", i), Confidence: .2})
		if err != nil {
			t.Fatal(err)
		}
	}
	h.FairService = fair.NewService(fair.NewFixtureSource(10))
	p := Principal{Subject: "spiffe://cluster.local/ns/x/sa/y", TenantID: "tenant-a", ExpiresAt: time.Now().Add(time.Hour), Permissions: map[Permission]bool{PermissionActorList: true, PermissionAnalysisRun: true, PermissionRiskRead: true}}
	router, err := NewProtectedRouter(h, staticAuthenticator{principal: p}, h.Audit, http.NotFoundHandler(), RouterOptions{DefaultPageSize: 2, MaxPageSize: 3, PrincipalBudget: 20})
	if err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/authorization?limit=2", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("authorization status=%d body=%s", w.Code, w.Body.String())
	}
	var authz AuthorizationQueryResponse
	if err := json.Unmarshal(w.Body.Bytes(), &authz); err != nil {
		t.Fatal(err)
	}
	if len(authz.Chains) > 2 {
		t.Fatalf("authorization chains=%d", len(authz.Chains))
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/actors", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("actors status=%d body=%s", w.Code, w.Body.String())
	}
	var listedActors []json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &listedActors); err != nil {
		t.Fatal(err)
	}
	if len(listedActors) > 2 {
		t.Fatalf("default actor page size not enforced: actors=%d", len(listedActors))
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/correlate?limit=2", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("correlate status=%d body=%s", w.Code, w.Body.String())
	}
	var correlate struct {
		Actors []json.RawMessage `json:"actors"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &correlate); err != nil {
		t.Fatal(err)
	}
	if len(correlate.Actors) > 2 {
		t.Fatalf("correlate actors=%d", len(correlate.Actors))
	}
	for _, path := range []string{"/api/v1/risk/fleet?limit=2", "/v1/risk/fleet?limit=2"} {
		w = httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", path, w.Code, w.Body.String())
		}
		var fleet struct {
			Top []json.RawMessage `json:"topAgents"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &fleet); err != nil {
			t.Fatal(err)
		}
		if len(fleet.Top) > 2 {
			t.Fatalf("%s topAgents=%d", path, len(fleet.Top))
		}
	}
}
