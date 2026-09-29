package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

// HealthResponse defines the JSON schema returned by /healthz.
type HealthResponse struct {
	Status         string `json:"status"`
	DryRun         bool   `json:"dry_run"`
	CgroupDriver   string `json:"cgroup_driver"`
	TCReady        bool   `json:"tc_ready"`
	ReconcileCount int64  `json:"reconcile_count"`
}

// HealthServer serves HTTP health and readiness probes on a configured address (default :8081).
type HealthServer struct {
	addr           string
	dryRun         bool
	cgroupDriver   string
	tcReady        func() bool
	reconcileCount *atomic.Int64
	// frozenUnlabelled backs the sentinel_frozen_unlabelled_pods gauge.
	frozenUnlabelled func() int
	server           *http.Server
}

func newHealthServer(addr string, dryRun bool, cgroupRoot string, reconcileCount *atomic.Int64) *HealthServer {
	driver := detectCgroupDriver(cgroupRoot)
	return &HealthServer{
		addr:           addr,
		dryRun:         dryRun,
		cgroupDriver:   driver,
		tcReady:        checkTCReady,
		reconcileCount: reconcileCount,
	}
}

// Handler returns the http.Handler serving /healthz and /readyz endpoints.
func (h *HealthServer) Handler() http.Handler {
	mux := http.NewServeMux()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		tcReady := true
		if h.tcReady != nil {
			tcReady = h.tcReady()
		}
		var count int64
		if h.reconcileCount != nil {
			count = h.reconcileCount.Load()
		}
		resp := HealthResponse{
			Status:         "ok",
			DryRun:         h.dryRun,
			CgroupDriver:   h.cgroupDriver,
			TCReady:        tcReady,
			ReconcileCount: count,
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})
	mux.Handle("/healthz", handler)
	mux.Handle("/readyz", handler)
	mux.Handle("/health", handler)
	mux.HandleFunc("/metrics", h.serveMetrics)
	return mux
}

// serveMetrics writes Prometheus text exposition without a client library.
func (h *HealthServer) serveMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	n := 0
	if h.frozenUnlabelled != nil {
		n = h.frozenUnlabelled()
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP sentinel_frozen_unlabelled_pods Pods whose cgroup.events reports frozen 1 with no stun label and no owner stun record.\n")
	fmt.Fprintf(w, "# TYPE sentinel_frozen_unlabelled_pods gauge\n")
	fmt.Fprintf(w, "sentinel_frozen_unlabelled_pods %d\n", n)
}

// Start launches the HTTP health server and stops gracefully when the context is cancelled.
func (h *HealthServer) Start(ctx context.Context) error {
	h.server = &http.Server{
		Addr:              h.addr,
		Handler:           h.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = h.server.Shutdown(shutdownCtx)
	}()
	if err := h.server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func checkTCReady() bool {
	_, err := exec.LookPath("tc")
	return err == nil
}

// detectCgroupDriver inspects the cgroup hierarchy to identify systemd vs cgroupfs driver.
func detectCgroupDriver(cgroupRoot string) string {
	if driver := os.Getenv("CGROUP_DRIVER"); driver != "" {
		return driver
	}
	entries, err := os.ReadDir(cgroupRoot)
	if err == nil {
		for _, e := range entries {
			if e.IsDir() && (strings.HasSuffix(e.Name(), ".slice") || strings.Contains(e.Name(), "slice")) {
				return "systemd"
			}
		}
	}
	if _, err := os.Stat(filepath.Join(cgroupRoot, "kubepods")); err == nil {
		return "cgroupfs"
	}
	return "systemd"
}
