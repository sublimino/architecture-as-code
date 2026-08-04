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

// TopologyResponse is the wire format for GET /api/v1/fleet/topology.
type TopologyResponse struct {
	Agents []Agent `json:"agents"`
	Edges  []Edge  `json:"edges"`
}

// Edge represents a dependency edge in the topology.
type Edge struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// StunRequest is the wire format for POST /api/v1/fleet/stun/{agentId}.
type StunRequest struct {
	AgentID string `json:"agent_id"`
}

// ErrorResponse is a standard error envelope.
type ErrorResponse struct {
	Error string `json:"error"`
}

// server holds the shared state for all HTTP handlers.
type server struct {
	dag          *DAG
	orchestrator *CascadeOrchestrator
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *server) handleTopology(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	agents := s.dag.AllAgents()
	resp := TopologyResponse{
		Agents: make([]Agent, len(agents)),
		Edges:  make([]Edge, 0),
	}

	for i, a := range agents {
		resp.Agents[i] = *a
		for _, dep := range a.Dependencies {
			resp.Edges = append(resp.Edges, Edge{From: a.ID, To: dep})
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (s *server) handleStun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Extract agent ID from URL path: /api/v1/fleet/stun/{agentId}
	agentID := strings.TrimPrefix(r.URL.Path, "/api/v1/fleet/stun/")
	if agentID == "" || agentID == r.URL.Path {
		writeError(w, http.StatusBadRequest, "agent_id is required in URL path")
		return
	}

	if s.dag.GetAgent(agentID) == nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("unknown agent: %s", agentID))
		return
	}

	result, err := s.orchestrator.Stun(r.Context(), agentID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *server) handleRecover(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Collect all currently stunned agents from the DAG state
	var stunnedIDs []string
	for _, a := range s.dag.AllAgents() {
		if a.State == StateStunned {
			stunnedIDs = append(stunnedIDs, a.ID)
		}
	}

	// If no agents are tracked as stunned in-memory, fall back to the request body
	if len(stunnedIDs) == 0 {
		var req struct {
			AgentIDs []string `json:"agent_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err == nil && len(req.AgentIDs) > 0 {
			stunnedIDs = req.AgentIDs
		}
	}

	if len(stunnedIDs) == 0 {
		writeError(w, http.StatusBadRequest, "no stunned agents to recover")
		return
	}

	result, err := s.orchestrator.Recover(r.Context(), stunnedIDs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *server) handleDeploy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "accepted",
		"message": "fleet deployment initiated",
	})
}

func (s *server) handleScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "accepted",
		"message": "fleet-wide compliance scan initiated",
	})
}

func (s *server) handleReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "accepted",
		"message": "fleet teardown initiated",
	})
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(ErrorResponse{Error: msg})
}

// noopFleetClient is used when running outside a cluster. All operations are no-ops.
type noopFleetClient struct{}

func (n *noopFleetClient) GetPodState(_ context.Context, _, _ string) (string, error) {
	return StateRunning, nil
}
func (n *noopFleetClient) SetPodState(_ context.Context, _, _, _ string) error { return nil }
func (n *noopFleetClient) RevokeCredentials(_ context.Context, _ string) error  { return nil }
func (n *noopFleetClient) RestoreCredentials(_ context.Context, _ string) error { return nil }

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	fleetPath := os.Getenv("FLEET_CONFIG")
	if fleetPath == "" {
		fleetPath = "/etc/fleet/fleet.yaml"
	}

	stepDelayMs := 200
	if v := os.Getenv("STEP_DELAY_MS"); v != "" {
		fmt.Sscanf(v, "%d", &stepDelayMs)
	}

	dag, err := LoadFleet(fleetPath)
	if err != nil {
		slog.Error("failed to load fleet config", "path", fleetPath, "error", err)
		os.Exit(1)
	}
	slog.Info("fleet topology loaded", "agents", len(dag.AllAgents()), "path", fleetPath)

	client := FleetClient(&noopFleetClient{})
	orchestrator := NewCascadeOrchestrator(dag, client, time.Duration(stepDelayMs)*time.Millisecond)

	s := &server{dag: dag, orchestrator: orchestrator}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/api/v1/fleet/topology", s.handleTopology)
	mux.HandleFunc("/api/v1/fleet/deploy", s.handleDeploy)
	mux.HandleFunc("/api/v1/fleet/stun/", s.handleStun)
	mux.HandleFunc("/api/v1/fleet/scan", s.handleScan)
	mux.HandleFunc("/api/v1/fleet/recover", s.handleRecover)
	mux.HandleFunc("/api/v1/fleet/reset", s.handleReset)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		slog.Info("fleet-manager starting", "port", port)
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
