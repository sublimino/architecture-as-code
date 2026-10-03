package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Live, 2026-10-03: OpenBao held 3,188 tokens for policy
// signalloom-cardvault-agent, all with no expiry. agent-cardvault runs its
// chain every 60 s and logged in afresh on every run. The agent now reuses
// its token until shortly before it expires.

type baoFake struct {
	mu      sync.Mutex
	logins  int
	lease   int // seconds; 0 = no lease reported
	valid   map[string]bool
	srv     *httptest.Server
	cv      *httptest.Server
	fetches int
}

func newBaoFake(t *testing.T, lease int) *baoFake {
	t.Helper()
	f := &baoFake{lease: lease, valid: map[string]bool{}}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch r.URL.Path {
		case "/v1/auth/jwt/login":
			f.logins++
			tok := fmt.Sprintf("s.token-%d", f.logins)
			f.valid[tok] = true
			_ = json.NewEncoder(w).Encode(map[string]any{"auth": map[string]any{"client_token": tok, "lease_duration": f.lease}})
		case "/v1/kv/data/signalloom/cardvault-agent":
			if !f.valid[r.Header.Get("X-Vault-Token")] {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
				return
			}
			_, _ = w.Write([]byte(`{"data":{"data":{"username":"u","password":"p"}}}`))
		default:
			t.Errorf("unexpected bao path %s", r.URL.Path)
		}
	}))
	t.Cleanup(f.srv.Close)
	f.cv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode([]card{{Cardholder: "C", PANMasked: "****", Expiry: "01/30"}})
	}))
	t.Cleanup(f.cv.Close)
	return f
}

func (f *baoFake) revokeAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.valid = map[string]bool{}
}

func (f *baoFake) agent(clock *time.Time) *agent {
	return &agent{
		baoAddr:      f.srv.URL,
		baoRole:      "signalloom-cardvault-agent",
		cardvaultURL: f.cv.URL,
		audience:     "openbao",
		invoke: func(string, ...string) ([]byte, error) {
			f.mu.Lock()
			f.fetches++
			f.mu.Unlock()
			return []byte(`{"svids":[{"svid":"jwt","spiffeID":"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"}]}`), nil
		},
		pause:  func(time.Duration) {},
		client: &http.Client{Timeout: 5 * time.Second},
		now:    func() time.Time { return *clock },
	}
}

func runs(t *testing.T, a *agent, clock *time.Time, n int, step time.Duration) string {
	t.Helper()
	var out strings.Builder
	for i := 0; i < n; i++ {
		var stderr strings.Builder
		if code := a.runDemo(&out, &stderr); code != 0 {
			t.Fatalf("run %d exit %d: %s", i, code, stderr.String())
		}
		*clock = clock.Add(step)
	}
	return out.String()
}

func TestRunsWithinTheTokenTTLLogInOnce(t *testing.T) {
	f := newBaoFake(t, 300)
	clock := time.Date(2026, 10, 3, 5, 0, 0, 0, time.UTC)
	out := runs(t, f.agent(&clock), &clock, 4, 60*time.Second) // 0, 60, 120, 180 s
	if f.logins != 1 || f.fetches != 1 {
		t.Fatalf("logins=%d svid fetches=%d over 4 runs inside a 300 s token, want 1/1", f.logins, f.fetches)
	}
	if strings.Contains(out, "s.token-") {
		t.Fatalf("the token was printed: %s", out)
	}
}

func TestATokenNearItsExpiryIsReplaced(t *testing.T) {
	f := newBaoFake(t, 300)
	clock := time.Date(2026, 10, 3, 5, 0, 0, 0, time.UTC)
	a := f.agent(&clock)
	runs(t, a, &clock, 1, 280*time.Second) // next run 20 s before expiry
	runs(t, a, &clock, 1, 0)
	if f.logins != 2 {
		t.Fatalf("logins = %d, want a fresh login inside the reuse margin", f.logins)
	}
}

func TestARejectedReusedTokenIsReplacedAndTheRunSucceeds(t *testing.T) {
	f := newBaoFake(t, 300)
	clock := time.Date(2026, 10, 3, 5, 0, 0, 0, time.UTC)
	a := f.agent(&clock)
	runs(t, a, &clock, 1, 60*time.Second)
	f.revokeAll() // e.g. fleet-manager revoked the agent's credentials
	runs(t, a, &clock, 1, 0)
	if f.logins != 2 {
		t.Fatalf("logins = %d, want one re-login after the rejection", f.logins)
	}
}

func TestATokenWithNoLeaseIsNeverReused(t *testing.T) {
	f := newBaoFake(t, 0)
	clock := time.Date(2026, 10, 3, 5, 0, 0, 0, time.UTC)
	runs(t, f.agent(&clock), &clock, 3, 10*time.Second)
	if f.logins != 3 {
		t.Fatalf("logins = %d, want 3: an unknown lifetime is never assumed", f.logins)
	}
}

// A freshly issued token that is rejected is a real failure, not a reason to
// loop logging in.
func TestAFreshTokenRejectedFailsTheRunWithoutRetrying(t *testing.T) {
	f := newBaoFake(t, 300)
	clock := time.Date(2026, 10, 3, 5, 0, 0, 0, time.UTC)
	a := f.agent(&clock)
	f.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.URL.Path == "/v1/auth/jwt/login" {
			f.logins++
			_ = json.NewEncoder(w).Encode(map[string]any{"auth": map[string]any{"client_token": "s.bad", "lease_duration": 300}})
			return
		}
		w.WriteHeader(http.StatusForbidden)
	})
	var out, stderr strings.Builder
	if code := a.runDemo(&out, &stderr); code == 0 {
		t.Fatal("a run whose fresh token is refused succeeded")
	}
	if f.logins != 1 {
		t.Fatalf("logins = %d, want 1", f.logins)
	}
}
