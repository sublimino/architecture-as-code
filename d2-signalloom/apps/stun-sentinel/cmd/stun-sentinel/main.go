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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/telemetry"
)

type config struct {
	cgroupRoot  string
	listenAddr  string
	deadline    time.Duration
	resumeToken string
}

func loadConfig(args []string) (*config, error) {
	fs := flag.NewFlagSet("stun-sentinel", flag.ContinueOnError)
	root := fs.String("cgroup-root", envOr("CGROUP_ROOT", cgroup.DefaultCgroupRoot), "cgroup-v2 unified hierarchy root")
	addr := fs.String("listen-addr", envOr("LISTEN_ADDR", ":8080"), "HTTP listen address")
	deadline := fs.Duration("freeze-deadline", cgroup.DefaultFreezeDeadline, "hard deadline for observing the frozen state")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	// The resume credential is read from the environment only. Putting it on
	// the command line would publish it in every `ps` and in the pod spec.
	return &config{
		cgroupRoot:  *root,
		listenAddr:  *addr,
		deadline:    *deadline,
		resumeToken: os.Getenv("STUN_RESUME_TOKEN"),
	}, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// constantTimeTokenValidator authorises a resume against the governance token.
//
// An empty configured token denies everything rather than accepting
// everything: a daemon deployed without governance wiring must refuse to
// return capability to a contained workload, not hand it back to anyone who
// asks.
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
	freezer *cgroup.Freezer
	emitter *telemetry.Emitter
	// validate guards the HTTP surface. It is the same constant-time validator the
	// freezer uses for resume, held here so freeze is gated at the same strength as
	// unfreeze rather than being reachable by anyone who can open a socket.
	validate cgroup.CredentialValidator
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
		return http.StatusForbidden
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
		PodUID    string `json:"pod_uid"`
		PodName   string `json:"pod"`
		Namespace string `json:"namespace"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed body: " + err.Error()})
		return
	}

	res, err := s.freezer.FreezePod(req.PodUID)
	obs := observationFrom(res, req.PodName, req.Namespace)
	if err != nil {
		_ = s.emitter.StunExecutionHaltFailed(obs, err.Error())
		writeJSON(w, statusFor(err), map[string]any{"error": err.Error(), "result": res})
		return
	}
	_ = s.emitter.StunExecutionHalted(obs)
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

// requireBearer makes a handler unreachable without the governance credential.
//
// /stun previously had no credential check of any kind. Only /resume validated,
// and it did so deep in the cgroup layer, so anything that could reach this
// daemon on its listen address could freeze a pod by UID and could not unfreeze
// it. That asymmetry is worse than an open pair: the caller gets a denial of
// service and the operator loses the recovery path. The daemon runs privileged
// with hostPID in a pod-security privileged namespace, and its app directory
// carries no NetworkPolicy, so reachability is not a meaningful barrier.
//
// The validator is the same constant-time one used for resume, which denies
// everything when no token is configured. Freeze therefore fails closed on an
// unconfigured daemon rather than leaving the dangerous half open.
func requireBearer(validate cgroup.CredentialValidator, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if validate == nil {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "no credential validator configured"})
			return
		}
		// The credential travels in a header, never in the URL, so it stays out of
		// access logs, referrers and proxy logs.
		if !validate(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")) {
			// 403, not 401: the cgroup layer already maps a failed governance credential
			// to Forbidden and /resume's suite asserts it. One condition, one code.
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "governance credential required"})
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
	// Both state-changing routes are gated. Resume keeps its deeper validation in
	// the cgroup layer; this is the outer gate that stops an unauthenticated caller
	// reaching either handler at all.
	mux.HandleFunc("/stun", requireBearer(s.validate, s.handleStun))
	mux.HandleFunc("/resume", requireBearer(s.validate, s.handleResume))
	return mux
}

func run(args []string) error {
	cfg, err := loadConfig(args)
	if err != nil {
		return err
	}

	// One validator instance guards both the HTTP surface and the freezer's resume
	// path, so freeze and unfreeze cannot drift apart in strength.
	validate := constantTimeTokenValidator(cfg.resumeToken)
	srv := &server{
		freezer: cgroup.New(cfg.cgroupRoot,
			cgroup.WithDeadline(cfg.deadline),
			cgroup.WithCredentialValidator(validate),
		),
		emitter:  telemetry.NewEmitter(os.Stdout),
		validate: validate,
	}

	// An unconfigured token means every state-changing route refuses. Say so at
	// startup rather than letting an operator discover it during an incident.
	if cfg.resumeToken == "" {
		fmt.Fprintln(os.Stderr, "stun-sentinel: STUN_RESUME_TOKEN is empty — /stun and /resume will refuse every request")
		fmt.Fprintln(os.Stderr, "stun-sentinel: set it from the DaemonSet secret before relying on containment")
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
