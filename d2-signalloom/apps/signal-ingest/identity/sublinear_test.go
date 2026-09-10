package identity

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestSublinear_IndexDefinitionsPresent(t *testing.T) {
	sql := MigrationSQL()

	expectedIndexes := []string{
		"CREATE INDEX IF NOT EXISTS idx_aliases_actor_temporal \n    ON aliases (actor_id, valid_from, valid_to)",
		"CREATE INDEX IF NOT EXISTS idx_aliases_value_temporal \n    ON aliases (alias_value, valid_from, valid_to)",
		"CREATE INDEX IF NOT EXISTS idx_aliases_hash_temporal \n    ON aliases (alias_value_hash, valid_from, valid_to)",
		"CREATE INDEX IF NOT EXISTS idx_delegations_delegate_temporal \n    ON delegations (delegate_actor_id, valid_from, valid_to)",
		"CREATE INDEX IF NOT EXISTS idx_delegations_principal_temporal \n    ON delegations (principal_actor_id, valid_from, valid_to)",
	}

	for _, idx := range expectedIndexes {
		// Normalize whitespace for check
		normExpected := strings.Join(strings.Fields(idx), " ")
		normSQL := strings.Join(strings.Fields(sql), " ")
		if !strings.Contains(normSQL, normExpected) {
			t.Errorf("missing expected B-tree index definition: %s", idx)
		}
	}
}

func TestSublinear_TemporalLookupPerformance(t *testing.T) {
	ctx := context.Background()
	repo := NewMemoryRepository()

	// Seed 2,000 actors with 5,000 time-sliced aliases
	numActors := 200
	aliasesPerActor := 25
	baseTime := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	for i := 0; i < numActors; i++ {
		actorID := fmt.Sprintf("actor-scale-%04d", i)
		_ = repo.CreateActor(ctx, ActorRecord{
			ActorID:   actorID,
			Status:    model.ActorActionable,
			CreatedAt: baseTime,
		})

		for j := 0; j < aliasesPerActor; j++ {
			vFrom := baseTime.Add(time.Duration(j) * 24 * time.Hour)
			vTo := vFrom.Add(24 * time.Hour)
			_ = repo.AddAlias(ctx, AliasRecord{
				ActorID:      actorID,
				AliasType:    "session",
				AliasValue:   fmt.Sprintf("session-%04d-%02d", i, j),
				EdgeFidelity: model.FidelityStrong,
				ValidFrom:    vFrom,
				ValidTo:      &vTo,
			})
		}
	}

	// Measure 1,000 random point lookups at specific timestamps
	targetActor := "actor-scale-0100"
	queryTime := baseTime.Add(10 * 24 * time.Hour).Add(12 * time.Hour) // Day 10 mid-day

	start := time.Now()
	const iterations = 1000
	for i := 0; i < iterations; i++ {
		aliases, err := repo.GetAliasesForActorAsOf(ctx, targetActor, queryTime)
		if err != nil {
			t.Fatalf("GetAliasesForActorAsOf: %v", err)
		}
		if len(aliases) != 1 {
			t.Fatalf("expected 1 active alias on day 10, got %d", len(aliases))
		}
	}
	elapsed := time.Since(start)

	avgPerOp := elapsed / iterations
	t.Logf("1000 temporal as-of queries took %v (average %v per lookup over 5000 edges)", elapsed, avgPerOp)

	// Threshold: Sub-linear in-memory search must stay well under 100 microseconds per query (500µs under -race instrumentation)
	if avgPerOp > 500*time.Microsecond {
		t.Errorf("as-of lookup performance regression: %v per op", avgPerOp)
	}
}
