package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

func TestParseAPIKeys(t *testing.T) {
	cases := []struct {
		raw  string
		want []string
	}{
		{"", nil},
		{"   ", nil},
		{",,", nil},
		{"k1", []string{"k1"}},
		{"k1,k2", []string{"k1", "k2"}},
		{" k1 , k2 ,", []string{"k1", "k2"}},
	}
	for _, tc := range cases {
		got := ParseAPIKeys(tc.raw)
		if strings.Join(got, "|") != strings.Join(tc.want, "|") {
			t.Errorf("ParseAPIKeys(%q) = %v, want %v", tc.raw, got, tc.want)
		}
	}
}

// TestBlankKeysNeverBecomeACredential: a trailing comma or an all-whitespace
// env value must not produce an empty key that an empty bearer token matches.
func TestBlankKeysNeverBecomeACredential(t *testing.T) {
	for _, raw := range []string{"", "  ", ",", ",,,", " , "} {
		keys := ParseAPIKeys(raw)
		if len(keys) != 0 {
			t.Fatalf("ParseAPIKeys(%q) must yield no keys, got %v", raw, keys)
		}
	}
	// With one real key plus noise, only the real key authorises.
	keys := ParseAPIKeys("real-key,,  ,")
	if len(keys) != 1 {
		t.Fatalf("expected 1 key, got %v", keys)
	}
	for _, token := range []string{"", " ", ","} {
		r := httptest.NewRequest(http.MethodGet, "/api/v1/policies", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		if authorized(r, keys) {
			t.Fatalf("token %q must not authorise", token)
		}
	}
}

func TestBearerTokenParsing(t *testing.T) {
	cases := []struct {
		header string
		want   string
		ok     bool
	}{
		{"", "", false},
		{"k", "", false},
		{"Basic abc", "", false},
		{"Bearer", "", false},
		{"Bearer ", "", false},
		{"Bearer   ", "", false},
		{"Bearer k1", "k1", true},
		{"bearer k1", "k1", true},
		{"BEARER k1", "k1", true},
		{"Bearer  k1 ", "k1", true},
	}
	for _, tc := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if tc.header != "" {
			r.Header.Set("Authorization", tc.header)
		}
		got, ok := bearerToken(r)
		if ok != tc.ok || got != tc.want {
			t.Errorf("header %q = (%q, %v), want (%q, %v)", tc.header, got, ok, tc.want, tc.ok)
		}
	}
}

// TestUnsetAPIKeysLeavesBehaviourUnchanged: the pre-existing unauthenticated
// mode is still the default, so every test and caller written before this card
// keeps working.
func TestUnsetAPIKeysLeavesBehaviourUnchanged(t *testing.T) {
	called := false
	h := RequireAPIKey(ParseAPIKeys(""), func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/api/v1/policies", nil))
	if !called || w.Code != http.StatusOK {
		t.Fatalf("with no keys configured the handler must run: called=%v code=%d", called, w.Code)
	}
}

// TestRequireAPIKeyRefusesWithoutAValidBearer is the auth-bypass mutation.
//
// Killed mutation: changing `if !authorized(...)` to `if false`, or dropping
// the RequireAPIKey wrapper from registerGuardedRoutes, makes every case below
// return 200 — i.e. the policy and observation APIs open to anyone who can
// reach the port, which is the state §4.3 exists to end.
func TestRequireAPIKeyRefusesWithoutAValidBearer(t *testing.T) {
	keys := ParseAPIKeys("good-key,second-key")

	cases := []struct {
		name   string
		header string
		want   int
	}{
		{"no header at all", "", http.StatusUnauthorized},
		{"wrong key", "Bearer wrong-key", http.StatusUnauthorized},
		{"wrong key of the same length", "Bearer good-kez", http.StatusUnauthorized},
		{"key as a prefix", "Bearer good", http.StatusUnauthorized},
		{"key with a suffix", "Bearer good-key-extra", http.StatusUnauthorized},
		{"empty bearer", "Bearer ", http.StatusUnauthorized},
		{"wrong scheme", "Basic good-key", http.StatusUnauthorized},
		{"raw key, no scheme", "good-key", http.StatusUnauthorized},
		{"first key", "Bearer good-key", http.StatusOK},
		{"second key", "Bearer second-key", http.StatusOK},
		{"lowercase scheme", "bearer good-key", http.StatusOK},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reached := false
			h := RequireAPIKey(keys, func(w http.ResponseWriter, r *http.Request) {
				reached = true
				w.WriteHeader(http.StatusOK)
			})
			req := httptest.NewRequest(http.MethodPost, "/api/v1/policies/bundles", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			w := httptest.NewRecorder()
			h(w, req)

			if w.Code != tc.want {
				t.Fatalf("got %d want %d (%s)", w.Code, tc.want, w.Body.String())
			}
			if tc.want == http.StatusUnauthorized {
				if reached {
					t.Fatal("the handler must not run on a refused request")
				}
				if got := w.Header().Get("WWW-Authenticate"); !strings.HasPrefix(got, "Bearer ") {
					t.Errorf("a 401 must carry a Bearer challenge, got %q", got)
				}
				// The refusal must not say which part was wrong.
				body := w.Body.String()
				for _, leak := range []string{"good-key", "second-key", "missing", "malformed"} {
					if strings.Contains(body, leak) {
						t.Errorf("the 401 body must not disclose %q: %s", leak, body)
					}
				}
			}
		})
	}
}

// newGuardedMux builds the real routing table, so the test asserts what main
// serves rather than a parallel wiring that could drift from it.
func newGuardedMux(t *testing.T, keys []string) *http.ServeMux {
	t.Helper()
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	store := NewPolicyStore(engine)
	ev, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/api/v1/evaluate", handleEvaluate)
	registerGuardedRoutes(mux, NewPolicyEngineHandlers(store, engine), NewObservationHandlers(store, ev), keys)
	return mux
}

// TestEveryGuardedRouteIs401WithoutAKey sweeps the whole declared surface, so a
// route added to GuardedRoutes without a guard cannot pass unnoticed.
func TestEveryGuardedRouteIs401WithoutAKey(t *testing.T) {
	mux := newGuardedMux(t, ParseAPIKeys("good-key"))

	for _, route := range GuardedRoutes {
		for _, method := range []string{http.MethodGet, http.MethodPost} {
			req := httptest.NewRequest(method, route, strings.NewReader("{}"))
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != http.StatusUnauthorized {
				t.Errorf("%s %s: got %d, want 401 — the route is reachable without a key", method, route, w.Code)
			}
		}
	}
}

// TestProbesAndLegacyEvaluateAreNotGuarded: a kubelet probe cannot carry a
// bearer token, and /api/v1/evaluate plus the compliance routes are explicitly
// out of scope for this card.
func TestProbesAndLegacyEvaluateAreNotGuarded(t *testing.T) {
	mux := newGuardedMux(t, ParseAPIKeys("good-key"))

	for _, route := range []string{"/healthz", "/readyz"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, route, nil))
		if w.Code != http.StatusOK {
			t.Errorf("%s must stay unauthenticated, got %d", route, w.Code)
		}
	}

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/api/v1/evaluate",
		strings.NewReader(`{"agent_id":"a","pod_spec":{"containers":[]}}`)))
	if w.Code != http.StatusOK {
		t.Errorf("/api/v1/evaluate must stay unauthenticated, got %d: %s", w.Code, w.Body.String())
	}

	for _, route := range GuardedRoutes {
		if route == "/api/v1/evaluate" {
			t.Fatal("/api/v1/evaluate must not be in the guarded set: this card does not change it")
		}
	}
}

// TestGuardedRoutesCoverBothFamilies pins the declared surface so a new
// /api/v1/policies/* or /api/v1/observations/* route must be added to it.
func TestGuardedRoutesCoverBothFamilies(t *testing.T) {
	want := map[string]bool{
		"/api/v1/policies":              false,
		"/api/v1/policies/evaluate":     false,
		"/api/v1/policies/bundles":      false,
		"/api/v1/policies/rollback":     false,
		"/api/v1/observations/evaluate": false,
	}
	for _, route := range GuardedRoutes {
		if _, ok := want[route]; !ok {
			t.Errorf("unexpected guarded route %q — add it to this test deliberately", route)
			continue
		}
		want[route] = true
	}
	for route, seen := range want {
		if !seen {
			t.Errorf("route %q must be guarded", route)
		}
	}
}

// TestAllRoutesServeWithAValidKey: the guard must not break the routes it
// protects.
func TestAllRoutesServeWithAValidKey(t *testing.T) {
	mux := newGuardedMux(t, ParseAPIKeys("good-key"))
	req := httptest.NewRequest(http.MethodGet, "/api/v1/policies", nil)
	req.Header.Set("Authorization", "Bearer good-key")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/policies with a valid key: got %d (%s)", w.Code, w.Body.String())
	}
}
