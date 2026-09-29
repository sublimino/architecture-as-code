package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/fleet-manager/pkg/attestation"
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

// StunRequest is the REQUIRED body of POST /api/v1/fleet/stun/{agentId}. An
// empty body, or one without a non-blank reason, is refused with 400: the
// reason is written to the provenance annotations, and a canned default there
// records a reason nobody gave.
type StunRequest struct {
	// AgentID, when present, must equal the agent in the URL path. The path is
	// authoritative; a body naming a different agent is a caller bug.
	AgentID string `json:"agent_id"`
	// Reason is written to the stun-reason annotations. Required; at most
	// MaxStunReasonRunes printable runes.
	Reason string `json:"reason"`
}

// maxStunBodyBytes caps the stun body. A 256-rune reason is at most 1 KiB of
// UTF-8; the rest is JSON framing and an agent id.
const maxStunBodyBytes = 4 << 10

// decodeStunRequest reads the stun body and returns the effective
// reason. Every rejection is a 400 before any enforcement call is made.
//
// The body's agent_id may name either what the path carried or the DAG id it
// resolved to; fe-signalloom echoes the path value, which is often a pod name.
func decodeStunRequest(r *http.Request, pathAgentID, resolvedID string) (string, error) {
	var req StunRequest
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, maxStunBodyBytes))
	if err := dec.Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("invalid stun body: %v", err)
	}
	if req.AgentID != "" && req.AgentID != pathAgentID && req.AgentID != resolvedID {
		return "", fmt.Errorf("agent_id %q in body contradicts %q in path", req.AgentID, pathAgentID)
	}
	return validateStunReason(req.Reason)
}

// errStunReasonRequired is the exact wire error for a stun without a reason.
var errStunReasonRequired = errors.New("reason is required")

// validateStunReason requires and bounds a caller-supplied reason. It rejects rather than
// sanitises: a reason that was silently rewritten is a provenance record that
// no longer says what the caller said.
func validateStunReason(reason string) (string, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return "", errStunReasonRequired
	}
	if !utf8.ValidString(reason) {
		return "", errors.New("reason is not valid UTF-8")
	}
	if n := utf8.RuneCountInString(reason); n > MaxStunReasonRunes {
		return "", fmt.Errorf("reason is %d characters, maximum %d", n, MaxStunReasonRunes)
	}
	for _, r := range reason {
		if !unicode.IsPrint(r) {
			return "", fmt.Errorf("reason contains non-printable character %U", r)
		}
	}
	return reason, nil
}

// ErrorResponse is a standard error envelope.
type ErrorResponse struct {
	Error string `json:"error"`
}

// server holds the shared state for all HTTP handlers.
type server struct {
	dag               *DAG
	orchestrator      *CascadeOrchestrator
	// enforcement records which FleetClient implementation was installed at
	// startup, so /health can report it rather than infer it. Nil in unit tests
	// that construct a server directly; handleHealth treats that as
	// "unconfigured" rather than assuming enforcement works.
	enforcement       *fleetClientSelection
	keyRegistry       OperatorKeyRegistry
	replayLedger      *ReplayLedger
	resumePolicy      ResumeTokenPolicy
	attestationEngine *attestation.AttestationEngine
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

	// The dashboard and the integration proxy send pod names; the DAG knows
	// agent ids. Resolve before anything else so a 404 means "no such agent"
	// and never "you used the pod's name".
	w.Header().Set(requestedAgentHeader, agentID)
	resolved, err := s.resolveAgentID(r.Context(), agentID)
	if err != nil {
		writeUnknownAgent(w, resolved)
		return
	}
	slog.Info("stun target resolved", "requested_id", agentID, "agent", resolved.ID, "resolved_by", resolved.By)

	reason, err := decodeStunRequest(r, agentID, resolved.ID)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	result, err := s.orchestrator.Stun(withAgentResolution(r.Context(), resolved), resolved.ID, reason)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeCascadeResult(w, result)
}

// cascadeStatusCode maps a cascade's aggregate verdict onto an HTTP status.
//
// Both handlers previously fell through to an implicit 200 on every path, so a
// stun in which every credential revoke and every label write failed answered
// exactly like one in which they all succeeded. A caller checking the status
// code — which is what callers check — read total enforcement failure as
// success.
//
// The four codes are distinguishable on purpose:
//
//	200 contained   every target fully contained (or recovered)
//	207 partial     some containment achieved, some step failed somewhere
//	404 not_found   no target resolved; the target IDs are stale, not the planes
//	500 unavailable nothing was contained anywhere
//
// 404 rather than 500 for not_found because it sends the operator to check
// their targeting rather than to check plane connectivity, and being sent to
// the wrong one costs time during an active containment.
func cascadeStatusCode(outcome PlaneOutcome) int {
	switch outcome {
	case OutcomeContained:
		return http.StatusOK
	case OutcomePartial:
		return http.StatusMultiStatus
	case OutcomeNotFound:
		return http.StatusNotFound
	default:
		return http.StatusInternalServerError
	}
}

// writeCascadeResult serialises a cascade result under the status code its own
// verdict earns. The body is written in full regardless of the code: an
// operator handed a 500 still needs the per-target breakdown to know which
// plane failed on which agent.
func writeCascadeResult(w http.ResponseWriter, result *CascadeResult) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(cascadeStatusCode(result.OverallOutcome))
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

	// Same status mapping as handleStun. A failed recovery unconditionally
	// answering 200 is the identical defect on the mirror-image operation, and
	// arguably the worse of the two: it tells an operator that agents are back
	// in service when their credentials were never restored.
	writeCascadeResult(w, result)
}

func (s *server) handleResume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req ResumeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid resume request body: %v", err))
		return
	}

	// Extract agent ID from URL if provided: /api/v1/fleet/resume/{agentId}
	urlAgentID := strings.TrimPrefix(r.URL.Path, "/api/v1/fleet/resume/")
	if urlAgentID != "" && urlAgentID != r.URL.Path && req.AgentID == "" {
		req.AgentID = urlAgentID
	}
	if req.AgentID == "" && req.Token.AgentID != "" {
		req.AgentID = req.Token.AgentID
	}
	if req.Namespace == "" && req.Token.Namespace != "" {
		req.Namespace = req.Token.Namespace
	}
	// Same resolution as stun: a pod name maps onto its DAG agent, and the
	// token's agent binding is then checked against the resolved id. An id no
	// branch resolves is a 404 before any token verification.
	if req.AgentID != "" {
		w.Header().Set(requestedAgentHeader, req.AgentID)
		resolved, err := s.resolveAgentID(r.Context(), req.AgentID)
		if err != nil {
			writeUnknownAgent(w, resolved)
			return
		}
		slog.Info("resume target resolved", "requested_id", req.AgentID, "agent", resolved.ID, "resolved_by", resolved.By)
		req.AgentID = resolved.ID
	}
	if req.IdempotencyKey == "" {
		req.IdempotencyKey = fmt.Sprintf("resume-%s-%s", req.AgentID, req.Token.TokenID)
	}

	if req.AgentID == "" {
		writeError(w, http.StatusBadRequest, "agent_id is required")
		return
	}

	var client FleetClient
	if s.enforcement != nil {
		client = s.enforcement.Client
	}

	policy := s.resumePolicy
	if policy.RequiredSignatures == 0 {
		policy = DefaultResumeTokenPolicy(policy.Audience, policy.TrustRootID)
	}

	resp, err := EnforceResumeWithAttestation(r.Context(), req, s.keyRegistry, policy, s.replayLedger, client, s.attestationEngine)
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		if errors.Is(err, ErrResumeTokenReplayed) {
			w.WriteHeader(http.StatusConflict)
		} else if errors.Is(err, ErrResumeTokenTargetMismatch) || errors.Is(err, ErrResumeTokenMalformed) {
			w.WriteHeader(http.StatusBadRequest)
		} else if errors.Is(err, ErrResumeTokenBadSignature) || errors.Is(err, ErrResumeTokenRevokedKey) || errors.Is(err, ErrResumeTokenUnknownKey) || errors.Is(err, ErrResumeTokenInsufficientSignature) {
			w.WriteHeader(http.StatusForbidden)
		} else {
			w.WriteHeader(http.StatusInternalServerError)
		}
		json.NewEncoder(w).Encode(resp)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
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

	// Operator key distribution loading for governance resume
	keyPath := os.Getenv("OPERATOR_KEY_BUNDLE_FILE")
	if keyPath == "" {
		keyPath = os.Getenv("OPERATOR_KEY_DIR")
	}
	keyReg, keyErr := LoadOperatorKeyRegistry(keyPath)
	if keyErr != nil {
		slog.Warn("failed to load operator keys from file/dir", "path", keyPath, "error", keyErr)
		keyReg = NewStaticOperatorKeyRegistry()
	}
	if envKeys := os.Getenv("OPERATOR_KEYS_JSON"); envKeys != "" {
		if entries, err := LoadOperatorKeysFromJSON([]byte(envKeys)); err == nil {
			for _, e := range entries {
				keyReg.Keys[e.KeyID] = e
			}
		}
	}

	replayLedger := NewReplayLedger()
	resumePolicy := DefaultResumeTokenPolicy(os.Getenv("FLEET_AUDIENCE"), os.Getenv("OPERATOR_TRUST_ROOT_ID"))

	// Witness Attestation Engine initialization (SLER-P5-1)
	witnessKeyPath := os.Getenv("WITNESS_KEY_PATH")
	if witnessKeyPath == "" {
		for _, p := range []string{".keys/witness.pem", "/etc/witness/witness.pem", "../../../.keys/witness.pem"} {
			if _, err := os.Stat(p); err == nil {
				witnessKeyPath = p
				break
			}
		}
	}

	var witnessSigner attestation.Signer
	if witnessKeyPath != "" {
		if s, err := attestation.NewLocalEd25519Signer(witnessKeyPath); err == nil {
			witnessSigner = s
			slog.Info("loaded witness attestation key from file", "key_id", s.KeyID(), "path", witnessKeyPath)
		} else {
			slog.Warn("failed to load witness key from file; falling back to in-memory key", "path", witnessKeyPath, "error", err)
		}
	} else if pemEnv := os.Getenv("WITNESS_KEY_PEM"); pemEnv != "" {
		if s, err := attestation.NewLocalEd25519SignerFromPEM([]byte(pemEnv)); err == nil {
			witnessSigner = s
			slog.Info("loaded witness attestation key from env PEM", "key_id", s.KeyID())
		}
	}

	if witnessSigner == nil {
		inMemSigner, err := attestation.GenerateInMemoryEd25519Signer("witness-inmem-v1")
		if err != nil {
			slog.Error("failed to generate in-memory witness signer", "error", err)
		} else {
			witnessSigner = inMemSigner
			slog.Info("initialized in-memory witness attestation signer", "key_id", inMemSigner.KeyID())
		}
	}

	var attEngine *attestation.AttestationEngine
	if witnessSigner != nil {
		historyStore := attestation.NewKeyHistoryStore()
		if pubDir := os.Getenv("WITNESS_KEY_HISTORY_DIR"); pubDir != "" {
			count, _ := historyStore.LoadPublicKeysFromDir(pubDir)
			slog.Info("loaded historical witness public keys", "count", count, "dir", pubDir)
		}
		if eng, err := attestation.NewAttestationEngine(witnessSigner, historyStore, "sler-fleet-manager"); err == nil {
			attEngine = eng
			slog.Info("witness attestation engine initialized", "key_id", eng.KeyID())
		} else {
			slog.Error("failed to initialize attestation engine", "error", err)
		}
	}

	orchestrator := NewCascadeOrchestrator(dag, selection.Client, time.Duration(stepDelayMs)*time.Millisecond)
	if attEngine != nil {
		orchestrator.SetAttestationEngine(attEngine)
	}

	s := &server{
		dag:               dag,
		orchestrator:      orchestrator,
		enforcement:       &selection,
		keyRegistry:       keyReg,
		replayLedger:      replayLedger,
		resumePolicy:      resumePolicy,
		attestationEngine: attEngine,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/api/v1/fleet/topology", s.handleTopology)
	mux.HandleFunc("/api/v1/fleet/deploy", s.handleDeploy)
	mux.HandleFunc("/api/v1/fleet/stun/", s.handleStun)
	mux.HandleFunc("/api/v1/fleet/resume", s.handleResume)
	mux.HandleFunc("/api/v1/fleet/resume/", s.handleResume)
	mux.HandleFunc("/api/v1/fleet/scan", s.handleScan)
	mux.HandleFunc("/api/v1/fleet/recover", s.handleRecover)
	mux.HandleFunc("/api/v1/fleet/reset", s.handleReset)
	registerConsistencyRoutes(mux, s)

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
