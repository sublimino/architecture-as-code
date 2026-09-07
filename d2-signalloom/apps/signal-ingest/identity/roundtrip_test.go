package identity

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestResolverStore_RoundTripMapping(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("SeedFixtureGraph: %v", err)
	}

	store := NewGraphResolverStore(repo)

	// Ingest an observation from deployer agent during T2 (when session alias & delegation 1 are active)
	obsTime := TimeT2.Add(30 * time.Minute)
	obs := model.Observation{
		ID:        "obs-flow-999",
		Layer:     model.LayerNetworkEgress,
		Fidelity:  model.FidelityDefinitive,
		ActorHint: "deployer-session-123",
		Timestamp: obsTime,
		Source:    "netebpf",
	}

	actor, err := store.ResolveObservationAsOf(ctx, obs)
	if err != nil {
		t.Fatalf("ResolveObservationAsOf: %v", err)
	}

	// 1. Verify Canonical ID
	if actor.CanonicalID != "actor-agent-deployer" {
		t.Errorf("expected canonical ID actor-agent-deployer, got %s", actor.CanonicalID)
	}

	// 2. Verify Principal ID from active delegation to Alice
	if actor.PrincipalID != "actor-human-alice" {
		t.Errorf("expected principal ID actor-human-alice, got %s", actor.PrincipalID)
	}

	// 3. Verify Aliases list contains time-valid aliases at T2
	hasSPIFFE := false
	hasSession := false
	for _, a := range actor.Aliases {
		if a == "spiffe://cluster.local/ns/prod/sa/deployer" {
			hasSPIFFE = true
		}
		if a == "deployer-session-123" {
			hasSession = true
		}
	}
	if !hasSPIFFE {
		t.Error("expected aliases to contain SPIFFE alias")
	}
	if !hasSession {
		t.Error("expected aliases to contain session alias at T2")
	}

	// 4. Verify EvidenceChain mapping: fidelity preserved verbatim
	var (
		foundSpiffeLink     bool
		foundSessionLink    bool
		foundDelegationLink bool
		foundObsLink        bool
	)

	for _, link := range actor.EvidenceChain {
		if link.ObservationID == obs.ID {
			foundObsLink = true
			if link.Fidelity != model.FidelityDefinitive {
				t.Errorf("observation fidelity mismatch: got %v, want definitive", link.Fidelity)
			}
		}
		if link.Fidelity == model.FidelityStrong && link.Contribution == "time-valid alias session:deployer-session-123" {
			foundSessionLink = true
		}
		if link.Fidelity == model.FidelityDefinitive && link.Contribution == "time-valid alias spiffe:spiffe://cluster.local/ns/prod/sa/deployer" {
			foundSpiffeLink = true
		}
		if link.Fidelity == model.FidelityDefinitive && link.Contribution == "acts-on-behalf-of actor-human-alice (authz: oauth2-token-grant-xyz-1)" {
			foundDelegationLink = true
		}
	}

	if !foundObsLink {
		t.Error("missing observation evidence link in chain")
	}
	if !foundSpiffeLink {
		t.Error("missing SPIFFE evidence link in chain")
	}
	if !foundSessionLink {
		t.Error("missing session evidence link in chain")
	}
	if !foundDelegationLink {
		t.Error("missing delegation evidence link in chain")
	}

	// 5. Verify Confidence score derivation
	if actor.Confidence < 0.95 {
		t.Errorf("expected high confidence (>=0.95) with definitive evidence, got %f", actor.Confidence)
	}
	if actor.Status != model.ActorActionable {
		t.Errorf("expected status actionable, got %v", actor.Status)
	}
}
