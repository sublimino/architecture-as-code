// swarm-governor: swarm coordinator and A2A dispatcher.
//
// Reads incoming issue/task complexity, discovers agent capabilities via
// A2A Agent Cards (JSON-RPC 2.0), delegates sub-tasks to specialist agents
// with token quotas.
//
// Endpoints:
//   POST /tasks/submit               — submit a task for dispatch
//   GET  /tasks/{id}                  — query task status
//   GET  /.well-known/agent-card.json — this agent's A2A card
//   GET  /healthz                     — liveness probe
//   GET  /readyz                      — readiness probe
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/swarm-governor/a2a"
)

// Governor holds the swarm state.
type Governor struct {
	namespace      string
	maxTokenBudget int
	a2aClient      *a2a.Client
	mu             sync.RWMutex
	tasks          map[string]*DispatchPlan
}

func NewGovernor(namespace string, maxTokenBudget int) *Governor {
	return &Governor{
		namespace:      namespace,
		maxTokenBudget: maxTokenBudget,
		a2aClient:      a2a.NewClient(),
		tasks:          make(map[string]*DispatchPlan),
	}
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if r != nil && r.Method == http.MethodHead {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}

// SubmitRequest is the payload for POST /tasks/submit.
type SubmitRequest struct {
	Description  string            `json:"description"`
	Requirements []string          `json:"requirements,omitempty"`
	Input        map[string]any    `json:"input,omitempty"`
	AgentURLs    []string          `json:"agent_urls,omitempty"`
	Metadata     map[string]string `json:"metadata,omitempty"`
}

func (g *Governor) handleSubmit(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	if r.Body != nil {
		defer r.Body.Close()
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
	var req SubmitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	req.Description = strings.TrimSpace(req.Description)
	if req.Description == "" {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "description required"})
		return
	}

	// Validate agent URLs to prevent SSRF
	for _, rawURL := range req.AgentURLs {
		parsed, err := url.ParseRequestURI(rawURL)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("invalid agent url: %s", rawURL)})
			return
		}
	}

	// Discover agent cards.
	var agents []a2a.AgentCard
	ctx := r.Context()
	for _, url := range req.AgentURLs {
		card, err := g.a2aClient.DiscoverCard(ctx, url)
		if err != nil {
			slog.Warn("failed to discover agent", "url", url, "error", err)
			continue
		}
		agents = append(agents, *card)
	}

	if len(agents) == 0 {
		writeJSON(w, r, http.StatusBadGateway, map[string]string{"error": "no agents discovered"})
		return
	}

	task := a2a.Task{
		ID:           fmt.Sprintf("swarm-%d", time.Now().UnixNano()),
		Description:  req.Description,
		Requirements: req.Requirements,
		Input:        req.Input,
		Metadata:     req.Metadata,
	}

	plan, err := Dispatch(task, agents, g.maxTokenBudget)
	if err != nil {
		slog.Error("dispatch failed", "error", err)
		writeJSON(w, r, http.StatusUnprocessableEntity, map[string]string{"error": err.Error()})
		return
	}

	g.mu.Lock()
	g.tasks[task.ID] = plan
	g.mu.Unlock()

	slog.Info("task dispatched",
		"task_id", task.ID,
		"complexity", plan.Complexity.String(),
		"assignments", len(plan.Assignments),
	)

	writeJSON(w, r, http.StatusAccepted, plan)
}

func (g *Governor) handleGetTask(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	taskID := strings.TrimPrefix(r.URL.Path, "/tasks/")
	if taskID == "" || taskID == r.URL.Path {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "task ID required"})
		return
	}

	g.mu.RLock()
	plan, ok := g.tasks[taskID]
	g.mu.RUnlock()

	if !ok {
		writeJSON(w, r, http.StatusNotFound, map[string]string{"error": "task not found"})
		return
	}

	writeJSON(w, r, http.StatusOK, plan)
}

func (g *Governor) handleAgentCard(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	card := a2a.AgentCard{
		Name:        "swarm-governor",
		Description: "Swarm coordinator. Evaluates task complexity, discovers agents, and dispatches sub-tasks with token budgets.",
		URL:         fmt.Sprintf("http://swarm-governor.%s.svc:8080", g.namespace),
		Version:     "1.0.0",
		Capabilities: []a2a.Capability{
			{Name: "dispatch", Description: "Evaluate and dispatch tasks to specialist agents"},
			{Name: "discover", Description: "Discover agent capabilities via A2A cards"},
			{Name: "coordinate", Description: "Coordinate multi-agent task execution"},
		},
	}
	writeJSON(w, r, http.StatusOK, card)
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]string{"status": "ready"})
}

// headResponseWriter suppresses response bodies for HTTP HEAD requests (RFC 9110 Section 6.4.1).
type headResponseWriter struct {
	http.ResponseWriter
}

func (w *headResponseWriter) Write(p []byte) (int, error) {
	return len(p), nil
}

// headBodySuppressingMiddleware wraps an http.Handler and suppresses the response body
// when the request method is HEAD, in compliance with RFC 9110 Section 6.4.1.
func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func newMux(gov *Governor) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/tasks/submit", gov.handleSubmit)
	mux.HandleFunc("/tasks/", gov.handleGetTask)
	mux.HandleFunc("/.well-known/agent-card.json", gov.handleAgentCard)
	mux.HandleFunc("/health", handleHealthz)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	return headBodySuppressingMiddleware(mux)
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	namespace := os.Getenv("GOVERNOR_NAMESPACE")
	if namespace == "" {
		namespace = "fe-signalloom-agents"
	}

	maxBudget := 250000
	if v := os.Getenv("MAX_TOKEN_BUDGET"); v != "" {
		var err error
		maxBudget, err = strconv.Atoi(v)
		if err != nil {
			slog.Error("invalid MAX_TOKEN_BUDGET", "value", v, "error", err)
			os.Exit(1)
		}
	}

	gov := NewGovernor(namespace, maxBudget)

	mux := newMux(gov)

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
		slog.Info("swarm-governor starting", "port", port, "namespace", namespace, "max_token_budget", maxBudget)
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
