package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/pkg/compliance"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Request/response types for legacy PodSpec evaluation

type SecurityContext struct {
	RunAsNonRoot *bool         `json:"runAsNonRoot,omitempty"`
	RunAsUser    *int64        `json:"runAsUser,omitempty"`
	Capabilities *Capabilities `json:"capabilities,omitempty"`
}

type Capabilities struct {
	Drop []string `json:"drop,omitempty"`
	Add  []string `json:"add,omitempty"`
}

type Container struct {
	Name            string           `json:"name"`
	SecurityContext *SecurityContext `json:"securityContext,omitempty"`
}

type PodSpec struct {
	Containers      []Container      `json:"containers,omitempty"`
	SecurityContext *SecurityContext `json:"securityContext,omitempty"`
}

type EvaluateRequest struct {
	AgentID   string   `json:"agent_id"`
	Namespace string   `json:"namespace"`
	PodSpec   *PodSpec `json:"pod_spec"`
	Checks    []string `json:"checks"`
}

type CheckResult struct {
	Check  string `json:"check"`
	Pass   bool   `json:"pass"`
	Reason string `json:"reason"`
}

type EvaluateResponse struct {
	AgentID     string        `json:"agent_id"`
	Compliant   bool          `json:"compliant"`
	Results     []CheckResult `json:"results"`
	EvaluatedAt string        `json:"evaluated_at"`
}

// Check evaluators

func checkSecurityContextPresent(spec *PodSpec) CheckResult {
	result := CheckResult{Check: "security-context-present"}

	if spec.SecurityContext == nil {
		result.Pass = false
		result.Reason = "pod-level securityContext is not set"
		return result
	}

	sc := spec.SecurityContext
	hasField := sc.RunAsNonRoot != nil || sc.RunAsUser != nil || sc.Capabilities != nil
	if !hasField {
		result.Pass = false
		result.Reason = "pod-level securityContext has no fields set"
		return result
	}

	result.Pass = true
	result.Reason = "pod-level securityContext is present"
	return result
}

func checkRunAsNonRoot(spec *PodSpec) CheckResult {
	result := CheckResult{Check: "run-as-non-root"}

	if spec.SecurityContext == nil || spec.SecurityContext.RunAsNonRoot == nil {
		result.Pass = false
		result.Reason = "runAsNonRoot is not set to true"
		return result
	}

	if !*spec.SecurityContext.RunAsNonRoot {
		result.Pass = false
		result.Reason = "runAsNonRoot is set to false"
		return result
	}

	result.Pass = true
	result.Reason = "runAsNonRoot is true"
	return result
}

func checkDropCapabilities(spec *PodSpec) CheckResult {
	result := CheckResult{Check: "drop-capabilities"}

	for _, c := range spec.Containers {
		if c.SecurityContext != nil && c.SecurityContext.Capabilities != nil {
			for _, cap := range c.SecurityContext.Capabilities.Drop {
				if strings.EqualFold(cap, "ALL") {
					result.Pass = true
					result.Reason = fmt.Sprintf("container %q drops ALL capabilities", c.Name)
					return result
				}
			}
		}
	}

	result.Pass = false
	result.Reason = "no container drops ALL capabilities"
	return result
}

func evaluateCheck(name string, spec *PodSpec) CheckResult {
	switch name {
	case "security-context-present":
		return checkSecurityContextPresent(spec)
	case "run-as-non-root":
		return checkRunAsNonRoot(spec)
	case "drop-capabilities":
		return checkDropCapabilities(spec)
	default:
		return CheckResult{Check: name, Pass: false, Reason: "unknown check"}
	}
}

// Handlers

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
}

func handleEvaluate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req EvaluateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid request body: " + err.Error()})
		return
	}

	if req.PodSpec == nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "pod_spec is required"})
		return
	}

	results := make([]CheckResult, 0, len(req.Checks))
	compliant := true

	for _, check := range req.Checks {
		result := evaluateCheck(check, req.PodSpec)
		results = append(results, result)
		if !result.Pass {
			compliant = false
		}
	}

	resp := EvaluateResponse{
		AgentID:     req.AgentID,
		Compliant:   compliant,
		Results:     results,
		EvaluatedAt: time.Now().UTC().Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}

	celEngine, err := NewCELEngine()
	if err != nil {
		slog.Error("failed initializing CEL engine", "error", err)
		os.Exit(1)
	}

	store := NewPolicyStore(celEngine)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealthz)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/api/v1/evaluate", handleEvaluate)
	mux.HandleFunc("/api/v1/compliance/scan-fleet", compliance.HandleScanFleet)

	// Observation policy: the durable bundle set is read from disk at boot, not
	// registered over the API (SLAWS v2 §4.4, D6).
	obsEvaluator, err := obscel.NewEvaluator()
	if err != nil {
		slog.Error("failed initializing observation evaluator", "error", err)
		os.Exit(1)
	}

	pseudonymKeyHex := os.Getenv("SIGNAL_SEGMENT_PSEUDONYM_KEY")
	if pseudonymKeyHex != "" {
		keyBytes, err := hex.DecodeString(pseudonymKeyHex)
		if err != nil {
			slog.Error("failed decoding SIGNAL_SEGMENT_PSEUDONYM_KEY", "error", err)
			os.Exit(1)
		}
		var epoch uint32
		if epochStr := os.Getenv("SIGNAL_SEGMENT_PSEUDONYM_EPOCH"); epochStr != "" {
			if ep, err := strconv.ParseUint(epochStr, 10, 32); err == nil {
				epoch = uint32(ep)
			}
		}
		store.SetPseudonymConfig(keyBytes, epoch)
		slog.Info("pseudonymisation key configured for policy evaluation", "epoch", epoch)
	}

	bundlesDir := os.Getenv(BundlesDirEnv)
	if bundlesDir == "" {
		bundlesDir = DefaultBundlesDir
	}
	loaded, err := store.LoadObservationBundles(bundlesDir)
	if err != nil {
		// A malformed bundle is a broken deployment, not an empty one. Booting
		// anyway would serve a policy set that silently detects less than the
		// one in git.
		slog.Error("failed loading observation bundles", "dir", bundlesDir, "error", err)
		os.Exit(1)
	}
	slog.Info("observation bundles loaded", "dir", bundlesDir, "bundles", loaded,
		"tenants", store.ObservationBundleTenants())

	// Versioned Policy Endpoints
	policyHandlers := NewPolicyEngineHandlers(store, celEngine)
	obsHandlers := NewObservationHandlers(store, obsEvaluator)
	apiKeys := ParseAPIKeys(os.Getenv(APIKeysEnv))
	if len(apiKeys) > 0 {
		slog.Info("policy and observation APIs require a bearer key")
	} else {
		slog.Warn("policy and observation APIs are unauthenticated", "hint", "set "+APIKeysEnv)
	}
	registerGuardedRoutes(mux, policyHandlers, obsHandlers, apiKeys)

	// Compliance scanner: FAIR risk engine + framework hierarchy + CEL evaluation.
	policyRoot := os.Getenv("POLICY_ROOT")
	if policyRoot == "" {
		policyRoot = findPolicyRoot()
	}
	if policyRoot != "" {
		if err := store.LoadFrameworks(policyRoot); err != nil {
			slog.Warn("loading frameworks into policy store", "error", err)
		}
		ch, err := newComplianceHandler(policyRoot, celEngine)
		if err != nil {
			slog.Warn("compliance handler disabled", "error", err)
		} else {
			mux.HandleFunc("/api/v1/compliance/scan", ch.handleScan)
			mux.HandleFunc("/api/v1/compliance/frameworks", ch.handleFrameworks)
			mux.HandleFunc("/api/v1/compliance/frameworks/", ch.handleFrameworks)
			mux.HandleFunc("/api/v1/compliance/summary", ch.handleSummary)
			slog.Info("compliance scanner enabled", "policyRoot", policyRoot)
		}
	} else {
		slog.Warn("compliance scanner disabled: policy/ directory not found (set POLICY_ROOT)")
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		slog.Info("policy-engine starting", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "error", err)
		os.Exit(1)
	}

	slog.Info("stopped")
}

// GuardedRoutes is every path that key auth covers when POLICY_API_KEYS is set
// (SLAWS v2 §4.3). /healthz, /readyz, /api/v1/evaluate and the compliance
// routes are deliberately absent: probes must not carry a credential, and the
// compliance scanner is a separate surface this card does not change.
//
// /api/v1/policies is in the set even though it has no trailing path segment:
// it returns bundle contents, so it is as sensitive as the routes beneath it.
var GuardedRoutes = []string{
	"/api/v1/policies",
	"/api/v1/policies/evaluate",
	"/api/v1/policies/bundles",
	"/api/v1/policies/rollback",
	"/api/v1/observations/evaluate",
}

// registerGuardedRoutes mounts the policy and observation APIs behind key auth.
//
// Routing and authentication are registered together, in one place, on purpose:
// a route added here cannot be reached without passing through RequireAPIKey,
// which is the failure mode a separate middleware list invites.
func registerGuardedRoutes(mux *http.ServeMux, ph *PolicyEngineHandlers, oh *ObservationHandlers, keys []string) {
	handlers := map[string]http.HandlerFunc{
		"/api/v1/policies":              ph.HandleListPolicies,
		"/api/v1/policies/evaluate":     ph.HandleEvaluatePolicies,
		"/api/v1/policies/bundles":      ph.HandleRegisterBundle,
		"/api/v1/policies/rollback":     ph.HandleRollback,
		"/api/v1/observations/evaluate": oh.HandleEvaluateObservation,
	}
	for _, route := range GuardedRoutes {
		h, ok := handlers[route]
		if !ok {
			// Unreachable unless GuardedRoutes and the table above drift apart;
			// panicking at boot beats serving a route with no handler or, worse,
			// a handler with no guard.
			panic("policy-engine: no handler registered for guarded route " + route)
		}
		mux.HandleFunc(route, RequireAPIKey(keys, h))
	}
}

// findPolicyRoot walks up from the working directory to find a policy/ directory
// containing a frameworks/ subdirectory.
func findPolicyRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		candidate := filepath.Join(dir, "policy")
		if info, err := os.Stat(filepath.Join(candidate, "frameworks")); err == nil && info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}
