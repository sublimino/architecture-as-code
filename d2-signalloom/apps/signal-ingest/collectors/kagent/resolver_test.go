// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package kagent

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.observations = append(m.observations, obs)
	return nil
}

func (m *mockSink) GetObservations() []*model.Observation {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*model.Observation, len(m.observations))
	copy(out, m.observations)
	return out
}

func (m *mockSink) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.observations)
}

// TestResolver_P0CalibratedTrace verifies resolution of the live-calibrated KAgent trace.
func TestResolver_P0CalibratedTrace(t *testing.T) {
	resolver := NewResolver(ResolverConfig{
		TrustDomain: DefaultTrustDomain,
	})

	now := time.Now().UTC()
	span := TelemetrySpan{
		SpanID:         "span-k8s-reader-001",
		TraceID:        "trace-k8s-reader-001",
		Name:           SpanNameToolExecution,
		Timestamp:      now,
		RuntimeVersion: RuntimeVersion0_9_9,
		Attributes: map[string]string{
			AttrAgentNamespace: "fe-signalloom-agents",
			AttrAgentName:      "kagent-k8s-reader",
			AttrAppName:        "fe_signalloom_agents__NS__kagent_k8s_reader",
			AttrToolName:       "k8s_get_resources",
			AttrFunctionCallID: "toolu_01HSGfBFovPGeMjBaUPhGfUj",
			AttrContextID:      "01a0722f-a1c4-7963-890c-37184946daca",
			AttrTaskID:         "01a0722f-a1c4-7874-a9c0-d55a1638c1e5",
			AttrUserID:         "admin@kagent.dev",
			AttrAuthType:       "session_header",
		},
	}

	res, err := resolver.Resolve(span)
	if err != nil {
		t.Fatalf("unexpected error resolving calibrated span: %v", err)
	}

	obs := res.Observation
	if obs == nil {
		t.Fatalf("expected observation to be non-nil")
	}

	// Verify Layer & Identity
	if obs.Layer != model.LayerIdentityAuth {
		t.Errorf("expected layer %s, got %s", model.LayerIdentityAuth, obs.Layer)
	}
	expectedSPIFFE := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader"
	if obs.ActorHint != expectedSPIFFE {
		t.Errorf("expected ActorHint %s, got %s", expectedSPIFFE, obs.ActorHint)
	}
	if obs.ActorID != expectedSPIFFE {
		t.Errorf("expected ActorID %s, got %s", expectedSPIFFE, obs.ActorID)
	}

	// Verify Labels
	if obs.Labels["agent_namespace"] != "fe-signalloom-agents" {
		t.Errorf("unexpected agent_namespace: %s", obs.Labels["agent_namespace"])
	}
	if obs.Labels["agent_name"] != "kagent-k8s-reader" {
		t.Errorf("unexpected agent_name: %s", obs.Labels["agent_name"])
	}
	if obs.Labels["service_account"] != "kagent-k8s-reader" {
		t.Errorf("unexpected service_account: %s", obs.Labels["service_account"])
	}
	if obs.Labels["spiffe_id"] != expectedSPIFFE {
		t.Errorf("unexpected spiffe_id: %s", obs.Labels["spiffe_id"])
	}
	if obs.Labels["tool_name"] != "k8s_get_resources" {
		t.Errorf("unexpected tool_name: %s", obs.Labels["tool_name"])
	}
	if obs.Labels["invoked_action"] != "tool:k8s_get_resources" {
		t.Errorf("unexpected invoked_action: %s", obs.Labels["invoked_action"])
	}
	if obs.Labels["context_id"] != "01a0722f-a1c4-7963-890c-37184946daca" {
		t.Errorf("unexpected context_id: %s", obs.Labels["context_id"])
	}

	// Verify Inferred Delegation Edge
	if res.IsProven {
		t.Errorf("expected inferred delegation, got proven")
	}
	if !res.HasDelegation {
		t.Fatalf("expected delegation edge to be present")
	}
	if res.DelegationEdge == nil {
		t.Fatalf("expected delegation edge struct to be non-nil")
	}
	if res.DelegationEdge.Contribution != "obo:delegation:inferred" {
		t.Errorf("expected contribution obo:delegation:inferred, got %s", res.DelegationEdge.Contribution)
	}
	if obs.Labels["delegation_tag"] != "inferred" {
		t.Errorf("unexpected delegation_tag: %s", obs.Labels["delegation_tag"])
	}
}

// TestResolver_ProvenDelegation verifies that cryptographic/SVID credentials produce a proven delegation edge.
func TestResolver_ProvenDelegation(t *testing.T) {
	resolver := NewResolver(ResolverConfig{
		TrustDomain: DefaultTrustDomain,
	})

	span := TelemetrySpan{
		SpanID:         "span-proven-002",
		Name:           SpanNameToolExecution,
		Timestamp:      time.Now().UTC(),
		RuntimeVersion: RuntimeVersion0_9_9,
		Attributes: map[string]string{
			AttrAgentNamespace: "fe-signalloom-agents",
			AttrAgentName:      "kagent-security-analyst",
			AttrToolName:       "k8s_get_resources",
			AttrContextID:      "ctx-proven-123",
			AttrUserID:         "spiffe://signalloom.demo/ns/agent-trust-platform/sa/lead-orchestrator",
			AttrAuthType:       "spiffe",
		},
	}

	res, err := resolver.Resolve(span)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !res.IsProven {
		t.Errorf("expected proven delegation, got inferred")
	}
	if !res.HasDelegation {
		t.Fatalf("expected delegation edge to be present")
	}
	if res.DelegationEdge.Contribution != "obo:delegation:proven" {
		t.Errorf("expected contribution obo:delegation:proven, got %s", res.DelegationEdge.Contribution)
	}
	if res.DelegationEdge.Fidelity != model.FidelityDefinitive {
		t.Errorf("expected definitive fidelity, got %s", res.DelegationEdge.Fidelity)
	}
	if res.Observation.Labels["delegation_tag"] != "proven" {
		t.Errorf("unexpected delegation_tag: %s", res.Observation.Labels["delegation_tag"])
	}
	if res.Observation.Fidelity != model.FidelityDefinitive {
		t.Errorf("expected definitive observation fidelity, got %s", res.Observation.Fidelity)
	}
}

// TestResolver_AntiSelfDelegationGuard asserts that top-level invocations or self-calls emit NO delegation edge.
func TestResolver_AntiSelfDelegationGuard(t *testing.T) {
	resolver := NewResolver(ResolverConfig{
		TrustDomain: DefaultTrustDomain,
	})

	testCases := []struct {
		name       string
		callerID   string
		expectEdge bool
	}{
		{
			name:       "empty caller (top-level trigger)",
			callerID:   "",
			expectEdge: false,
		},
		{
			name:       "caller identical to agent name",
			callerID:   "kagent-k8s-reader",
			expectEdge: false,
		},
		{
			name:       "caller identical to full spiffe id",
			callerID:   "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader",
			expectEdge: false,
		},
		{
			name:       "caller identical to namespace/name",
			callerID:   "fe-signalloom-agents/kagent-k8s-reader",
			expectEdge: false,
		},
		{
			name:       "distinct human caller",
			callerID:   "alice@example.com",
			expectEdge: true,
		},
		{
			name:       "distinct agent caller",
			callerID:   "spiffe://signalloom.demo/ns/other/sa/other-agent",
			expectEdge: true,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			span := TelemetrySpan{
				SpanID:         "span-guard",
				Name:           SpanNameToolExecution,
				RuntimeVersion: RuntimeVersion0_9_9,
				Attributes: map[string]string{
					AttrAgentNamespace: "fe-signalloom-agents",
					AttrAgentName:      "kagent-k8s-reader",
					AttrToolName:       "k8s_get_resources",
					AttrUserID:         tc.callerID,
				},
			}

			res, err := resolver.Resolve(span)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if tc.expectEdge {
				if !res.HasDelegation || res.DelegationEdge == nil {
					t.Errorf("expected delegation edge for caller %q, got none", tc.callerID)
				}
			} else {
				if res.HasDelegation || res.DelegationEdge != nil {
					t.Errorf("expected NO delegation edge for caller %q, got %+v", tc.callerID, res.DelegationEdge)
				}
				if res.Observation.Labels["delegation_tag"] != "none" {
					t.Errorf("expected delegation_tag 'none', got %q", res.Observation.Labels["delegation_tag"])
				}
			}
		})
	}
}

// TestResolver_UnknownRuntimeVersionFailsLoudly verifies that unknown runtime versions return an explicit error.
func TestResolver_UnknownRuntimeVersionFailsLoudly(t *testing.T) {
	resolver := NewResolver(ResolverConfig{})

	span := TelemetrySpan{
		SpanID:         "span-unknown-version",
		RuntimeVersion: "99.99.99-unsupported",
		Attributes: map[string]string{
			AttrAgentNamespace: "fe-signalloom-agents",
			AttrAgentName:      "kagent-k8s-reader",
		},
	}

	res, err := resolver.Resolve(span)
	if err == nil {
		t.Fatalf("expected error on unknown runtime version, got success with res: %+v", res)
	}

	if !errors.Is(err, ErrUnknownRuntimeVersion) {
		t.Errorf("expected error wrapping ErrUnknownRuntimeVersion, got: %v", err)
	}
}

// TestCollector_LifecycleAndShutdown asserts non-blocking Start, span consumption, and leak-free Stop.
func TestCollector_LifecycleAndShutdown(t *testing.T) {
	sink := &mockSink{}
	col := NewCollector(sink, ResolverConfig{})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := col.Start(ctx); err != nil {
		t.Fatalf("failed to start collector: %v", err)
	}

	if err := col.Health(ctx); err != nil {
		t.Fatalf("expected collector to report healthy: %v", err)
	}

	span := TelemetrySpan{
		SpanID:         "live-test-span-001",
		Name:           SpanNameToolExecution,
		Timestamp:      time.Now().UTC(),
		RuntimeVersion: RuntimeVersion0_9_9,
		Attributes: map[string]string{
			AttrAgentNamespace: "fe-signalloom-agents",
			AttrAgentName:      "kagent-k8s-reader",
			AttrToolName:       "k8s_get_resources",
			AttrContextID:      "ctx-live-001",
			AttrUserID:         "admin@kagent.dev",
		},
	}

	// Feed span asynchronously
	if !col.FeedSpan(span) {
		t.Fatalf("failed to feed span to collector")
	}

	// Also test immediate synchronous ingestion
	if _, err := col.IngestSpan(ctx, span); err != nil {
		t.Fatalf("failed to ingest span synchronously: %v", err)
	}

	// Wait briefly for consumer loop
	time.Sleep(50 * time.Millisecond)

	col.Stop()

	// Stop must be idempotent
	col.Stop()

	if sink.Count() < 1 {
		t.Fatalf("expected at least 1 ingested observation in sink, got %d", sink.Count())
	}
}

// TestCollector_FixtureFunction reproduces calibrated observation deterministically.
func TestCollector_FixtureFunction(t *testing.T) {
	fixtures := CalibratedP0Fixtures(time.Now().UTC())
	if len(fixtures) != 1 {
		t.Fatalf("expected 1 fixture observation, got %d", len(fixtures))
	}

	obs := fixtures[0]
	if obs.Labels["framework"] != "kagent" {
		t.Errorf("unexpected framework label: %s", obs.Labels["framework"])
	}
	if obs.Labels["tool_name"] != "k8s_get_resources" {
		t.Errorf("unexpected tool_name: %s", obs.Labels["tool_name"])
	}
	if obs.ActorHint != "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader" {
		t.Errorf("unexpected ActorHint: %s", obs.ActorHint)
	}
	if obs.Labels["delegation_tag"] != "inferred" {
		t.Errorf("unexpected delegation_tag: %s", obs.Labels["delegation_tag"])
	}
}
