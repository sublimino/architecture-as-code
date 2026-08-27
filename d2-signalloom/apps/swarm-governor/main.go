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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
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
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	var req SubmitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
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
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "no agents discovered"})
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
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": err.Error()})
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

	writeJSON(w, http.StatusAccepted, plan)
}

func (g *Governor) handleGetTask(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	taskID := strings.TrimPrefix(r.URL.Path, "/tasks/")
	if taskID == "" || taskID == r.URL.Path {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "task ID required"})
		return
	}

	g.mu.RLock()
	plan, ok := g.tasks[taskID]
	g.mu.RUnlock()

	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "task not found"})
		return
	}

	writeJSON(w, http.StatusOK, plan)
}

func (g *Governor) handleAgentCard(w http.ResponseWriter, _ *http.Request) {
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
	writeJSON(w, http.StatusOK, card)
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
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

	mux := http.NewServeMux()
	mux.HandleFunc("/tasks/submit", gov.handleSubmit)
	mux.HandleFunc("/tasks/", gov.handleGetTask)
	mux.HandleFunc("/.well-known/agent-card.json", gov.handleAgentCard)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)

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
