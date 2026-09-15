// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Command stun-sentinel is the Tier 0 containment daemon. It runs as a
// privileged DaemonSet on every node, holds a read-write mount of the host
// cgroup-v2 hierarchy, and halts a compromised agent container's execution
// in-kernel on demand.
//
// Structure note for CRKC-P1-3 / SLER-P4-3: this file owns flag parsing, the
// HTTP surface, and wiring. Governance-gated resume verifies Ed25519-signed
// resume tokens against a node-local operator key registry and attributes the
// operator identity in forensic telemetry records.
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

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/auth"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/telemetry"
)

type config struct {
	cgroupRoot         string
	listenAddr         string
	deadline           time.Duration
	freezeToken        string
	resumeToken        string
	operatorKeyPath    string
	operatorKeysJSON   string
	audience           string
	trustRootID        string
	requiredSignatures int
}

func loadConfig(args []string) (*config, error) {
	fs := flag.NewFlagSet("stun-sentinel", flag.ContinueOnError)
	root := fs.String("cgroup-root", envOr("CGROUP_ROOT", cgroup.DefaultCgroupRoot), "cgroup-v2 unified hierarchy root")
	addr := fs.String("listen-addr", envOr("LISTEN_ADDR", ":8080"), "HTTP listen address")
	deadline := fs.Duration("freeze-deadline", cgroup.DefaultFreezeDeadline, "hard deadline for observing the frozen state")
	keyPath := fs.String("operator-key-path", envOr("OPERATOR_KEY_BUNDLE_FILE", envOr("OPERATOR_KEY_PATH", envOr("OPERATOR_KEY_DIR", ""))), "path to operator public key JSON bundle or directory")
	audience := fs.String("audience", envOr("AUDIENCE", "osramp-fleet"), "target fleet audience for resume tokens")
	trustRootID := fs.String("trust-root-id", envOr("TRUST_ROOT_ID", "sler-root-2026"), "pinned operator key trust root ID")
	reqSigs := fs.Int("required-signatures", 1, "minimum required distinct operator signatures")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	// The freeze and resume credentials are read from the environment only.
	return &config{
		cgroupRoot:         *root,
		listenAddr:         *addr,
		deadline:           *deadline,
		freezeToken:        os.Getenv("STUN_FREEZE_TOKEN"),
		resumeToken:        os.Getenv("STUN_RESUME_TOKEN"),
		operatorKeyPath:    *keyPath,
		operatorKeysJSON:   os.Getenv("OPERATOR_KEYS_JSON"),
		audience:           *audience,
		trustRootID:        *trustRootID,
		requiredSignatures: *reqSigs,
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

// ed25519ResumeValidator verifies an Ed25519 token or falls back to legacy shared secret.
func ed25519ResumeValidator(registry auth.OperatorKeyRegistry, policy auth.ResumeTokenPolicy, fallbackToken string) cgroup.CredentialValidator {
	return func(got string) bool {
		if got == "" {
			return false
		}
		// Attempt Ed25519 token verification
		token, err := auth.ParseResumeToken(got)
		if err == nil {
			if registry != nil {
				_, vErr := auth.VerifyResumeToken(token, auth.TargetRef{}, registry, policy, time.Now().UTC())
				if vErr == nil {
					return true
				}
			}
		}

		// Fallback to symmetric token validator if configured (legacy compatibility)
		if fallbackToken != "" {
			return constantTimeTokenValidator(fallbackToken)(got)
		}
		return false
	}
}

type server struct {
	freezer        *cgroup.Freezer
	emitter        *telemetry.Emitter
	freezeValidate cgroup.CredentialValidator
	resumeValidate cgroup.CredentialValidator
	keyRegistry    auth.OperatorKeyRegistry
	policy         auth.ResumeTokenPolicy
	replayLedger   *auth.ReplayLedger
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
	case errors.Is(err, cgroup.ErrUnauthorized),
		errors.Is(err, auth.ErrResumeTokenMalformed),
		errors.Is(err, auth.ErrResumeTokenSchemaVersion),
		errors.Is(err, auth.ErrResumeTokenUnsupportedAlgorithm),
		errors.Is(err, auth.ErrResumeTokenProjectionMismatch),
		errors.Is(err, auth.ErrResumeTokenShortNonce),
		errors.Is(err, auth.ErrResumeTokenTargetMismatch),
		errors.Is(err, auth.ErrResumeTokenAudienceMismatch),
		errors.Is(err, auth.ErrResumeTokenExpired),
		errors.Is(err, auth.ErrResumeTokenNotYetValid),
		errors.Is(err, auth.ErrResumeTokenLifetimeTooLong),
		errors.Is(err, auth.ErrResumeTokenUnknownKey),
		errors.Is(err, auth.ErrResumeTokenRevokedKey),
		errors.Is(err, auth.ErrResumeTokenKeyIDMismatch),
		errors.Is(err, auth.ErrResumeTokenOperatorMismatch),
		errors.Is(err, auth.ErrResumeTokenBadSignature),
		errors.Is(err, auth.ErrResumeTokenDuplicateSigner),
		errors.Is(err, auth.ErrResumeTokenInsufficientSignature),
		errors.Is(err, auth.ErrResumeTokenTrustRootMismatch),
		errors.Is(err, auth.ErrResumeTokenSignedAtOutOfWindow),
		errors.Is(err, auth.ErrResumeTokenApprovalWindowExceed),
		errors.Is(err, auth.ErrResumeTokenReplayed):
		return http.StatusUnauthorized
	case errors.Is(err, cgroup.ErrCgroupNotFound):
		return http.StatusNotFound
	case errors.Is(err, cgroup.ErrPermission):
		return http.StatusInternalServerError
	case errors.Is(err, cgroup.ErrFreezeDeadline):
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
	credential := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")

	res, err := s.freezer.FreezePod(req.PodUID, credential)
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
		PodUID         string            `json:"pod_uid"`
		PodName        string            `json:"pod"`
		Namespace      string            `json:"namespace"`
		AgentID        string            `json:"agent_id"`
		IdempotencyKey string            `json:"idempotency_key"`
		Token          *auth.ResumeToken `json:"token,omitempty"`
		TokenString    string            `json:"token_string,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed body: " + err.Error()})
		return
	}
	// The governance credential travels in a header or request body
	headerCred := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")

	var token auth.ResumeToken
	var tokenParsed bool

	if req.Token != nil && req.Token.TokenID != "" {
		token = *req.Token
		tokenParsed = true
	} else if req.TokenString != "" {
		if t, err := auth.ParseResumeToken(req.TokenString); err == nil {
			token = t
			tokenParsed = true
		}
	} else if headerCred != "" {
		if t, err := auth.ParseResumeToken(headerCred); err == nil {
			token = t
			tokenParsed = true
		}
	}

	var operatorIDs []string
	var tokenID string

	// Perform Ed25519 verification if token was provided and registry is configured
	if tokenParsed {
		target := auth.TargetRef{
			AgentID:   req.AgentID,
			Namespace: req.Namespace,
			PodUID:    req.PodUID,
		}
		vRes, err := auth.VerifyResumeToken(token, target, s.keyRegistry, s.policy, time.Now().UTC())
		if err != nil {
			writeJSON(w, statusFor(err), map[string]any{
				"error":     fmt.Sprintf("resume token verification failed: %v", err),
				"error_tag": err.Error(),
			})
			return
		}
		operatorIDs = vRes.OperatorIDs
		tokenID = token.TokenID

		// Replay & Idempotency check
		if s.replayLedger != nil {
			isRetry, cachedOps, repErr := s.replayLedger.CheckAndRecord(token.TokenID, req.IdempotencyKey, operatorIDs, time.Now().UTC())
			if repErr != nil {
				writeJSON(w, statusFor(repErr), map[string]any{
					"error": fmt.Sprintf("replay protection: %v", repErr),
				})
				return
			}
			if isRetry {
				// Idempotent retry: do not re-unfreeze cgroup, return cached state
				writeJSON(w, http.StatusOK, map[string]any{
					"pod_uid":      req.PodUID,
					"cgroup_path":  "",
					"frozen":       false,
					"operator_ids": cachedOps,
					"operator_id":  token.OperatorID,
					"token_id":     token.TokenID,
					"idempotent":   true,
				})
				return
			}
		}
	}

	// Always pass validation check to freezer.UnfreezePod
	credToValidate := headerCred
	if credToValidate == "" && tokenParsed {
		tokenJSON, _ := json.Marshal(token)
		credToValidate = string(tokenJSON)
	}

	res, err := s.freezer.UnfreezePod(req.PodUID, credToValidate)
	if err != nil {
		writeJSON(w, statusFor(err), map[string]any{"error": err.Error(), "result": res})
		return
	}

	obs := observationFrom(res, req.PodName, req.Namespace)
	obs.OperatorIDs = operatorIDs
	if len(operatorIDs) > 0 {
		obs.OperatorID = operatorIDs[0]
	}
	obs.TokenID = tokenID
	_ = s.emitter.StunExecutionResumed(obs)

	respBody := map[string]any{
		"pod_uid":      res.PodUID,
		"cgroup_path":  res.CgroupPath,
		"frozen":       res.Frozen,
		"latency_ms":   res.LatencyMS,
		"polls":        res.Polls,
		"pids":         res.PIDs,
		"operator_ids": operatorIDs,
		"token_id":     tokenID,
	}
	if len(operatorIDs) > 0 {
		respBody["operator_id"] = operatorIDs[0]
	}
	writeJSON(w, http.StatusOK, respBody)
}

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
	keyCount := 0
	if s.keyRegistry != nil {
		keyCount = len(s.keyRegistry.AllKeys())
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":                 "ok",
		"cgroup_root":            s.freezer.Root(),
		"cgroup_write":           true,
		"deadline_ms":            float64(s.freezer.Deadline().Nanoseconds()) / 1e6,
		"operator_keys_enrolled": keyCount,
	})
}

// requireBearer makes a handler unreachable without a valid governance credential.
func requireBearer(validate cgroup.CredentialValidator, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if validate == nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "no credential validator configured"})
			return
		}
		// The credential travels in a header, never in the URL.
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
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/readyz", s.handleHealth)
	mux.HandleFunc("/stun", requireBearer(s.freezeValidate, s.handleStun))
	mux.HandleFunc("/resume", requireBearer(s.resumeValidate, s.handleResume))
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

	// Load operator key registry if path or JSON is provided
	var registry auth.OperatorKeyRegistry
	if cfg.operatorKeyPath != "" {
		reg, err := auth.LoadOperatorKeyRegistry(cfg.operatorKeyPath)
		if err != nil {
			return fmt.Errorf("stun-sentinel: load operator key registry: %w", err)
		}
		registry = reg
	} else if cfg.operatorKeysJSON != "" {
		entries, err := auth.LoadOperatorKeysFromJSON([]byte(cfg.operatorKeysJSON))
		if err != nil {
			return fmt.Errorf("stun-sentinel: parse OPERATOR_KEYS_JSON: %w", err)
		}
		registry = auth.NewStaticOperatorKeyRegistry(entries...)
	}

	// 2. Either an operator key registry or STUN_RESUME_TOKEN must be configured.
	if registry == nil && cfg.resumeToken == "" {
		return errors.New("stun-sentinel: STUN_RESUME_TOKEN is required and cannot be empty")
	}

	// 3. STUN_FREEZE_TOKEN and STUN_RESUME_TOKEN must not share the same value.
	if cfg.resumeToken != "" && cfg.freezeToken == cfg.resumeToken {
		return errors.New("stun-sentinel: STUN_FREEZE_TOKEN and STUN_RESUME_TOKEN must be distinct credentials")
	}

	policy := auth.DefaultResumeTokenPolicy(cfg.audience, cfg.trustRootID)
	policy.RequiredSignatures = cfg.requiredSignatures

	freezeValidate := constantTimeTokenValidator(cfg.freezeToken)
	resumeValidate := ed25519ResumeValidator(registry, policy, cfg.resumeToken)
	ledger := auth.NewReplayLedger()

	srv := &server{
		freezer: cgroup.New(cfg.cgroupRoot,
			cgroup.WithDeadline(cfg.deadline),
			cgroup.WithFreezeCredentialValidator(freezeValidate),
			cgroup.WithCredentialValidator(resumeValidate),
		),
		emitter:        telemetry.NewEmitter(os.Stdout),
		freezeValidate: freezeValidate,
		resumeValidate: resumeValidate,
		keyRegistry:    registry,
		policy:         policy,
		replayLedger:   ledger,
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
