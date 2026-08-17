package api

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// Readiness is the visible half of the signal-ingest startup fix.
//
// Boot no longer blocks on Postgres, which means a pod whose audit backend is
// unreachable now STARTS instead of crash-looping. That is the right trade for
// availability, but on its own it swaps a loud failure (CrashLoopBackOff) for
// a silent one (1/1 Running, auditing nothing). These tests pin the signal
// that keeps it loud: /readyz must go red while the audit backend is
// unreachable, and green again when it recovers, without a restart.

func decodeBody(t *testing.T, w *httptest.ResponseRecorder) map[string]string {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("readyz body is not JSON: %v (raw %q)", err, w.Body.String())
	}
	return body
}

func getReadyz(t *testing.T, h *Handlers) *httptest.ResponseRecorder {
	t.Helper()
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	return w
}

func TestReadyz_ReportsNotReadyWhenAuditBackendUnreachable(t *testing.T) {
	wantErr := errors.New("dial tcp 10.96.0.10:5432: i/o timeout")
	h := &Handlers{AuditReady: func(context.Context) error { return wantErr }}

	w := getReadyz(t, h)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz with an unreachable audit backend: got %d, want %d -- "+
			"a 200 here puts a replica that cannot record its work back into the "+
			"Service endpoints and makes the degradation invisible",
			w.Code, http.StatusServiceUnavailable)
	}

	body := decodeBody(t, w)
	if body["status"] != "not_ready" {
		t.Errorf(`status = %q, want "not_ready"`, body["status"])
	}
	// The reason has to name the subsystem: "not ready" with no cause sends
	// whoever is paged straight back to the logs this field exists to replace.
	if body["reason"] != "audit_backend_unreachable" {
		t.Errorf(`reason = %q, want "audit_backend_unreachable"`, body["reason"])
	}
	if body["error"] != wantErr.Error() {
		t.Errorf("error = %q, want the underlying failure %q", body["error"], wantErr.Error())
	}
}

func TestReadyz_ReadyWhenAuditBackendAnswers(t *testing.T) {
	h := &Handlers{AuditReady: func(context.Context) error { return nil }}

	w := getReadyz(t, h)

	if w.Code != http.StatusOK {
		t.Fatalf("readyz with a healthy audit backend: got %d, want 200 (body %q)", w.Code, w.Body.String())
	}
	if got := decodeBody(t, w)["status"]; got != "ready" {
		t.Errorf(`status = %q, want "ready"`, got)
	}
}

// A nil AuditReady is the no-DATABASE_URL case: audit is deliberately off, not
// broken. Fixture and local runs must stay ready, or every developer's kind
// cluster reports a permanently unready pod.
func TestReadyz_ReadyWhenAuditDeliberatelyDisabled(t *testing.T) {
	w := getReadyz(t, &Handlers{AuditReady: nil})

	if w.Code != http.StatusOK {
		t.Fatalf("readyz with audit disabled: got %d, want 200", w.Code)
	}
}

// The check must be live per probe, not a verdict cached at boot. A cached
// verdict is wrong in both directions -- it keeps saying ready after the
// database goes away, and keeps saying not-ready after it comes back, leaving
// a recovered pod out of the endpoints until a human restarts it.
func TestReadyz_RecoversWithoutRestart(t *testing.T) {
	var calls int
	failing := true
	h := &Handlers{AuditReady: func(context.Context) error {
		calls++
		if failing {
			return errors.New("connection refused")
		}
		return nil
	}}

	if w := getReadyz(t, h); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("first probe: got %d, want 503", w.Code)
	}

	failing = false // the database comes back; nothing restarts the process

	if w := getReadyz(t, h); w.Code != http.StatusOK {
		t.Fatalf("probe after recovery: got %d, want 200 -- the verdict is cached, "+
			"so a recovered pod would stay out of the Service endpoints indefinitely", w.Code)
	}
	if calls != 2 {
		t.Errorf("AuditReady called %d times across 2 probes, want 2 -- the check is not live", calls)
	}
}

// Liveness must stay independent of the audit backend. Wiring the database
// into /healthz would convert a Postgres outage back into the restart loop
// this whole change removes -- restarting cannot make a database reachable.
func TestHealthz_IgnoresAuditBackend(t *testing.T) {
	h := &Handlers{AuditReady: func(context.Context) error {
		t.Error("healthz consulted the audit backend; liveness must not depend on it")
		return errors.New("unreachable")
	}}

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if w.Code != http.StatusOK {
		t.Fatalf("healthz: got %d, want 200 even with the audit backend down", w.Code)
	}
}

// The readiness check gets a deadline of its own. Without one, the same
// silence that hung boot would hang the probe handler instead: the kubelet
// would time out rather than receive a verdict, and the goroutine would sit
// in the syscall for as long as the drop persisted.
func TestReadyz_BoundsTheCheck(t *testing.T) {
	var deadline time.Time
	var hadDeadline bool
	h := &Handlers{AuditReady: func(ctx context.Context) error {
		deadline, hadDeadline = ctx.Deadline()
		return nil
	}}

	start := time.Now()
	if w := getReadyz(t, h); w.Code != http.StatusOK {
		t.Fatalf("readyz: got %d, want 200", w.Code)
	}

	if !hadDeadline {
		t.Fatal("AuditReady received a context with no deadline -- an unreachable " +
			"backend would block the probe handler indefinitely")
	}
	if budget := deadline.Sub(start); budget > readyCheckTimeout+time.Second {
		t.Errorf("readiness check budget %v exceeds readyCheckTimeout %v", budget, readyCheckTimeout)
	}
	// Must stay under the readinessProbe's timeoutSeconds (3, in
	// apps/signal-ingest/base/deployment.yaml) so the handler answers with a
	// diagnosable body instead of being cut off mid-check.
	if readyCheckTimeout >= 3*time.Second {
		t.Errorf("readyCheckTimeout = %v must be under the probe's 3s timeoutSeconds", readyCheckTimeout)
	}
}

// blackholeAddr returns an address that swallows SYNs, or "" if none does.
// Mirrors audit's own probe: an address that answers fast would let a handler
// report a verdict without the backend state ever being in question, and the
// test below would pass without testing anything.
func blackholeAddr(t *testing.T) string {
	t.Helper()
	for _, addr := range []string{"10.255.255.1:5432", "192.0.2.1:5432"} {
		start := time.Now()
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		elapsed := time.Since(start)
		if conn != nil {
			conn.Close()
		}
		if err != nil && elapsed >= time.Second {
			return addr
		}
	}
	return ""
}

// TestReadyz_AgreesWithRealBackendState is the regression guard for the class
// of bug where the readiness ENDPOINT and the actual audit-backend state
// disagree -- a pod reporting 200 while it cannot write, or 503 while it can.
//
// The distinction this test exists to preserve: a log line is not a control
// surface. Nothing schedules, routes, or pages on a WARN. Kubernetes acts on
// the status code alone, so the status code is the thing that has to be true.
// A degradation that is loud in the log and silent in /readyz is worse than a
// crashloop, because a crashloop is at least visible in `kubectl get pods`.
//
// Unlike the tests above it does not accept a fake: it drives the REAL
// audit.PostgresWriter through the real handler. A fake AuditReady can only
// prove the handler branches on whatever it is handed; it cannot prove the
// thing it is handed reflects the database. This closes that gap.
func TestReadyz_AgreesWithRealBackendState(t *testing.T) {
	t.Parallel()

	addr := blackholeAddr(t)
	if addr == "" {
		t.Skip("no blackholed address available; cannot stage an unreachable backend")
	}

	// A real writer whose pool can never reach a server.
	pw, err := audit.OpenPostgresWriter("postgres://u:p@" + addr + "/db?sslmode=disable")
	if err != nil {
		t.Fatalf("OpenPostgresWriter: %v", err)
	}
	defer pw.Close()

	tests := []struct {
		name        string
		auditReady  func(context.Context) error
		backendUp   bool
		wantStatus  int
		wantPayload string
	}{
		{
			name:        "real writer, backend unreachable",
			auditReady:  pw.Ping,
			backendUp:   false,
			wantStatus:  http.StatusServiceUnavailable,
			wantPayload: "not_ready",
		},
		{
			name:        "backend answers",
			auditReady:  func(context.Context) error { return nil },
			backendUp:   true,
			wantStatus:  http.StatusOK,
			wantPayload: "ready",
		},
		{
			name:        "audit deliberately disabled",
			auditReady:  nil,
			backendUp:   true, // nothing to reach, so nothing is broken
			wantStatus:  http.StatusOK,
			wantPayload: "ready",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			h := &Handlers{AuditReady: tc.auditReady}

			// The handler must also RETURN. If it blocks on an unreachable
			// backend the kubelet times out instead of receiving a verdict,
			// which is the boot hang relocated to the probe.
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- getReadyz(t, h) }()

			var w *httptest.ResponseRecorder
			select {
			case w = <-done:
			case <-time.After(readyCheckTimeout + 5*time.Second):
				t.Fatalf("/readyz did not return within %v -- the probe would hang rather than fail",
					readyCheckTimeout+5*time.Second)
			}

			if w.Code != tc.wantStatus {
				t.Fatalf("backend_reachable=%v but /readyz returned %d (want %d) -- "+
					"the readiness ENDPOINT and the audit backend disagree, which is "+
					"the exact regression this test exists to catch. Body: %s",
					tc.backendUp, w.Code, tc.wantStatus, w.Body.String())
			}
			if got := decodeBody(t, w)["status"]; got != tc.wantPayload {
				t.Errorf("status = %q, want %q", got, tc.wantPayload)
			}

			// Consistency in the other direction: a 200 must never carry a
			// failure reason, and a 503 must always name one. A body that
			// contradicts its own status code is the same defect in miniature.
			body := decodeBody(t, w)
			if w.Code == http.StatusOK && body["reason"] != "" {
				t.Errorf("200 response carries a failure reason %q", body["reason"])
			}
			if w.Code == http.StatusServiceUnavailable && body["reason"] == "" {
				t.Error("503 response names no reason; whoever is paged learns nothing")
			}
		})
	}
}
