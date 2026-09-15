// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Command stun-sentinel is the Tier 0 containment daemon. It runs as a
// privileged DaemonSet on every node, holds a read-write mount of the host
// cgroup-v2 hierarchy, and halts a compromised agent container's execution
// in-kernel on demand.
//
// Structure note for CRKC-P1-3: this file is deliberately thin. It owns
// flag parsing, the HTTP surface, and wiring — nothing else. Enforcement
// logic lives behind an interface in pkg/, so the network-containment half
// can be added by registering another handler and another emitter
// constructor without touching the code below.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/quarantine"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/telemetry"
)

type config struct {
	cgroupRoot        string
	listenAddr        string
	deadline          time.Duration
	freezeToken       string
	resumeToken       string
	quarantineDir     string
	quarantineMaxMB   int64
	quarantineTimeout time.Duration
}

func loadConfig(args []string) (*config, error) {
	fs := flag.NewFlagSet("stun-sentinel", flag.ContinueOnError)
	root := fs.String("cgroup-root", envOr("CGROUP_ROOT", cgroup.DefaultCgroupRoot), "cgroup-v2 unified hierarchy root")
	addr := fs.String("listen-addr", envOr("LISTEN_ADDR", ":8080"), "HTTP listen address")
	deadline := fs.Duration("freeze-deadline", cgroup.DefaultFreezeDeadline, "hard deadline for observing the frozen state")
	qDir := fs.String("quarantine-dir", envOr("STUN_QUARANTINE_DIR", quarantine.DefaultStorageDir), "directory for storing quarantine snapshots")
	qMaxMB := fs.Int64("quarantine-max-mb", 64, "maximum memory snapshot size in megabytes")
	qTimeout := fs.Duration("quarantine-timeout", quarantine.DefaultMaxTimeBudget, "maximum time budget for forensic capture")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	// The freeze and resume credentials are read from the environment only. Putting them on
	// the command line would publish them in every `ps` and in the pod spec.
	return &config{
		cgroupRoot:        *root,
		listenAddr:        *addr,
		deadline:          *deadline,
		freezeToken:       os.Getenv("STUN_FREEZE_TOKEN"),
		resumeToken:       os.Getenv("STUN_RESUME_TOKEN"),
		quarantineDir:     *qDir,
		quarantineMaxMB:   *qMaxMB,
		quarantineTimeout: *qTimeout,
	}, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// constantTimeTokenValidator authorises a request against the expected token.
//
// An empty configured token denies everything rather than accepting
// everything: a daemon deployed without governance wiring must refuse to
// act on a workload, not hand control to anyone who asks.
func constantTimeTokenValidator(expected string) cgroup.CredentialValidator {
	return func(got string) bool {
		if expected == "" || got == "" {
			return false
		}
		// Compare over a fixed width so the check does not leak length.
		if len(got) != len(expected) {
			return false
		}
		var diff byte
		for i := range expected {
			diff |= expected[i] ^ got[i]
		}
		return diff == 0
	}
}

type server struct {
	freezer        *cgroup.Freezer
	emitter        *telemetry.Emitter
	capturer       *quarantine.Capturer
	freezeValidate cgroup.CredentialValidator
	resumeValidate cgroup.CredentialValidator
}

func observationFrom(res *cgroup.FreezeResult, podName, namespace string) telemetry.FreezeObservation {
	return telemetry.FreezeObservation{
		PodUID:     res.PodUID,
		PodName:    podName,
		Namespace:  namespace,
		CgroupPath: res.CgroupPath,
		Frozen:     res.Frozen,
		LatencyMS:  res.LatencyMS,
		DeadlineMS: float64(res.Deadline.Nanoseconds()) / 1e6,
		Polls:      res.Polls,
		PIDs:       res.PIDs,
	}
}

func quarantineObservationFrom(m *quarantine.QuarantineManifest, pids []int) telemetry.QuarantineObservation {
	return telemetry.QuarantineObservation{
		PodUID:            m.Target.PodUID,
		PodName:           m.Target.PodName,
		Namespace:         m.Target.Namespace,
		CgroupPath:        m.Target.CgroupPath,
		SnapshotID:        m.CaptureID,
		SnapshotPath:      m.StoragePath,
		SnapshotSizeBytes: m.Summary.TotalSnapshotSizeBytes,
		CaptureDurationMS: m.CaptureDurationMS,
		ProcessCount:      m.Summary.ProcessCount,
		FDCount:           m.Summary.TotalFDCount,
		SocketCount:       m.Summary.TotalSocketCount,
		LockCount:         m.Summary.TotalLockCount,
		Partial:           m.Partial,
		PartialReason:     m.PartialReason,
		PIDs:              pids,
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// statusFor maps a containment failure onto an HTTP status an operator can
// act on without reading the daemon's logs.
func statusFor(err error) int {
	switch {
	case errors.Is(err, cgroup.ErrInvalidPodUID):
		return http.StatusBadRequest
	case errors.Is(err, cgroup.ErrUnauthorized):
		return http.StatusUnauthorized
	case errors.Is(err, cgroup.ErrCgroupNotFound):
		return http.StatusNotFound
	case errors.Is(err, cgroup.ErrPermission):
		// The daemon is misconfigured, not the request.
		return http.StatusInternalServerError
	case errors.Is(err, cgroup.ErrFreezeDeadline):
		// Containment was attempted and could not be proven. 504 rather than
		// 500: the distinction matters to whoever is deciding whether to
		// escalate to eviction.
		return http.StatusGatewayTimeout
	default:
		return http.StatusInternalServerError
	}
}

func (s *server) handleStun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
		return
	}
	var req struct {
		PodUID            string `json:"pod_uid"`
		PodName           string `json:"pod"`
		Namespace         string `json:"namespace"`
		CaptureQuarantine bool   `json:"capture_quarantine"`
		Quarantine        bool   `json:"quarantine"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed body: " + err.Error()})
		return
	}
	credential := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	captureQuarantine := req.CaptureQuarantine || req.Quarantine

	opts := cgroup.FreezeOptions{
		CaptureQuarantine: captureQuarantine,
		PodUID:            req.PodUID,
		PodName:           req.PodName,
		Namespace:         req.Namespace,
	}

	res, err := s.freezer.FreezePodWithOptions(r.Context(), req.PodUID, credential, opts)
	obs := observationFrom(res, req.PodName, req.Namespace)
	if err != nil {
		_ = s.emitter.StunExecutionHaltFailed(obs, err.Error())
		writeJSON(w, statusFor(err), map[string]any{"error": err.Error(), "result": res})
		return
	}
	_ = s.emitter.StunExecutionHalted(obs)

	// Emit forensic quarantine telemetry if snapshotting was performed
	if res.Quarantine != nil {
		qObs := quarantineObservationFrom(res.Quarantine, res.PIDs)
		if res.Quarantine.Partial {
			_ = s.emitter.QuarantineSnapshotPartial(qObs)
		} else {
			_ = s.emitter.QuarantineSnapshotCaptured(qObs)
		}
	}

	writeJSON(w, http.StatusOK, res)
}

func (s *server) handleResume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
		return
	}
	var req struct {
		PodUID    string `json:"pod_uid"`
		PodName   string `json:"pod"`
		Namespace string `json:"namespace"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed body: " + err.Error()})
		return
	}
	// The governance credential travels in a header, never in the URL.
	credential := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")

	res, err := s.freezer.UnfreezePod(req.PodUID, credential)
	if err != nil {
		writeJSON(w, statusFor(err), map[string]any{"error": err.Error(), "result": res})
		return
	}
	_ = s.emitter.StunExecutionResumed(observationFrom(res, req.PodName, req.Namespace))
	writeJSON(w, http.StatusOK, res)
}

func (s *server) handleListSnapshots(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "GET required"})
		return
	}
	if s.capturer == nil {
		writeJSON(w, http.StatusOK, []*quarantine.QuarantineManifest{})
		return
	}
	snapshots, err := s.capturer.ListSnapshots()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, snapshots)
}

func (s *server) handleGetSnapshot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "GET required"})
		return
	}
	if s.capturer == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "snapshot capturer not configured"})
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/quarantine/snapshots/")
	if id == "" {
		s.handleListSnapshots(w, r)
		return
	}
	snapshot, err := s.capturer.GetSnapshot(id)
	if err != nil {
		if errors.Is(err, quarantine.ErrSnapshotNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "snapshot not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *server) handlePruneSnapshots(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
		return
	}
	if s.capturer == nil {
		writeJSON(w, http.StatusOK, &quarantine.PruneResult{})
		return
	}
	res, err := s.capturer.Prune()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// handleHealth proves the daemon can write the host cgroup hierarchy. A
// read-only hostPath mount passes every other check and fails only here,
// which is exactly the misconfiguration this endpoint exists to surface —
// before an incident rather than during one.
func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	if err := s.freezer.HealthCheck(); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"status":       "unhealthy",
			"cgroup_root":  s.freezer.Root(),
			"cgroup_write": false,
			"error":        err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "ok",
		"cgroup_root":  s.freezer.Root(),
		"cgroup_write": true,
		"deadline_ms":  float64(s.freezer.Deadline().Nanoseconds()) / 1e6,
	})
}

// requireBearer makes a handler unreachable without a valid governance credential.
//
// Both /stun and /resume are gated on distinct credentials. The validator is
// constant-time and denies everything when no token is configured. An invalid or
// missing credential results in HTTP 401 Unauthorized before any cgroup operations
// or request body decodings take place.
func requireBearer(validate cgroup.CredentialValidator, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if validate == nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "no credential validator configured"})
			return
		}
		// The credential travels in a header, never in the URL, so it stays out of
		// access logs, referrers and proxy logs.
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !validate(token) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "governance credential required"})
			return
		}
		next(w, r)
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	// Liveness and readiness stay open: a kubelet probe carries no credential, and
	// neither handler reveals anything beyond cgroup writability.
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/readyz", s.handleHealth)
	// Both state-changing routes are gated on distinct tokens. Freeze and resume
	// keep their deeper validation in the cgroup layer; this is the outer gate
	// that stops an unauthenticated caller reaching either handler at all.
	mux.HandleFunc("/stun", requireBearer(s.freezeValidate, s.handleStun))
	mux.HandleFunc("/resume", requireBearer(s.resumeValidate, s.handleResume))
	// Quarantine inspection and maintenance endpoints
	mux.HandleFunc("/quarantine/snapshots", s.handleListSnapshots)
	mux.HandleFunc("/quarantine/snapshots/", s.handleGetSnapshot)
	mux.HandleFunc("/quarantine/prune", requireBearer(s.freezeValidate, s.handlePruneSnapshots))
	return mux
}

func run(args []string) error {
	cfg, err := loadConfig(args)
	if err != nil {
		return err
	}

	// Startup fail-fast checks:
	// 1. STUN_FREEZE_TOKEN must be configured and non-empty.
	if cfg.freezeToken == "" {
		return errors.New("stun-sentinel: STUN_FREEZE_TOKEN is required and cannot be empty")
	}
	// 2. STUN_RESUME_TOKEN must be configured and non-empty.
	if cfg.resumeToken == "" {
		return errors.New("stun-sentinel: STUN_RESUME_TOKEN is required and cannot be empty")
	}
	// 3. STUN_FREEZE_TOKEN and STUN_RESUME_TOKEN must not share the same value.
	if cfg.freezeToken == cfg.resumeToken {
		return errors.New("stun-sentinel: STUN_FREEZE_TOKEN and STUN_RESUME_TOKEN must be distinct credentials")
	}

	freezeValidate := constantTimeTokenValidator(cfg.freezeToken)
	resumeValidate := constantTimeTokenValidator(cfg.resumeToken)
	capturer := quarantine.New(quarantine.CaptureConfig{
		StorageDir:         cfg.quarantineDir,
		MaxMemorySizeBytes: cfg.quarantineMaxMB * 1024 * 1024,
		MaxTimeBudget:      cfg.quarantineTimeout,
		DumpAnonymousOnly:  true,
	})
	srv := &server{
		freezer: cgroup.New(cfg.cgroupRoot,
			cgroup.WithDeadline(cfg.deadline),
			cgroup.WithFreezeCredentialValidator(freezeValidate),
			cgroup.WithCredentialValidator(resumeValidate),
			cgroup.WithQuarantineCapturer(capturer),
		),
		emitter:        telemetry.NewEmitter(os.Stdout),
		capturer:       capturer,
		freezeValidate: freezeValidate,
		resumeValidate: resumeValidate,
	}

	// Fail loudly at startup rather than at the first incident.
	if err := srv.freezer.HealthCheck(); err != nil {
		fmt.Fprintf(os.Stderr, "stun-sentinel: cgroup hierarchy is not writable: %v\n", err)
		fmt.Fprintf(os.Stderr, "stun-sentinel: check the DaemonSet mounts %s read-write and runs privileged\n", cfg.cgroupRoot)
		return err
	}

	httpServer := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		fmt.Fprintf(os.Stderr, "stun-sentinel: listening on %s, cgroup root %s, freeze deadline %s\n",
			cfg.listenAddr, cfg.cgroupRoot, cfg.deadline)
		errCh <- httpServer.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "stun-sentinel: %v\n", err)
		os.Exit(1)
	}
}
