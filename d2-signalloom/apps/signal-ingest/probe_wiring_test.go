package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
)

// TestProbeServerAnswersTheKubeletOnTheConfiguredPort: the server main starts for probes listens
// where the manifest points the kubelet, and answers an anonymous /healthz.
func TestProbeServerAnswersTheKubeletOnTheConfiguredPort(t *testing.T) {
	t.Setenv(ProbePortEnvVar, "9443")
	srv := newProbeServer(&api.Handlers{})
	if srv.Addr != ":9443" {
		t.Fatalf("probe server Addr = %q, want :9443 from %s", srv.Addr, ProbePortEnvVar)
	}
	w := httptest.NewRecorder()
	srv.Handler.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("anonymous GET /healthz on the probe server: %d %s", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	srv.Handler.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/v1/observations", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("GET /api/v1/observations on the probe server: %d, want 404", w.Code)
	}

	t.Setenv(ProbePortEnvVar, "")
	if got := probePort(); got != "8083" {
		t.Fatalf("default probe port = %q, want 8083", got)
	}
}
