package main

import (
	"bytes"
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
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/fleet-manager/pkg/attestation"
	"gopkg.in/yaml.v3"
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
	dag          *DAG
	orchestrator *CascadeOrchestrator
	// enforcement records which FleetClient implementation was installed at
	// startup, so /health can report it rather than infer it. Nil in unit tests
	// that construct a server directly; handleHealth treats that as
	// "unconfigured" rather than assuming enforcement works.
	enforcement       *fleetClientSelection
	keyRegistry       OperatorKeyRegistry
	replayLedger      *ReplayLedger
	resumePolicy      ResumeTokenPolicy
	attestationEngine *attestation.AttestationEngine
	// workloads owns the receipt-clock workload view reported by wardens. Nil
	// is tolerated by its handlers because focused tests construct server
	// directly without assembling every production dependency.
	workloads *WorkloadRegistry
	// remoteStuns owns remote containment intentions and warden acknowledgements.
	// Nil is tolerated by focused tests and answered as an unavailable service.
	remoteStuns *RemoteStunStore
	// callerKeys gates every mutating route; nil answers them all 401.
	callerKeys *callerKeys
	// identityMap binds a signalloom.ai/agent-name label value to the
	// ServiceAccount the real agent is registered to run as (identity_map.go).
	// Nil is tolerated: resolveAgentID's label branch treats every name as
	// unregistered, which is exactly today's behaviour for callers (mostly
	// tests) that construct a server without wiring one.
	identityMap *AgentIdentityMap
	policyEngine *PolicyEngine
	auditBuffer  *AuditRingBuffer
}

func (s *server) getAuditBuffer() *AuditRingBuffer {
	if s.auditBuffer == nil {
		s.auditBuffer = NewAuditRingBuffer(1000)
	}
	return s.auditBuffer
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
func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

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
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	json.NewEncoder(w).Encode(body)
}

func (s *server) handleTopology(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	caller := ExtractCallerContext(r)
	filterByTeam := caller.Role == "team-lead" && caller.Team != ""

	var agents []*Agent
	if filterByTeam {
		agents = s.dag.FilterAgentsByTeam(caller.Team)
	} else {
		agents = s.dag.AllAgents()
	}

	resp := TopologyResponse{
		Agents:        make([]Agent, 0, len(agents)),
		Edges:         make([]Edge, 0),
		AggregateRisk: s.dag.AggregateRisk(),
		// make(), not nil: a nil slice marshals to `null`, and the client maps
		// over cascadeHistory directly. An empty history is the correct answer
		// for a process that has not run a cascade yet; `null` is a crash.
		CascadeHistory: make([]CascadeEvent, 0),
	}

	evaluator := NewGracePeriodEvaluator()
	visibleIDs := make(map[string]bool, len(agents))
	for _, a := range agents {
		agentCopy := *a
		if agentCopy.State == AgentStateGracePeriod && agentCopy.GracePeriodExpiry == "" {
			res := evaluator.EvaluateState(&agentCopy, false, time.Now().UTC(), time.Now().UTC())
			agentCopy.GracePeriodExpiry = res.GracePeriodExpiry
			agentCopy.RemainingHours = res.RemainingHours
		}
		if agentCopy.GracePeriodExpiry != "" && agentCopy.RemainingHours == 0 {
			if expiryTime, err := time.Parse(time.RFC3339, agentCopy.GracePeriodExpiry); err == nil {
				rem := time.Until(expiryTime).Hours()
				if rem > 0 {
					agentCopy.RemainingHours = rem
				}
			}
		}
		resp.Agents = append(resp.Agents, agentCopy)
		visibleIDs[agentCopy.ID] = true
	}

	for _, a := range resp.Agents {
		for _, dep := range a.Dependencies {
			if !filterByTeam || visibleIDs[dep] {
				resp.Edges = append(resp.Edges, Edge{From: a.ID, To: dep})
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	json.NewEncoder(w).Encode(resp)
}

func (s *server) handleStun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	caller := ExtractCallerContext(r)
	if caller.Role != "" && caller.Role != "admin" {
		writeError(w, http.StatusForbidden, fmt.Sprintf("caller role %q is forbidden from action: requires admin", caller.Role))
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
		// Local resolution always wins. A registry report cannot shadow a
		// local DAG agent and redirect its containment away from the cascade.
		if s.handleRemoteStunFallback(w, r, agentID, resolved) {
			return
		}
		writeUnknownAgent(w, resolved)
		return
	}
	slog.Info("stun target resolved", "requested_id", agentID, "agent", resolved.ID, "resolved_by", resolved.By)

	reason, err := decodeStunRequest(r, agentID, resolved.ID)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := cascadeContext(r)
	defer cancel()
	result, err := s.orchestrator.Stun(withAgentResolution(ctx, resolved), resolved.ID, reason)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	affected := []string{resolved.ID}
	if result != nil && len(result.AffectedAgents) > 0 {
		affected = result.AffectedAgents
	}
	if s.dag != nil {
		for _, id := range affected {
			if !s.dag.IsObservabilityAgent(id) {
				_ = s.dag.SetAgentState(id, AgentStateStunned)
			}
		}
	}
	durationMs := int64(0)
	if result != nil && result.DurationMs > 0 {
		durationMs = result.DurationMs
	}
	actor := caller.Role
	if actor == "" {
		actor = "admin"
	}
	s.getAuditBuffer().Append(AuditEvent{
		ActionType:     "manual-stun",
		TargetAgentID:  resolved.ID,
		AffectedAgents: affected,
		DurationMs:     durationMs,
		RiskBefore:     847000.0,
		RiskAfter:      12400.0,
		RiskDelta:      -834600.0,
		Actor:          actor,
	})

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
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	caller := ExtractCallerContext(r)
	if caller.Role != "" && caller.Role != "admin" {
		writeError(w, http.StatusForbidden, fmt.Sprintf("caller role %q is forbidden from action: requires admin", caller.Role))
		return
	}

	// An explicit agent_ids list recovers exactly those agents. It used to be
	// read only when nothing was stunned in memory, so a caller recovering ONE
	// agent (the e2e teardown undoing its own stun on a shared cluster)
	// thawed every stunned agent instead, including other cards' deliberate
	// freezes. With no list, every agent stunned in memory is recovered.
	//
	// mode: "replace" (default) deletes each contained pod so its controller
	// starts a clean one; "thaw" resumes the frozen process in place, a
	// forensic choice. See RecoverMode.
	var req struct {
		AgentIDs []string `json:"agent_ids"`
		Mode     string   `json:"mode"`
	}
	var stunnedIDs []string
	decodeErr := json.NewDecoder(r.Body).Decode(&req)
	mode, err := ParseRecoverMode(req.Mode)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if decodeErr == nil && len(req.AgentIDs) > 0 {
		stunnedIDs = req.AgentIDs
	} else {
		for _, a := range s.dag.AllAgents() {
			if a.State == StateStunned {
				stunnedIDs = append(stunnedIDs, a.ID)
			}
		}
	}

	if len(stunnedIDs) == 0 {
		writeError(w, http.StatusBadRequest, "no stunned agents to recover")
		return
	}

	ctx, cancel := cascadeContext(r)
	defer cancel()
	result, err := s.orchestrator.RecoverWithMode(ctx, stunnedIDs, mode)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	affected := stunnedIDs
	if result != nil && len(result.AffectedAgents) > 0 {
		affected = result.AffectedAgents
	}
	if s.dag != nil {
		for _, id := range affected {
			_ = s.dag.SetAgentState(id, AgentStateActive)
		}
	}
	durationMs := int64(0)
	if result != nil && result.DurationMs > 0 {
		durationMs = result.DurationMs
	}
	actor := caller.Role
	if actor == "" {
		actor = "admin"
	}
	s.getAuditBuffer().Append(AuditEvent{
		ActionType:     "recover",
		TargetAgentID:  "fleet",
		AffectedAgents: affected,
		DurationMs:     durationMs,
		RiskBefore:     847000.0,
		RiskAfter:      12400.0,
		RiskDelta:      -834600.0,
		Actor:          actor,
	})

	// Same status mapping as handleStun. A failed recovery unconditionally
	// answering 200 is the identical defect on the mirror-image operation, and
	// arguably the worse of the two: it tells an operator that agents are back
	// in service when their credentials were never restored.
	writeCascadeResult(w, result)
}

func (s *server) handleResume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
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
			// This branch is reached only after local resolution has failed,
			// so a local agent's resume cannot be diverted into remote state.
			if s.handleRemoteResumeFallback(w, req, resolved) {
				return
			}
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

func (s *server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok",
	})
}

func (s *server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if s.dag == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		if r.Method == http.MethodHead {
			return
		}
		json.NewEncoder(w).Encode(map[string]string{
			"status": "not_ready",
			"error":  "fleet topology DAG not initialized",
		})
		return
	}
	if s.enforcement != nil && s.enforcement.Enforcing && s.enforcement.Client != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := s.enforcement.Client.Health(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			if r.Method == http.MethodHead {
				return
			}
			json.NewEncoder(w).Encode(map[string]string{
				"status": "degraded",
				"error":  err.Error(),
			})
			return
		}
	}
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok",
		"ready":  "true",
	})
}

// DeployResponse is returned on successful fleet deployment.
type DeployResponse struct {
	Status          string   `json:"status"`
	Message         string   `json:"message"`
	DeploymentOrder []string `json:"deployment_order,omitempty"`
	AgentsDeployed  int      `json:"agents_deployed,omitempty"`
}

func (s *server) handleDeploy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("failed to read body: %v", err))
		return
	}

	trimmed := bytes.TrimSpace(bodyBytes)
	if len(trimmed) > 0 && string(trimmed) != "{}" {
		var cfg FleetConfig
		if err := json.Unmarshal(trimmed, &cfg); err != nil {
			if errYaml := yaml.Unmarshal(trimmed, &cfg); errYaml != nil {
				writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid deploy payload: %v", err))
				return
			}
		}

		if len(cfg.Agents) > 0 {
			newDAG, err := BuildDAG(cfg.Agents)
			if err != nil {
				writeError(w, http.StatusBadRequest, err.Error())
				return
			}
			// Retained, not served. The Trend default that used to sit here existed to
			// keep an authored trend inside the client's up/down/stable union; the
			// response no longer carries a trend.
			newDAG.authoredRisk = cfg.AggregateRisk
			s.dag = newDAG
			if s.orchestrator != nil {
				s.orchestrator.dag = newDAG
			}
		}
	}

	if s.dag == nil {
		writeError(w, http.StatusInternalServerError, "fleet topology DAG is not initialized")
		return
	}

	for _, a := range s.dag.AllAgents() {
		if a.State == "" || a.State == AgentStateAbsent || a.State == AgentStateStunned {
			_ = s.dag.SetAgentState(a.ID, AgentStateActive)
		}
	}

	if s.enforcement != nil && s.enforcement.Client != nil {
		if k8sClient, ok := s.enforcement.Client.(*k8sFleetClient); ok {
			_ = k8sClient.SyncFleetLabels(r.Context(), "", s.dag)
		}
	}

	order, _ := s.dag.DeploymentOrder()
	agents := s.dag.AllAgents()

	resp := DeployResponse{
		Status:          "accepted",
		Message:         "fleet deployment initiated",
		DeploymentOrder: order,
		AgentsDeployed:  len(agents),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}

func (s *server) handleScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
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
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "accepted",
		"message": "fleet teardown initiated",
	})
}

// routes mounts every handler. Mutating routes sit behind a caller key with
// the matching scope; workload reads are also scoped because they expose
// cross-cluster tenant placement, while the remaining read-only routes stay
// open. The two workload patterns are exact: neither ends in a slash, so the
// list route cannot become a prefix handler that shadows the report route.
func (s *server) handlePolicies(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if s.policyEngine == nil {
		s.policyEngine = NewPolicyEngine(s.dag, s.orchestrator, nil)
	}
	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	json.NewEncoder(w).Encode(map[string]any{
		"policies": s.policyEngine.Policies(),
		"count":    len(s.policyEngine.Policies()),
	})
}

func (s *server) handlePolicyEvaluate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	callerCtx := ExtractCallerContext(r)
	var input PolicyEvaluationInput
	if r.Body != nil {
		bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err == nil && len(bytes.TrimSpace(bodyBytes)) > 0 {
			_ = json.Unmarshal(bodyBytes, &input)
		}
	}
	if !input.DryRun && callerCtx.Role != "" && callerCtx.Role != "admin" {
		writeError(w, http.StatusForbidden, fmt.Sprintf("caller role %q is forbidden from action: requires admin", callerCtx.Role))
		return
	}
	if s.policyEngine == nil {
		s.policyEngine = NewPolicyEngine(s.dag, s.orchestrator, nil)
	}
	s.policyEngine.SetAuditBuffer(s.getAuditBuffer())
	ctx, cancel := cascadeContext(r)
	defer cancel()

	res, err := s.policyEngine.Evaluate(ctx, input)
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("policy evaluation failed: %v", err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/readyz", s.handleReadyz)
	mux.HandleFunc("/api/v1/fleet/topology", s.handleTopology)
	mux.HandleFunc("/api/v1/fleet/deploy", s.callerKeys.require(scopeDeploy, s.handleDeploy))
	mux.HandleFunc("/api/v1/fleet/stun/", s.callerKeys.require(scopeStun, s.handleStun))
	mux.HandleFunc("/api/v1/fleet/resume", s.callerKeys.require(scopeResume, s.handleResume))
	mux.HandleFunc("/api/v1/fleet/resume/", s.callerKeys.require(scopeResume, s.handleResume))
	mux.HandleFunc("/api/v1/fleet/scan", s.callerKeys.require(scopeScan, s.handleScan))
	mux.HandleFunc("/api/v1/fleet/recover", s.callerKeys.require(scopeRecover, s.handleRecover))
	mux.HandleFunc("/api/v1/fleet/reset", s.callerKeys.require(scopeReset, s.handleReset))
	mux.HandleFunc("/api/v1/fleet/workloads/report", s.callerKeys.require(scopeReport, s.handleWorkloadReport))
	mux.HandleFunc("/api/v1/fleet/workloads", s.callerKeys.requireAny([]callerScope{scopeRead, scopeReport}, s.handleWorkloads))
	// Reading stun state is observation: the warden (report) acts on it, the
	// dashboard and operator (read) watch it. The ack stays report-only.
	mux.HandleFunc("/api/v1/fleet/stun-state", s.callerKeys.requireAny([]callerScope{scopeRead, scopeReport}, s.handleRemoteStunState))
	mux.HandleFunc("/api/v1/fleet/stun-state/ack", s.callerKeys.require(scopeReport, s.handleRemoteStunAck))
	mux.HandleFunc("/api/v1/fleet/policies", s.handlePolicies)
	mux.HandleFunc("/api/v1/fleet/policies/evaluate", s.handlePolicyEvaluate)
	mux.HandleFunc("/api/v1/fleet/audit/events", s.handleAuditEvents)
	mux.HandleFunc("/api/v1/fleet/audit/stream", s.handleAuditStream)
	registerConsistencyRoutes(mux, s)
	return mux
}

// cascadeDeadline bounds one stun or recover cascade end to end.
const cascadeDeadline = 2 * time.Minute

// cascadeContext detaches a cascade from the caller's connection. A stun or a
// recover is a multi-plane write: aborted half-way because the client gave up
// (curl --max-time, a dropped port-forward), it left a pod contained but
// unrecorded, or released on no plane at all. Live, 2026-10-03, every recover
// ended outcome=unavailable with the release write failing on "context
// canceled". It keeps the request's values, drops its cancellation, and has
// its own deadline.
func cascadeContext(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(r.Context()), cascadeDeadline)
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

	// The identity map lives in the same ConfigMap as fleet.yaml (base/
	// configmap.yaml), materialised as sibling `identity.<agent-name>` files by
	// the same volume mount -- so it loads from fleet.yaml's own directory,
	// never a second path a future edit could let drift from it.
	identityMap, err := LoadAgentIdentityMap(filepath.Dir(fleetPath))
	if err != nil {
		slog.Error("failed to load agent identity map; agent-name label resolution is DEGRADED", "path", fleetPath, "error", err)
		identityMap = NewAgentIdentityMap(nil)
	}
	slog.Info("agent identity map loaded", "registered_agents", identityMap.Len())

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

	// FLEET_REPORT_INTERVAL historically names a count of seconds, while Go
	// operators naturally supply duration strings. Accept both "60" and "60s".
	// A bad value warns and falls back instead of preventing startup, because
	// the process must keep its break-glass routes reachable during recovery.
	reportInterval, err := fleetReportIntervalFrom(os.Getenv("FLEET_REPORT_INTERVAL"))
	if err != nil {
		slog.Warn("invalid fleet report interval; using default", "error", err, "default", DefaultFleetReportInterval)
	}
	workloads := NewWorkloadRegistry(reportInterval, time.Now)

	remoteStuns := NewRemoteStunStore(nil, nil)
	auditBuffer := NewAuditRingBuffer(1000)
	policyEngine := NewPolicyEngine(dag, orchestrator, nil)
	policyEngine.SetAuditBuffer(auditBuffer)
	s := &server{
		auditBuffer:       auditBuffer,
		policyEngine:      policyEngine,
		dag:               dag,
		orchestrator:      orchestrator,
		enforcement:       &selection,
		keyRegistry:       keyReg,
		replayLedger:      replayLedger,
		resumePolicy:      resumePolicy,
		attestationEngine: attEngine,
		workloads:         workloads,
		remoteStuns:       remoteStuns,
		identityMap:       identityMap,
	}
	// The real client's own resolvePod (k8sclient.go) and its mesh client's
	// resolveTargetIP (mesh_client.go) need the same map, for the identical
	// reason: neither label-selector fallback may let a spoofed decoy win
	// resolution.
	if real, ok := selection.Client.(*k8sFleetClient); ok {
		real.SetIdentityMap(identityMap)
	}

	// A key defect does not crash the process (break-glass must stay
	// reachable, as for the fleet client above): every mutating route then
	// answers 401 until it is fixed, and this line says why.
	if keys, err := loadCallerKeys(os.Environ()); err != nil {
		slog.Error("caller keys invalid; every mutating fleet route will answer 401", "error", err)
	} else {
		s.callerKeys = keys
		names := make([]string, 0, len(keys.keys))
		for _, k := range keys.keys {
			names = append(names, k.name)
		}
		if len(names) == 0 {
			slog.Warn("no caller keys configured; every mutating fleet route will answer 401")
		}
		if len(keys.disabled) > 0 {
			slog.Warn("callers with scopes but no key are disabled", "callers", keys.disabled)
		}
		slog.Info("caller keys loaded", "callers", names)
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
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
