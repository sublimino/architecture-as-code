package identity

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func setupTestMemoryRepo(t *testing.T) *MemoryRepository {
	t.Helper()
	return NewMemoryRepository(NewNoopEncryptor())
}

// TestFindTransitiveDelegations_SingleHop asserts that a 1-hop delegation resolves cleanly.
func TestFindTransitiveDelegations_SingleHop(t *testing.T) {
	ctx := context.Background()
	repo := setupTestMemoryRepo(t)

	now := time.Now().UTC()
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-alpha", CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "principal-alice", CreatedAt: now.Add(-5 * time.Hour)})

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-alpha",
		PrincipalActorID: "principal-alice",
		AuthzRef:         "authz-alpha-alice",
		ValidFrom:        now.Add(-1 * time.Hour),
	})

	path, cycle, err := repo.FindTransitiveDelegations(ctx, "agent-alpha", now, 8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cycle {
		t.Errorf("expected no cycle, got cycle=true")
	}
	if len(path) != 1 {
		t.Fatalf("expected path length 1, got %d", len(path))
	}
	if path[0].DelegateActorID != "agent-alpha" || path[0].PrincipalActorID != "principal-alice" {
		t.Errorf("unexpected edge: %+v", path[0])
	}
}

// TestFindTransitiveDelegations_MultiHop asserts that A -> B -> C -> D resolves to terminal principal D.
func TestFindTransitiveDelegations_MultiHop(t *testing.T) {
	ctx := context.Background()
	repo := setupTestMemoryRepo(t)

	now := time.Now().UTC()
	actors := []string{"agent-a", "agent-b", "agent-c", "human-d"}
	for _, a := range actors {
		_ = repo.CreateActor(ctx, ActorRecord{ActorID: a, CreatedAt: now.Add(-5 * time.Hour)})
	}

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-a",
		PrincipalActorID: "agent-b",
		AuthzRef:         "authz-a-b",
		ValidFrom:        now.Add(-2 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-b",
		PrincipalActorID: "agent-c",
		AuthzRef:         "authz-b-c",
		ValidFrom:        now.Add(-2 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-c",
		PrincipalActorID: "human-d",
		AuthzRef:         "authz-c-d",
		ValidFrom:        now.Add(-2 * time.Hour),
	})

	path, cycle, err := repo.FindTransitiveDelegations(ctx, "agent-a", now, 8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cycle {
		t.Errorf("expected no cycle")
	}
	if len(path) != 3 {
		t.Fatalf("expected 3 hops, got %d", len(path))
	}
	if path[2].PrincipalActorID != "human-d" {
		t.Errorf("expected terminal principal human-d, got %s", path[2].PrincipalActorID)
	}

	// Test integration with ResolveActorAsOf
	res, err := ResolveActorAsOf(ctx, repo, "agent-a", now)
	if err != nil {
		t.Fatalf("ResolveActorAsOf error: %v", err)
	}
	if res.PrincipalID != "human-d" {
		t.Errorf("expected resolved principal human-d, got %s", res.PrincipalID)
	}
	if len(res.DelegationPath) != 3 {
		t.Errorf("expected 3 delegation path hops in resolution, got %d", len(res.DelegationPath))
	}
}

// TestFindTransitiveDelegations_CycleDetection asserts that cyclic delegation halts in <5ms with cycleDetected=true.
func TestFindTransitiveDelegations_CycleDetection(t *testing.T) {
	ctx := context.Background()
	repo := setupTestMemoryRepo(t)

	now := time.Now().UTC()
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "node-1", CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "node-2", CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "node-3", CreatedAt: now.Add(-5 * time.Hour)})

	// Cycle: 1 -> 2 -> 3 -> 1
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "node-1",
		PrincipalActorID: "node-2",
		AuthzRef:         "ref-1-2",
		ValidFrom:        now.Add(-1 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "node-2",
		PrincipalActorID: "node-3",
		AuthzRef:         "ref-2-3",
		ValidFrom:        now.Add(-1 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "node-3",
		PrincipalActorID: "node-1",
		AuthzRef:         "ref-3-1",
		ValidFrom:        now.Add(-1 * time.Hour),
	})

	start := time.Now()
	path, cycle, err := repo.FindTransitiveDelegations(ctx, "node-1", now, 8)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cycle {
		t.Errorf("expected cycle detected, got cycle=false")
	}
	if elapsed > 5*time.Millisecond {
		t.Errorf("cycle detection took %v, expected < 5ms", elapsed)
	}
	if len(path) == 0 {
		t.Errorf("expected partial path before cycle, got 0")
	}

	// Verify ResolveActorAsOf flags cycle in EvidenceChain
	res, err := ResolveActorAsOf(ctx, repo, "node-1", now)
	if err != nil {
		t.Fatalf("ResolveActorAsOf error: %v", err)
	}
	if !res.CycleDetected {
		t.Errorf("expected res.CycleDetected = true")
	}

	foundWarning := false
	for _, ev := range res.ProvisionalActor.EvidenceChain {
		if ev.ObservationID == "delegation-cycle-detected" {
			foundWarning = true
			break
		}
	}
	if !foundWarning {
		t.Errorf("expected delegation-cycle-detected evidence link in chain")
	}
}

// TestFindTransitiveDelegations_DepthClamping asserts that a 10-node chain clamps to max 8 hops.
func TestFindTransitiveDelegations_DepthClamping(t *testing.T) {
	ctx := context.Background()
	repo := setupTestMemoryRepo(t)

	now := time.Now().UTC()
	// Create 12 sequential actors: hop-0 -> hop-1 -> ... -> hop-11
	for i := 0; i <= 11; i++ {
		_ = repo.CreateActor(ctx, ActorRecord{ActorID: fmt.Sprintf("hop-%d", i), CreatedAt: now.Add(-5 * time.Hour)})
	}
	for i := 0; i < 11; i++ {
		_ = repo.AddDelegation(ctx, DelegationRecord{
			DelegateActorID:  fmt.Sprintf("hop-%d", i),
			PrincipalActorID: fmt.Sprintf("hop-%d", i+1),
			AuthzRef:         fmt.Sprintf("authz-%d", i),
			ValidFrom:        now.Add(-1 * time.Hour),
		})
	}

	path, cycle, err := repo.FindTransitiveDelegations(ctx, "hop-0", now, 8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cycle {
		t.Errorf("expected no cycle in linear chain")
	}
	if len(path) != 8 {
		t.Errorf("expected depth clamped to 8, got %d", len(path))
	}
	if path[7].PrincipalActorID != "hop-8" {
		t.Errorf("expected terminal node at clamped depth to be hop-8, got %s", path[7].PrincipalActorID)
	}
}

// TestFindTransitiveDelegations_TemporalWindow asserts that expired delegations halt traversal.
func TestFindTransitiveDelegations_TemporalWindow(t *testing.T) {
	ctx := context.Background()
	repo := setupTestMemoryRepo(t)

	now := time.Now().UTC()
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-1", CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-2", CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "principal-3", CreatedAt: now.Add(-5 * time.Hour)})

	expiredTime := now.Add(-10 * time.Minute)

	// agent-1 -> agent-2 is currently active
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-1",
		PrincipalActorID: "agent-2",
		AuthzRef:         "authz-active",
		ValidFrom:        now.Add(-1 * time.Hour),
	})

	// agent-2 -> principal-3 expired 10 minutes ago
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-2",
		PrincipalActorID: "principal-3",
		AuthzRef:         "authz-expired",
		ValidFrom:        now.Add(-2 * time.Hour),
		ValidTo:          &expiredTime,
	})

	path, cycle, err := repo.FindTransitiveDelegations(ctx, "agent-1", now, 8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cycle {
		t.Errorf("expected no cycle")
	}
	// Traversal should stop after hop 1 because hop 2 is expired at `now`
	if len(path) != 1 {
		t.Fatalf("expected 1 active hop, got %d", len(path))
	}
	if path[0].PrincipalActorID != "agent-2" {
		t.Errorf("expected terminal principal agent-2, got %s", path[0].PrincipalActorID)
	}

	// At timestamp prior to expiration, both hops should resolve
	past := now.Add(-30 * time.Minute)
	pastPath, _, err := repo.FindTransitiveDelegations(ctx, "agent-1", past, 8)
	if err != nil {
		t.Fatalf("unexpected error at past timestamp: %v", err)
	}
	if len(pastPath) != 2 {
		t.Fatalf("expected 2 active hops at past timestamp, got %d", len(pastPath))
	}
	if pastPath[1].PrincipalActorID != "principal-3" {
		t.Errorf("expected principal-3 at past timestamp, got %s", pastPath[1].PrincipalActorID)
	}
}

// TestFindTransitiveDelegations_SP1_NeverMerge asserts that delegation hops never merge entities.
func TestFindTransitiveDelegations_SP1_NeverMerge(t *testing.T) {
	ctx := context.Background()
	repo := setupTestMemoryRepo(t)

	now := time.Now().UTC()
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-x", Status: model.ActorProvisional, CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "agent-y", Status: model.ActorProvisional, CreatedAt: now.Add(-5 * time.Hour)})
	_ = repo.CreateActor(ctx, ActorRecord{ActorID: "principal-z", Status: model.ActorActionable, CreatedAt: now.Add(-5 * time.Hour)})

	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-x",
		PrincipalActorID: "agent-y",
		AuthzRef:         "authz-x-y",
		ValidFrom:        now.Add(-1 * time.Hour),
	})
	_ = repo.AddDelegation(ctx, DelegationRecord{
		DelegateActorID:  "agent-y",
		PrincipalActorID: "principal-z",
		AuthzRef:         "authz-y-z",
		ValidFrom:        now.Add(-1 * time.Hour),
	})

	resX, err := ResolveActorAsOf(ctx, repo, "agent-x", now)
	if err != nil {
		t.Fatalf("ResolveActorAsOf agent-x error: %v", err)
	}
	resY, err := ResolveActorAsOf(ctx, repo, "agent-y", now)
	if err != nil {
		t.Fatalf("ResolveActorAsOf agent-y error: %v", err)
	}

	// SP-1 invariant: agent-x and agent-y must remain separate canonical entities
	if resX.CanonicalID == resY.CanonicalID {
		t.Fatalf("SP-1 VIOLATION: agent-x and agent-y were merged into %s", resX.CanonicalID)
	}
	if resX.ActorID == resX.PrincipalID {
		t.Fatalf("SP-1 VIOLATION: agent-x self-merged with principal %s", resX.PrincipalID)
	}
	if resX.PrincipalID != "principal-z" {
		t.Errorf("expected agent-x terminal principal to be principal-z, got %s", resX.PrincipalID)
	}
	if resY.PrincipalID != "principal-z" {
		t.Errorf("expected agent-y terminal principal to be principal-z, got %s", resY.PrincipalID)
	}
}
