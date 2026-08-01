package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Request/response types

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
	SecurityContext *SecurityContext  `json:"securityContext,omitempty"`
}

type PodSpec struct {
	Containers      []Container      `json:"containers,omitempty"`
	SecurityContext *SecurityContext  `json:"securityContext,omitempty"`
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

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/api/v1/evaluate", handleEvaluate)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
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
