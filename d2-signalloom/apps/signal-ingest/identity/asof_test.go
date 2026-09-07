package identity

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestAsOfResolution_SeededGraphTimeline(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("SeedFixtureGraph: %v", err)
	}

	store := NewGraphResolverStore(repo)

	// --- 1. Query at T0 (2026-01-01): Initial state ---
	// Alice has alias alice@corp.internal
	aliceT0, err := store.LookupAliasAsOf(ctx, "alice@corp.internal", TimeT0)
	if err != nil {
		t.Fatalf("LookupAliasAsOf alice@corp.internal at T0: %v", err)
	}
	if aliceT0.CanonicalID != "actor-human-alice" {
		t.Errorf("expected canonical ID actor-human-alice, got %s", aliceT0.CanonicalID)
	}
	if aliceT0.PrincipalID != "" {
		t.Errorf("Alice should not have a principal at T0, got %s", aliceT0.PrincipalID)
	}

	// Deployer at T0 has no delegations
	delegationsT0, err := store.GetDelegationsAsOf(ctx, "actor-agent-deployer", TimeT0)
	if err != nil {
		t.Fatalf("GetDelegationsAsOf deployer at T0: %v", err)
	}
	if len(delegationsT0) != 0 {
		t.Errorf("expected 0 delegations for deployer at T0, got %d", len(delegationsT0))
	}

	// --- 2. Query at T1 (2026-02-01): Delegation 1 begins ---
	delegationsT1, err := store.GetDelegationsAsOf(ctx, "actor-agent-deployer", TimeT1)
	if err != nil {
		t.Fatalf("GetDelegationsAsOf deployer at T1: %v", err)
	}
	if len(delegationsT1) != 1 {
		t.Fatalf("expected 1 delegation for deployer at T1, got %d", len(delegationsT1))
	}
	if delegationsT1[0].PrincipalActorID != "actor-human-alice" {
		t.Errorf("expected principal actor-human-alice, got %s", delegationsT1[0].PrincipalActorID)
	}
	if delegationsT1[0].AuthzRef != "oauth2-token-grant-xyz-1" {
		t.Errorf("expected authz ref oauth2-token-grant-xyz-1, got %s", delegationsT1[0].AuthzRef)
	}

	// --- 3. Query at T2 (2026-03-01): Session alias active ---
	deployerSessionT2, err := store.LookupAliasAsOf(ctx, "deployer-session-123", TimeT2)
	if err != nil {
		t.Fatalf("LookupAliasAsOf deployer-session-123 at T2: %v", err)
	}
	if deployerSessionT2.CanonicalID != "actor-agent-deployer" {
		t.Errorf("expected canonical ID actor-agent-deployer, got %s", deployerSessionT2.CanonicalID)
	}
	if deployerSessionT2.PrincipalID != "actor-human-alice" {
		t.Errorf("expected principal ID actor-human-alice via active delegation, got %s", deployerSessionT2.PrincipalID)
	}

	// --- 4. Query at T3 (2026-04-01): Delegation transition & session alias expiration ---
	// Session alias expired at T3
	_, err = store.LookupAliasAsOf(ctx, "deployer-session-123", TimeT3)
	if err == nil {
		t.Error("expected error looking up expired session alias at T3")
	}

	// Delegation 1 expired, Delegation 2 active
	delegationsT3, err := store.GetDelegationsAsOf(ctx, "actor-agent-deployer", TimeT3)
	if err != nil {
		t.Fatalf("GetDelegationsAsOf deployer at T3: %v", err)
	}
	if len(delegationsT3) != 1 {
		t.Fatalf("expected 1 delegation for deployer at T3, got %d", len(delegationsT3))
	}
	if delegationsT3[0].AuthzRef != "oauth2-token-grant-xyz-2" {
		t.Errorf("expected authz ref oauth2-token-grant-xyz-2, got %s", delegationsT3[0].AuthzRef)
	}

	// --- 5. Query at T4 (2026-05-01): Multi-hop delegation chain ---
	// Scanner -> Deployer -> Alice
	scannerChain, err := store.GetDelegationsAsOf(ctx, "actor-agent-scanner", TimeT4)
	if err != nil {
		t.Fatalf("GetDelegationsAsOf scanner at T4: %v", err)
	}
	if len(scannerChain) != 2 {
		t.Fatalf("expected 2-hop delegation chain at T4, got %d", len(scannerChain))
	}
	if scannerChain[0].DelegateActorID != "actor-agent-scanner" || scannerChain[0].PrincipalActorID != "actor-agent-deployer" {
		t.Errorf("unexpected hop 1: %+v", scannerChain[0])
	}
	if scannerChain[1].DelegateActorID != "actor-agent-deployer" || scannerChain[1].PrincipalActorID != "actor-human-alice" {
		t.Errorf("unexpected hop 2: %+v", scannerChain[1])
	}

	// --- 6. Query at T5 (2026-06-01): Alice alias promotion & Scanner delegation expired ---
	// Old alias expired
	_, err = store.LookupAliasAsOf(ctx, "alice@corp.internal", TimeT5)
	if err == nil {
		t.Error("expected alice@corp.internal to be expired at T5")
	}
	// New alias active
	aliceT5, err := store.LookupAliasAsOf(ctx, "alice-promoted@corp.internal", TimeT5)
	if err != nil {
		t.Fatalf("LookupAliasAsOf alice-promoted@corp.internal at T5: %v", err)
	}
	if aliceT5.CanonicalID != "actor-human-alice" {
		t.Errorf("expected canonical ID actor-human-alice, got %s", aliceT5.CanonicalID)
	}

	// Scanner delegation expired at T5
	scannerChainT5, err := store.GetDelegationsAsOf(ctx, "actor-agent-scanner", TimeT5)
	if err != nil {
		t.Fatalf("GetDelegationsAsOf scanner at T5: %v", err)
	}
	if len(scannerChainT5) != 0 {
		t.Errorf("expected 0 delegations for scanner at T5, got %d", len(scannerChainT5))
	}
}

func TestAsOfResolution_ExplicitTimestampRequired(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	store := NewGraphResolverStore(repo)

	// Zero timestamp must fail closed to prevent accidental resolution against current graph
	_, err := store.LookupActorAsOf(ctx, "actor-1", time.Time{})
	if err == nil {
		t.Error("expected error for zero timestamp in LookupActorAsOf")
	}

	_, err = store.LookupAliasAsOf(ctx, "alias-1", time.Time{})
	if err == nil {
		t.Error("expected error for zero timestamp in LookupAliasAsOf")
	}

	obs := model.Observation{
		ID:        "obs-1",
		ActorHint: "alice@corp.internal",
		Timestamp: time.Time{}, // Zero timestamp
	}
	_, err = store.ResolveObservationAsOf(ctx, obs)
	if err == nil {
		t.Error("expected error for observation with zero timestamp in ResolveObservationAsOf")
	}
}

func TestAsOfResolution_OBOEventsYieldDelegationEdgesNeverAliasMerges(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("SeedFixtureGraph: %v", err)
	}
	store := NewGraphResolverStore(repo)

	// Simulate 100 acts-on-behalf-of observations across various timestamps
	oboEvents := []struct {
		timestamp time.Time
		agentSA   string
		userEmail string
	}{
		{TimeT1.Add(1 * time.Hour), "spiffe://cluster.local/ns/prod/sa/deployer", "alice@corp.internal"},
		{TimeT2.Add(2 * time.Hour), "deployer-session-123", "alice@corp.internal"},
		{TimeT4.Add(3 * time.Hour), "spiffe://cluster.local/ns/security/sa/scanner", "deployer-session-123"},
		{TimeT4.Add(4 * time.Hour), "spiffe://cluster.local/ns/prod/sa/deployer", "alice@corp.internal"},
	}

	for i, ev := range oboEvents {
		obs := model.Observation{
			ID:               "obo-obs",
			ActorHint:        ev.agentSA,
			ImpersonatedUser: ev.userEmail,
			Timestamp:        ev.timestamp,
			Layer:            model.LayerNetworkEgress,
			Fidelity:         model.FidelityDefinitive,
		}

		actor, err := store.ResolveObservationAsOf(ctx, obs)
		if err != nil {
			t.Fatalf("[%d] ResolveObservationAsOf: %v", i, err)
		}

		// The resolved actor ID MUST be the acting agent's canonical ID, NEVER merged with the principal
		if actor.CanonicalID == "actor-human-alice" && ev.agentSA != "alice@corp.internal" {
			t.Fatalf("[%d] FALSE MERGE: agent %s was merged into principal alice", i, ev.agentSA)
		}

		// Principal is properly tracked via delegation / ImpersonatedUser
		if actor.PrincipalID == "" {
			t.Errorf("[%d] expected non-empty PrincipalID for OBO event", i)
		}

		// Graph aliases for deployer must NEVER contain alice's email
		deployerAliases, err := repo.GetAliasesForActorAsOf(ctx, "actor-agent-deployer", ev.timestamp)
		if err != nil {
			t.Fatalf("[%d] GetAliasesForActorAsOf: %v", i, err)
		}
		for _, a := range deployerAliases {
			if a.AliasValue == "alice@corp.internal" || a.AliasValue == "alice-promoted@corp.internal" {
				t.Fatalf("[%d] INVARIANT VIOLATION: deployer was aliased to alice: %s", i, a.AliasValue)
			}
		}
	}
}
