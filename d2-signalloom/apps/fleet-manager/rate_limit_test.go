package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Live, 2026-10-03: a stun's freeze pin landed 4.2 s after the call (1.5 s
// alone, 4.2 s beside two recovers). Its API calls were done in ~20 ms; the
// rest was client-go's default client-side rate limiter (QPS 5, burst 10)
// queueing ~16 calls per stun and ~14 per recover: (30 - 10) x 200 ms = 4 s.
// Containment latency must not be set by a client-side default.

func fakeAPIServer(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"apiVersion":"v1","kind":"Pod","metadata":{"name":"agent-kusari","namespace":"fe-signalloom-agents"}}`)
	}))
	t.Cleanup(srv.Close)
	kubeconfig := filepath.Join(t.TempDir(), "kubeconfig")
	if err := os.WriteFile(kubeconfig, []byte(fmt.Sprintf(`apiVersion: v1
kind: Config
clusters: [{name: fake, cluster: {server: %q}}]
users: [{name: fake, user: {token: t}}]
contexts: [{name: fake, context: {cluster: fake, user: fake}}]
current-context: fake
`, srv.URL)), 0o600); err != nil {
		t.Fatal(err)
	}
	return kubeconfig
}

func TestTheContainmentClientIsNotThrottledByClientGoDefaults(t *testing.T) {
	t.Setenv("KUBERNETES_SERVICE_HOST", "") // not in a cluster: the KUBECONFIG branch
	t.Setenv("KUBERNETES_SERVICE_PORT", "")
	t.Setenv("KUBECONFIG", fakeAPIServer(t))
	cfg, _, err := defaultRestConfigLoader()
	if err != nil {
		t.Fatal(err)
	}
	cs, err := defaultClientsetBuilder(cfg)
	if err != nil {
		t.Fatal(err)
	}
	// One stun plus one recover against the live Kusari shape.
	const calls = 30
	start := time.Now()
	for i := 0; i < calls; i++ {
		if _, err := cs.CoreV1().Pods("fe-signalloom-agents").Get(context.Background(), "agent-kusari", metav1.GetOptions{}); err != nil {
			t.Fatal(err)
		}
	}
	if el := time.Since(start); el > time.Second {
		t.Fatalf("%d API calls took %v: the client-side rate limiter is throttling containment", calls, el)
	}
}

func TestTheRateLimitsAreRaisedOnACopyAndLeaveTheTimeout(t *testing.T) {
	t.Setenv("KUBERNETES_SERVICE_HOST", "")
	t.Setenv("KUBERNETES_SERVICE_PORT", "")
	t.Setenv("KUBECONFIG", fakeAPIServer(t))
	cfg, _, err := defaultRestConfigLoader()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Timeout != apiRequestTimeout {
		t.Fatalf("timeout = %v, want %v", cfg.Timeout, apiRequestTimeout)
	}
	tuned := withContainmentRateLimits(cfg)
	if tuned.QPS < containmentQPS || tuned.Burst < containmentBurst {
		t.Fatalf("QPS/Burst = %v/%d", tuned.QPS, tuned.Burst)
	}
	if cfg.QPS != 0 || cfg.Burst != 0 {
		t.Fatalf("the caller's config was mutated: %v/%d", cfg.QPS, cfg.Burst)
	}
}
