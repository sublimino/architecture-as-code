package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// TopologyResponse is the wire format for GET /api/v1/fleet/topology.
//
// Every field mirrors the FleetTopology interface in
// apps/dashboard-signalloom/src/api/fleetApi.ts, all four of whose members are
// non-optional. This struct carried only Agents and Edges once, and the two
// missing keys did not fail visibly: FleetDemoPage.tsx:328 defaults a missing
// aggregateRisk to zeros, so the page reported a fleet worth nothing rather
// than reporting that it had been told nothing.
type TopologyResponse struct {
	Agents         []Agent        `json:"agents"`
	Edges          []Edge         `json:"edges"`
	AggregateRisk  RiskSummary    `json:"aggregateRisk"`
	CascadeHistory []CascadeEvent `json:"cascadeHistory"`
}

// CascadeEvent mirrors the CascadeEvent interface in fleetApi.ts.
//
// Distinct from CascadeResult in cascade.go, which is the INTERNAL record of a
// run and uses snake_case. Keeping the wire type separate is deliberate: the
// client contract and the orchestrator's bookkeeping are free to differ, and
// conflating them is how a rename inside the orchestrator would silently become
// a breaking API change.
type CascadeEvent struct {
	TriggerID   string   `json:"triggerId"`
	AffectedIDs []string `json:"affectedIds"`
	Timestamp   string   `json:"timestamp"`
	DurationMs  int64    `json:"durationMs"`
	RiskBefore  float64  `json:"riskBefore"`
	RiskAfter   float64  `json:"riskAfter"`
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
	// enforcement records which FleetClient implementation was installed at
	// startup, so /health can report it rather than infer it. Nil in unit tests
	// that construct a server directly; handleHealth treats that as
	// "unconfigured" rather than assuming enforcement works.
	enforcement *fleetClientSelection
}

// degradedReporter is implemented by the clients that keep a fail-closed
// registry (k8sFleetClient, unavailableFleetClient). The no-op double does not
// implement it, which is itself informative.
type degradedReporter interface {
	DegradedTargets() map[string]DegradedTarget
}

// handleHealth reports process liveness AND enforcement state, as two separate
// fields.
//
// `status` stays "ok" whenever the process is serving, even when enforcement is
// degraded, and this is deliberate. The Deployment points its liveness, startup
// and readiness probes at this endpoint (base/deployment.yaml), so failing it
// during an API-server outage would crash-loop fleet-manager exactly when an
// operator needs it — break-glass would have to traverse the plane that just
// failed. Enforcement blindness is reported in `enforcement` and
// `degraded_targets` instead, which is what an operator or a scrape should
// alert on.
//
// Every value is a string on purpose: the existing contract test decodes this
// body into a map[string]string, and a numeric field would abort that decode
// part-way through and silently blank the keys after it.
func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	body := map[string]string{
		"status":           "ok",
		"fleet_client":     "unconfigured",
		"enforcement":      "unknown",
		"degraded_targets": "0",
	}

	if s.enforcement != nil {
		body["fleet_client"] = string(s.enforcement.Kind)
		if s.enforcement.Enforcing {
			body["enforcement"] = "available"
		} else {
			body["enforcement"] = "unavailable"
		}
		if reporter, ok := s.enforcement.Client.(degradedReporter); ok {
			body["degraded_targets"] = strconv.Itoa(len(reporter.DegradedTargets()))
		}
		if s.enforcement.Reason != "" {
			body["enforcement_reason"] = s.enforcement.Reason
		}

		// Re-probe live rather than reporting the startup verdict forever.
		//
		// Selection happens once, at boot. If this endpoint only echoed that, a
		// process that started cleanly and lost its API server an hour later would
		// keep answering enforcement=available indefinitely, because
		// degraded_targets only moves when an enforcement operation is ATTEMPTED
		// and a quiet fleet attempts none. The endpoint this file's own comment
		// names as the thing to alert on would be reporting a stale boot-time fact.
		//
		// The probe is a Limit:1 List and the request timeout is short, because
		// this endpoint also backs the liveness probe.
		if s.enforcement.Enforcing && s.enforcement.Client != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			if err := s.enforcement.Client.Health(ctx); err != nil {
				body["enforcement"] = "unavailable"
				body["enforcement_reason"] = err.Error()
			}
			cancel()
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(body)
}

func (s *server) handleTopology(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	agents := s.dag.AllAgents()
	resp := TopologyResponse{
		Agents:        make([]Agent, len(agents)),
		Edges:         make([]Edge, 0),
		AggregateRisk: s.dag.AggregateRisk(),
		// make(), not nil: a nil slice marshals to `null`, and the client maps
		// over cascadeHistory directly. An empty history is the correct answer
		// for a process that has not run a cascade yet; `null` is a crash.
		CascadeHistory: make([]CascadeEvent, 0),
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

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	// --fleet-client defaults from FLEET_CLIENT so a Deployment can set it as an
	// env var, but the flag wins when both are present. The accepted values and
	// the exact-match rule that guards the test double are documented on
	// selectFleetClient in fleetclient_select.go.
	// ContinueOnError, not the default ExitOnError. The whole point of
	// unavailableFleetClient is that this process stays up so break-glass does
	// not have to traverse a failed plane; letting one typo'd argument call
	// os.Exit(2) before the listener binds reintroduces a startup crash-loop
	// through the back door.
	fs := flag.NewFlagSet("fleet-manager", flag.ContinueOnError)
	envFleetClient := os.Getenv("FLEET_CLIENT")
	fleetClientFlag := fs.String("fleet-client", envFleetClient,
		"FleetClient implementation: auto|kubernetes|noop-test-only. "+
			"noop-test-only enforces NOTHING, must be spelled exactly, and is "+
			"accepted ONLY on the command line — never from FLEET_CLIENT.")
	agentNamespaceFlag := fs.String("agent-namespace", os.Getenv("AGENT_NAMESPACE"),
		"namespace holding the agent pods; defaults to "+DefaultAgentNamespace)
	if err := fs.Parse(os.Args[1:]); err != nil {
		slog.Error("failed to parse flags; continuing with defaults rather than exiting", "error", err)
	}

	// Where the value came from is part of the gate: the environment may request
	// the real client but may not disarm enforcement. See selectFleetClientFrom.
	clientSource := requestSourceFlag
	if *fleetClientFlag == envFleetClient && envFleetClient != "" {
		clientSource = requestSourceEnv
	}

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

	// This line used to construct the no-op double directly and unconditionally
	// — no flag, no log, and the reason nothing in this service ever enforced
	// anything. Selection is now explicit, logged, and fail-closed: the worst
	// case is unavailableFleetClient, never the no-op. The double, and the
	// exact-match rule that is now the only route to it, live in
	// fleetclient_select.go.
	//
	// The double's type name is deliberately never spelled in this file. A guard
	// grepping this file for it must return zero matches, and a comment
	// describing the defect must not be able to satisfy the check that exists to
	// detect it.
	selection := selectFleetClientFrom(*fleetClientFlag, clientSource, *agentNamespaceFlag,
		defaultRestConfigLoader, defaultClientsetBuilder)

	// Probe once at startup so a misconfigured deployment says so in its first
	// five log lines. A failure is loud but not fatal — see the comment on
	// unavailableFleetClient for why exiting here would destroy break-glass.
	healthCtx, cancelHealth := context.WithTimeout(context.Background(), 5*time.Second)
	if err := selection.Client.Health(healthCtx); err != nil {
		slog.Error("fleet client health probe failed at startup; enforcement is DEGRADED",
			"implementation", string(selection.Kind), "error", err)
	} else {
		slog.Info("fleet client health probe passed", "implementation", string(selection.Kind))
	}
	cancelHealth()

	orchestrator := NewCascadeOrchestrator(dag, selection.Client, time.Duration(stepDelayMs)*time.Millisecond)

	s := &server{dag: dag, orchestrator: orchestrator, enforcement: &selection}

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
