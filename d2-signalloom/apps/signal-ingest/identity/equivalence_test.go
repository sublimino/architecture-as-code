package identity

import (
	"context"
	"testing"
	"time"
)

func TestEquivalence_GraphOperations(t *testing.T) {
	ctx := context.Background()
	repo1 := NewMemoryRepository(NewNoopEncryptor())
	repo2 := NewMemoryRepository(NewNoopEncryptor())

	// Seed both repos with identical fixture sets
	if err := SeedFixtureGraph(ctx, repo1); err != nil {
		t.Fatalf("Seed repo1: %v", err)
	}
	if err := SeedFixtureGraph(ctx, repo2); err != nil {
		t.Fatalf("Seed repo2: %v", err)
	}

	testTimestamps := []time.Time{
		TimeT0,
		TimeT1,
		TimeT2,
		TimeT3,
		TimeT4,
		TimeT5,
		TimeT2.Add(12 * time.Hour),
		TimeT4.Add(6 * time.Hour),
	}

	for _, ts := range testTimestamps {
		for _, actor := range FixtureActors {
			snap1, err1 := repo1.GetActiveGraphForActorAsOf(ctx, actor.ActorID, ts)
			snap2, err2 := repo2.GetActiveGraphForActorAsOf(ctx, actor.ActorID, ts)

			if (err1 == nil) != (err2 == nil) {
				t.Fatalf("err mismatch at %v for %s: %v vs %v", ts, actor.ActorID, err1, err2)
			}
			if err1 != nil {
				continue
			}

			if len(snap1.Aliases) != len(snap2.Aliases) {
				t.Fatalf("aliases count mismatch at %v for %s: %d vs %d", ts, actor.ActorID, len(snap1.Aliases), len(snap2.Aliases))
			}
			if len(snap1.DelegationsAsDelegate) != len(snap2.DelegationsAsDelegate) {
				t.Fatalf("delegations count mismatch at %v for %s: %d vs %d", ts, actor.ActorID, len(snap1.DelegationsAsDelegate), len(snap2.DelegationsAsDelegate))
			}

			res1, _ := ResolveActorAsOf(ctx, repo1, actor.ActorID, ts)
			res2, _ := ResolveActorAsOf(ctx, repo2, actor.ActorID, ts)

			if res1.PrincipalID != res2.PrincipalID {
				t.Errorf("principal mismatch at %v for %s: %s vs %s", ts, actor.ActorID, res1.PrincipalID, res2.PrincipalID)
			}
			if res1.ProvisionalActor.Confidence != res2.ProvisionalActor.Confidence {
				t.Errorf("confidence score mismatch at %v for %s: %f vs %f", ts, actor.ActorID, res1.ProvisionalActor.Confidence, res2.ProvisionalActor.Confidence)
			}
		}
	}
}
