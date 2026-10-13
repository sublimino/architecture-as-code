package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"k8s.io/client-go/kubernetes/fake"
)

// decodeHealth mirrors the existing contract test's decode: a map[string]string.
// Every value the handler emits must be a string, because json.Unmarshal into
// this type aborts at the first non-string value and silently blanks every key
// after it — a numeric degraded_targets would make this body half-readable and
// the existing TestHandleHealth would keep passing while reporting nothing.
func decodeHealth(t *testing.T, w *httptest.ResponseRecorder) map[string]string {
	t.Helper()
	var body map[string]string
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("health body is not a flat string map: %v", err)
	}
	return body
}

func getHealth(t *testing.T, s *server) (*httptest.ResponseRecorder, map[string]string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	s.handleHealth(w, req)
	return w, decodeHealth(t, w)
}

func TestHealthReportsEnforcingClient(t *testing.T) {
	s := newTestServer(t)
	s.enforcement = &fleetClientSelection{
		Kind:      fleetClientKubernetes,
		Client:    newK8sFleetClient(fake.NewSimpleClientset(), testNamespace),
		Reason:    "client-go clientset built from test loader",
		Enforcing: true,
	}

	w, body := getHealth(t, s)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if body["enforcement"] != "available" {
		t.Fatalf("expected enforcement=available, got %q", body["enforcement"])
	}
	if body["fleet_client"] != string(fleetClientKubernetes) {
		t.Fatalf("expected fleet_client=%q, got %q", fleetClientKubernetes, body["fleet_client"])
	}
	if body["degraded_targets"] != "0" {
		t.Fatalf("expected degraded_targets=0, got %q", body["degraded_targets"])
	}
}

// The break-glass invariant. /health backs the liveness, readiness AND startup
// probes (base/deployment.yaml), so failing it during an API-server outage would
// crash-loop fleet-manager exactly when an operator needs to reach it — making
// break-glass traverse the plane that just failed. Degradation is reported in a
// field, not in the status code.
func TestHealthStaysUpWhenEnforcementIsUnavailable(t *testing.T) {
	s := newTestServer(t)
	client := newUnavailableFleetClient(errors.New("no in-cluster config"), testNamespace)
	_ = client.SetPodState(t.Context(), testNamespace, "agent-monitor", StateStunned) // create a degraded record
	s.enforcement = &fleetClientSelection{
		Kind:      fleetClientUnavailable,
		Client:    client,
		Reason:    "cluster configuration unavailable",
		Enforcing: false,
	}

	w, body := getHealth(t, s)

	if w.Code != http.StatusOK {
		t.Fatalf("a degraded enforcement plane must not fail the liveness probe; got %d — "+
			"this would crash-loop the pod during an API outage and destroy break-glass", w.Code)
	}
	if body["status"] != "ok" {
		t.Fatalf("status reports PROCESS liveness and must stay ok, got %q", body["status"])
	}
	if body["enforcement"] != "unavailable" {
		t.Fatalf("expected enforcement=unavailable, got %q — blindness must be visible somewhere", body["enforcement"])
	}
	if body["fleet_client"] != string(fleetClientUnavailable) {
		t.Fatalf("expected fleet_client=%q, got %q", fleetClientUnavailable, body["fleet_client"])
	}
	if body["degraded_targets"] == "0" || body["degraded_targets"] == "" {
		t.Fatalf("expected a non-zero degraded target count, got %q", body["degraded_targets"])
	}
	if body["enforcement_reason"] == "" {
		t.Fatal("an unavailable plane must say why")
	}
}

// Selecting the test double must be visible on the wire, not just in a log line
// nobody scrapes.
func TestHealthNamesTheNoopDouble(t *testing.T) {
	s := newTestServer(t)
	s.enforcement = &fleetClientSelection{
		Kind:      fleetClientNoopTestOnly,
		Client:    &noopFleetClient{},
		Reason:    "explicitly requested",
		Enforcing: false,
	}

	_, body := getHealth(t, s)
	if body["fleet_client"] != string(fleetClientNoopTestOnly) {
		t.Fatalf("the no-op double must be named on /health, got %q", body["fleet_client"])
	}
	if body["enforcement"] == "available" {
		t.Fatal("the no-op double must never report enforcement=available — it enforces nothing")
	}
}

// A server built without a selection must not imply that enforcement works.
func TestHealthUnconfiguredDoesNotClaimEnforcement(t *testing.T) {
	s := newTestServer(t) // enforcement left nil, as the pre-existing tests build it

	w, body := getHealth(t, s)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if body["enforcement"] == "available" {
		t.Fatal("an unconfigured server must not report enforcement=available")
	}
	if body["status"] != "ok" {
		t.Fatalf("expected the pre-existing status contract to hold, got %q", body["status"])
	}
}

func TestHealthMethodsAndHead(t *testing.T) {
	s := newTestServer(t)

	// HEAD on /health
	req := httptest.NewRequest(http.MethodHead, "/health", nil)
	w := httptest.NewRecorder()
	s.handleHealth(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("HEAD /health: expected 200, got %d", w.Code)
	}
	if w.Body.Len() != 0 {
		t.Fatalf("HEAD /health: expected 0 body bytes, got %d", w.Body.Len())
	}

	// POST rejected on /health
	req = httptest.NewRequest(http.MethodPost, "/health", nil)
	w = httptest.NewRecorder()
	s.handleHealth(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /health: expected 405, got %d", w.Code)
	}
	if allow := w.Header().Get("Allow"); !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") {
		t.Fatalf("POST /health: expected Allow header with GET, HEAD, got %q", allow)
	}
}

func TestHealthzAndReadyzMethodsAndHead(t *testing.T) {
	s := newTestServer(t)

	// HEAD on /healthz
	req := httptest.NewRequest(http.MethodHead, "/healthz", nil)
	w := httptest.NewRecorder()
	s.handleHealthz(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("HEAD /healthz: expected 200, got %d", w.Code)
	}
	if w.Body.Len() != 0 {
		t.Fatalf("HEAD /healthz: expected 0 body bytes, got %d", w.Body.Len())
	}

	// POST rejected on /healthz
	req = httptest.NewRequest(http.MethodPost, "/healthz", nil)
	w = httptest.NewRecorder()
	s.handleHealthz(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /healthz: expected 405, got %d", w.Code)
	}
	if allow := w.Header().Get("Allow"); !strings.Contains(allow, "GET") {
		t.Fatalf("POST /healthz: expected Allow header with GET, got %q", allow)
	}

	// HEAD on /readyz
	req = httptest.NewRequest(http.MethodHead, "/readyz", nil)
	w = httptest.NewRecorder()
	s.handleReadyz(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("HEAD /readyz: expected 200, got %d", w.Code)
	}
	if w.Body.Len() != 0 {
		t.Fatalf("HEAD /readyz: expected 0 body bytes, got %d", w.Body.Len())
	}

	// POST rejected on /readyz
	req = httptest.NewRequest(http.MethodPost, "/readyz", nil)
	w = httptest.NewRecorder()
	s.handleReadyz(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /readyz: expected 405, got %d", w.Code)
	}
	if allow := w.Header().Get("Allow"); !strings.Contains(allow, "GET") {
		t.Fatalf("POST /readyz: expected Allow header with GET, got %q", allow)
	}
}
