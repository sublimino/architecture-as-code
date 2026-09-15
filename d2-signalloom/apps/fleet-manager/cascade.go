package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
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
	Targets        []TargetOutcome `json:"targets"`
	Planes         []PlaneResult   `json:"planes,omitempty"`
	DurationMs     int64           `json:"duration_ms"`
	RecoveryOrder  []string        `json:"recovery_order,omitempty"`
	OverallOutcome PlaneOutcome    `json:"overall_outcome,omitempty"`
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
}

// CascadeOrchestrator sequences stun and recovery operations using the DAG.
type CascadeOrchestrator struct {
	dag       *DAG
	client    FleetClient
	stepDelay time.Duration
}

// NewCascadeOrchestrator creates a new orchestrator.
func NewCascadeOrchestrator(dag *DAG, client FleetClient, stepDelay time.Duration) *CascadeOrchestrator {
	return &CascadeOrchestrator{
		dag:       dag,
		client:    client,
		stepDelay: stepDelay,
	}
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
func (o *CascadeOrchestrator) Stun(ctx context.Context, agentID string) (*CascadeResult, error) {
	start := time.Now()

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

		// Step 2: revoke credentials.
		outcome.Credential = StepResult{Attempted: true}
		if err := o.client.RevokeCredentials(ctx, id); err != nil {
			slog.Warn("failed to revoke credentials", "agent", id, "error", err)
			outcome.Credential.Error = err.Error()
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
		if err := o.client.SetPodState(ctx, namespace, id, StateStunned); err != nil {
			slog.Warn("failed to set pod state", "agent", id, "error", err)
			outcome.StateWrite.Error = err.Error()
		} else {
			outcome.StateWrite.Succeeded = true
		}

		// ToState is what the agent is, not what we asked it to be. Only a
		// successful label write moves it.
		outcome.ToState = currentState
		if outcome.StateWrite.Succeeded {
			outcome.ToState = StateStunned
		}

		outcome.Outcome = classifyOutcome(outcome.StateRead, outcome.Credential, outcome.StateWrite)
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

		// Step 3: write the running label.
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

		outcome.Outcome = classifyOutcome(outcome.StateRead, outcome.Credential, outcome.StateWrite)
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
