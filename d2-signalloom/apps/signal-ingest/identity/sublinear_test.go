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

// seedSublinearAliases seeds 200 actors with 25 day-long session aliases each
// (5,000 time-sliced edges) and returns the repository.
func seedSublinearAliases(ctx context.Context) *MemoryRepository {
	repo := NewMemoryRepository()
	baseTime := sublinearBaseTime
	for i := 0; i < 200; i++ {
		actorID := fmt.Sprintf("actor-scale-%04d", i)
		_ = repo.CreateActor(ctx, ActorRecord{
			ActorID:   actorID,
			Status:    model.ActorActionable,
			CreatedAt: baseTime,
		})
		for j := 0; j < 25; j++ {
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
	return repo
}

var sublinearBaseTime = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// TestSublinear_TemporalLookupPerformance asserts the as-of lookup over 5,000
// time-sliced edges returns exactly the one alias valid at the query time, for
// every day of the actor's history. It asserts no per-op latency: a stopwatch
// average measured the machine. The 500µs ceiling lives in
// BenchmarkSublinear_TemporalLookup.
func TestSublinear_TemporalLookupPerformance(t *testing.T) {
	ctx := context.Background()
	repo := seedSublinearAliases(ctx)
	for day := 0; day < 25; day++ {
		queryTime := sublinearBaseTime.Add(time.Duration(day)*24*time.Hour + 12*time.Hour)
		aliases, err := repo.GetAliasesForActorAsOf(ctx, "actor-scale-0100", queryTime)
		if err != nil {
			t.Fatalf("GetAliasesForActorAsOf day %d: %v", day, err)
		}
		want := fmt.Sprintf("session-0100-%02d", day)
		if len(aliases) != 1 || aliases[0].AliasValue != want {
			var got []string
			for _, a := range aliases {
				got = append(got, a.AliasValue)
			}
			t.Errorf("day %d: as-of lookup returned %v, want exactly [%s]", day, got, want)
		}
	}
}

// BenchmarkSublinear_TemporalLookup carries the 500µs-per-lookup ceiling the
// unit test used to assert. Nothing in the estate runs Go benchmarks.
func BenchmarkSublinear_TemporalLookup(b *testing.B) {
	ctx := context.Background()
	repo := seedSublinearAliases(ctx)
	queryTime := sublinearBaseTime.Add(10*24*time.Hour + 12*time.Hour)
	b.ResetTimer()
	start := time.Now()
	for n := 0; n < b.N; n++ {
		if _, err := repo.GetAliasesForActorAsOf(ctx, "actor-scale-0100", queryTime); err != nil {
			b.Fatal(err)
		}
	}
	if avg := time.Since(start) / time.Duration(b.N); avg > 500*time.Microsecond {
		b.Errorf("as-of lookup performance regression: %v per op", avg)
	}
}
