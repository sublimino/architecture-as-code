package main

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// ConditionType represents the operational trigger condition for automated policies.
type ConditionType string

const (
	ConditionRiskThreshold     ConditionType = "RiskThreshold"
	ConditionComplianceFailure  ConditionType = "ComplianceFailure"
	ConditionGracePeriodExpiry  ConditionType = "GracePeriodExpiry"
)

// ActionType represents the action executed upon policy trigger.
type ActionType string

const (
	ActionCascadeStun ActionType = "CascadeStun"
	ActionStunTarget  ActionType = "StunTarget"
	ActionAlert       ActionType = "Alert"
)

// ResponsePolicy defines an automated containment rule.
type ResponsePolicy struct {
	ID            string        `json:"id"`
	Name          string        `json:"name"`
	Description   string        `json:"description"`
	Enabled       bool          `json:"enabled"`
	ConditionType ConditionType `json:"condition_type"`
	Operator      string        `json:"operator"` // ">", ">=", "==", "<="
	Threshold     float64       `json:"threshold"`
	TargetAgentID string        `json:"target_agent_id"`
	Action        ActionType    `json:"action"`
}

// AgentEvaluationProfile provides agent compliance and grace period state.
type AgentEvaluationProfile struct {
	ID               string  `json:"id"`
	State            string  `json:"state"`
	ComplianceStatus string  `json:"compliance_status"` // "compliant" or "non-compliant"
	RemainingHours   float64 `json:"remaining_hours"`
}

// PolicyEvaluationInput provides fleet posture data for policy evaluation.
type PolicyEvaluationInput struct {
	CarriedGBP float64                           `json:"carried_gbp"`
	Agents     map[string]AgentEvaluationProfile `json:"agents,omitempty"`
	DryRun     bool                              `json:"dry_run"`
}

// PolicyActionResult records the outcome of an evaluated policy.
type PolicyActionResult struct {
	PolicyID      string         `json:"policy_id"`
	PolicyName    string         `json:"policy_name"`
	Action        ActionType     `json:"action"`
	TargetAgentID string         `json:"target_agent_id"`
	Triggered     bool           `json:"triggered"`
	Reason        string         `json:"reason"`
	CascadeResult *CascadeResult `json:"cascade_result,omitempty"`
	Error         string         `json:"error,omitempty"`
}

// PolicyEvaluationResult summarizes the complete evaluation cycle.
type PolicyEvaluationResult struct {
	EvaluatedAt     time.Time            `json:"evaluated_at"`
	DryRun          bool                 `json:"dry_run"`
	Triggered       bool                 `json:"triggered"`
	PoliciesChecked int                  `json:"policies_checked"`
	Actions         []PolicyActionResult `json:"actions"`
}

// PolicyEngine coordinates automated response policies and autonomous containment.
type PolicyEngine struct {
	mu           sync.RWMutex
	policies     []ResponsePolicy
	orchestrator *CascadeOrchestrator
	dag          *DAG
}

// DefaultPolicies returns canonical baseline policies for enterprise agent governance.
func DefaultPolicies() []ResponsePolicy {
	return []ResponsePolicy{
		{
			ID:            "pol-risk-500k",
			Name:          "High-Risk Carried GBP Auto-Containment",
			Description:   "Trigger cascading stun on root cardvault when fleet Carried GBP exceeds £500,000 threshold.",
			Enabled:       true,
			ConditionType: ConditionRiskThreshold,
			Operator:      ">",
			Threshold:     500000.0,
			TargetAgentID: "cardvault",
			Action:        ActionCascadeStun,
		},
		{
			ID:            "pol-pii-compliance",
			Name:          "Critical PII Zero-Grace Compliance Containment",
			Description:   "Trigger cascading stun on agent-llm-classifier upon compliance failure with zero grace period.",
			Enabled:       true,
			ConditionType: ConditionComplianceFailure,
			Operator:      "==",
			Threshold:     0.0,
			TargetAgentID: "agent-llm-classifier",
			Action:        ActionCascadeStun,
		},
		{
			ID:            "pol-grace-expiry",
			Name:          "Grace Period Expiry Containment",
			Description:   "Trigger stun when non-compliant agent grace period remaining hours reach zero.",
			Enabled:       true,
			ConditionType: ConditionGracePeriodExpiry,
			Operator:      "<=",
			Threshold:     0.0,
			TargetAgentID: "agent-txn-pipeline",
			Action:        ActionCascadeStun,
		},
	}
}

// NewPolicyEngine creates an initialized policy engine.
func NewPolicyEngine(dag *DAG, orchestrator *CascadeOrchestrator, initialPolicies []ResponsePolicy) *PolicyEngine {
	if len(initialPolicies) == 0 {
		initialPolicies = DefaultPolicies()
	}
	return &PolicyEngine{
		policies:     initialPolicies,
		orchestrator: orchestrator,
		dag:          dag,
	}
}

// Policies returns a thread-safe copy of all active policies.
func (pe *PolicyEngine) Policies() []ResponsePolicy {
	pe.mu.RLock()
	defer pe.mu.RUnlock()
	res := make([]ResponsePolicy, len(pe.policies))
	copy(res, pe.policies)
	return res
}

// SetPolicies updates the active policies.
func (pe *PolicyEngine) SetPolicies(policies []ResponsePolicy) {
	pe.mu.Lock()
	defer pe.mu.Unlock()
	pe.policies = make([]ResponsePolicy, len(policies))
	copy(pe.policies, policies)
}

// Evaluate evaluates all enabled policies against the provided input.
func (pe *PolicyEngine) Evaluate(ctx context.Context, input PolicyEvaluationInput) (*PolicyEvaluationResult, error) {
	pe.mu.RLock()
	policies := make([]ResponsePolicy, len(pe.policies))
	copy(policies, pe.policies)
	pe.mu.RUnlock()

	result := &PolicyEvaluationResult{
		EvaluatedAt:     time.Now().UTC(),
		DryRun:          input.DryRun,
		PoliciesChecked: len(policies),
		Actions:         make([]PolicyActionResult, 0),
	}

	for _, policy := range policies {
		if !policy.Enabled {
			continue
		}

		matched, reason := pe.matchesPolicy(policy, input)
		if !matched {
			continue
		}

		// Target agent debounce: check if target agent is already stunned
		alreadyStunned := false
		if profile, ok := input.Agents[policy.TargetAgentID]; ok {
			if profile.State == StateStunned {
				alreadyStunned = true
			}
		}
		if !alreadyStunned && pe.orchestrator != nil && pe.orchestrator.client != nil {
			ns := "default"
			if pe.dag != nil {
				pe.dag.mu.RLock()
				if a, ok := pe.dag.agents[policy.TargetAgentID]; ok && a.Namespace != "" {
					ns = a.Namespace
				}
				pe.dag.mu.RUnlock()
			}
			if st, err := pe.orchestrator.client.GetPodState(ctx, ns, policy.TargetAgentID); err == nil && st == StateStunned {
				alreadyStunned = true
			}
		}

		if alreadyStunned {
			result.Actions = append(result.Actions, PolicyActionResult{
				PolicyID:      policy.ID,
				PolicyName:    policy.Name,
				Action:        policy.Action,
				TargetAgentID: policy.TargetAgentID,
				Triggered:     false,
				Reason:        fmt.Sprintf("target %q already in stunned state (debounced)", policy.TargetAgentID),
			})
			continue
		}

		result.Triggered = true
		actionRes := PolicyActionResult{
			PolicyID:      policy.ID,
			PolicyName:    policy.Name,
			Action:        policy.Action,
			TargetAgentID: policy.TargetAgentID,
			Triggered:     true,
			Reason:        reason,
		}

		if input.DryRun {
			actionRes.Reason = fmt.Sprintf("%s (dry-run: simulation only)", reason)
			result.Actions = append(result.Actions, actionRes)
			continue
		}

		// Active execution
		if policy.Action == ActionCascadeStun || policy.Action == ActionStunTarget {
			if pe.orchestrator != nil {
				cascadeRes, err := pe.orchestrator.Stun(ctx, policy.TargetAgentID, reason)
				if err != nil {
					slog.Error("automated policy execution failed", "policy", policy.ID, "target", policy.TargetAgentID, "error", err)
					actionRes.Error = err.Error()
				} else {
					actionRes.CascadeResult = cascadeRes
				}
			} else {
				actionRes.Error = "orchestrator unavailable"
			}
		}

		result.Actions = append(result.Actions, actionRes)
	}

	return result, nil
}

func (pe *PolicyEngine) matchesPolicy(p ResponsePolicy, input PolicyEvaluationInput) (bool, string) {
	switch p.ConditionType {
	case ConditionRiskThreshold:
		switch p.Operator {
		case ">":
			if input.CarriedGBP > p.Threshold {
				return true, fmt.Sprintf("Carried GBP £%.2f exceeds threshold £%.2f", input.CarriedGBP, p.Threshold)
			}
		case ">=":
			if input.CarriedGBP >= p.Threshold {
				return true, fmt.Sprintf("Carried GBP £%.2f meets or exceeds threshold £%.2f", input.CarriedGBP, p.Threshold)
			}
		case "<=":
			if input.CarriedGBP <= p.Threshold {
				return true, fmt.Sprintf("Carried GBP £%.2f falls at or below threshold £%.2f", input.CarriedGBP, p.Threshold)
			}
		}

	case ConditionComplianceFailure:
		if agent, ok := input.Agents[p.TargetAgentID]; ok {
			if agent.ComplianceStatus == "non-compliant" && agent.RemainingHours <= p.Threshold {
				return true, fmt.Sprintf("Agent %q has compliance failure with %.1fh remaining grace period (threshold: %.1fh)", p.TargetAgentID, agent.RemainingHours, p.Threshold)
			}
		}

	case ConditionGracePeriodExpiry:
		if agent, ok := input.Agents[p.TargetAgentID]; ok {
			if agent.RemainingHours <= p.Threshold && agent.ComplianceStatus == "non-compliant" {
				return true, fmt.Sprintf("Agent %q grace period expired (%.1fh <= %.1fh)", p.TargetAgentID, agent.RemainingHours, p.Threshold)
			}
		}
	}

	return false, ""
}
