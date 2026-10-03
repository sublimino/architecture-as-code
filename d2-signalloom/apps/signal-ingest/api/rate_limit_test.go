package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

func newRateLimitRouter(t *testing.T, authn Authenticator, aw audit.AuditWriter, opts RouterOptions, now func() time.Time) *ProtectedRouter {
	t.Helper()
	h, _ := newTestHandlersWithAudit(t, aw)
	router, err := NewProtectedRouter(h, authn, aw, http.NotFoundHandler(), opts)
	if err != nil {
		t.Fatal(err)
	}
	if now != nil {
		router.now = now
	}
	return router
}

func TestRateLimitFloodFromOneKeyDoesNotStarveAnother(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken
	tokenB := testGatewayToken

	cfgs := []StaticBearerConfig{
		{
			Name:        "key-a",
			Token:       tokenA,
			Subject:     "static-key/key-a",
			TenantID:    "kusari",
			Permissions: []Permission{PermissionObservationWrite},
			ExpiresAt:   time.Now().Add(30 * 24 * time.Hour),
		},
		{
			Name:        "key-b",
			Token:       tokenB,
			Subject:     "static-key/key-b",
			TenantID:    "kusari",
			Permissions: []Permission{PermissionObservationWrite},
			ExpiresAt:   time.Now().Add(30 * 24 * time.Hour),
		},
	}

	authn, err := NewStaticKeyAuthenticator(cfgs, delegate)
	if err != nil {
		t.Fatal(err)
	}

	currentTime := time.Now()
	nowFn := func() time.Time { return currentTime }

	burst := 5
	rate := 10.0 // 10 req/s

	aw := audit.NewFakeWriter()
	router := newRateLimitRouter(t, authn, aw, RouterOptions{
		KeyRatePerSecond: rate,
		KeyBurst:         burst,
	}, nowFn)

	// Key A sends burst (5) + 5 = 10 requests immediately at currentTime
	count201 := 0
	count429 := 0
	for i := 0; i < 10; i++ {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, observationRequest(tokenA))
		if w.Code == http.StatusCreated {
			count201++
		} else if w.Code == http.StatusTooManyRequests {
			count429++
		} else {
			t.Fatalf("key A request %d unexpected status: %d body=%s", i, w.Code, w.Body.String())
		}
	}

	if count201 != burst {
		t.Fatalf("key A accepted %d requests, want burst=%d", count201, burst)
	}
	if count429 != 5 {
		t.Fatalf("key A rate limited %d requests, want 5", count429)
	}

	// Interleaved: Key B sends a single request in the middle of Key A's flood at the exact same time
	wB := httptest.NewRecorder()
	router.ServeHTTP(wB, observationRequest(tokenB))
	if wB.Code != http.StatusCreated {
		t.Fatalf("key B starved by key A flood: code=%d body=%s", wB.Code, wB.Body.String())
	}
}

func TestRateLimit429CarriesRetryAfter(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken

	cfgs := []StaticBearerConfig{
		{
			Name:        "key-a",
			Token:       tokenA,
			Subject:     "static-key/key-a",
			TenantID:    "kusari",
			Permissions: []Permission{PermissionObservationWrite},
			ExpiresAt:   time.Now().Add(30 * 24 * time.Hour),
		},
	}

	authn, err := NewStaticKeyAuthenticator(cfgs, delegate)
	if err != nil {
		t.Fatal(err)
	}

	currentTime := time.Now()
	nowFn := func() time.Time { return currentTime }

	burst := 1
	rate := 1.0 // 1 req/s -> 1 token takes 1s to refill

	aw := audit.NewFakeWriter()
	router := newRateLimitRouter(t, authn, aw, RouterOptions{
		KeyRatePerSecond: rate,
		KeyBurst:         burst,
	}, nowFn)

	// First request succeeds
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, observationRequest(tokenA))
	if w1.Code != http.StatusCreated {
		t.Fatalf("req 1 failed: %d", w1.Code)
	}

	// Second request is rate limited
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, observationRequest(tokenA))
	if w2.Code != http.StatusTooManyRequests {
		t.Fatalf("req 2 expected 429, got %d", w2.Code)
	}

	retryAfterHeader := w2.Header().Get("Retry-After")
	if retryAfterHeader == "" {
		t.Fatal("429 response missing Retry-After header")
	}

	retrySeconds, err := strconv.Atoi(retryAfterHeader)
	if err != nil {
		t.Fatalf("Retry-After is not an integer: %q", retryAfterHeader)
	}
	if retrySeconds < 1 {
		t.Fatalf("Retry-After must be at least 1 second, got %d", retrySeconds)
	}
}

func TestRateLimitCountsOnlyAuthenticatedRequests(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken

	cfgs := []StaticBearerConfig{
		{
			Name:        "key-a",
			Token:       tokenA,
			Subject:     "static-key/key-a",
			TenantID:    "kusari",
			Permissions: []Permission{PermissionObservationWrite},
			ExpiresAt:   time.Now().Add(30 * 24 * time.Hour),
		},
	}

	authn, err := NewStaticKeyAuthenticator(cfgs, delegate)
	if err != nil {
		t.Fatal(err)
	}

	currentTime := time.Now()
	nowFn := func() time.Time { return currentTime }

	burst := 3
	rate := 1.0

	aw := audit.NewFakeWriter()
	router := newRateLimitRouter(t, authn, aw, RouterOptions{
		KeyRatePerSecond: rate,
		KeyBurst:         burst,
	}, nowFn)

	// Send 50 unauthenticated requests
	for i := 0; i < 50; i++ {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, observationRequest("invalid-or-missing-token-12345678901234567890"))
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("unauthenticated req %d got %d, want 401", i, w.Code)
		}
	}

	// Key A sends its burst of 3 requests -> ALL MUST SUCCEED with 201
	for i := 0; i < burst; i++ {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, observationRequest(tokenA))
		if w.Code != http.StatusCreated {
			t.Fatalf("key A request %d failed with %d (was bucket drained by unauth flood?): %s", i, w.Code, w.Body.String())
		}
	}
}

func TestRateLimitBucketIsPerKeyName(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA1 := testSentinelToken
	tokenA2 := "RotatedTokenForSameKeyName1234567890"

	proj := newProjectedDir(t, map[string]string{
		"stun-sentinel":                        tokenA1,
		"stun-sentinel" + StaticKeyExpirySuffix: testKeyExpiry(),
	})

	specs := []StaticKeySpec{
		{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatal(err)
	}

	currentTime := time.Now()
	nowFn := func() time.Time { return currentTime }

	burst := 2
	rate := 1.0

	aw := audit.NewFakeWriter()
	router := newRateLimitRouter(t, authn, aw, RouterOptions{
		KeyRatePerSecond: rate,
		KeyBurst:         burst,
	}, nowFn)

	// 1st request with tokenA1 consumes 1 token
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, observationRequest(tokenA1))
	if w1.Code != http.StatusCreated {
		t.Fatalf("w1 code: %d", w1.Code)
	}

	// 2nd request with tokenA1 consumes 2nd token (bucket now empty)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, observationRequest(tokenA1))
	if w2.Code != http.StatusCreated {
		t.Fatalf("w2 code: %d", w2.Code)
	}

	// Rotate key to tokenA2 under the SAME key name / subject
	proj.swap(t, map[string]string{
		"stun-sentinel":                        tokenA2,
		"stun-sentinel" + StaticKeyExpirySuffix: testKeyExpiry(),
	})
	authn.Reload(currentTime)

	// 3rd request with tokenA2 (bucket was already drained by tokenA1) -> MUST 429
	w3 := httptest.NewRecorder()
	router.ServeHTTP(w3, observationRequest(tokenA2))
	if w3.Code != http.StatusTooManyRequests {
		t.Fatalf("tokenA2 after rotation was not rate limited (different bucket?): code=%d", w3.Code)
	}
}

func TestRateLimitConfigRefusesNonPositive(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	aw := audit.NewFakeWriter()
	h, _ := newTestHandlersWithAudit(t, aw)

	for _, tc := range []struct {
		name  string
		rate  float64
		burst int
	}{
		{"negative rate", -1.0, 10},
		{"negative burst", 10.0, -5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := NewProtectedRouter(h, delegate, aw, http.NotFoundHandler(), RouterOptions{
				KeyRatePerSecond: tc.rate,
				KeyBurst:         tc.burst,
			})
			if err == nil {
				t.Fatalf("%s accepted, want error", tc.name)
			}
		})
	}
}

func TestRateLimitAuditFirstRefusalPerMinute(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken

	cfgs := []StaticBearerConfig{
		{
			Name:        "key-a",
			Token:       tokenA,
			Subject:     "static-key/key-a",
			TenantID:    "kusari",
			Permissions: []Permission{PermissionObservationWrite},
			ExpiresAt:   time.Now().Add(30 * 24 * time.Hour),
		},
	}

	authn, err := NewStaticKeyAuthenticator(cfgs, delegate)
	if err != nil {
		t.Fatal(err)
	}

	currentTime := time.Now()
	nowFn := func() time.Time { return currentTime }

	aw := audit.NewFakeWriter()
	router := newRateLimitRouter(t, authn, aw, RouterOptions{
		KeyRatePerSecond: 1.0,
		KeyBurst:         1,
	}, nowFn)

	// 1st request -> 201 (exhausts burst of 1)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, observationRequest(tokenA))
	if w1.Code != http.StatusCreated {
		t.Fatalf("req 1 failed: %d", w1.Code)
	}

	initialAuditCount := len(aw.Events())

	// 2nd request -> 429 (1st refusal in minute -> MUST write audit)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, observationRequest(tokenA))
	if w2.Code != http.StatusTooManyRequests {
		t.Fatalf("req 2 expected 429, got %d", w2.Code)
	}

	if len(aw.Events()) != initialAuditCount+1 {
		t.Fatalf("first 429 did not write audit event: count=%d, want %d", len(aw.Events()), initialAuditCount+1)
	}

	// 3rd request -> 429 (2nd refusal in same minute -> MUST NOT write audit)
	w3 := httptest.NewRecorder()
	router.ServeHTTP(w3, observationRequest(tokenA))
	if w3.Code != http.StatusTooManyRequests {
		t.Fatalf("req 3 expected 429, got %d", w3.Code)
	}

	if len(aw.Events()) != initialAuditCount+1 {
		t.Fatalf("subsequent 429 in same minute wrote audit event (flood amplification): count=%d, want %d", len(aw.Events()), initialAuditCount+1)
	}

	// Advance time by 61 seconds
	currentTime = currentTime.Add(61 * time.Second)

	// 4th request -> 429 (first refusal in new minute -> MUST write audit)
	// (note: 61s elapsed at 1 token/s refilled 1 token, so 4th request consumes it and 5th request 429s)
	w4 := httptest.NewRecorder()
	router.ServeHTTP(w4, observationRequest(tokenA))
	if w4.Code != http.StatusCreated {
		t.Fatalf("req 4 expected 201 after refill, got %d", w4.Code)
	}

	w5 := httptest.NewRecorder()
	router.ServeHTTP(w5, observationRequest(tokenA))
	if w5.Code != http.StatusTooManyRequests {
		t.Fatalf("req 5 expected 429, got %d", w5.Code)
	}

	if len(aw.Events()) != initialAuditCount+2 {
		t.Fatalf("first 429 in new minute did not write audit: count=%d, want %d", len(aw.Events()), initialAuditCount+2)
	}
}

type failingAuditWriter struct{}

func (failingAuditWriter) WriteAuditEvent(ctx context.Context, e audit.Event) error {
	return errors.New("audit store is down")
}
func (failingAuditWriter) Close() error { return nil }

func TestRateLimitAuditDownYields503(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken

	cfgs := []StaticBearerConfig{
		{
			Name:        "key-a",
			Token:       tokenA,
			Subject:     "static-key/key-a",
			TenantID:    "kusari",
			Permissions: []Permission{PermissionObservationWrite},
			ExpiresAt:   time.Now().Add(30 * 24 * time.Hour),
		},
	}

	authn, err := NewStaticKeyAuthenticator(cfgs, delegate)
	if err != nil {
		t.Fatal(err)
	}

	currentTime := time.Now()
	nowFn := func() time.Time { return currentTime }

	h, _ := newTestHandlersWithAudit(t, failingAuditWriter{})
	router, err := NewProtectedRouter(h, authn, failingAuditWriter{}, http.NotFoundHandler(), RouterOptions{
		KeyRatePerSecond: 1.0,
		KeyBurst:         1,
	})
	if err != nil {
		t.Fatal(err)
	}
	router.now = nowFn

	// Request 1 succeeds (201)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, observationRequest(tokenA))
	if w1.Code != http.StatusCreated {
		t.Fatalf("req 1 failed: %d", w1.Code)
	}

	// Request 2 hits rate limit. First refusal needs audit, audit fails -> MUST 503
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, observationRequest(tokenA))
	if w2.Code != http.StatusServiceUnavailable {
		t.Fatalf("rate limit with audit down must be 503, got %d body=%s", w2.Code, w2.Body.String())
	}
}
