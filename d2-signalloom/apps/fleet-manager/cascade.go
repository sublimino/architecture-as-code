package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// AgentState constants used as pod label values.
const (
	StateRunning = "running"
	StateStunned = "stunned"
)

// StateChangeEvent records a single agent state transition during a cascade.
type StateChangeEvent struct {
	AgentID   string `json:"agent_id"`
	FromState string `json:"from_state"`
	ToState   string `json:"to_state"`
	Timestamp string `json:"timestamp"`
}

// CascadeResult is the response payload for a stun or recover operation.
type CascadeResult struct {
	TargetAgent    string             `json:"target_agent"`
	AffectedAgents []string           `json:"affected_agents"`
	Events         []StateChangeEvent `json:"events"`
	DurationMs     int64              `json:"duration_ms"`
	RecoveryOrder  []string           `json:"recovery_order,omitempty"`
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

// Stun executes a cascade stun operation starting from the target agent.
func (o *CascadeOrchestrator) Stun(ctx context.Context, agentID string) (*CascadeResult, error) {
	start := time.Now()

	targets, err := o.dag.CascadeTargets(agentID)
	if err != nil {
		return nil, fmt.Errorf("cascade targets: %w", err)
	}

	result := &CascadeResult{
		TargetAgent:    agentID,
		AffectedAgents: targets,
		Events:         make([]StateChangeEvent, 0, len(targets)),
	}

	for _, id := range targets {
		agent := o.dag.GetAgent(id)
		if agent == nil {
			continue
		}

		// Read current state
		currentState, err := o.client.GetPodState(ctx, agent.Namespace, id)
		if err != nil {
			slog.Warn("failed to read pod state", "agent", id, "error", err)
			currentState = StateRunning // assume running if we can't read
		}

		// Revoke credentials
		if err := o.client.RevokeCredentials(ctx, id); err != nil {
			slog.Warn("failed to revoke credentials", "agent", id, "error", err)
		}

		// Update pod label to stunned
		if err := o.client.SetPodState(ctx, agent.Namespace, id, StateStunned); err != nil {
			slog.Warn("failed to set pod state", "agent", id, "error", err)
		}

		result.Events = append(result.Events, StateChangeEvent{
			AgentID:   id,
			FromState: currentState,
			ToState:   StateStunned,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})

		slog.Info("agent stunned", "agent", id, "from", currentState)

		// Inter-step delay for visual effect
		if o.stepDelay > 0 {
			select {
			case <-ctx.Done():
				return result, ctx.Err()
			case <-time.After(o.stepDelay):
			}
		}
	}

	// Include recovery order in result for UI consumption
	result.RecoveryOrder = o.dag.RecoveryOrder(targets)
	result.DurationMs = time.Since(start).Milliseconds()

	return result, nil
}

// Recover executes a recovery operation in topological order.
func (o *CascadeOrchestrator) Recover(ctx context.Context, stunnedIDs []string) (*CascadeResult, error) {
	start := time.Now()

	recoveryOrder := o.dag.RecoveryOrder(stunnedIDs)

	result := &CascadeResult{
		TargetAgent:    "fleet-recovery",
		AffectedAgents: recoveryOrder,
		RecoveryOrder:  recoveryOrder,
		Events:         make([]StateChangeEvent, 0, len(recoveryOrder)),
	}

	for _, id := range recoveryOrder {
		agent := o.dag.GetAgent(id)
		if agent == nil {
			continue
		}

		// Restore credentials
		if err := o.client.RestoreCredentials(ctx, id); err != nil {
			slog.Warn("failed to restore credentials", "agent", id, "error", err)
		}

		// Update pod label to running
		if err := o.client.SetPodState(ctx, agent.Namespace, id, StateRunning); err != nil {
			slog.Warn("failed to set pod state", "agent", id, "error", err)
		}

		result.Events = append(result.Events, StateChangeEvent{
			AgentID:   id,
			FromState: StateStunned,
			ToState:   StateRunning,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		})

		slog.Info("agent recovered", "agent", id)

		// Inter-step delay for visual effect
		if o.stepDelay > 0 {
			select {
			case <-ctx.Done():
				return result, ctx.Err()
			case <-time.After(o.stepDelay):
			}
		}
	}

	result.DurationMs = time.Since(start).Milliseconds()

	return result, nil
}
