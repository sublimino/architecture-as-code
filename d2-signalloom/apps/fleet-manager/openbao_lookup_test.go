package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Live, 2026-10-03: a lone stun took ~1.4 s, nearly all in the bao plane's
// token revocation. RevokeTokensBySubject lists every token accessor in
// OpenBao and looked each one up in turn: 3,209 live tokens (vault_token_count)
// at ~0.44 ms per lookup. Containment latency grew with every token in the
// estate. The lookups now run concurrently, bounded.

type slowAccessorServer struct {
	srv               *httptest.Server
	inFlight, maxSeen atomic.Int64
	mu                sync.Mutex
	revoked           []string
}

func newSlowAccessorServer(t *testing.T, n int, match map[int]bool, sub string, delay time.Duration, failAt int) *slowAccessorServer {
	return newSlowAccessorServerHook(t, n, match, sub, delay, failAt, nil)
}

// onLookup, when set, runs as each accessor is looked up.
func newSlowAccessorServerHook(t *testing.T, n int, match map[int]bool, sub string, delay time.Duration, failAt int, onLookup func(i int)) *slowAccessorServer {
	t.Helper()
	s := &slowAccessorServer{}
	keys := make([]string, n)
	for i := range keys {
		keys[i] = fmt.Sprintf("acc-%03d", i)
	}
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/token/accessors":
			_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"keys": keys}})
		case "/v1/auth/token/lookup-accessor":
			cur := s.inFlight.Add(1)
			for {
				prev := s.maxSeen.Load()
				if cur <= prev || s.maxSeen.CompareAndSwap(prev, cur) {
					break
				}
			}
			var body struct {
				Accessor string `json:"accessor"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			var i int
			fmt.Sscanf(body.Accessor, "acc-%03d", &i)
			if i == failAt { // fails at once, while its siblings are still in flight
				s.inFlight.Add(-1)
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"errors":["internal error"]}`))
				return
			}
			if onLookup != nil {
				onLookup(i)
			}
			time.Sleep(delay)
			s.inFlight.Add(-1)
			display := "jwt-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/other"
			if match[i] {
				display = "jwt-" + sub
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"display_name": display}})
		case "/v1/auth/token/revoke-accessor":
			var body struct {
				Accessor string `json:"accessor"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			s.mu.Lock()
			s.revoked = append(s.revoked, body.Accessor)
			s.mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.srv.Close)
	return s
}

const lookupSub = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent"

func TestTokenLookupsRunConcurrentlyAndBounded(t *testing.T) {
	const n, delay = 120, 10 * time.Millisecond
	s := newSlowAccessorServer(t, n, map[int]bool{7: true, 64: true, 119: true}, lookupSub, delay, -1)
	client := NewOpenBaoClient(OpenBaoConfig{Address: s.srv.URL, Token: "s.fleet"})
	start := time.Now()
	revoked, err := client.RevokeTokensBySubject(context.Background(), lookupSub)
	el := time.Since(start)
	if err != nil || revoked != 3 {
		t.Fatalf("revoked=%d err=%v", revoked, err)
	}
	if sequential := time.Duration(n) * delay; el > sequential/3 {
		t.Fatalf("%d lookups took %v (sequential is %v): they are not concurrent", n, el, sequential)
	}
	if m := s.maxSeen.Load(); m > tokenLookupWorkers {
		t.Fatalf("%d lookups in flight at once, want at most %d", m, tokenLookupWorkers)
	}
	if got := s.revoked; len(got) != 3 || got[0] != "acc-007" || got[1] != "acc-064" || got[2] != "acc-119" {
		t.Fatalf("revoked %v, want exactly the subject's tokens in LIST order", got)
	}
}

func TestATokenLookupFailureStillFailsClosed(t *testing.T) {
	s := newSlowAccessorServer(t, 60, map[int]bool{3: true}, lookupSub, time.Millisecond, 41)
	client := NewOpenBaoClient(OpenBaoConfig{Address: s.srv.URL, Token: "s.fleet"})
	revoked, err := client.RevokeTokensBySubject(context.Background(), lookupSub)
	if err == nil || revoked != 0 || len(s.revoked) != 0 {
		t.Fatalf("revoked=%d calls=%v err=%v: an incomplete enumeration must not act", revoked, s.revoked, err)
	}
}

// The caller giving up mid-enumeration is an error, never a short list read
// as complete: that would revoke some of an agent's tokens and report all.
func TestACancelledEnumerationIsNotReadAsComplete(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := newSlowAccessorServerHook(t, 200, map[int]bool{3: true, 190: true}, lookupSub, 2*time.Millisecond, -1,
		func(i int) {
			if i == 20 {
				cancel()
			}
		})
	client := NewOpenBaoClient(OpenBaoConfig{Address: s.srv.URL, Token: "s.fleet"})
	// The enumeration itself, with no revoke step after it to fail on the
	// cancelled context and hide a short list.
	counts, err := client.ActiveTokensBySubject(ctx)
	if err == nil {
		t.Fatalf("counts=%v: a cancelled enumeration was read as complete", counts)
	}
}

// One bad answer among concurrent lookups is one breaker failure, as it was
// sequentially: the lookups still in flight finish rather than being
// cancelled into failures that would open the breaker (threshold 3) and take
// the bao plane down for its cooldown.
func TestOneBadLookupDoesNotOpenTheBreaker(t *testing.T) {
	s := newSlowAccessorServer(t, 120, nil, lookupSub, 20*time.Millisecond, 0)
	client := NewOpenBaoClient(OpenBaoConfig{Address: s.srv.URL, Token: "s.fleet"})
	if _, err := client.RevokeTokensBySubject(context.Background(), lookupSub); err == nil {
		t.Fatal("a failed lookup must fail the enumeration")
	}
	if st := client.breaker.State(); st != BreakerClosed {
		t.Fatalf("breaker = %v after one failed lookup, want closed", st)
	}
}
