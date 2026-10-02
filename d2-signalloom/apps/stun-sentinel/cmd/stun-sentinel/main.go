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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/filter"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/quarantine"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/telemetry"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
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
	quarantineDir      string
	quarantineMaxMB    int64
	quarantineTimeout  time.Duration
}

func loadConfig(args []string) (*config, error) {
	fs := flag.NewFlagSet("stun-sentinel", flag.ContinueOnError)
	root := fs.String("cgroup-root", envOr("CGROUP_ROOT", cgroup.DefaultCgroupRoot), "cgroup-v2 unified hierarchy root")
	addr := fs.String("listen-addr", envOr("LISTEN_ADDR", ":8080"), "HTTP listen address")
	deadline := fs.Duration("freeze-deadline", cgroup.DefaultFreezeDeadline, "hard deadline for observing the frozen state")
	qDir := fs.String("quarantine-dir", envOr("STUN_QUARANTINE_DIR", quarantine.DefaultStorageDir), "directory for storing quarantine snapshots")
	qMaxMB := fs.Int64("quarantine-max-mb", 64, "maximum memory snapshot size in megabytes")
	qTimeout := fs.Duration("quarantine-timeout", quarantine.DefaultMaxTimeBudget, "maximum time budget for forensic capture")
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
		quarantineDir:      *qDir,
		quarantineMaxMB:    *qMaxMB,
		quarantineTimeout:  *qTimeout,
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
	capturer       *quarantine.Capturer
	freezeValidate cgroup.CredentialValidator
	resumeValidate cgroup.CredentialValidator
	keyRegistry    auth.OperatorKeyRegistry
	policy         auth.ResumeTokenPolicy
	replayLedger   *auth.ReplayLedger
	// exclusion guards infrastructure namespaces and the sentinel itself.
	// nil means filter.Default(): the guard cannot be switched off.
	exclusion *filter.Filter
}

func (s *server) exclusionFilter() *filter.Filter {
	if s.exclusion != nil {
		return s.exclusion
	}
	return filter.Default()
}

// exclusionGate refuses a stun aimed at an excluded pod (infrastructure
// namespace, the sentinel itself, a peer sentinel), a pod reported as not
// Running, or a cgroup that turns out to hold the sentinel's own process. It
// runs after bearer authentication so the policy cannot be probed anonymously.
// Returns false after writing the refusal.
func (s *server) exclusionGate(w http.ResponseWriter, podUID, podName, namespace, phase string) bool {
	f := s.exclusionFilter()
	target := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: podName, Namespace: namespace, UID: types.UID(podUID)},
		Status:     corev1.PodStatus{Phase: corev1.PodPhase(phase)},
	}
	if d := f.Evaluate(target); d.Excluded {
		f.AuditSkip(target, d)
		writeJSON(w, http.StatusForbidden, map[string]any{"error": filter.ErrExcluded.Error(), "skipped": true, "reason": d.Reason, "detail": d.Detail})
		return false
	}
	// Phase is optional on the wire; when the caller knows it, a pod that is
	// not Running (e.g. still ContainerCreating) is refused rather than
	// frozen half-way through runtime setup.
	if phase != "" {
		if err := f.CheckFreezable(target); err != nil {
			writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error(), "skipped": true, "reason": filter.ReasonNotRunning})
			return false
		}
	}
	if cgPath, err := s.freezer.ResolvePodCgroup(podUID); err == nil {
		pids, _ := cgroup.ListProcs(cgPath)
		if d := f.ContainsSelf(s.freezer.Root(), cgPath, pids); d.Excluded {
			f.AuditSkip(target, d)
			writeJSON(w, http.StatusForbidden, map[string]any{"error": filter.ErrExcluded.Error(), "skipped": true, "reason": d.Reason, "detail": d.Detail})
			return false
		}
	}
	return true
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
	case errors.Is(err, cgroup.ErrDiscoveryDeadline):
		// SLAAT-P2-4/F2: the cgroup-tree discovery walk timed out under host
		// contention, not because the pod is absent. 503 (retryable) rather
		// than a bare connection stall that an upstream (kubectl port-forward)
		// eventually reports as an uninformative 504.
		return http.StatusServiceUnavailable
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
		PodUID            string `json:"pod_uid"`
		PodName           string `json:"pod"`
		Namespace         string `json:"namespace"`
		CaptureQuarantine bool   `json:"capture_quarantine"`
		Quarantine        bool   `json:"quarantine"`
		// Phase is the pod phase as last observed by the caller (optional).
		Phase string `json:"phase"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed body: " + err.Error()})
		return
	}
	if !s.exclusionGate(w, req.PodUID, req.PodName, req.Namespace, req.Phase) {
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

// containmentRequestTimeout bounds /stun and /resume end-to-end. The freeze
// write+poll itself is bounded by cgroup.DefaultFreezeDeadline (50ms) and the
// cgroup-tree discovery fallback by cgroup.maxDiscoveryBudget (2s); this is
// the outer belt-and-suspenders bound so a genuinely wedged syscall (not a
// slow search, an actually stuck one) still gets a typed 503 from THIS
// server rather than an uninformative 504 from an upstream proxy or
// port-forward that gave up waiting (SLAAT-P2-4/F2).
const containmentRequestTimeout = 5 * time.Second

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/readyz", s.handleHealth)
	mux.Handle("/stun", http.TimeoutHandler(requireBearer(s.freezeValidate, s.handleStun), containmentRequestTimeout, `{"error":"containment request exceeded the server-side deadline"}`))
	mux.Handle("/resume", http.TimeoutHandler(requireBearer(s.resumeValidate, s.handleResume), containmentRequestTimeout, `{"error":"containment request exceeded the server-side deadline"}`))
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
		keyRegistry:    registry,
		policy:         policy,
		replayLedger:   ledger,
		exclusion: filter.New(filter.SelfFromEnv(),
			filter.WithExtraNamespaces(strings.Split(os.Getenv("STUN_EXTRA_EXCLUDED_NAMESPACES"), ",")...)),
	}
	fmt.Fprintf(os.Stderr, "stun-sentinel: exclusion namespaces=%s\n", strings.Join(srv.exclusion.ExcludedNamespaces(), ","))

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
