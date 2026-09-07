// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// dynamicHealthSource simulates a live external dependency (e.g. database or agent socket)
// whose health status can be dynamically mutated during test execution.
type dynamicHealthSource struct {
	mu      sync.RWMutex
	err     error
	blocked bool
	blockCh chan struct{}
}

func newDynamicHealthSource() *dynamicHealthSource {
	return &dynamicHealthSource{
		blockCh: make(chan struct{}),
	}
}

func (s *dynamicHealthSource) SetHealthy() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = nil
	s.blocked = false
}

func (s *dynamicHealthSource) SetUnhealthy(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = err
	s.blocked = false
}

func (s *dynamicHealthSource) SetHanging() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.blocked = true
	s.blockCh = make(chan struct{})
}

func (s *dynamicHealthSource) Check(ctx context.Context) error {
	s.mu.RLock()
	blocked := s.blocked
	blockCh := s.blockCh
	err := s.err
	s.mu.RUnlock()

	if blocked {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-blockCh:
			return nil
		}
	}
	return err
}

func decodeJSON(t *testing.T, w *httptest.ResponseRecorder) map[string]string {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("readyz response body is not JSON: %v (raw %q)", err, w.Body.String())
	}
	return body
}

func probeReadyz(h *Handlers) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	return w
}

// TestReadyzFault_LiveSourceLossFailsClosed tests the full lifecycle:
// 1. Initially healthy live source -> /readyz returns 200 OK.
// 2. Source disconnects/fails -> /readyz transitions to 503 (fails closed, never ready-while-dead).
// 3. Source recovers -> /readyz transitions back to 200 OK without restart.
func TestReadyzFault_LiveSourceLossFailsClosed(t *testing.T) {
	collectorSource := newDynamicHealthSource()
	collectorSource.SetHealthy()

	auditSource := newDynamicHealthSource()
	auditSource.SetHealthy()

	h := &Handlers{
		CollectorHealth: collectorSource.Check,
		AuditReady:      auditSource.Check,
	}

	// 1. Initial State: Healthy live sources -> 200 OK
	w1 := probeReadyz(h)
	if w1.Code != http.StatusOK {
		t.Fatalf("step 1: initial healthy state expected 200, got %d (body: %s)", w1.Code, w1.Body.String())
	}
	b1 := decodeJSON(t, w1)
	if b1["status"] != "ready" {
		t.Errorf("step 1: status = %q, want ready", b1["status"])
	}

	// 2. Fault Injection: Collector source drops connection -> 503 Fail-Closed
	injectedErr := errors.New("spire-agent socket: connection refused")
	collectorSource.SetUnhealthy(injectedErr)

	w2 := probeReadyz(h)
	if w2.Code != http.StatusServiceUnavailable {
		t.Fatalf("step 2: broken collector source expected 503, got %d -- CRITICAL FAIL-OPEN DEFECT: replica reported ready while dead", w2.Code)
	}
	b2 := decodeJSON(t, w2)
	if b2["status"] != "not_ready" {
		t.Errorf("step 2: status = %q, want not_ready", b2["status"])
	}
	if b2["reason"] != "collector_source_unhealthy" {
		t.Errorf("step 2: reason = %q, want collector_source_unhealthy", b2["reason"])
	}
	if b2["error"] != injectedErr.Error() {
		t.Errorf("step 2: error = %q, want %q", b2["error"], injectedErr.Error())
	}

	// 3. Recovery: Collector source recovers -> 200 OK without restart
	collectorSource.SetHealthy()

	w3 := probeReadyz(h)
	if w3.Code != http.StatusOK {
		t.Fatalf("step 3: recovered collector source expected 200, got %d", w3.Code)
	}
	b3 := decodeJSON(t, w3)
	if b3["status"] != "ready" {
		t.Errorf("step 3: status = %q, want ready", b3["status"])
	}

	// 4. Fault Injection: Audit database backend unreachable -> 503 Fail-Closed
	auditErr := errors.New("pq: connection reset by peer")
	auditSource.SetUnhealthy(auditErr)

	w4 := probeReadyz(h)
	if w4.Code != http.StatusServiceUnavailable {
		t.Fatalf("step 4: broken audit backend expected 503, got %d -- CRITICAL FAIL-OPEN DEFECT", w4.Code)
	}
	b4 := decodeJSON(t, w4)
	if b4["status"] != "not_ready" {
		t.Errorf("step 4: status = %q, want not_ready", b4["status"])
	}
	if b4["reason"] != "audit_backend_unreachable" {
		t.Errorf("step 4: reason = %q, want audit_backend_unreachable", b4["reason"])
	}
	if b4["error"] != auditErr.Error() {
		t.Errorf("step 4: error = %q, want %q", b4["error"], auditErr.Error())
	}

	// 5. Recovery: Audit backend recovers -> 200 OK
	auditSource.SetHealthy()

	w5 := probeReadyz(h)
	if w5.Code != http.StatusOK {
		t.Fatalf("step 5: recovered audit backend expected 200, got %d", w5.Code)
	}
}

// TestReadyzFault_HangingSourceEnforcesDeadline proves that when a live source hangs/deadlocks,
// the /readyz probe terminates within readyCheckTimeout, returns 503, and does not block indefinitely.
func TestReadyzFault_HangingSourceEnforcesDeadline(t *testing.T) {
	hangingSource := newDynamicHealthSource()
	hangingSource.SetHanging()

	h := &Handlers{
		CollectorHealth: hangingSource.Check,
	}

	start := time.Now()
	w := probeReadyz(h)
	elapsed := time.Since(start)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("hanging source returned status %d, want 503", w.Code)
	}

	// Bounded execution assertion: must return within readyCheckTimeout + 1s tolerance
	maxAllowed := readyCheckTimeout + 1*time.Second
	if elapsed > maxAllowed {
		t.Fatalf("probe took %v, exceeded bounded limit %v", elapsed, maxAllowed)
	}

	body := decodeJSON(t, w)
	if body["status"] != "not_ready" {
		t.Errorf("status = %q, want not_ready", body["status"])
	}
}

// TestReadyzFault_LivenessDecoupledFromReadiness confirms that /healthz returns 200 even
// when /readyz is 503 (preventing Kubernetes CrashLoop restarts on external dependency outages).
func TestReadyzFault_LivenessDecoupledFromReadiness(t *testing.T) {
	h := &Handlers{
		CollectorHealth: func(context.Context) error { return errors.New("unhealthy") },
		AuditReady:      func(context.Context) error { return errors.New("unhealthy") },
	}

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	// Liveness check
	wHealthz := httptest.NewRecorder()
	mux.ServeHTTP(wHealthz, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if wHealthz.Code != http.StatusOK {
		t.Errorf("/healthz returned %d, want 200 (liveness must remain decoupled)", wHealthz.Code)
	}

	// Readiness check
	wReadyz := httptest.NewRecorder()
	mux.ServeHTTP(wReadyz, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if wReadyz.Code != http.StatusServiceUnavailable {
		t.Errorf("/readyz returned %d, want 503", wReadyz.Code)
	}
}
