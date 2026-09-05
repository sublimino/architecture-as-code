// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// FalseMergeRegressionTestCase defines the table-driven discriminator contract
// for false-merge regression verification.
type FalseMergeRegressionTestCase struct {
	ID                 string
	Class              AttackClass
	Name               string
	Description        string
	Observations       []model.Observation
	ExpectedActors     int
	ExpectedAliases    []string
	RequireProvisional bool
	MustNotMerge       bool
}

// BuildFalseMergeRegressionCorpus curates the complete regression corpus
// comprising P4-2 adversarial cases and historical false-merge triggers.
func BuildFalseMergeRegressionCorpus(baseTime time.Time) []FalseMergeRegressionTestCase {
	// Base P4-2 adversarial cases
	advCases := BuildAdversarialCorpus(baseTime)
	var corpus []FalseMergeRegressionTestCase

	for _, c := range advCases {
		corpus = append(corpus, FalseMergeRegressionTestCase{
			ID:                 c.ID,
			Class:              c.Class,
			Name:               c.Name,
			Description:        c.Description,
			Observations:       c.Observations,
			ExpectedActors:     c.ExpectedActors,
			ExpectedAliases:    c.ExpectedAliases,
			RequireProvisional: c.RequireProvisional,
			MustNotMerge:       c.MustNotMerge,
		})
	}

	// Historical false-merge triggers (Hardening against past regression surfaces)
	t0 := baseTime

	// HIST-FM-01: Contradictory principal hints across layers
	obsContradictory1 := model.Observation{
		ID:          "HIST-OBS-01-A",
		Timestamp:   t0.Add(5 * time.Minute),
		Layer:       model.LayerIdentityAuth,
		Fidelity:    model.FidelityDefinitive,
		Source:      "gcpaudit",
		ActorHint:   "alice@corp.internal",
		PrincipalID: "alice@corp.internal",
		Confidence:  1.0,
		Labels: map[string]string{
			"src_ip": "10.0.1.50",
		},
	}
	obsContradictory2 := model.Observation{
		ID:          "HIST-OBS-01-B",
		Timestamp:   t0.Add(6 * time.Minute),
		Layer:       model.LayerIdentityAuth,
		Fidelity:    model.FidelityDefinitive,
		Source:      "gcpaudit",
		ActorHint:   "bob@corp.internal",
		PrincipalID: "bob@corp.internal",
		Confidence:  1.0,
		Labels: map[string]string{
			"src_ip": "10.0.1.50", // Same IP, but contradictory non-empty principals
		},
	}
	corpus = append(corpus, FalseMergeRegressionTestCase{
		ID:             "HIST-FM-01",
		Class:          AttackClassSplitHuman,
		Name:           "Contradictory Principal Hints Across Identical IP",
		Description:    "Observations with contradictory non-empty principal IDs must reject merge and yield distinct actors",
		Observations:   []model.Observation{obsContradictory1, obsContradictory2},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})

	// HIST-FM-02: Cross-namespace identical ServiceAccount names
	obsSameSAName1 := model.Observation{
		ID:          "HIST-OBS-02-A",
		Timestamp:   t0.Add(15 * time.Minute),
		Layer:       model.LayerIdentityAuth,
		Fidelity:    model.FidelityDefinitive,
		Source:      "spirea",
		ActorHint:   "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-runner",
		PrincipalID: "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-runner",
		Confidence:  1.0,
	}
	obsSameSAName2 := model.Observation{
		ID:          "HIST-OBS-02-B",
		Timestamp:   t0.Add(16 * time.Minute),
		Layer:       model.LayerIdentityAuth,
		Fidelity:    model.FidelityDefinitive,
		Source:      "spirea",
		ActorHint:   "spiffe://cluster.local/ns/default/sa/agent-runner",
		PrincipalID: "spiffe://cluster.local/ns/default/sa/agent-runner",
		Confidence:  1.0,
	}
	corpus = append(corpus, FalseMergeRegressionTestCase{
		ID:             "HIST-FM-02",
		Class:          AttackClassSplitHuman,
		Name:           "Cross-Namespace Identical ServiceAccount Separation",
		Description:    "Service accounts with the same name in different namespaces must resolve to distinct actors",
		Observations:   []model.Observation{obsSameSAName1, obsSameSAName2},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})

	// HIST-FM-03: Multiple shadow containers without SVID
	obsShadow1 := model.Observation{
		ID:          "HIST-OBS-03-A",
		Timestamp:   t0.Add(25 * time.Minute),
		Layer:       model.LayerNetworkEgress,
		Fidelity:    model.FidelitySuggestive,
		Source:      "sentinel.ebpf",
		ActorHint:   "container:shadow-worker-1",
		Confidence:  0.3,
		Description: "Unauthenticated socket connect from shadow-worker-1",
	}
	obsShadow2 := model.Observation{
		ID:          "HIST-OBS-03-B",
		Timestamp:   t0.Add(26 * time.Minute),
		Layer:       model.LayerNetworkEgress,
		Fidelity:    model.FidelitySuggestive,
		Source:      "sentinel.ebpf",
		ActorHint:   "container:shadow-worker-2",
		Confidence:  0.3,
		Description: "Unauthenticated socket connect from shadow-worker-2",
	}
	corpus = append(corpus, FalseMergeRegressionTestCase{
		ID:                 "HIST-FM-03",
		Class:              AttackClassShadowAgent,
		Name:               "Multiple Unauthenticated Containers Remain Distinct Provisionals",
		Description:        "Unauthenticated containers without SPIFFE SVIDs must each remain separate provisional actors",
		Observations:       []model.Observation{obsShadow1, obsShadow2},
		ExpectedActors:     2,
		RequireProvisional: true,
		MustNotMerge:       true,
	})

	// HIST-FM-04: Cross-tenant SaaS user collision
	obsTenant1 := model.Observation{
		ID:          "HIST-OBS-04-A",
		Timestamp:   t0.Add(35 * time.Minute),
		Layer:       model.LayerApplicationSaaS,
		Fidelity:    model.FidelityDefinitive,
		Source:      "workspacesaas",
		ActorHint:   "admin@tenant-alpha.com",
		PrincipalID: "admin@tenant-alpha.com",
		Confidence:  1.0,
		Labels: map[string]string{
			"tenant": "tenant-alpha",
		},
	}
	obsTenant2 := model.Observation{
		ID:          "HIST-OBS-04-B",
		Timestamp:   t0.Add(36 * time.Minute),
		Layer:       model.LayerApplicationSaaS,
		Fidelity:    model.FidelityDefinitive,
		Source:      "workspacesaas",
		ActorHint:   "admin@tenant-beta.com",
		PrincipalID: "admin@tenant-beta.com",
		Confidence:  1.0,
		Labels: map[string]string{
			"tenant": "tenant-beta",
		},
	}
	corpus = append(corpus, FalseMergeRegressionTestCase{
		ID:             "HIST-FM-04",
		Class:          AttackClassSplitHuman,
		Name:           "Cross-Tenant Admin User Collision Separation",
		Description:    "Admin identities belonging to different tenants must never merge into a single actor",
		Observations:   []model.Observation{obsTenant1, obsTenant2},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})

	return corpus
}

// TestFalseMergeRegression_PermanentZeroGate runs the curated regression corpus
// as a table test and asserts false-merge == 0 as an immutable gate.
func TestFalseMergeRegression_PermanentZeroGate(t *testing.T) {
	// Pin locale for byte-stable deterministic execution
	os.Setenv("LC_ALL", "C")
	os.Setenv("LANG", "C")

	ctx := context.Background()
	baseTime := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	corpus := BuildFalseMergeRegressionCorpus(baseTime)

	if len(corpus) < 22 {
		t.Fatalf("Corpus size (%d) less than expected minimum of 22 cases (18 P4-2 + 4 historical)", len(corpus))
	}

	totalFalseMerges := 0
	totalCaught := 0
	totalMissed := 0

	t.Logf("═══════════════════════════════════════════════════════════════════════════")
	t.Logf("FALSE-MERGE REGRESSION CORPUS: %d cases under evaluation", len(corpus))
	t.Logf("Permanent Invariant: false-merge == 0 across all adversarial and historical classes")
	t.Logf("═══════════════════════════════════════════════════════════════════════════")

	for _, tc := range corpus {
		t.Run(tc.ID+"_"+tc.Name, func(t *testing.T) {
			s := store.NewMemoryStore()
			if err := s.Append(ctx, tc.Observations); err != nil {
				t.Fatalf("[%s] store append failed: %v", tc.ID, err)
			}

			engine, err := NewEngineWithVerifier(s, TrustedCollectorAdapter{})
			if err != nil {
				t.Fatalf("[%s] engine initialization failed: %v", tc.ID, err)
			}

			actors, err := engine.Correlate(ctx)
			if err != nil {
				t.Fatalf("[%s] correlation failed: %v", tc.ID, err)
			}

			falseMerge := false
			caught := true
			var details string

			switch tc.Class {
			case AttackClassHiddenAlias:
				// Hidden alias must join into exactly 1 actor with all observations in its evidence chain
				if len(actors) != 1 {
					caught = false
					details = fmt.Sprintf("expected 1 joined actor, got %d", len(actors))
				} else {
					actor := actors[0]
					obsSeen := make(map[string]bool)
					for _, ev := range actor.EvidenceChain {
						obsSeen[ev.ObservationID] = true
					}
					for _, o := range tc.Observations {
						if !obsSeen[o.ID] {
							caught = false
							details = fmt.Sprintf("joined actor %s missing observation %s in evidence chain", actor.ID, o.ID)
							break
						}
					}
					if caught {
						details = fmt.Sprintf("correctly joined %d observations into actor %s", len(tc.Observations), actor.ID)
					}
				}

			case AttackClassSplitHuman:
				// Two distinct humans / services sharing NAT/IP must NOT collapse into fewer actors
				if len(actors) < tc.ExpectedActors {
					falseMerge = true
					caught = false
					details = fmt.Sprintf("FALSE MERGE: %d distinct principals collapsed into %d actor(s)", tc.ExpectedActors, len(actors))
				} else if len(actors) != tc.ExpectedActors {
					caught = false
					details = fmt.Sprintf("expected %d distinct actors, got %d", tc.ExpectedActors, len(actors))
				} else {
					// Check for duplicate actor IDs
					seen := make(map[string]bool)
					for _, a := range actors {
						if seen[a.ID] {
							falseMerge = true
							caught = false
							details = fmt.Sprintf("FALSE MERGE: duplicate actor ID %s", a.ID)
							break
						}
						seen[a.ID] = true
					}
					if caught {
						details = fmt.Sprintf("correctly preserved %d distinct actors (IDs: %s, %s)", len(actors), actors[0].ID, actors[1].ID)
					}
				}

			case AttackClassShadowAgent:
				// Shadow agent without SVID must surface as provisional, never merged or promoted
				if len(actors) != tc.ExpectedActors {
					caught = false
					details = fmt.Sprintf("expected %d provisional actor(s), got %d", tc.ExpectedActors, len(actors))
				} else {
					for _, a := range actors {
						if a.Status != model.ActorProvisional && !strings.HasPrefix(a.ID, "actor-signal-ingest|observation|") {
							falseMerge = true
							caught = false
							details = fmt.Sprintf("FALSE MERGE: shadow agent merged/promoted to %s (status=%v)", a.ID, a.Status)
							break
						}
					}
					if caught {
						details = fmt.Sprintf("correctly preserved %d provisional unauthenticated actor(s)", len(actors))
					}
				}

			default:
				caught = false
				details = fmt.Sprintf("unknown attack class %q", tc.Class)
			}

			if falseMerge {
				totalFalseMerges++
				t.Errorf("CRITICAL INVARIANT VIOLATION [%s]: %s", tc.ID, details)
			}
			if !caught {
				totalMissed++
				t.Errorf("CASE MISSED [%s]: %s", tc.ID, details)
			} else {
				totalCaught++
				t.Logf("PASS [%s] (%s): %s", tc.ID, tc.Class, details)
			}
		})
	}

	t.Logf("═══════════════════════════════════════════════════════════════════════════")
	t.Logf("REGRESSION SUMMARY: Total=%d | Caught=%d | Missed=%d | False-Merges=%d",
		len(corpus), totalCaught, totalMissed, totalFalseMerges)
	t.Logf("═══════════════════════════════════════════════════════════════════════════")

	// Hard permanent gate assertion
	if totalFalseMerges != 0 {
		t.Fatalf("PERMANENT INVARIANT GATE FAILED: false-merge count is %d, want exactly 0", totalFalseMerges)
	}

	if totalCaught != len(corpus) {
		t.Fatalf("Regression corpus resolution failed: caught %d/%d cases, want %d/%d",
			totalCaught, len(corpus), len(corpus), len(corpus))
	}
}

// TestFalseMergeRegression_DirectResolvePairDiscriminator exercises the pair-wise
// ResolvePair discriminator across all adversarial and historical pairs.
func TestFalseMergeRegression_DirectResolvePairDiscriminator(t *testing.T) {
	os.Setenv("LC_ALL", "C")
	os.Setenv("LANG", "C")

	baseTime := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	shObs := collectors.AdversarialSplitHumanFixtures(baseTime)

	// Test direct ResolvePair rejection on each split-human pair
	for i := 0; i < len(shObs); i += 2 {
		o1 := shObs[i]
		o2 := shObs[i+1]
		name := fmt.Sprintf("SplitHumanPair_%s_vs_%s", o1.ID, o2.ID)

		t.Run(name, func(t *testing.T) {
			// Direct Resolve() on each observation must return distinct actors
			a1, err1 := Resolve(o1)
			if err1 != nil {
				t.Fatalf("Resolve(%s) failed: %v", o1.ID, err1)
			}
			a2, err2 := Resolve(o2)
			if err2 != nil {
				t.Fatalf("Resolve(%s) failed: %v", o2.ID, err2)
			}

			if a1.ID == a2.ID {
				t.Fatalf("FALSE MERGE: Direct Resolve() produced identical actor ID %s for distinct humans", a1.ID)
			}
			if a1.PrincipalID != "" && a2.PrincipalID != "" && a1.PrincipalID == a2.PrincipalID {
				t.Fatalf("FALSE MERGE: Direct Resolve() assigned identical PrincipalID %s to distinct humans", a1.PrincipalID)
			}

			// ResolvePair must reject merging them
			pairActor, errPair := ResolvePair(o1, o2, Rule{Name: "test_join"})
			if errPair == nil && pairActor != nil && pairActor.ID != "" && pairActor.Status != model.ActorProvisional {
				t.Fatalf("FALSE MERGE: ResolvePair erroneously merged distinct humans %s and %s into %s", o1.ID, o2.ID, pairActor.ID)
			}
		})
	}
}

// TestFalseMergeRegression_NegativeControl_GateDetectsFalseMerge verifies that if
// a false merge were to occur, the regression test suite detects it and fails.
func TestFalseMergeRegression_NegativeControl_GateDetectsFalseMerge(t *testing.T) {
	os.Setenv("LC_ALL", "C")
	os.Setenv("LANG", "C")

	baseTime := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	shObs := collectors.AdversarialSplitHumanFixtures(baseTime)

	// Synthetic case where 2 observations are expected to produce 3 actors (impossible)
	syntheticFailingCase := RedTeamCase{
		ID:             "NEGATIVE-CONTROL-FM",
		Class:          AttackClassSplitHuman,
		Name:           "Negative Control Synthetic False Merge",
		Description:    "Synthetic probe proving false-merge detector triggers when actor count is less than expected",
		Observations:   []model.Observation{shObs[0], shObs[1]},
		ExpectedActors: 3, // Expecting 3 actors from 2 observations forces a mismatch
		MustNotMerge:   true,
	}

	res := EvaluateRedTeamCase(context.Background(), syntheticFailingCase)
	if res.Status != "MISSED" {
		t.Fatalf("Negative control expected MISSED status, got %s", res.Status)
	}
	t.Logf("Negative control successfully verified detector failure reporting: %s", res.Details)
}
