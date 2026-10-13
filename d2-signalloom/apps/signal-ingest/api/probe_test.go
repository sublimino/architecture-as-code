package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// The kubelet sends no credential. Behind ProtectedRouter every route, /healthz and /readyz
// included, is authenticated first, so an HTTP probe against the API port is a 401 and the pod
// never becomes Ready (startupProbe exhausts and restarts it). The probe surface is therefore a
// separate handler, served on its own port that neither the Service nor the ingress
// NetworkPolicy exposes. It must carry the two probe answers and nothing else.

func probeGet(t *testing.T, h http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(method, path, nil))
	return w
}

func TestProbeHandlerAnswersLivenessWithoutACredential(t *testing.T) {
	w := probeGet(t, NewProbeHandler(&Handlers{}), http.MethodGet, "/healthz")
	if w.Code != http.StatusOK || decodeBody(t, w)["status"] != "ok" {
		t.Fatalf("GET /healthz on the probe handler: %d %s, want 200 {\"status\":\"ok\"}", w.Code, w.Body.String())
	}
	wHead := probeGet(t, NewProbeHandler(&Handlers{}), http.MethodHead, "/healthz")
	if wHead.Code != http.StatusOK {
		t.Fatalf("HEAD /healthz: %d, want 200", wHead.Code)
	}
	if wHead.Body.Len() != 0 {
		t.Fatalf("HEAD /healthz body length: %d, want 0", wHead.Body.Len())
	}
	if ct := wHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("HEAD /healthz content-type: %q, want application/json", ct)
	}
}

func TestProbeHandlerReadinessFollowsTheAuditBackend(t *testing.T) {
	down := &Handlers{AuditReady: func(context.Context) error { return errors.New("dial tcp: i/o timeout") }}
	w := probeGet(t, NewProbeHandler(down), http.MethodGet, "/readyz")
	if w.Code != http.StatusServiceUnavailable || decodeBody(t, w)["reason"] != "audit_backend_unreachable" {
		t.Fatalf("GET /readyz with the audit backend down: %d %s, want 503 audit_backend_unreachable", w.Code, w.Body.String())
	}
	wHeadDown := probeGet(t, NewProbeHandler(down), http.MethodHead, "/readyz")
	if wHeadDown.Code != http.StatusServiceUnavailable {
		t.Fatalf("HEAD /readyz down: %d, want 503", wHeadDown.Code)
	}
	if wHeadDown.Body.Len() != 0 {
		t.Fatalf("HEAD /readyz down body length: %d, want 0", wHeadDown.Body.Len())
	}

	up := &Handlers{AuditReady: func(context.Context) error { return nil }}
	w = probeGet(t, NewProbeHandler(up), http.MethodGet, "/readyz")
	if w.Code != http.StatusOK || decodeBody(t, w)["status"] != "ready" {
		t.Fatalf("GET /readyz with the audit backend up: %d %s, want 200 ready", w.Code, w.Body.String())
	}
	wHeadUp := probeGet(t, NewProbeHandler(up), http.MethodHead, "/readyz")
	if wHeadUp.Code != http.StatusOK {
		t.Fatalf("HEAD /readyz up: %d, want 200", wHeadUp.Code)
	}
	if wHeadUp.Body.Len() != 0 {
		t.Fatalf("HEAD /readyz up body length: %d, want 0", wHeadUp.Body.Len())
	}
}

// Nothing but the two probe answers: no data route, no posture detail (/health), no metrics, no
// second method on a probe path.
func TestProbeHandlerServesNothingElse(t *testing.T) {
	h, _ := newTestHandlers(t)
	probe := NewProbeHandler(h)
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/api/v1/observations"},
		{http.MethodPost, "/api/v1/observations"},
		{http.MethodGet, "/api/v1/actors"},
		{http.MethodGet, "/health"},
		{http.MethodGet, "/api/v1/health"},
		{http.MethodGet, "/metrics"},
		{http.MethodGet, "/"},
	} {
		if w := probeGet(t, probe, tc.method, tc.path); w.Code != http.StatusNotFound {
			t.Errorf("%s %s on the probe handler: %d, want 404", tc.method, tc.path, w.Code)
		}
	}
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		for _, path := range []string{"/healthz", "/readyz"} {
			if w := probeGet(t, probe, method, path); w.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s on the probe handler: %d, want 405", method, path, w.Code)
			}
		}
	}
}

// The probe listener exists BECAUSE the API port stays closed to an anonymous caller. If this ever
// turns 200, the API gate was weakened and the probe port is no longer the only open surface.
func TestAPIRouterStillRefusesAnAnonymousProbe(t *testing.T) {
	h, _ := newTestHandlers(t)
	jwt, _, _ := testJWTDelegate(t)
	router, err := NewProtectedRouter(h, jwt, audit.NewFakeWriter(), http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/healthz", "/readyz"} {
		if w := probeGet(t, router, http.MethodGet, path); w.Code != http.StatusUnauthorized {
			t.Errorf("anonymous GET %s on the API router: %d, want 401", path, w.Code)
		}
	}
}

func TestProbeHandlerHEADRequests(t *testing.T) {
	h, _ := newTestHandlers(t)
	probe := NewProbeHandler(h)
	for _, path := range []string{"/healthz", "/readyz"} {
		w := probeGet(t, probe, http.MethodHead, path)
		if w.Code != http.StatusOK {
			t.Errorf("HEAD %s on probe handler: %d, want 200", path, w.Code)
		}
		if w.Body.Len() != 0 {
			t.Errorf("HEAD %s on probe handler returned %d body bytes, want 0", path, w.Body.Len())
		}
	}
}

