package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestHealthHandlerReturns200AndExpectedJSON(t *testing.T) {
	reconcileCount := &atomic.Int64{}
	reconcileCount.Store(42)

	srv := &HealthServer{
		addr:           ":8081",
		dryRun:         true,
		cgroupDriver:   "systemd",
		tcReady:        func() bool { return true },
		reconcileCount: reconcileCount,
	}

	handler := srv.Handler()

	// Test /healthz
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("/healthz status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}

	var resp HealthResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode JSON response: %v", err)
	}

	if resp.Status != "ok" {
		t.Errorf("Status = %q, want ok", resp.Status)
	}
	if !resp.DryRun {
		t.Errorf("DryRun = false, want true")
	}
	if resp.CgroupDriver != "systemd" {
		t.Errorf("CgroupDriver = %q, want systemd", resp.CgroupDriver)
	}
	if !resp.TCReady {
		t.Errorf("TCReady = false, want true")
	}
	if resp.ReconcileCount != 42 {
		t.Errorf("ReconcileCount = %d, want 42", resp.ReconcileCount)
	}

	// Test /readyz alias
	readyReq := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	readyRec := httptest.NewRecorder()
	handler.ServeHTTP(readyRec, readyReq)
	if readyRec.Code != http.StatusOK {
		t.Fatalf("/readyz status = %d, want 200", readyRec.Code)
	}
}

func TestHealthHandlerRejectsNonGetMethods(t *testing.T) {
	srv := &HealthServer{
		addr:         ":8081",
		dryRun:       false,
		cgroupDriver: "systemd",
	}
	handler := srv.Handler()

	for _, endpoint := range []string{"/healthz", "/health", "/readyz", "/metrics", "/captures"} {
		req := httptest.NewRequest(http.MethodPost, endpoint, nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("POST %s status = %d, want 405", endpoint, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Errorf("POST %s Allow = %q, want 'GET, HEAD'", endpoint, allow)
		}
	}
}

func TestHealthHandlerHEADRequests(t *testing.T) {
	srv := &HealthServer{
		addr:         ":8081",
		dryRun:       false,
		cgroupDriver: "systemd",
		tcReady:      func() bool { return true },
	}
	handler := srv.Handler()

	for _, endpoint := range []string{"/healthz", "/health", "/readyz", "/metrics"} {
		req := httptest.NewRequest(http.MethodHead, endpoint, nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Errorf("HEAD %s status = %d, want 200", endpoint, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s wrote body: %s", endpoint, rec.Body.String())
		}
		if ct := rec.Header().Get("Content-Type"); ct == "" {
			t.Errorf("HEAD %s missing Content-Type header", endpoint)
		}
	}
}

func TestHealthHandlerHEADErrorBodySuppression(t *testing.T) {
	srv := &HealthServer{
		addr:         ":8081",
		dryRun:       false,
		cgroupDriver: "systemd",
		tcReady:      func() bool { return true },
		isReady:      func() bool { return false }, // readyz returns 503 cutover_waiting
	}
	handler := srv.Handler()

	// 1. Readyz 503 on HEAD returns empty body and application/json Content-Type
	req := httptest.NewRequest(http.MethodHead, "/readyz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("HEAD /readyz status = %d, want 503", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /readyz wrote body: %s", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD /readyz Content-Type = %q, want application/json", ct)
	}

	// 2. Captures 404 on HEAD when captures is nil
	req = httptest.NewRequest(http.MethodHead, "/captures", nil)
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Errorf("HEAD /captures status = %d, want 404", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /captures wrote body: %s", rec.Body.String())
	}

	// 3. Unknown route 404 on HEAD
	req = httptest.NewRequest(http.MethodHead, "/nonexistent", nil)
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Errorf("HEAD /nonexistent status = %d, want 404", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /nonexistent wrote body: %s", rec.Body.String())
	}
}

func TestDetectCgroupDriver(t *testing.T) {
	// 1. Env var override
	t.Setenv("CGROUP_DRIVER", "custom-driver")
	if d := detectCgroupDriver("/tmp"); d != "custom-driver" {
		t.Errorf("driver = %q, want custom-driver", d)
	}
	os.Unsetenv("CGROUP_DRIVER")

	// 2. Systemd slice detection
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "kubepods.slice"), 0755)
	if d := detectCgroupDriver(dir); d != "systemd" {
		t.Errorf("driver = %q, want systemd", d)
	}

	// 3. Cgroupfs detection
	dirFs := t.TempDir()
	os.MkdirAll(filepath.Join(dirFs, "kubepods"), 0755)
	if d := detectCgroupDriver(dirFs); d != "cgroupfs" {
		t.Errorf("driver = %q, want cgroupfs", d)
	}
}

func TestHealthServerGracefulLifecycle(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	reconcileCount := &atomic.Int64{}

	srv := newHealthServer("127.0.0.1:0", false, "/tmp", reconcileCount)

	serverErrCh := make(chan error, 1)
	go func() {
		serverErrCh <- srv.Start(ctx)
	}()

	// Give server a moment to bind
	time.Sleep(50 * time.Millisecond)

	// Cancel context to trigger shutdown
	cancel()

	select {
	case err := <-serverErrCh:
		if err != nil {
			t.Fatalf("server exited with error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("health server did not shut down within deadline")
	}
}

// The e2e Step 5 waits out one resync before re-reading the kernel; the value
// it reads must be the interval the informer actually runs with.
func TestHealthPublishesTheInformerResyncInterval(t *testing.T) {
	srv := &HealthServer{tcReady: func() bool { return true }}
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	var resp HealthResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if want := int64(informerResync / time.Second); resp.ResyncSeconds != want || want <= 0 {
		t.Fatalf("resync_seconds = %d, want %d", resp.ResyncSeconds, want)
	}
}

// A correlator freeze fleet-manager never recorded must be visible without log
// access: it is frozen in the kernel with no stun record and no Flux pin.
func TestHealthReportsFleetStunFailures(t *testing.T) {
	srv := &HealthServer{tcReady: func() bool { return true }, fleetStunFailures: func() int64 { return 3 }}
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	var resp HealthResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.FleetStunFailures != 3 {
		t.Fatalf("fleet_stun_failures = %d, want 3 (body %s)", resp.FleetStunFailures, w.Body.String())
	}
}
