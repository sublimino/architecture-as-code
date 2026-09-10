package identity

import (
	"context"
	"testing"
	"time"
)

func TestSeedFixtureGraph_Idempotent(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	// First seeding run
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("first SeedFixtureGraph failed: %v", err)
	}

	// Verify counts after first seed
	snapT1, err := repo.GetActiveGraphForActorAsOf(ctx, "actor-agent-deployer", TimeT1.Add(time.Hour))
	if err != nil {
		t.Fatalf("failed to query graph at T1: %v", err)
	}
	initialAliases := len(snapT1.Aliases)
	initialDelegations := len(snapT1.DelegationsAsDelegate)

	// Second seeding run must succeed idempotently without error
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("second SeedFixtureGraph failed (idempotency violation): %v", err)
	}

	// Third seeding run must also succeed
	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("third SeedFixtureGraph failed: %v", err)
	}

	// Verify graph counts remain identical (no duplicate keys or duplicated edges)
	snapT1After, err := repo.GetActiveGraphForActorAsOf(ctx, "actor-agent-deployer", TimeT1.Add(time.Hour))
	if err != nil {
		t.Fatalf("failed to query graph after re-seeding: %v", err)
	}

	if len(snapT1After.Aliases) != initialAliases {
		t.Errorf("expected %d aliases after idempotent seed, got %d", initialAliases, len(snapT1After.Aliases))
	}
	if len(snapT1After.DelegationsAsDelegate) != initialDelegations {
		t.Errorf("expected %d delegations after idempotent seed, got %d", initialDelegations, len(snapT1After.DelegationsAsDelegate))
	}
}

func TestClampDelegation(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	if err := SeedFixtureGraph(ctx, repo); err != nil {
		t.Fatalf("SeedFixtureGraph failed: %v", err)
	}

	// At TimeT3, actor-agent-deployer has an active delegation to alice (open-ended)
	tQuery := TimeT3.Add(time.Hour)
	dels, err := repo.GetDelegationsForDelegateAsOf(ctx, "actor-agent-deployer", tQuery)
	if err != nil {
		t.Fatalf("GetDelegationsForDelegateAsOf: %v", err)
	}
	if len(dels) == 0 {
		t.Fatal("expected active delegation at T3+1h")
	}

	// Clamp delegation at T3+2h
	clampTime := TimeT3.Add(2 * time.Hour)
	if err := repo.ClampDelegation(ctx, "actor-agent-deployer", clampTime); err != nil {
		t.Fatalf("ClampDelegation failed: %v", err)
	}

	// Query before clamp time -> still active
	delsBefore, err := repo.GetDelegationsForDelegateAsOf(ctx, "actor-agent-deployer", clampTime.Add(-time.Minute))
	if err != nil || len(delsBefore) == 0 {
		t.Fatal("expected delegation to still be active before clampTime")
	}

	// Query at or after clamp time -> terminated (0 active)
	delsAfter, err := repo.GetDelegationsForDelegateAsOf(ctx, "actor-agent-deployer", clampTime.Add(time.Minute))
	if err != nil {
		t.Fatalf("GetDelegationsForDelegateAsOf after clamp: %v", err)
	}
	if len(delsAfter) != 0 {
		t.Errorf("expected 0 active delegations after clampTime, got %d", len(delsAfter))
	}
}
