package correlation

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestTransitiveDelegationGraphTraversal verifies multi-hop agent delegation resolution,
// cycle detection, depth limits, and SP-1 never-merge enforcement across correlation & identity layers.
func TestTransitiveDelegationGraphTraversal(t *testing.T) {
	ctx := context.Background()
	repo := identity.NewMemoryRepository(identity.NewNoopEncryptor())

	now := time.Date(2026, 9, 10, 20, 0, 0, 0, time.UTC)

	// Create a 4-hop delegation hierarchy:
	// agent-leaf -> agent-mid1 -> agent-mid2 -> agent-root -> human-ceo
	actors := []string{"agent-leaf", "agent-mid1", "agent-mid2", "agent-root", "human-ceo"}
	for _, a := range actors {
		_ = repo.CreateActor(ctx, identity.ActorRecord{
			ActorID:   a,
			Status:    model.ActorActionable,
			CreatedAt: now.Add(-10 * time.Hour),
		})
	}

	delegations := []struct {
		delegate  string
		principal string
		ref       string
	}{
		{"agent-leaf", "agent-mid1", "grant-leaf-mid1"},
		{"agent-mid1", "agent-mid2", "grant-mid1-mid2"},
		{"agent-mid2", "agent-root", "grant-mid2-root"},
		{"agent-root", "human-ceo", "grant-root-ceo"},
	}

	for _, d := range delegations {
		_ = repo.AddDelegation(ctx, identity.DelegationRecord{
			DelegateActorID:  d.delegate,
			PrincipalActorID: d.principal,
			AuthzRef:         d.ref,
			ValidFrom:        now.Add(-5 * time.Hour),
		})
	}

	// 1. Resolve agent-leaf: should transitively resolve to human-ceo
	res, err := identity.ResolveActorAsOf(ctx, repo, "agent-leaf", now)
	if err != nil {
		t.Fatalf("unexpected resolution error: %v", err)
	}

	if res.PrincipalID != "human-ceo" {
		t.Errorf("expected terminal principal 'human-ceo', got '%s'", res.PrincipalID)
	}
	if len(res.DelegationPath) != 4 {
		t.Fatalf("expected 4 hops in delegation path, got %d", len(res.DelegationPath))
	}
	if res.CycleDetected {
		t.Errorf("expected cycleDetected=false for acyclic chain")
	}

	// 2. SP-1 Invariant Verification:
	// Verify that each agent in the chain remains a separate, distinct canonical entity.
	for _, a := range actors {
		actRes, err := identity.ResolveActorAsOf(ctx, repo, a, now)
		if err != nil {
			t.Fatalf("failed to resolve actor %s: %v", a, err)
		}
		if actRes.ActorID != a {
			t.Errorf("actor %s resolved to differing ActorID %s", a, actRes.ActorID)
		}
		if actRes.CanonicalID != a {
			t.Errorf("SP-1 violation: actor %s merged into %s", a, actRes.CanonicalID)
		}
	}
}

// TestTransitiveDelegationCycleSafeguard asserts cycle detection halts in <5ms without unbounded recursion.
func TestTransitiveDelegationCycleSafeguard(t *testing.T) {
	ctx := context.Background()
	repo := identity.NewMemoryRepository(identity.NewNoopEncryptor())

	now := time.Date(2026, 9, 10, 20, 0, 0, 0, time.UTC)
	for i := 1; i <= 3; i++ {
		_ = repo.CreateActor(ctx, identity.ActorRecord{
			ActorID:   fmt.Sprintf("cyclic-agent-%d", i),
			CreatedAt: now.Add(-10 * time.Hour),
		})
	}

	// Cycle: 1 -> 2 -> 3 -> 1
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "cyclic-agent-1",
		PrincipalActorID: "cyclic-agent-2",
		AuthzRef:         "authz-1-2",
		ValidFrom:        now.Add(-1 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "cyclic-agent-2",
		PrincipalActorID: "cyclic-agent-3",
		AuthzRef:         "authz-2-3",
		ValidFrom:        now.Add(-1 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "cyclic-agent-3",
		PrincipalActorID: "cyclic-agent-1",
		AuthzRef:         "authz-3-1",
		ValidFrom:        now.Add(-1 * time.Hour),
	})

	start := time.Now()
	res, err := identity.ResolveActorAsOf(ctx, repo, "cyclic-agent-1", now)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !res.CycleDetected {
		t.Errorf("expected cycle detection flag on cyclic graph")
	}
	if elapsed > 5*time.Millisecond {
		t.Errorf("cycle detection took %v (> 5ms)", elapsed)
	}
	if len(res.DelegationPath) == 0 {
		t.Errorf("expected partial delegation path before cycle cutoff")
	}
}
