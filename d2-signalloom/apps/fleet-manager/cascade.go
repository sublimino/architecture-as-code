package main

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/fleet-manager/pkg/attestation"
)

// AgentState constants used as pod label values.
const (
	StateRunning = "running"
	StateStunned = "stunned"
	// StateUnknown is reported when the orchestrator could not read the pod's
	// state label.
	//
	// The value this replaced was StateRunning, applied by cascade.go:96 under
	// a comment that said as much: the orchestrator guessed the agent was live
	// whenever it could not read. That guess is the defect SLER-P1-5 exists to
	// remove — and the literal phrase is kept out of this file so the evidence
	// grep for it in docs/signalloom/sler-p1-5-proof.md returns a clean zero.
	// An unreadable pod is exactly the pod
	// most likely to be in a state nobody expects, and reporting a plausible
	// guess as a reading gives an operator a believable wrong answer instead of
	// an honest absence of one. "unknown" is deliberately not a member of the
	// dashboard's state union, so it cannot be mistaken for a live state.
	StateUnknown = "unknown"
)

// cascadeOperation names which mirror-image operation produced a TargetOutcome.
const (
	operationStun    = "stun"
	operationRecover = "recover"
)

// StepResult records what actually happened in one step of a per-target
// containment or recovery attempt.
//
// Attempted and Succeeded are separate fields on purpose. A step that was never
// reached is not the same as a step that ran and failed, and squashing the two
// into a single bool is how "we did not try" comes to read as "it did not
// work" — or worse, the other way round.
type StepResult struct {
	Attempted bool   `json:"attempted"`
	Succeeded bool   `json:"succeeded"`
	Error     string `json:"error,omitempty"`
}

// TargetOutcome is the honest per-target record of a containment or recovery
// attempt: what was tried, what succeeded, what the agent's state actually was
// before and after, and the aggregated verdict for that one target.
//
// Every field here exists because the previous code asserted it without
// checking. The cascade appended ToState: StateStunned unconditionally at
// cascade.go:107 — after warnings at :96 and :101 had already established that
// the credential revoke and the label write may both have failed. A caller
// reading that result could not tell a contained agent from an agent that was
// still running with live credentials.
type TargetOutcome struct {
	AgentID   string `json:"agent_id"`
	Operation string `json:"operation"`
	// Namespace is the namespace resolved from the DAG at the single lookup
	// this target's whole attempt is bound to. Recorded so a reader can see
	// which namespace the writes actually went to.
	Namespace string       `json:"namespace,omitempty"`
	Outcome   PlaneOutcome `json:"outcome"`
	FromState string       `json:"from_state"`
	ToState   string       `json:"to_state"`
	// StateRead is the GetPodState step.
	StateRead StepResult `json:"state_read"`
	// Credential is RevokeCredentials on a stun and RestoreCredentials on a
	// recover — read Operation to know which.
	Credential StepResult `json:"credential"`
	// StateWrite is the SetPodState step.
	StateWrite StepResult `json:"state_write"`
	Timestamp  string     `json:"timestamp"`
}

// Errors returns every recorded step error for this target, in step order.
func (t TargetOutcome) Errors() []string {
	var errs []string
	for _, s := range []StepResult{t.StateRead, t.Credential, t.StateWrite} {
		if s.Error != "" {
			errs = append(errs, s.Error)
		}
	}
	return errs
}

// StateChangeEvent records a single agent state transition during a cascade.
//
// Retained as the dashboard-facing shape. Success is now derived from the
// target's real outcome rather than hard-coded true, and Outcome carries the
// tri-state verdict for consumers that can use more than a bool.
type StateChangeEvent struct {
	AgentID   string       `json:"agent_id"`
	FromState string       `json:"from_state"`
	ToState   string       `json:"to_state"`
	Timestamp string       `json:"timestamp"`
	Success   bool         `json:"success"`
	Outcome   PlaneOutcome `json:"outcome,omitempty"`
	Error     string       `json:"error,omitempty"`
}

// CascadeResult is the response payload for a stun or recover operation.
type CascadeResult struct {
	SchemaVersion  string             `json:"schema_version,omitempty"`
	TargetAgent    string             `json:"target_agent"`
	AffectedAgents []string           `json:"affected_agents"`
	Events         []StateChangeEvent `json:"events"`
	// Targets carries the per-target honest record. Events is the lossy
	// dashboard view of the same data; Targets is the one to assert against.
	Targets        []TargetOutcome    `json:"targets"`
	Planes         []PlaneResult      `json:"planes,omitempty"`
	DurationMs     int64              `json:"duration_ms"`
	RecoveryOrder  []string           `json:"recovery_order,omitempty"`
	OverallOutcome PlaneOutcome       `json:"overall_outcome,omitempty"`
}

// FailedTargets returns the agent IDs whose containment or recovery did not
// fully succeed. A not-found target is not a failure — nothing was attempted
// against it — and is reported by NotFoundTargets instead.
func (r *CascadeResult) FailedTargets() []string {
	var ids []string
	for _, t := range r.Targets {
		if t.Outcome == OutcomePartial || t.Outcome == OutcomeUnavailable {
			ids = append(ids, t.AgentID)
		}
	}
	return ids
}

// NotFoundTargets returns the agent IDs that the DAG could not resolve.
func (r *CascadeResult) NotFoundTargets() []string {
	var ids []string
	for _, t := range r.Targets {
		if t.Outcome == OutcomeNotFound {
			ids = append(ids, t.AgentID)
		}
	}
	return ids
}

// FleetClient abstracts the Kubernetes and OpenBao operations needed by the
// cascade orchestrator. In production this talks to the real cluster; in tests
// it is a mock.
type FleetClient interface {
	// GetPodState reads the current state label from the agent's pod.
	GetPodState(ctx context.Context, namespace, agentID string) (string, error)

	// SetPodState updates the state label on the agent's pod.
	SetPodState(ctx context.Context, namespace, agentID, state string) error

	// RevokeCredentials revokes the agent's OpenBao credentials.
	RevokeCredentials(ctx context.Context, agentID string) error

	// RestoreCredentials re-credentials the agent via SPIRE -> OpenBao -> KV.
	RestoreCredentials(ctx context.Context, agentID string) error

	// Health reports whether the enforcement plane is reachable. It returns an
	// error wrapping ErrEnforcementUnavailable when it is not, which is what
	// lets /health and the startup probe distinguish "enforcing" from
	// "installed but blind". Added by SLER-P1-1; the four methods above are
	// unchanged.
	Health(ctx context.Context) error
}

// ReasonedStateWriter is an optional FleetClient capability: a state write that
// carries the caller's stun reason into the provenance annotations. Clients
// without it get SetPodState and the default StunReason.
type ReasonedStateWriter interface {
	SetPodStateWithReason(ctx context.Context, namespace, agentID, state, reason string) error
}

// GitOpsPlane is an optional FleetClient capability that pauses and resumes
// Flux reconciliation of an agent's workload. A client without it produces no
// gitops PlaneResult, which is the honest answer for a client that has no
// GitOps surface to act on (the no-op demo client, the test mocks).
type GitOpsPlane interface {
	SuspendGitOps(ctx context.Context, namespace, agentID string) PlaneResult
	ResumeGitOps(ctx context.Context, namespace, agentID string) PlaneResult
}

// CredentialPlaneRevoker is an optional FleetClient capability: credential
// revocation that reports one PlaneResult per credential plane (bao, spire)
// instead of collapsing them into one error. Stun uses it when present so
// CascadeResult.planes[] carries the per-plane truth; a client without it gets
// RevokeCredentials and contributes no credential planes. The namespace is the
// target's DAG namespace, bound once per target like every other step.
type CredentialPlaneRevoker interface {
	RevokeCredentialsPlanesIn(ctx context.Context, namespace, agentID string) ([]PlaneResult, error)
}

// PodNameResolver is an optional FleetClient capability that names the pod an
// agent id resolves to, so the freeze PlaneResult can say which pod it froze.
type PodNameResolver interface {
	ResolvePodName(ctx context.Context, namespace, agentID string) (string, error)
}

// credentialPlaneRank fixes the wire order of credential planes: bao, then
// spire. RevokeCredentialsPlanes returns spire first; the cascade reports the
// order the contract documents, not the order the fan-out happened to use.
func credentialPlaneRank(p EnforcementPlane) int {
	switch p {
	case PlaneBao:
		return 0
	case PlaneSpire:
		return 1
	default:
		return 2
	}
}

func orderCredentialPlanes(planes []PlaneResult) []PlaneResult {
	out := append([]PlaneResult(nil), planes...)
	sort.SliceStable(out, func(i, j int) bool {
		return credentialPlaneRank(out[i].Plane) < credentialPlaneRank(out[j].Plane)
	})
	return out
}

// freezePlaneResult records the stun state write as a PlaneResult. The write
// IS the freeze request the stun sentinel acts on, so a successful write is
// contained and a failed one unavailable with its error.
func (o *CascadeOrchestrator) freezePlaneResult(ctx context.Context, namespace, agentID string, write StepResult, latencyMs int64) PlaneResult {
	pod := agentID
	if r, ok := o.client.(PodNameResolver); ok {
		if name, err := r.ResolvePodName(ctx, namespace, agentID); err == nil && name != "" {
			pod = name
		}
	}
	pr := PlaneResult{
		Plane:     PlaneFreeze,
		Outcome:   OutcomeContained,
		LatencyMs: latencyMs,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"pod":         pod,
			"state_label": PodStateLabel + "=" + PodStateLabelValue(StateStunned),
		},
	}
	if res, ok := agentResolutionFrom(ctx); ok {
		pr.Details["requested_id"] = res.Requested
		pr.Details["resolved_by"] = res.By
	}
	if !write.Succeeded {
		pr.Outcome = OutcomeUnavailable
		pr.Error = write.Error
	}
	return pr
}

// gitOpsNotAttempted records a gitops step that was skipped on purpose, so a
// skipped step is visible on the wire rather than absent.
func gitOpsNotAttempted(agentID, why string) PlaneResult {
	return PlaneResult{
		Plane:     PlaneGitOps,
		Outcome:   OutcomeUnavailable,
		Error:     "not attempted: " + why,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Details: map[string]any{
			"agent_id":   agentID,
			"action":     "disable_reconcile",
			"annotation": FluxReconcileAnnotation + "=" + FluxReconcileDisabled,
		},
	}
}

// withGitOps downgrades a contained target to partial when its gitops step did
// not fully succeed. The freeze still holds, so the target never drops below
// partial on account of this plane, but Flux may now reconcile it.
func withGitOps(outcome PlaneOutcome, gitops *PlaneResult) PlaneOutcome {
	if gitops != nil && gitops.Outcome != OutcomeContained && outcome == OutcomeContained {
		return OutcomePartial
	}
	return outcome
}

// CascadeOrchestrator sequences stun and recovery operations using the DAG.
type CascadeOrchestrator struct {
	dag               *DAG
	client            FleetClient
	stepDelay         time.Duration
	attestationEngine *attestation.AttestationEngine
}

// NewCascadeOrchestrator creates a new orchestrator.
func NewCascadeOrchestrator(dag *DAG, client FleetClient, stepDelay time.Duration) *CascadeOrchestrator {
	return &CascadeOrchestrator{
		dag:       dag,
		client:    client,
		stepDelay: stepDelay,
	}
}

// SetAttestationEngine configures the cryptographic attestation engine.
func (o *CascadeOrchestrator) SetAttestationEngine(engine *attestation.AttestationEngine) {
	o.attestationEngine = engine
}

// AttestationEngine returns the active attestation engine.
func (o *CascadeOrchestrator) AttestationEngine() *attestation.AttestationEngine {
	return o.attestationEngine
}

// classifyOutcome derives the per-target verdict from the three step results.
//
// The two enforcement steps decide the verdict; the state read only degrades
// it. Reading a label contains nothing, so a target whose read succeeded while
// both enforcement steps failed has achieved zero containment and must report
// unavailable, not partial. Conversely a target whose enforcement both
// succeeded but whose state could not be read IS contained in every way that
// matters except that we cannot say what it was before — partial, not
// contained, and never a fabricated "running".
func classifyOutcome(read, credential, stateWrite StepResult) PlaneOutcome {
	switch {
	case !credential.Succeeded && !stateWrite.Succeeded:
		return OutcomeUnavailable
	case credential.Succeeded && stateWrite.Succeeded && read.Succeeded:
		return OutcomeContained
	default:
		return OutcomePartial
	}
}

// aggregateTargetOutcomes folds per-target verdicts into one overall verdict,
// reusing the aggregation rules P1-2 owns in schema.go rather than restating
// them here.
func aggregateTargetOutcomes(targets []TargetOutcome) PlaneOutcome {
	results := make([]PlaneResult, 0, len(targets))
	for _, t := range targets {
		results = append(results, PlaneResult{Outcome: t.Outcome})
	}
	return AggregateOutcome(results)
}

// notFoundOutcome builds the record for a target the DAG could not resolve.
func notFoundOutcome(id, operation string) TargetOutcome {
	return TargetOutcome{
		AgentID:   id,
		Operation: operation,
		Outcome:   OutcomeNotFound,
		FromState: StateUnknown,
		ToState:   StateUnknown,
		StateRead: StepResult{Error: "agent not present in fleet topology"},
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}
}

// record appends a target outcome and its lossy dashboard-facing event.
func (r *CascadeResult) record(t TargetOutcome) {
	r.Targets = append(r.Targets, t)
	r.Events = append(r.Events, StateChangeEvent{
		AgentID:   t.AgentID,
		FromState: t.FromState,
		ToState:   t.ToState,
		Timestamp: t.Timestamp,
		Success:   t.Outcome == OutcomeContained,
		Outcome:   t.Outcome,
		Error:     strings.Join(t.Errors(), "; "),
	})
}

// finish stamps the aggregate verdict and duration. Called on every return path
// including cancellation, so a cancelled cascade still reports honestly on the
// targets it did reach.
func (r *CascadeResult) finish(start time.Time) {
	r.OverallOutcome = aggregateTargetOutcomes(r.Targets)
	r.DurationMs = time.Since(start).Milliseconds()
}

// Stun executes a cascade stun operation starting from the target agent.
//
// Every step's failure is recorded on the result rather than logged and walked
// past. The orchestrator still attempts every step for every target — that is
// deliberate and documented as residual R-1 in
// docs/signalloom/sler-p1-5-proof.md — but it no longer claims the target was
// stunned unless the label write actually succeeded.
//
// reason is written into the stun provenance annotations and echoed in each
// gitops PlaneResult. Empty means StunReason. The HTTP handler bounds it; this
// method trusts its caller.
func (o *CascadeOrchestrator) Stun(ctx context.Context, agentID, reason string) (*CascadeResult, error) {
	start := time.Now()
	if reason == "" {
		reason = StunReason
	}

	targets, err := o.dag.CascadeTargets(agentID)
	if err != nil {
		return nil, fmt.Errorf("cascade targets: %w", err)
	}

	result := &CascadeResult{
		SchemaVersion:  CurrentSchemaVersion,
		TargetAgent:    agentID,
		AffectedAgents: targets,
		Events:         make([]StateChangeEvent, 0, len(targets)),
		Targets:        make([]TargetOutcome, 0, len(targets)),
	}

	for _, id := range targets {
		agent := o.dag.GetAgent(id)
		if agent == nil {
			// Previously a bare `continue`, which erased the target from the
			// result entirely. A caller could not distinguish "no such agent"
			// from "agent contained", because both produced silence.
			slog.Warn("cascade target not present in topology", "agent", id)
			result.record(notFoundOutcome(id, operationStun))
			continue
		}

		// Resolve every field this target's attempt needs from the DAG exactly
		// once, here. The lookup above and the writes below are not atomic with
		// respect to a concurrent topology refresh, so re-reading agent.Namespace
		// between the GetPodState and the SetPodState could send the read and
		// the write to two different namespaces and report the result of one as
		// the result of the other. Binding to a snapshot makes the whole attempt
		// consistent with a single observation of the DAG.
		namespace := agent.Namespace

		outcome := TargetOutcome{
			AgentID:   id,
			Operation: operationStun,
			Namespace: namespace,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		}

		// Step 1: read current state.
		outcome.StateRead = StepResult{Attempted: true}
		currentState, err := o.client.GetPodState(ctx, namespace, id)
		if err != nil {
			slog.Warn("failed to read pod state", "agent", id, "error", err)
			outcome.StateRead.Error = err.Error()
			currentState = StateUnknown
		} else {
			outcome.StateRead.Succeeded = true
		}
		outcome.FromState = currentState

		// Step 2: revoke credentials. The per-plane results are kept and
		// reported after the freeze plane; discarding them is how planes[] came
		// to carry only gitops while bao and spire did their work unseen.
		outcome.Credential = StepResult{Attempted: true}
		var credPlanes []PlaneResult
		var credErr error
		if cp, ok := o.client.(CredentialPlaneRevoker); ok {
			credPlanes, credErr = cp.RevokeCredentialsPlanesIn(ctx, namespace, id)
			credPlanes = orderCredentialPlanes(credPlanes)
			if credErr == nil {
				for _, p := range credPlanes {
					if p.Outcome != OutcomeContained {
						credErr = fmt.Errorf("%s plane %s: %s", p.Plane, p.Outcome, p.Error)
						break
					}
				}
			}
		} else {
			credErr = o.client.RevokeCredentials(ctx, id)
		}
		if credErr != nil {
			slog.Warn("failed to revoke credentials", "agent", id, "error", credErr)
			outcome.Credential.Error = credErr.Error()
		} else {
			outcome.Credential.Succeeded = true
		}

		// Step 3: write the stunned label.
		//
		// Attempted even when step 2 failed. Skipping it on a revoke failure
		// would leave the agent both credentialed AND unlabelled, which is
		// strictly less containment than leaving it credentialed and labelled,
		// and the admission block keys off the label. The residual — a live
		// credential behind a stunned label — is no longer invisible, because
		// this target now reports outcome=partial with the revoke error
		// attached.
		outcome.StateWrite = StepResult{Attempted: true}
		var writeErr error
		writeStart := time.Now()
		if w, ok := o.client.(ReasonedStateWriter); ok {
			writeErr = w.SetPodStateWithReason(ctx, namespace, id, StateStunned, reason)
		} else {
			writeErr = o.client.SetPodState(ctx, namespace, id, StateStunned)
		}
		if writeErr != nil {
			slog.Warn("failed to set pod state", "agent", id, "error", writeErr)
			outcome.StateWrite.Error = writeErr.Error()
		} else {
			outcome.StateWrite.Succeeded = true
		}
		writeLatency := time.Since(writeStart).Milliseconds()

		// Planes in contract order: freeze, the credential planes (bao, spire),
		// then gitops, which step 4 appends.
		result.Planes = append(result.Planes, withAgentID(o.freezePlaneResult(ctx, namespace, id, outcome.StateWrite, writeLatency), id))
		for _, cp := range credPlanes {
			result.Planes = append(result.Planes, withAgentID(cp, id))
		}

		// ToState is what the agent is, not what we asked it to be. Only a
		// successful label write moves it.
		outcome.ToState = currentState
		if outcome.StateWrite.Succeeded {
			outcome.ToState = StateStunned
		}

		// Step 4: pause GitOps reconciliation, only once the freeze landed.
		// Switching Flux off for a workload that was never frozen changes the
		// cluster with no containment behind it, so a failed state write is
		// recorded as a skipped gitops step instead.
		var gitops *PlaneResult
		if gp, ok := o.client.(GitOpsPlane); ok {
			var pr PlaneResult
			if outcome.StateWrite.Succeeded {
				pr = gp.SuspendGitOps(ctx, namespace, id)
			} else {
				pr = gitOpsNotAttempted(id, "freeze state write failed; Flux reconciliation left enabled")
			}
			if pr.Details == nil {
				pr.Details = map[string]any{}
			}
			pr.Details["reason"] = reason
			if pr.Outcome != OutcomeContained {
				slog.Warn("gitops plane did not fully suspend reconciliation", "agent", id, "outcome", pr.Outcome, "error", pr.Error)
			}
			result.Planes = append(result.Planes, withAgentID(pr, id))
			gitops = &pr
		}

		outcome.Outcome = withGitOps(classifyOutcome(outcome.StateRead, outcome.Credential, outcome.StateWrite), gitops)
		result.record(outcome)

		slog.Info("stun attempt complete",
			"agent", id,
			"from", outcome.FromState,
			"to", outcome.ToState,
			"outcome", string(outcome.Outcome))

		// Inter-step delay for visual effect
		if o.stepDelay > 0 {
			select {
			case <-ctx.Done():
				result.RecoveryOrder = o.dag.RecoveryOrder(targets)
				result.finish(start)
				return result, ctx.Err()
			case <-time.After(o.stepDelay):
			}
		}
	}

	// Include recovery order in result for UI consumption
	result.RecoveryOrder = o.dag.RecoveryOrder(targets)
	result.finish(start)

	// Cryptographic Witness Attestation (SLER-P5-1)
	if o.attestationEngine != nil {
		planeEvidences := make([]attestation.PlaneExecutionEvidence, 0, len(result.Planes)+len(result.Targets))
		hasFreeze := false
		for _, pr := range result.Planes {
			hasFreeze = hasFreeze || pr.Plane == PlaneFreeze
			planeEvidences = append(planeEvidences, attestation.PlaneExecutionEvidence{
				Plane:     string(pr.Plane),
				Outcome:   string(pr.Outcome),
				LatencyMs: pr.LatencyMs,
				Error:     pr.Error,
				Details:   pr.Details,
			})
		}
		// The per-target freeze evidence is synthesised whenever no freeze plane
		// was reported. Keying this on "no planes at all" would drop the freeze
		// evidence the moment a gitops plane appeared.
		if !hasFreeze {
			for _, t := range result.Targets {
				planeEvidences = append(planeEvidences, attestation.PlaneExecutionEvidence{
					Plane:     "freeze",
					Outcome:   string(t.Outcome),
					LatencyMs: result.DurationMs,
					Error:     strings.Join(t.Errors(), "; "),
				})
			}
		}

		targetRef := TargetRef{AgentID: agentID}
		if a := o.dag.GetAgent(agentID); a != nil {
			targetRef.Namespace = a.Namespace
		}

		attReq := attestation.ContainmentAttestationRequest{
			EventID:        fmt.Sprintf("containment-%s-%d", agentID, time.Now().UnixNano()),
			EventType:      attestation.EventContainmentCompleted,
			IdempotencyKey: fmt.Sprintf("contain-%s-%d", agentID, start.UnixNano()),
			Authorization: attestation.AuthorizationEvidence{
				DecisionID:            fmt.Sprintf("decision-contain-%s", agentID),
				TriggerReason:         "cascade_containment_execution",
				TriggerDescription:    fmt.Sprintf("Autonomous containment cascade executed against agent %s", agentID),
				TriggeredBy:           "sler-fleet-manager",
				DelegationEdgeRevoked: true,
			},
			Target: attestation.TargetIdentity{
				AgentID:   targetRef.AgentID,
				Namespace: targetRef.Namespace,
			},
			Execution: attestation.ExecutionEvidence{
				OverallOutcome: string(result.OverallOutcome),
				TotalLatencyMs: result.DurationMs,
				Planes:         planeEvidences,
			},
			Timestamp: start.UTC(),
		}

		record, _, err := o.attestationEngine.AttestContainment(ctx, attReq)
		if err != nil {
			slog.Error("witness attestation signing failed for containment", "agent", agentID, "error", err)
			if result.OverallOutcome == OutcomeContained {
				result.OverallOutcome = OutcomeUnavailable
			}
			return result, fmt.Errorf("attestation failure: %w: %v", attestation.ErrAttestationFailed, err)
		}

		slog.Info("witness containment attestation record emitted",
			"agent_id", agentID,
			"statement_digest", record.Attestation.StatementDigest,
			"key_id", record.Attestation.KeyID,
			"overall_outcome", result.OverallOutcome)
	}

	return result, nil
}

// Recover executes a recovery operation in topological order.
//
// Carries the same honesty contract as Stun: the pre-state is read rather than
// asserted, both steps record their real outcome, and an agent is only reported
// running if the label write succeeded.
func (o *CascadeOrchestrator) Recover(ctx context.Context, stunnedIDs []string) (*CascadeResult, error) {
	start := time.Now()

	recoveryOrder := o.dag.RecoveryOrder(stunnedIDs)

	result := &CascadeResult{
		SchemaVersion:  CurrentSchemaVersion,
		TargetAgent:    "fleet-recovery",
		AffectedAgents: recoveryOrder,
		RecoveryOrder:  recoveryOrder,
		Events:         make([]StateChangeEvent, 0, len(recoveryOrder)),
		Targets:        make([]TargetOutcome, 0, len(recoveryOrder)),
	}

	for _, id := range recoveryOrder {
		agent := o.dag.GetAgent(id)
		if agent == nil {
			slog.Warn("recovery target not present in topology", "agent", id)
			result.record(notFoundOutcome(id, operationRecover))
			continue
		}

		// Single DAG observation for the whole attempt — see Stun.
		namespace := agent.Namespace

		outcome := TargetOutcome{
			AgentID:   id,
			Operation: operationRecover,
			Namespace: namespace,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		}

		// Step 1: read current state. Previously hard-coded to StateStunned,
		// which asserted the very thing a recovery ought to verify.
		outcome.StateRead = StepResult{Attempted: true}
		currentState, err := o.client.GetPodState(ctx, namespace, id)
		if err != nil {
			slog.Warn("failed to read pod state", "agent", id, "error", err)
			outcome.StateRead.Error = err.Error()
			currentState = StateUnknown
		} else {
			outcome.StateRead.Succeeded = true
		}
		outcome.FromState = currentState

		// Step 2: restore credentials.
		outcome.Credential = StepResult{Attempted: true}
		if err := o.client.RestoreCredentials(ctx, id); err != nil {
			slog.Warn("failed to restore credentials", "agent", id, "error", err)
			outcome.Credential.Error = err.Error()
		} else {
			outcome.Credential.Succeeded = true
		}

		// Step 3: resume GitOps reconciliation. Deliberately after the
		// credential step and before the state label is cleared, and attempted
		// whatever step 2 returned, like every other recovery step.
		var gitops *PlaneResult
		if gp, ok := o.client.(GitOpsPlane); ok {
			pr := gp.ResumeGitOps(ctx, namespace, id)
			if pr.Outcome != OutcomeContained {
				slog.Warn("gitops plane did not fully resume reconciliation", "agent", id, "outcome", pr.Outcome, "error", pr.Error)
			}
			result.Planes = append(result.Planes, withAgentID(pr, id))
			gitops = &pr
		}

		// Step 4: write the running label.
		outcome.StateWrite = StepResult{Attempted: true}
		if err := o.client.SetPodState(ctx, namespace, id, StateRunning); err != nil {
			slog.Warn("failed to set pod state", "agent", id, "error", err)
			outcome.StateWrite.Error = err.Error()
		} else {
			outcome.StateWrite.Succeeded = true
		}

		outcome.ToState = currentState
		if outcome.StateWrite.Succeeded {
			outcome.ToState = StateRunning
		}

		outcome.Outcome = withGitOps(classifyOutcome(outcome.StateRead, outcome.Credential, outcome.StateWrite), gitops)
		result.record(outcome)

		slog.Info("recover attempt complete",
			"agent", id,
			"from", outcome.FromState,
			"to", outcome.ToState,
			"outcome", string(outcome.Outcome))

		// Inter-step delay for visual effect
		if o.stepDelay > 0 {
			select {
			case <-ctx.Done():
				result.finish(start)
				return result, ctx.Err()
			case <-time.After(o.stepDelay):
			}
		}
	}

	result.finish(start)

	return result, nil
}

// withAgentID stamps the target's DAG id on a plane result. fe-signalloom
// attributes planes to targets by details.agent_id and fails closed on
// ambiguity, so every plane a multi-target cascade emits must name its
// target. The details map is copied so a map shared with the client is not
// mutated.
func withAgentID(pr PlaneResult, agentID string) PlaneResult {
	details := make(map[string]any, len(pr.Details)+1)
	for k, v := range pr.Details {
		details[k] = v
	}
	details["agent_id"] = agentID
	pr.Details = details
	return pr
}
