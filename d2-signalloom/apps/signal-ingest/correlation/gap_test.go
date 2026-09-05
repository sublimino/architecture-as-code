// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func TestTelemetryGapEvaluator_NoGaps(t *testing.T) {
	evaluator := NewTelemetryGapEvaluator(5 * time.Minute)

	obs := []model.Observation{
		{
			ID:        "obs-1",
			Timestamp: time.Now().UTC(),
			Layer:     model.LayerNetworkEgress,
			Fidelity:  model.FidelityStrong,
			Labels: map[string]string{
				"provider": "OpenAI",
			},
		},
	}

	res := evaluator.Evaluate(obs, time.Now().UTC())
	if res.HasActiveGap {
		t.Errorf("Expected HasActiveGap false, got true")
	}
	if !res.CleanAssertionValid {
		t.Errorf("Expected CleanAssertionValid true when no gaps exist")
	}
	if res.GapCount != 0 {
		t.Errorf("Expected 0 gaps, got %d", res.GapCount)
	}
}

func TestTelemetryGapEvaluator_ActiveGapInvalidatesCleanClaim(t *testing.T) {
	evaluator := NewTelemetryGapEvaluator(5 * time.Minute)
	now := time.Now().UTC()

	obs := []model.Observation{
		{
			ID:        "gap-1",
			Timestamp: now.Add(-2 * time.Minute),
			Layer:     model.LayerNetworkEgress,
			Fidelity:  model.FidelitySuggestive,
			Labels: map[string]string{
				"type":          "telemetry_gap",
				"dropped_count": "50",
				"reason":        "ringbuf_full_burst_drop",
			},
		},
		{
			ID:        "normal-obs",
			Timestamp: now,
			Layer:     model.LayerNetworkEgress,
			Fidelity:  model.FidelityStrong,
		},
	}

	res := evaluator.Evaluate(obs, now)
	if !res.HasActiveGap {
		t.Fatalf("Expected HasActiveGap true, got false")
	}
	if res.CleanAssertionValid {
		t.Errorf("Fail-closed invariant violation: CleanAssertionValid must be FALSE during active gap")
	}
	if res.GapCount != 1 {
		t.Errorf("Expected GapCount 1, got %d", res.GapCount)
	}
	if res.TotalDroppedEvents != 50 {
		t.Errorf("Expected TotalDroppedEvents 50, got %d", res.TotalDroppedEvents)
	}
	if res.DegradationReason != "ringbuf_full_burst_drop" {
		t.Errorf("Expected reason ringbuf_full_burst_drop, got %s", res.DegradationReason)
	}
}

func TestTelemetryGapEvaluator_OldGapIgnoredAfterWindow(t *testing.T) {
	evaluator := NewTelemetryGapEvaluator(5 * time.Minute)
	now := time.Now().UTC()

	obs := []model.Observation{
		{
			ID:        "old-gap",
			Timestamp: now.Add(-10 * time.Minute), // 10 mins ago, window is 5 mins
			Layer:     model.LayerNetworkEgress,
			Fidelity:  model.FidelitySuggestive,
			Labels: map[string]string{
				"type":          "telemetry_gap",
				"dropped_count": "10",
			},
		},
	}

	res := evaluator.Evaluate(obs, now)
	if res.HasActiveGap {
		t.Errorf("Old gap beyond lookback window should not be marked active")
	}
	if !res.CleanAssertionValid {
		t.Errorf("Clean assertion should be valid when gap is outside the window")
	}
}

func TestSymmetricNetworkEgressCELRules(t *testing.T) {
	rules := DefaultRules()
	var netRules []Rule
	for _, r := range rules {
		if r.Name == "net_ebpf_unauthorized_model_provider_egress" ||
			r.Name == "net_ebpf_c2_exfiltration_burst" ||
			r.Name == "net_ebpf_cross_layer_audit_correlation" ||
			r.Name == "net_ebpf_saas_shadow_agent" {
			netRules = append(netRules, r)
		}
	}

	if len(netRules) != 4 {
		t.Fatalf("Expected 4 network egress rules, got %d", len(netRules))
	}

	now := time.Now().UTC()
	egressObs := model.Observation{
		ID:        "obs-egress",
		Timestamp: now,
		Layer:     model.LayerNetworkEgress,
		Fidelity:  model.FidelityStrong,
		ActorHint: "agent-cardvault-sa",
		Labels: map[string]string{
			"provider": "OpenAI",
		},
	}
	authObs := model.Observation{
		ID:        "obs-auth",
		Timestamp: now.Add(30 * time.Second),
		Layer:     model.LayerIdentityAuth,
		Fidelity:  model.FidelitySuggestive,
		ActorHint: "agent-cardvault-sa",
	}

	// Test forward store
	s1 := store.NewMemoryStore()
	_ = s1.Append(context.Background(), []model.Observation{egressObs, authObs})
	e1, err := NewEngine(s1)
	if err != nil {
		t.Fatalf("Engine init error: %v", err)
	}
	actors1, err := e1.Correlate(context.Background())
	if err != nil {
		t.Fatalf("Correlate forward failed: %v", err)
	}
	if len(actors1) != 2 {
		t.Fatalf("Expected 2 forward actors for weak-only match, got %d", len(actors1))
	}

	// Test reverse store — symmetric rule guarantee
	s2 := store.NewMemoryStore()
	_ = s2.Append(context.Background(), []model.Observation{authObs, egressObs})
	e2, err := NewEngine(s2)
	if err != nil {
		t.Fatalf("Engine init error: %v", err)
	}
	actors2, err := e2.Correlate(context.Background())
	if err != nil {
		t.Fatalf("Correlate reverse failed: %v", err)
	}
	if len(actors2) != 2 {
		t.Fatalf("Expected 2 reverse actors for weak-only match, got %d", len(actors2))
	}
}
