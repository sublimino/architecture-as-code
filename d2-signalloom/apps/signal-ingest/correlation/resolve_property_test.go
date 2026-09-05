// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"errors"
	"fmt"
	"math/rand"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

var (
	testLayers = []model.Layer{
		model.LayerNetworkEgress,
		model.LayerIdentityAuth,
		model.LayerCloudControlPlane,
		model.LayerApplicationSaaS,
		model.LayerBehavioural,
	}

	testFidelities = []model.FidelityTier{
		model.FidelityCircumstantial,
		model.FidelitySuggestive,
		model.FidelityStrong,
		model.FidelityDefinitive,
	}

	testSources = []string{
		"openbao-audit",
		"spire-agent",
		"gcp-iam-audit",
		"k8s-apiserver",
		"sentinel-ebpf",
		"slack-audit",
		"m365-graph",
	}

	testNamespaces = []string{
		"default",
		"kube-system",
		"fe-signalloom-agents",
		"finance-prod",
		"payments-stage",
		"core-routing",
	}

	testServiceAccounts = []string{
		"agent-cardvault-sa",
		"agent-billing-processor",
		"agent-auth-issuer",
		"agent-sentinel-reporter",
		"agent-tool-executor",
	}
)

// generateRandomObservation generates a semi-randomized, well-formed or adversarial Observation.
func generateRandomObservation(rng *rand.Rand, idPrefix string) model.Observation {
	t := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC).Add(time.Duration(rng.Intn(3600)) * time.Second)
	layer := testLayers[rng.Intn(len(testLayers))]
	fidelity := testFidelities[rng.Intn(len(testFidelities))]
	source := testSources[rng.Intn(len(testSources))]

	var actorHint string
	hintType := rng.Intn(4)
	switch hintType {
	case 0: // SPIFFE ID
		ns := testNamespaces[rng.Intn(len(testNamespaces))]
		sa := testServiceAccounts[rng.Intn(len(testServiceAccounts))]
		actorHint = fmt.Sprintf("spiffe://cluster.local/ns/%s/sa/%s", ns, sa)
	case 1: // IAM email
		actorHint = fmt.Sprintf("agent-%d@project-corp.iam.gserviceaccount.com", rng.Intn(100))
	case 2: // Simple name
		actorHint = fmt.Sprintf("agent-worker-%02d", rng.Intn(50))
	case 3: // Anonymous
		actorHint = ""
	}

	return model.Observation{
		ID:          fmt.Sprintf("%s-%d", idPrefix, rng.Int63()),
		Timestamp:   t,
		Layer:       layer,
		Fidelity:    fidelity,
		Source:      source,
		ActorHint:   actorHint,
		Description: fmt.Sprintf("property test observation %s", idPrefix),
	}
}

// TestResolve_Property_IdempotencyAndDeterminism asserts that for any Observation,
// repeated invocations of Resolve() produce byte-for-byte identical ProvisionalActor instances.
func TestResolve_Property_IdempotencyAndDeterminism(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	const iterations = 500

	for i := 0; i < iterations; i++ {
		obs := generateRandomObservation(rng, fmt.Sprintf("idemp-%d", i))
		if obs.ActorHint == "" && obs.Source == "" && obs.ID == "" {
			continue
		}

		actor1, err1 := Resolve(obs)
		if err1 != nil {
			t.Fatalf("iteration %d: unexpected error on Resolve: %v", i, err1)
		}

		// Perform 5 repeated calls and assert deep equality
		for repeat := 0; repeat < 5; repeat++ {
			actorRepeat, errRepeat := Resolve(obs)
			if errRepeat != nil {
				t.Fatalf("iteration %d, repeat %d: unexpected error: %v", i, repeat, errRepeat)
			}

			if !reflect.DeepEqual(actor1, actorRepeat) {
				t.Fatalf("iteration %d: determinism violation!\nActor1: %+v\nActorRepeat: %+v",
					i, actor1, actorRepeat)
			}
		}
	}
}

// TestResolve_Property_StableActorKey verifies the structural contract of derived actor IDs.
func TestResolve_Property_StableActorKey(t *testing.T) {
	rng := rand.New(rand.NewSource(1337))
	const iterations = 500

	for i := 0; i < iterations; i++ {
		obs := generateRandomObservation(rng, fmt.Sprintf("key-%d", i))
		actor, err := Resolve(obs)
		if err != nil {
			if errors.Is(err, ErrUnresolvableObservation) {
				continue
			}
			t.Fatalf("unexpected error: %v", err)
		}

		// Verify ID formatting
		if !strings.HasPrefix(actor.ID, "actor-") {
			t.Errorf("actor.ID %q does not have 'actor-' prefix", actor.ID)
		}
		if actor.CanonicalID != actor.ID {
			t.Errorf("actor.CanonicalID %q != actor.ID %q", actor.CanonicalID, actor.ID)
		}

		// Verify correlation keys contain expected resolution key
		expectedKey := deriveResolutionKey(obs)
		if len(actor.CorrelationKeys) == 0 || actor.CorrelationKeys[0] != expectedKey {
			t.Errorf("actor.CorrelationKeys = %v, want [%s]", actor.CorrelationKeys, expectedKey)
		}

		// Verify EvidenceChain has exactly 1 entry linking the observation
		if len(actor.EvidenceChain) != 1 {
			t.Fatalf("actor.EvidenceChain length = %d, want 1", len(actor.EvidenceChain))
		}
		ev := actor.EvidenceChain[0]
		if ev.ObservationID != obs.ID {
			t.Errorf("evidence ObservationID = %q, want %q", ev.ObservationID, obs.ID)
		}
		if ev.Layer != obs.Layer {
			t.Errorf("evidence Layer = %v, want %v", ev.Layer, obs.Layer)
		}
		if ev.Fidelity != obs.Fidelity {
			t.Errorf("evidence Fidelity = %v, want %v", ev.Fidelity, obs.Fidelity)
		}
	}
}

// TestResolve_Property_ZeroFalseMergeAcrossDistinctIdentities rigorously enforces the false-merge == 0
// invariant across thousands of randomized distinct and near-collision identity pairs.
func TestResolve_Property_ZeroFalseMergeAcrossDistinctIdentities(t *testing.T) {
	rng := rand.New(rand.NewSource(2026))
	const iterations = 1000
	falseMerges := 0

	for i := 0; i < iterations; i++ {
		// Generate distinct identities
		nsA := testNamespaces[rng.Intn(len(testNamespaces))]
		nsB := testNamespaces[rng.Intn(len(testNamespaces))]
		saA := testServiceAccounts[rng.Intn(len(testServiceAccounts))]
		saB := testServiceAccounts[rng.Intn(len(testServiceAccounts))]

		// Ensure identities are distinct
		identityA := fmt.Sprintf("spiffe://cluster.local/ns/%s/sa/%s", nsA, saA)
		identityB := fmt.Sprintf("spiffe://cluster.local/ns/%s/sa/%s", nsB, saB)
		if identityA == identityB {
			identityB += "-distinct"
		}

		now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC).Add(time.Duration(i) * time.Second)

		obsA := model.Observation{
			ID:        fmt.Sprintf("obs-a-%d", i),
			Timestamp: now,
			Layer:     model.LayerIdentityAuth,
			Fidelity:  model.FidelityStrong,
			Source:    "bao-audit",
			ActorHint: identityA,
		}

		obsB := model.Observation{
			ID:        fmt.Sprintf("obs-b-%d", i),
			Timestamp: now.Add(5 * time.Second),
			Layer:     model.LayerNetworkEgress,
			Fidelity:  model.FidelitySuggestive,
			Source:    "sentinel-ebpf",
			ActorHint: identityB,
		}

		rule := Rule{Name: "property_cross_layer_check"}
		actor, err := ResolvePair(obsA, obsB, rule)

		// Must refuse to merge distinct principal hints
		if err == nil {
			falseMerges++
			t.Errorf("FALSE MERGE #%d: distinct identities %q and %q were merged into actor %q",
				falseMerges, identityA, identityB, actor.ID)
		} else if !errors.Is(err, ErrContradictoryPrincipals) {
			t.Errorf("expected ErrContradictoryPrincipals, got %v", err)
		}
	}

	if falseMerges != 0 {
		t.Fatalf("CRITICAL ZERO-FALSE-MERGE INVARIANT VIOLATED: %d false merges observed", falseMerges)
	}
}

// TestResolve_Property_NearCollisionAndAdversarialDiscriminators tests subtle identity differences:
// prefix overlaps, case differences, whitespace, trailing characters, and similar lookalikes.
func TestResolve_Property_NearCollisionAndAdversarialDiscriminators(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	nearCollisionPairs := []struct {
		hintA string
		hintB string
	}{
		{"agent-cardvault", "agent-cardvault-0"},
		{"agent-cardvault-sa", "agent-cardvault"},
		{"admin", "administrator"},
		{"user@company.com", "user@company.org"},
		{"user@company.com", "user@company.co"},
		{"spiffe://cluster.local/ns/prod/sa/bot", "spiffe://cluster.local/ns/stage/sa/bot"},
		{"spiffe://cluster.local/ns/prod/sa/bot", "spiffe://cluster.local/ns/prod/sa/bot-1"},
		{"10.0.0.1", "10.0.0.10"},
		{"svc-billing", "svc-billing-internal"},
		{"role:read", "role:read-write"},
		{"accessor:acc-1234", "accessor:acc-12345"},
	}

	rule := Rule{Name: "adversarial_collision_test"}

	for _, pair := range nearCollisionPairs {
		t.Run(fmt.Sprintf("%s_vs_%s", pair.hintA, pair.hintB), func(t *testing.T) {
			obsA := model.Observation{
				ID: "obs-a", Timestamp: now, Layer: model.LayerIdentityAuth, Source: "src-1",
				ActorHint: pair.hintA, Fidelity: model.FidelityStrong,
			}
			obsB := model.Observation{
				ID: "obs-b", Timestamp: now, Layer: model.LayerNetworkEgress, Source: "src-2",
				ActorHint: pair.hintB, Fidelity: model.FidelityStrong,
			}

			actor, err := ResolvePair(obsA, obsB, rule)
			if err == nil {
				t.Fatalf("adversarial pair (%q, %q) falsely merged into actor ID %q",
					pair.hintA, pair.hintB, actor.ID)
			}
			if !errors.Is(err, ErrContradictoryPrincipals) {
				t.Errorf("expected ErrContradictoryPrincipals, got %v", err)
			}
		})
	}
}

// TestResolve_Property_EmptyAndMalformedResilience tests edge-case inputs (empty structs,
// special characters, unicode, control bytes) ensuring no panics occur.
func TestResolve_Property_EmptyAndMalformedResilience(t *testing.T) {
	edgeCases := []struct {
		name      string
		obs       model.Observation
		expectErr error
	}{
		{
			name:      "completely_empty",
			obs:       model.Observation{},
			expectErr: ErrUnresolvableObservation,
		},
		{
			name: "unicode_and_emojis",
			obs: model.Observation{
				ID:        "obs-emoji",
				Source:    "audit-🚀",
				ActorHint: "spiffe://cluster.local/ns/✨/sa/🌟-agent",
			},
			expectErr: nil,
		},
		{
			name: "whitespace_in_hints",
			obs: model.Observation{
				ID:        "obs-space",
				Source:    "custom-app",
				ActorHint: "Agent Worker Process #1",
			},
			expectErr: nil,
		},
		{
			name: "very_long_hint_10kb",
			obs: model.Observation{
				ID:        "obs-long",
				Source:    "overflow-source",
				ActorHint: strings.Repeat("x", 10240),
			},
			expectErr: nil,
		},
		{
			name: "special_characters",
			obs: model.Observation{
				ID:        "obs-special",
				Source:    "src/test?query=1&val=2",
				ActorHint: "cn=agent,ou=services,dc=controlplane,dc=io",
			},
			expectErr: nil,
		},
	}

	for _, tc := range edgeCases {
		t.Run(tc.name, func(t *testing.T) {
			actor, err := Resolve(tc.obs)
			if tc.expectErr != nil {
				if !errors.Is(err, tc.expectErr) {
					t.Fatalf("expected error %v, got %v (actor: %+v)", tc.expectErr, err, actor)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error on %q: %v", tc.name, err)
			}
			if actor == nil {
				t.Fatalf("expected actor for %q, got nil", tc.name)
			}
			if actor.ID == "" {
				t.Fatalf("actor.ID is empty for %q", tc.name)
			}
		})
	}
}

// TestResolve_Property_ConfidenceScoringInvariants asserts confidence derivation and status assignment.
func TestResolve_Property_ConfidenceScoringInvariants(t *testing.T) {
	testCases := []struct {
		fidelity   model.FidelityTier
		wantStatus model.ActorStatus
		minConf    float64
	}{
		{model.FidelityCircumstantial, model.ActorProvisional, 0.0},
		{model.FidelitySuggestive, model.ActorProvisional, 0.0},
		{model.FidelityStrong, model.ActorActionable, 0.5},
		{model.FidelityDefinitive, model.ActorActionable, 0.5},
	}

	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	for _, tc := range testCases {
		t.Run(string(tc.fidelity), func(t *testing.T) {
			obs := model.Observation{
				ID:        "obs-conf",
				Timestamp: now,
				Layer:     model.LayerIdentityAuth,
				Fidelity:  tc.fidelity,
				Source:    "bao-audit",
				ActorHint: "spiffe://test/sa",
			}

			actor, err := Resolve(obs)
			if err != nil {
				t.Fatalf("Resolve failed: %v", err)
			}

			if actor.Status != tc.wantStatus {
				t.Errorf("fidelity %v produced status %v, want %v", tc.fidelity, actor.Status, tc.wantStatus)
			}
			if actor.Confidence < tc.minConf {
				t.Errorf("fidelity %v confidence = %f, want >= %f", tc.fidelity, actor.Confidence, tc.minConf)
			}
		})
	}
}
