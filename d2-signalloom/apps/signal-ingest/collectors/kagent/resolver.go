// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package kagent

import (
	"fmt"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TelemetrySpan represents an OpenTelemetry span or A2A protocol event received from Kagent runtime.
type TelemetrySpan struct {
	SpanID         string            `json:"span_id"`
	TraceID        string            `json:"trace_id"`
	ParentSpanID   string            `json:"parent_span_id,omitempty"`
	Name           string            `json:"name"`
	Timestamp      time.Time         `json:"timestamp"`
	Attributes     map[string]string `json:"attributes"`
	RuntimeVersion string            `json:"runtime_version,omitempty"`
}

// ResolverConfig contains options for configuring a KAgent ToolLogResolver.
type ResolverConfig struct {
	TrustDomain      string
	AdapterRegistry  *AdapterRegistry
}

// Resolver resolves Kagent telemetry spans into LayerIdentityAuth observations and delegation edges.
type Resolver struct {
	trustDomain string
	registry    *AdapterRegistry
}

// NewResolver instantiates a Resolver with the given configuration.
func NewResolver(cfg ResolverConfig) *Resolver {
	td := cfg.TrustDomain
	if td == "" {
		td = DefaultTrustDomain
	}
	reg := cfg.AdapterRegistry
	if reg == nil {
		reg = DefaultAdapterRegistry()
	}
	return &Resolver{
		trustDomain: td,
		registry:    reg,
	}
}

// ResolutionResult contains the resolved model.Observation and optional OBO delegation EvidenceLink.
type ResolutionResult struct {
	Observation    *model.Observation
	DelegationEdge *model.EvidenceLink
	IsProven       bool
	HasDelegation  bool
}

// Resolve processes an incoming TelemetrySpan, derives agent SPIFFE identity, extracts tool name,
// tags inferred vs proven delegation, and returns the observation and delegation edge.
func (r *Resolver) Resolve(span TelemetrySpan) (*ResolutionResult, error) {
	// Look up the versioned adapter
	adapter, err := r.registry.Get(span.RuntimeVersion)
	if err != nil {
		return nil, fmt.Errorf("failed to select runtime adapter: %w", err)
	}

	attrs := span.Attributes
	if attrs == nil {
		attrs = make(map[string]string)
	}

	// 1. Extract agent identity
	namespace, agentName, ok := adapter.ExtractAgent(attrs)
	if !ok {
		return nil, fmt.Errorf("unable to resolve agent identity from telemetry attributes")
	}

	// 2. Derive ServiceAccount and SPIFFE identity
	sa := attrs["service_account"]
	if sa == "" {
		sa = agentName
	}
	spiffeID := fmt.Sprintf("spiffe://%s/ns/%s/sa/%s", r.trustDomain, namespace, sa)

	// 3. Extract tool name & action
	toolName, hasTool := adapter.ExtractTool(attrs)
	if !hasTool || toolName == "" {
		if span.Name == SpanNameToolExecution || span.Name == SpanNameToolAlt {
			toolName = "unknown_tool"
		} else {
			toolName = "task_execution"
		}
	}
	invokedAction := fmt.Sprintf("tool:%s", toolName)

	// 4. Extract A2A protocol context
	contextID, taskID, callerID, authType := adapter.ExtractContext(attrs)

	ts := span.Timestamp
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	spanID := span.SpanID
	if spanID == "" {
		spanID = fmt.Sprintf("span-%d", ts.UnixNano())
	}

	obsID := fmt.Sprintf("kagent-obs-%s", spanID)

	// 5. Evaluate Inferred vs Proven Delegation Edge
	var delegationEdge *model.EvidenceLink
	var delegationTag string
	isProven := false
	hasDelegation := false

	// Check if a distinct caller is present (prevent spurious self-delegation)
	if isDistinctCaller(callerID, spiffeID, agentName, namespace) {
		hasDelegation = true
		// Proven delegation requires verifiable SPIFFE SVID or cryptographic credential
		if strings.EqualFold(authType, "spiffe") || strings.EqualFold(authType, "svid") || strings.HasPrefix(callerID, "spiffe://") {
			isProven = true
			delegationTag = "proven"
			delegationEdge = &model.EvidenceLink{
				ObservationID: obsID,
				Layer:         model.LayerIdentityAuth,
				Fidelity:      model.FidelityDefinitive,
				Contribution:  "obo:delegation:proven",
				Timestamp:     ts,
			}
		} else {
			// Inferred delegation derived from correlation context (e.g. user_id/session correlation)
			isProven = false
			delegationTag = "inferred"
			delegationEdge = &model.EvidenceLink{
				ObservationID: obsID,
				Layer:         model.LayerIdentityAuth,
				Fidelity:      model.FidelityStrong,
				Contribution:  "obo:delegation:inferred",
				Timestamp:     ts,
			}
		}
	} else {
		delegationTag = "none"
	}

	// 6. Build model.Observation
	fidelity := model.FidelityStrong
	confidence := 0.85
	if isProven {
		fidelity = model.FidelityDefinitive
		confidence = 1.0
	}

	labels := map[string]string{
		"framework":        "kagent",
		"runtime_version":  adapter.Version(),
		"agent_namespace":  namespace,
		"agent_name":       agentName,
		"service_account":  sa,
		"spiffe_id":        spiffeID,
		"tool_name":        toolName,
		"invoked_action":   invokedAction,
	}

	if contextID != "" {
		labels["context_id"] = contextID
	}
	if taskID != "" {
		labels["task_id"] = taskID
	}
	if callerID != "" {
		labels["caller_id"] = callerID
	}
	if delegationTag != "" {
		labels["delegation_tag"] = delegationTag
	}
	if span.TraceID != "" {
		labels["trace_id"] = span.TraceID
	}

	obs := &model.Observation{
		ID:             obsID,
		Timestamp:      ts,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       fidelity,
		Source:         "kagent.telemetry",
		Confidence:     confidence,
		ActorHint:      spiffeID,
		ActorID:        spiffeID,
		PrincipalID:    callerID,
		SessionID:      contextID,
		RawEvidenceRef: fmt.Sprintf("otel://kagent/%s/%s/span/%s", namespace, agentName, spanID),
		Labels:         labels,
		Description:    fmt.Sprintf("Kagent agent %s invoked action %s in namespace %s (context: %s)", agentName, invokedAction, namespace, contextID),
	}

	if hasDelegation {
		obs.ImpersonatedUser = callerID
		obs.DelegationDepth = 1
	}

	if err := obs.Validate(); err != nil {
		return nil, fmt.Errorf("generated observation validation failed: %w", err)
	}

	return &ResolutionResult{
		Observation:    obs,
		DelegationEdge: delegationEdge,
		IsProven:       isProven,
		HasDelegation:  hasDelegation,
	}, nil
}

func isDistinctCaller(callerID, spiffeID, agentName, namespace string) bool {
	if callerID == "" {
		return false
	}
	if callerID == spiffeID {
		return false
	}
	if callerID == agentName {
		return false
	}
	if callerID == fmt.Sprintf("%s/%s", namespace, agentName) {
		return false
	}
	return true
}
