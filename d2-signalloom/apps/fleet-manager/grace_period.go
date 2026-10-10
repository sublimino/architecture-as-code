package main

import (
	"fmt"
	"math"
	"strings"
	"time"
)

// Standard duration constants for grace period evaluation.
const (
	GracePeriodImmediate = 0 * time.Hour   // 0h: immediate containment / enforcement
	GracePeriodShort     = 12 * time.Hour  // 12h: high-throughput ingress / gateway
	GracePeriodStandard  = 24 * time.Hour  // 24h: standard services
	GracePeriodBatch     = 72 * time.Hour  // 72h: batch data processing pipelines
	GracePeriodExtended  = 168 * time.Hour // 168h: low-risk / observability
)

// GracePeriodEvaluator evaluates agent type, riskClass, and dataSensitivity to determine
// differentiated compliance grace periods and drive the agent compliance state machine.
type GracePeriodEvaluator struct {
	DefaultGracePeriod time.Duration
}

// NewGracePeriodEvaluator initializes an evaluator with standard policy defaults.
func NewGracePeriodEvaluator() *GracePeriodEvaluator {
	return &GracePeriodEvaluator{
		DefaultGracePeriod: GracePeriodStandard,
	}
}

// ParseGracePeriod parses a duration string (e.g. "72h", "0h", "24h", "168h", "30m").
// It handles case-insensitivity, leading/trailing whitespace, and rejects negative durations.
func ParseGracePeriod(s string) (time.Duration, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	if s == "" || s == "0" || s == "0h" || s == "0s" || s == "0m" {
		return GracePeriodImmediate, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("invalid grace period duration %q: %w", s, err)
	}
	if d < 0 {
		return 0, fmt.Errorf("grace period duration cannot be negative: %s", d)
	}
	return d, nil
}

// ParseDuration parses a duration string on the evaluator instance.
func (e *GracePeriodEvaluator) ParseDuration(s string) (time.Duration, error) {
	return ParseGracePeriod(s)
}

// ParseGracePeriod parses a duration string on the evaluator instance.
func (e *GracePeriodEvaluator) ParseGracePeriod(s string) (time.Duration, error) {
	return ParseGracePeriod(s)
}

// FormatDuration formats a time.Duration into a clean representation like "72h", "0h", "30m".
func FormatDuration(d time.Duration) string {
	if d <= 0 {
		return "0h"
	}
	hours := d.Hours()
	if hours == math.Trunc(hours) {
		return fmt.Sprintf("%dh", int(hours))
	}
	minutes := d.Minutes()
	if minutes == math.Trunc(minutes) {
		return fmt.Sprintf("%dm", int(minutes))
	}
	return d.String()
}

// CalculateGracePeriod evaluates agent type, riskClass, and dataSensitivity to determine
// the appropriate grace period duration:
//   - Returns 0h (immediate enforcement) for high-risk customer PII workloads (e.g. agent-llm-classifier).
//   - Returns 72h for batch data processing agents (e.g. agent-txn-pipeline with medium risk).
//   - Returns 168h for low-risk observability/monitoring agents.
//   - Returns 24h for medium-risk ingress/standard services.
//   - Returns 0h for critical-risk workloads.
func (e *GracePeriodEvaluator) CalculateGracePeriod(agentType, riskClass, dataSensitivity string) time.Duration {
	aType := strings.ToLower(strings.TrimSpace(agentType))
	risk := strings.ToLower(strings.TrimSpace(riskClass))
	sens := strings.ToLower(strings.TrimSpace(dataSensitivity))

	// 1. Critical risk always requires immediate enforcement
	if risk == "critical" {
		return GracePeriodImmediate
	}

	// Helper detectors
	isCustomerPII := strings.Contains(sens, "pii") ||
		strings.Contains(sens, "customer") ||
		strings.Contains(sens, "pci") ||
		strings.Contains(sens, "cardholder")

	isHighRisk := risk == "high"

	// 2. High-risk customer PII workloads -> 0h (immediate enforcement)
	// (e.g. agent-llm-classifier with high risk and customer PII, or data-vault with PCI/PII scope)
	if isHighRisk && (isCustomerPII || aType == "llm-inference" || strings.Contains(aType, "inference") || aType == "data-vault") {
		return GracePeriodImmediate
	}

	// Any customer PII workload with high risk
	if isHighRisk && isCustomerPII {
		return GracePeriodImmediate
	}

	// 3. Batch data processing agents -> 72h grace period
	// (e.g. agent-txn-pipeline with medium risk)
	isBatch := aType == "data-pipeline" ||
		aType == "batch" ||
		aType == "batch-data-processing" ||
		aType == "data-processing" ||
		aType == "batch-processor" ||
		strings.Contains(aType, "pipeline") ||
		strings.Contains(aType, "batch")

	if isBatch {
		// Medium or low risk batch pipelines get 72h
		if risk == "medium" || risk == "low" || risk == "" {
			return GracePeriodBatch
		}
		// High risk batch pipelines without PII get standard 24h
		if isHighRisk && !isCustomerPII {
			return GracePeriodStandard
		}
	}

	// 4. Observability / Monitoring workloads
	isObservability := aType == "observability" ||
		aType == "monitor" ||
		aType == "logging" ||
		strings.Contains(aType, "observability")

	if isObservability {
		return GracePeriodExtended // 168h
	}

	// 5. Ingress / API Gateway workloads
	isGateway := aType == "api-gateway" ||
		aType == "gateway" ||
		aType == "ingress"

	if isGateway {
		if risk == "low" {
			return GracePeriodExtended
		}
		if risk == "medium" {
			return GracePeriodStandard // 24h
		}
		if isHighRisk {
			return GracePeriodShort // 12h
		}
	}

	// 6. Generic classification by risk class
	switch risk {
	case "low":
		return GracePeriodExtended // 168h
	case "medium":
		return GracePeriodStandard // 24h
	case "high":
		if isCustomerPII {
			return GracePeriodImmediate // 0h
		}
		return GracePeriodShort // 12h
	default:
		if e.DefaultGracePeriod > 0 {
			return e.DefaultGracePeriod
		}
		return GracePeriodStandard
	}
}

// Evaluate is an alias for CalculateGracePeriod.
func (e *GracePeriodEvaluator) Evaluate(agentType, riskClass, dataSensitivity string) time.Duration {
	return e.CalculateGracePeriod(agentType, riskClass, dataSensitivity)
}

// EvaluateGracePeriod is an alias for CalculateGracePeriod.
func (e *GracePeriodEvaluator) EvaluateGracePeriod(agentType, riskClass, dataSensitivity string) time.Duration {
	return e.CalculateGracePeriod(agentType, riskClass, dataSensitivity)
}

// EvaluateAgent calculates the grace period for an AgentProfile.
func (e *GracePeriodEvaluator) EvaluateAgent(agent *AgentProfile) time.Duration {
	if agent == nil {
		return e.DefaultGracePeriod
	}
	return e.CalculateGracePeriod(agent.Type, agent.RiskClass, agent.DataSensitivity)
}

// StateEvaluationResult holds the evaluated lifecycle state, timing, and expiry.
type StateEvaluationResult struct {
	State             string        `json:"state"`
	GracePeriod       time.Duration `json:"gracePeriod"`
	GracePeriodString string        `json:"gracePeriodString"`
	GracePeriodExpiry string        `json:"gracePeriodExpiry,omitempty"`
	ExpiryTime        time.Time     `json:"expiryTime,omitempty"`
	RemainingHours    float64       `json:"remainingHours,omitempty"`
	RemainingDuration time.Duration `json:"remainingDuration,omitempty"`
	IsCompliant       bool          `json:"isCompliant"`
	InGracePeriod     bool          `json:"inGracePeriod"`
	IsExpired         bool          `json:"isExpired"`
}

// EvaluateState executes the compliance state machine for an agent:
//   - Compliant agents -> 'active'
//   - Non-compliant agents within grace period -> 'grace-period'
//   - Non-compliant agents with zero grace period -> 'non-compliant'
//   - Non-compliant agents whose grace period has expired -> 'non-compliant'
func (e *GracePeriodEvaluator) EvaluateState(agent *AgentProfile, compliant bool, detectedAt, now time.Time) StateEvaluationResult {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if detectedAt.IsZero() {
		detectedAt = now
	}

	var agentType, riskClass, dataSensitivity, explicitGrace string
	if agent != nil {
		agentType = agent.Type
		riskClass = agent.RiskClass
		dataSensitivity = agent.DataSensitivity
		explicitGrace = agent.GracePeriod
	}

	gp := e.CalculateGracePeriod(agentType, riskClass, dataSensitivity)

	// If explicitGrace is defined and not overridden by high-risk PII / critical rules
	if explicitGrace != "" && gp != GracePeriodImmediate {
		if parsed, err := ParseGracePeriod(explicitGrace); err == nil && parsed > 0 {
			gp = parsed
		}
	}

	gpStr := FormatDuration(gp)

	if compliant {
		return StateEvaluationResult{
			State:             AgentStateActive,
			GracePeriod:       gp,
			GracePeriodString: gpStr,
			IsCompliant:       true,
			InGracePeriod:     false,
			IsExpired:         false,
			RemainingHours:    0,
			RemainingDuration: 0,
		}
	}

	// Non-compliant agent:
	if gp <= 0 {
		// Non-compliant agents with zero grace period -> 'non-compliant'
		return StateEvaluationResult{
			State:             AgentStateNonCompliant,
			GracePeriod:       0,
			GracePeriodString: "0h",
			GracePeriodExpiry: detectedAt.UTC().Format(time.RFC3339),
			ExpiryTime:        detectedAt.UTC(),
			IsCompliant:       false,
			InGracePeriod:     false,
			IsExpired:         true,
			RemainingHours:    0,
			RemainingDuration: 0,
		}
	}

	expiry := detectedAt.Add(gp).UTC()
	if now.Before(expiry) {
		// Non-compliant agents within grace period -> 'grace-period'
		remainingDuration := expiry.Sub(now)
		remainingHours := remainingDuration.Hours()
		return StateEvaluationResult{
			State:             AgentStateGracePeriod,
			GracePeriod:       gp,
			GracePeriodString: gpStr,
			GracePeriodExpiry: expiry.Format(time.RFC3339),
			ExpiryTime:        expiry,
			RemainingHours:    remainingHours,
			RemainingDuration: remainingDuration,
			IsCompliant:       false,
			InGracePeriod:     true,
			IsExpired:         false,
		}
	}

	// Non-compliant agents with expired grace period -> 'non-compliant'
	return StateEvaluationResult{
		State:             AgentStateNonCompliant,
		GracePeriod:       gp,
		GracePeriodString: gpStr,
		GracePeriodExpiry: expiry.Format(time.RFC3339),
		ExpiryTime:        expiry,
		RemainingHours:    0,
		RemainingDuration: 0,
		IsCompliant:       false,
		InGracePeriod:     false,
		IsExpired:         true,
	}
}

// EvaluateAgentState evaluates state by scalar fields rather than agent struct.
func (e *GracePeriodEvaluator) EvaluateAgentState(agentType, riskClass, dataSensitivity string, compliant bool, detectedAt, now time.Time) StateEvaluationResult {
	profile := &AgentProfile{
		Type:            agentType,
		RiskClass:       riskClass,
		DataSensitivity: dataSensitivity,
	}
	return e.EvaluateState(profile, compliant, detectedAt, now)
}

// DetermineState returns just the string state ('active', 'grace-period', 'non-compliant').
func (e *GracePeriodEvaluator) DetermineState(compliant bool, gracePeriod time.Duration, detectedAt, now time.Time) string {
	profile := &AgentProfile{
		GracePeriod: FormatDuration(gracePeriod),
	}
	res := e.EvaluateState(profile, compliant, detectedAt, now)
	return res.State
}

// ApplyEvaluation updates the agent's State, GracePeriodExpiry, and RemainingHours in place.
func (e *GracePeriodEvaluator) ApplyEvaluation(agent *AgentProfile, compliant bool, detectedAt, now time.Time) StateEvaluationResult {
	res := e.EvaluateState(agent, compliant, detectedAt, now)
	if agent != nil {
		agent.State = res.State
		agent.GracePeriodExpiry = res.GracePeriodExpiry
		agent.RemainingHours = res.RemainingHours
		if agent.GracePeriod == "" {
			agent.GracePeriod = res.GracePeriodString
		}
	}
	return res
}
