package main

import (
	"context"
	"fmt"
	"io"
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

func newFakeAPIServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			if r.Method != http.MethodHead {
				fmt.Fprint(w, `{"kind":"Status","apiVersion":"v1","status":"Failure","message":"method not allowed","reason":"MethodNotAllowed","code":405}`)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			fmt.Fprint(w, `{"apiVersion":"v1","kind":"Pod","metadata":{"name":"agent-kusari","namespace":"fe-signalloom-agents"}}`)
		}
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
	return srv, kubeconfig
}

func fakeAPIServer(t *testing.T) string {
	t.Helper()
	_, kubeconfig := newFakeAPIServer(t)
	return kubeconfig
}

func TestFakeAPIServerMethodGatingAndHEAD(t *testing.T) {
	srv, _ := newFakeAPIServer(t)

	headResp, err := http.Head(srv.URL + "/api/v1/namespaces/fe-signalloom-agents/pods/agent-kusari")
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD status = %d, want 200", headResp.StatusCode)
	}
	headBytes, _ := io.ReadAll(headResp.Body)
	if len(headBytes) != 0 {
		t.Errorf("HEAD response had body length %d, want 0", len(headBytes))
	}

	postResp, err := http.Post(srv.URL+"/api/v1/namespaces/fe-signalloom-agents/pods/agent-kusari", "application/json", nil)
	if err != nil {
		t.Fatalf("POST request failed: %v", err)
	}
	defer postResp.Body.Close()
	if postResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST status = %d, want 405", postResp.StatusCode)
	}
	if allow := postResp.Header.Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("POST Allow header = %q, want 'GET, HEAD'", allow)
	}
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
