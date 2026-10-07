package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
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
	// ResyncSeconds is the pod informer's resync interval, so a containment
	// check can wait out one resync instead of guessing a sleep.
	ResyncSeconds int64 `json:"resync_seconds"`
	// FleetStunFailures counts failed stun deliveries to fleet-manager: each is
	// a correlator freeze held in the kernel without its stun record or pin.
	FleetStunFailures int64 `json:"fleet_stun_failures"`
	// RingbufDrops is the count of records discarded due to ring buffer overflow.
	RingbufDrops uint64 `json:"ringbuf_drops"`
	// RingbufPrefiltered is the count of open records filtered out before the ring buffer.
	RingbufPrefiltered uint64 `json:"ringbuf_prefiltered"`
}

// HealthServer serves HTTP health and readiness probes on a configured address (default :8081).
type HealthServer struct {
	addr           string
	dryRun         bool
	cgroupDriver   string
	tcReady        func() bool
	reconcileCount *atomic.Int64
	// isReady returns true when the probe is armed and ready for traffic.
	isReady func() bool
	// frozenUnlabelled backs the sentinel_frozen_unlabelled_pods gauge.
	frozenUnlabelled func() int
	// fleetStunFailures counts correlator freezes fleet-manager did not record.
	fleetStunFailures func() int64
	// drops and prefiltered report eBPF probe ring buffer statistics.
	drops       func() (uint64, error)
	prefiltered func() (uint64, error)
	// captures serves GET /captures and /captures/<id>[/<artifact>]
	// (capture.go); nil means 404. Only the manifest and the two
	// spec-analogue artifacts are served, never the quarantine snapshot with
	// its process memory, and every request passes capturesGate first.
	captures *captureWriter
	// capturesToken returns the bearer a reader must present; "" means the
	// route is disabled (403 captures_disabled). Read per request so a
	// Secret mounted after start is honoured.
	capturesToken func() string
	// capturesAllow lists the source networks a reader may come from. The
	// warden is hostNetwork, so no NetworkPolicy can bind this listener; this
	// in-process list is the enforced network control. Default: loopback.
	capturesAllow []*net.IPNet
	server        *http.Server
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

// Handler returns the http.Handler serving /healthz (liveness) and /readyz (readiness) endpoints.
func (h *HealthServer) Handler() http.Handler {
	mux := http.NewServeMux()
	livenessHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		var ringbufDrops, ringbufPrefiltered uint64
		if h.drops != nil {
			if d, err := h.drops(); err == nil {
				ringbufDrops = d
			}
		}
		if h.prefiltered != nil {
			if p, err := h.prefiltered(); err == nil {
				ringbufPrefiltered = p
			}
		}
		resp := HealthResponse{
			Status:             "ok",
			DryRun:             h.dryRun,
			CgroupDriver:       h.cgroupDriver,
			TCReady:            tcReady,
			ReconcileCount:     count,
			ResyncSeconds:      int64(informerResync / time.Second),
			RingbufDrops:       ringbufDrops,
			RingbufPrefiltered: ringbufPrefiltered,
		}
		if h.fleetStunFailures != nil {
			resp.FleetStunFailures = h.fleetStunFailures()
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	readinessHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		var ringbufDrops, ringbufPrefiltered uint64
		if h.drops != nil {
			if d, err := h.drops(); err == nil {
				ringbufDrops = d
			}
		}
		if h.prefiltered != nil {
			if p, err := h.prefiltered(); err == nil {
				ringbufPrefiltered = p
			}
		}
		status := "ok"
		ready := true
		if h.isReady != nil && !h.isReady() {
			status = "cutover_waiting"
			ready = false
		}
		resp := HealthResponse{
			Status:             status,
			DryRun:             h.dryRun,
			CgroupDriver:       h.cgroupDriver,
			TCReady:            tcReady,
			ReconcileCount:     count,
			ResyncSeconds:      int64(informerResync / time.Second),
			RingbufDrops:       ringbufDrops,
			RingbufPrefiltered: ringbufPrefiltered,
		}
		if h.fleetStunFailures != nil {
			resp.FleetStunFailures = h.fleetStunFailures()
		}
		w.Header().Set("Content-Type", "application/json")
		if !ready {
			w.WriteHeader(http.StatusServiceUnavailable)
		} else {
			w.WriteHeader(http.StatusOK)
		}
		_ = json.NewEncoder(w).Encode(resp)
	})

	mux.Handle("/healthz", livenessHandler)
	mux.Handle("/health", livenessHandler)
	mux.Handle("/readyz", readinessHandler)
	mux.HandleFunc("/metrics", h.serveMetrics)
	mux.HandleFunc("/captures", h.serveCaptures)
	mux.HandleFunc("/captures/", h.serveCaptures)
	return mux
}

// serveCaptures answers /captures (ids), /captures/<id> (manifest.json) and
// /captures/<id>/<artifact> for the served artifact set only.
func (h *HealthServer) serveCaptures(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	if h.captures == nil {
		http.NotFound(w, r)
		return
	}
	if status, code := h.capturesGate(r); status != 0 {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="signalloom-warden-captures"`)
		}
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": code})
		return
	}
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/captures"), "/")
	if rest == "" {
		ids, err := h.captures.ids()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"kind": captureKind, "captures": ids})
		return
	}
	id, name, _ := strings.Cut(rest, "/")
	if name == "" {
		name = captureManifestFile
	}
	body, ctype, err := h.captures.open(id, name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

// capturesGate decides whether a /captures request may proceed: the source
// address must be inside capturesAllow and the Authorization header must
// carry the configured bearer. The token comparison is constant-time and the
// network check runs first, so an address outside the list learns nothing
// about the token. Returns (0, "") when the request may proceed.
func (h *HealthServer) capturesGate(r *http.Request) (int, string) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	allow := h.capturesAllow
	if allow == nil {
		allow = defaultCapturesAllow()
	}
	permitted := false
	for _, n := range allow {
		if ip != nil && n.Contains(ip) {
			permitted = true
			break
		}
	}
	if !permitted {
		return http.StatusForbidden, "captures_source_not_allowed"
	}
	want := ""
	if h.capturesToken != nil {
		want = strings.TrimSpace(h.capturesToken())
	}
	if want == "" {
		return http.StatusForbidden, "captures_disabled"
	}
	scheme, got, found := strings.Cut(r.Header.Get("Authorization"), " ")
	if !found || !strings.EqualFold(scheme, "Bearer") ||
		subtle.ConstantTimeCompare([]byte(strings.TrimSpace(got)), []byte(want)) != 1 {
		return http.StatusUnauthorized, "captures_unauthorized"
	}
	return 0, ""
}

// defaultCapturesAllow is loopback only: a reader on the node itself
// (kubectl exec, a node-local operator), nothing across the network.
func defaultCapturesAllow() []*net.IPNet {
	nets, _ := parseCIDRList("127.0.0.0/8,::1/128")
	return nets
}

// parseCIDRList parses a comma-separated CIDR list; a bare address is a host.
func parseCIDRList(list string) ([]*net.IPNet, error) {
	var out []*net.IPNet
	for _, item := range strings.Split(list, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if !strings.Contains(item, "/") {
			if ip := net.ParseIP(item); ip != nil {
				if ip.To4() != nil {
					item += "/32"
				} else {
					item += "/128"
				}
			}
		}
		_, n, err := net.ParseCIDR(item)
		if err != nil {
			return nil, fmt.Errorf("captures allow list: %q: %w", item, err)
		}
		out = append(out, n)
	}
	return out, nil
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
	if h.drops != nil {
		if d, err := h.drops(); err == nil {
			fmt.Fprintf(w, "# HELP sentinel_ringbuf_drops_total Total kernel ring buffer drops due to buffer saturation.\n")
			fmt.Fprintf(w, "# TYPE sentinel_ringbuf_drops_total counter\n")
			fmt.Fprintf(w, "sentinel_ringbuf_drops_total %d\n", d)
		}
	}
	if h.prefiltered != nil {
		if p, err := h.prefiltered(); err == nil {
			fmt.Fprintf(w, "# HELP sentinel_ringbuf_prefiltered_total Total opens filtered before reserving ring buffer space.\n")
			fmt.Fprintf(w, "# TYPE sentinel_ringbuf_prefiltered_total counter\n")
			fmt.Fprintf(w, "sentinel_ringbuf_prefiltered_total %d\n", p)
		}
	}
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
