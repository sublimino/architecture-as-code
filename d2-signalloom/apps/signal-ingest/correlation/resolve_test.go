// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestResolve_SingleObservation tests resolution of individual observations to canonical provisional actors.
func TestResolve_SingleObservation(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	t.Run("with_actor_hint", func(t *testing.T) {
		obs := model.Observation{
			ID:         "obs-1",
			Timestamp:  now,
			Layer:      model.LayerIdentityAuth,
			Fidelity:   model.FidelityStrong,
			Source:     "openbao-audit",
			ActorHint:  "spiffe://cluster.local/ns/prod/sa/payment-agent",
			Confidence: 0.8,
		}
		actor, err := Resolve(obs)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		wantID := "actor-spiffe://cluster.local/ns/prod/sa/payment-agent"
		if actor.ID != wantID {
			t.Errorf("actor.ID = %q, want %q", actor.ID, wantID)
		}
		if actor.CanonicalID != wantID {
			t.Errorf("actor.CanonicalID = %q, want %q", actor.CanonicalID, wantID)
		}
		if actor.PrincipalID != obs.ActorHint {
			t.Errorf("actor.PrincipalID = %q, want %q", actor.PrincipalID, obs.ActorHint)
		}
		if len(actor.EvidenceChain) != 1 || actor.EvidenceChain[0].ObservationID != "obs-1" {
			t.Errorf("unexpected evidence chain: %+v", actor.EvidenceChain)
		}
		if actor.Status != model.ActorActionable {
			t.Errorf("actor.Status = %v, want actionable for strong fidelity", actor.Status)
		}
	})

	t.Run("with_principal_id", func(t *testing.T) {
		obs := model.Observation{
			ID:          "obs-2",
			Timestamp:   now,
			Layer:       model.LayerCloudControlPlane,
			Fidelity:    model.FidelityDefinitive,
			Source:      "gcp-audit",
			PrincipalID: "agent-runner@project.iam.gserviceaccount.com",
			Confidence:  1.0,
		}
		actor, err := Resolve(obs)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		wantID := "actor-agent-runner@project.iam.gserviceaccount.com"
		if actor.ID != wantID {
			t.Errorf("actor.ID = %q, want %q", actor.ID, wantID)
		}
	})

	t.Run("with_source_only", func(t *testing.T) {
		obs := model.Observation{
			ID:         "obs-3",
			Timestamp:  now,
			Layer:      model.LayerNetworkEgress,
			Fidelity:   model.FidelitySuggestive,
			Source:     "sentinel-ebpf",
			Confidence: 0.4,
		}
		actor, err := Resolve(obs)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		wantID := "actor-src-sentinel-ebpf"
		if actor.ID != wantID {
			t.Errorf("actor.ID = %q, want %q", actor.ID, wantID)
		}
	})

	t.Run("with_id_only", func(t *testing.T) {
		obs := model.Observation{
			ID:         "obs-4",
			Timestamp:  now,
			Layer:      model.LayerBehavioural,
			Fidelity:   model.FidelityCircumstantial,
			Confidence: 0.2,
		}
		actor, err := Resolve(obs)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		wantID := "actor-obs-obs-4"
		if actor.ID != wantID {
			t.Errorf("actor.ID = %q, want %q", actor.ID, wantID)
		}
	})
}

// TestResolve_Unresolved verifies that observations without any resolvable identity surface typed errors.
func TestResolve_Unresolved(t *testing.T) {
	emptyObs := model.Observation{}
	actor, err := Resolve(emptyObs)
	if !errors.Is(err, ErrUnresolvableObservation) {
		t.Fatalf("expected ErrUnresolvableObservation, got actor=%v, err=%v", actor, err)
	}
}

// TestResolve_Determinism verifies that Resolve is pure and returns identical results across repeated runs.
func TestResolve_Determinism(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	obs := model.Observation{
		ID:         "det-1",
		Timestamp:  now,
		Layer:      model.LayerIdentityAuth,
		Fidelity:   model.FidelityStrong,
		Source:     "bao-audit",
		ActorHint:  "spiffe://cluster.local/ns/default/sa/bot",
		Confidence: 0.8,
	}

	actor1, err1 := Resolve(obs)
	if err1 != nil {
		t.Fatal(err1)
	}
	actor2, err2 := Resolve(obs)
	if err2 != nil {
		t.Fatal(err2)
	}

	if !reflect.DeepEqual(actor1, actor2) {
		t.Fatalf("determinism violation: actor1=%+v != actor2=%+v", actor1, actor2)
	}
}

// TestResolve_DiscriminatorTableSuite models discrete match/no-match cases and enforces false-merge == 0.
func TestResolve_DiscriminatorTableSuite(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		name           string
		obsA           model.Observation
		obsB           model.Observation
		rule           Rule
		groundTruthA   string
		groundTruthB   string
		expectMerge    bool
		wantActorID    string
		expectErr      error
	}{
		{
			name: "same_principal_concordant_spiffe",
			obsA: model.Observation{
				ID: "alice-id", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelityStrong,
				Source: "bao-audit", ActorHint: "spiffe://test/alice",
			},
			obsB: model.Observation{
				ID: "alice-net", Timestamp: now.Add(time.Second), Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive,
				Source: "sentinel", ActorHint: "spiffe://test/alice",
			},
			rule:         Rule{Name: "cross_layer_identity"},
			groundTruthA: "alice",
			groundTruthB: "alice",
			expectMerge:  true,
			wantActorID:  "actor-spiffe://test/alice",
		},
		{
			name: "distinct_principals_shared_source_timing_overlap_refused",
			obsA: model.Observation{
				ID: "alice-id", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive,
				Source: "shared-egress", ActorHint: "spiffe://test/alice",
			},
			obsB: model.Observation{
				ID: "bob-net", Timestamp: now.Add(10 * time.Second), Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive,
				Source: "shared-egress", ActorHint: "spiffe://test/bob",
			},
			rule:         Rule{Name: "timing_correlation"},
			groundTruthA: "alice",
			groundTruthB: "bob",
			expectMerge:  false,
			expectErr:    ErrContradictoryPrincipals,
		},
		{
			name: "distinct_principals_separate_source_refused",
			obsA: model.Observation{
				ID: "alice-id", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive,
				Source: "egress-1", ActorHint: "spiffe://test/alice",
			},
			obsB: model.Observation{
				ID: "bob-net", Timestamp: now.Add(10 * time.Second), Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive,
				Source: "egress-2", ActorHint: "spiffe://test/bob",
			},
			rule:         Rule{Name: "cross_layer_identity"},
			groundTruthA: "alice",
			groundTruthB: "bob",
			expectMerge:  false,
			expectErr:    ErrContradictoryPrincipals,
		},
		{
			name: "anonymous_observations_shared_source_timing_merge",
			obsA: model.Observation{
				ID: "anon-net", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive,
				Source: "gateway-proxy", ActorHint: "",
			},
			obsB: model.Observation{
				ID: "anon-beh", Timestamp: now.Add(2 * time.Minute), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive,
				Source: "gateway-proxy", ActorHint: "",
			},
			rule:         Rule{Name: "timing_correlation"},
			groundTruthA: "anon-gateway",
			groundTruthB: "anon-gateway",
			expectMerge:  true,
			wantActorID:  "actor-src-gateway-proxy",
		},
		{
			name: "single_hint_with_anonymous_observation_shared_source",
			obsA: model.Observation{
				ID: "hinted-net", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive,
				Source: "gateway-proxy", ActorHint: "service-x",
			},
			obsB: model.Observation{
				ID: "anon-beh", Timestamp: now.Add(time.Minute), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive,
				Source: "gateway-proxy", ActorHint: "",
			},
			rule:         Rule{Name: "timing_correlation"},
			groundTruthA: "service-x",
			groundTruthB: "service-x",
			expectMerge:  true,
			wantActorID:  "actor-src-gateway-proxy",
		},
	}

	totalFalseMerges := 0

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			actor, err := ResolvePair(tc.obsA, tc.obsB, tc.rule)
			if tc.expectErr != nil {
				if !errors.Is(err, tc.expectErr) {
					t.Fatalf("expected error %v, got %v", tc.expectErr, err)
				}
				// Verify no merge occurred
				if actor != nil {
					t.Fatalf("actor returned on error: %+v", actor)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if tc.expectMerge {
				if actor == nil {
					t.Fatal("expected merged actor, got nil")
				}
				if actor.ID != tc.wantActorID {
					t.Errorf("actor ID = %q, want %q", actor.ID, tc.wantActorID)
				}
				if len(actor.EvidenceChain) != 2 {
					t.Errorf("evidence chain length = %d, want 2", len(actor.EvidenceChain))
				}

				// Check ground truth false merge
				if tc.groundTruthA != tc.groundTruthB {
					totalFalseMerges++
					t.Errorf("CRITICAL INVARIANT VIOLATION: false merge between %q and %q into actor %q",
						tc.groundTruthA, tc.groundTruthB, actor.ID)
				}
			}
		})
	}

	if totalFalseMerges != 0 {
		t.Fatalf("false-merge gate failed: total false merges = %d, want 0", totalFalseMerges)
	}
}

// TestCorrelation_EquivalenceWithLegacyEngine verifies that Resolve yields the same actor grouping
// as legacy correlation on concordant labelled fixtures.
func TestCorrelation_EquivalenceWithLegacyEngine(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	fixtures := []struct {
		name        string
		obs         []model.Observation
		wantActors  int
		wantActorID string
	}{
		{
			name: "cross_layer_identity",
			obs: []model.Observation{
				{ID: "net-1", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "src-a", ActorHint: "sa-shadow-bot"},
				{ID: "id-1", Timestamp: now.Add(time.Minute), Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive, Source: "src-b", ActorHint: "sa-shadow-bot"},
			},
			wantActors:  1,
			wantActorID: "actor-sa-shadow-bot",
		},
		{
			name: "timing_correlation_unhinted",
			obs: []model.Observation{
				{ID: "net-t", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "workload-x"},
				{ID: "beh-t", Timestamp: now.Add(2 * time.Minute), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "workload-x", ActorHint: "workload-x"},
			},
			wantActors:  1,
			wantActorID: "actor-src-workload-x",
		},
		{
			name: "credential_chain",
			obs: []model.Observation{
				{ID: "id-c", Timestamp: now, Layer: model.LayerIdentityAuth, Fidelity: model.FidelitySuggestive, Source: "auth-server", ActorHint: "sa-cred-bot"},
				{ID: "beh-c", Timestamp: now.Add(30 * time.Second), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "api-server", ActorHint: "sa-cred-bot"},
			},
			wantActors:  1,
			wantActorID: "actor-sa-cred-bot",
		},
		{
			name: "gcp_iam_agent_escalation",
			obs: []model.Observation{
				{ID: "gcp-1", Timestamp: now, Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityStrong, Source: "gcp-iam", ActorHint: "agent-iam-0"},
				{ID: "saas-1", Timestamp: now.Add(time.Minute), Layer: model.LayerApplicationSaaS, Fidelity: model.FidelitySuggestive, Source: "slack", ActorHint: "agent-iam-0"},
			},
			wantActors:  1,
			wantActorID: "actor-agent-iam-0",
		},
	}

	for _, tc := range fixtures {
		t.Run(tc.name, func(t *testing.T) {
			s := seedStore(t, tc.obs)
			e, err := NewEngine(s)
			if err != nil {
				t.Fatal(err)
			}
			actors, err := e.Correlate(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if len(actors) != tc.wantActors {
				t.Fatalf("actor count = %d, want %d", len(actors), tc.wantActors)
			}
			if tc.wantActors > 0 && actors[0].ID != tc.wantActorID {
				t.Errorf("actor ID = %q, want %q", actors[0].ID, tc.wantActorID)
			}
		})
	}
}

// TestCorrelation_PromotePathIntact verifies PromoteActor operates identically over Resolve.
func TestCorrelation_PromotePathIntact(t *testing.T) {
	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "net-p", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelityStrong, Source: "src-a", ActorHint: "agent-prom"},
		{ID: "id-p", Timestamp: now.Add(time.Minute), Layer: model.LayerIdentityAuth, Fidelity: model.FidelityDefinitive, Source: "src-b", ActorHint: "agent-prom"},
	}
	s := seedStore(t, obs)
	e, err := NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}
	actors, err := e.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) != 1 {
		t.Fatalf("want 1 actor, got %d", len(actors))
	}

	actorID := actors[0].ID
	promoted, err := e.PromoteActor(actorID)
	if err != nil {
		t.Fatalf("PromoteActor failed: %v", err)
	}
	if promoted.Status != model.ActorPromoted {
		t.Errorf("status = %v, want promoted", promoted.Status)
	}
	if promoted.PromotedAt == nil {
		t.Errorf("PromotedAt should not be nil")
	}

	// Double promotion should fail
	_, err = e.PromoteActor(actorID)
	if !errors.Is(err, ErrAlreadyPromoted) {
		t.Errorf("expected ErrAlreadyPromoted, got %v", err)
	}
}

// TestCorrelation_ObsToMapProjection verifies obsToMap projects standard and additive fields.
func TestCorrelation_ObsToMapProjection(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	obs := model.Observation{
		ID:               "proj-1",
		Timestamp:        now,
		Layer:            model.LayerIdentityAuth,
		Fidelity:         model.FidelityStrong,
		Source:           "bao-audit",
		Confidence:       0.85,
		ActorHint:        "spiffe://cluster.local/ns/test/sa/bot",
		RawEvidenceRef:   "ref-123",
		Description:      "projected obs",
		PrincipalID:      "principal-abc",
		ActorID:          "actor-xyz",
		SessionID:        "sess-999",
		ImpersonatedUser: "admin-user",
		DelegationDepth:  2,
	}

	m := obsToMap(obs)

	expectedKeys := []string{
		"id", "timestamp", "layer", "fidelity", "source", "confidence", "actor_hint",
		"raw_evidence_ref", "description", "principal_id", "actor_id", "session_id",
		"impersonated_user", "delegation_depth",
	}

	for _, k := range expectedKeys {
		if _, ok := m[k]; !ok {
			t.Errorf("obsToMap missing key %q", k)
		}
	}

	if m["principal_id"] != "principal-abc" {
		t.Errorf("principal_id = %v, want principal-abc", m["principal_id"])
	}
	if m["delegation_depth"] != int64(2) {
		t.Errorf("delegation_depth = %v, want 2", m["delegation_depth"])
	}
}

// TestCorrelation_DeterministicRestarts verifies that correlation produces identical outputs across runs.
func TestCorrelation_DeterministicRestarts(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	obs := []model.Observation{
		{ID: "obs-b", Timestamp: now.Add(time.Minute), Layer: model.LayerIdentityAuth, Fidelity: model.FidelityStrong, Source: "src-1", ActorHint: "agent-beta"},
		{ID: "obs-a", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelityStrong, Source: "src-1", ActorHint: "agent-alpha"},
		{ID: "obs-c", Timestamp: now.Add(2 * time.Minute), Layer: model.LayerBehavioural, Fidelity: model.FidelitySuggestive, Source: "src-1", ActorHint: "agent-alpha"},
		{ID: "obs-d", Timestamp: now.Add(3 * time.Minute), Layer: model.LayerApplicationSaaS, Fidelity: model.FidelitySuggestive, Source: "src-1", ActorHint: "agent-beta"},
	}

	runEngine := func() []*model.ProvisionalActor {
		s := seedStore(t, obs)
		e, err := NewEngine(s)
		if err != nil {
			t.Fatal(err)
		}
		actors, err := e.Correlate(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		return actors
	}

	run1 := runEngine()
	run2 := runEngine()

	if len(run1) != len(run2) {
		t.Fatalf("run1 len = %d, run2 len = %d", len(run1), len(run2))
	}
	for i := range run1 {
		if run1[i].ID != run2[i].ID {
			t.Errorf("actor[%d] ID mismatch: %q vs %q", i, run1[i].ID, run2[i].ID)
		}
		if run1[i].Confidence != run2[i].Confidence {
			t.Errorf("actor[%d] Confidence mismatch: %f vs %f", i, run1[i].Confidence, run2[i].Confidence)
		}
	}
}
