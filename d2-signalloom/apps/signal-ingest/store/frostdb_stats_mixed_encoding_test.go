//go:build frostdb

package store

import (
	"context"
	"testing"
)

// TestFrostDBStore_Stats_AgreesWithObservationStatsOverMixedBlocks carries the mixed-encoding
// guard (2a500684) across to the EAPCI P1-6 Stats aggregate, which arrived by merge with its own
// read path.
//
// newMixedBlockStore holds one rotated (Parquet, *array.String) block and one active
// (*array.Binary) block. Stats must read the layer and fidelity columns under BOTH encodings and
// report the same totals as ObservationStats, the path already proven over this fixture. A Stats
// that pushed a string group-by into the engine, or that decoded only one concrete Arrow type,
// would disagree here on every run, because half the rows live in each block.
func TestFrostDBStore_Stats_AgreesWithObservationStatsOverMixedBlocks(t *testing.T) {
	ctx := context.Background()
	s := newMixedBlockStore(ctx, t)

	want, err := s.ObservationStats(ctx, Query{})
	if err != nil {
		t.Fatalf("ObservationStats over a rotated plus an active block: %v", err)
	}
	if want.Total == 0 {
		t.Fatal("fixture holds no rows; the comparison would be vacuous")
	}

	got, err := s.Stats(ctx, StatsQuery{AllTenants: true})
	if err != nil {
		t.Fatalf("Stats over a rotated plus an active block: %v", err)
	}

	if got.TotalObservations != want.Total {
		t.Fatalf("Stats.TotalObservations = %d, ObservationStats.Total = %d", got.TotalObservations, want.Total)
	}
	if len(got.ObservationsByLayer) != len(want.ByLayer) {
		t.Fatalf("Stats has %d layer groups, ObservationStats %d: %v vs %v",
			len(got.ObservationsByLayer), len(want.ByLayer), got.ObservationsByLayer, want.ByLayer)
	}
	for layer, n := range want.ByLayer {
		if got.ObservationsByLayer[layer] != n {
			t.Fatalf("Stats layer %q = %d, ObservationStats = %d", layer, got.ObservationsByLayer[layer], n)
		}
	}
	if len(got.ObservationsByFidelity) != len(want.ByFidelity) {
		t.Fatalf("Stats has %d fidelity groups, ObservationStats %d: %v vs %v",
			len(got.ObservationsByFidelity), len(want.ByFidelity), got.ObservationsByFidelity, want.ByFidelity)
	}
	for tier, n := range want.ByFidelity {
		if got.ObservationsByFidelity[tier] != n {
			t.Fatalf("Stats fidelity %q = %d, ObservationStats = %d", tier, got.ObservationsByFidelity[tier], n)
		}
	}
	if got.LastIngestion == nil || want.LastIngestion == nil || !got.LastIngestion.Equal(*want.LastIngestion) {
		t.Fatalf("Stats.LastIngestion = %v, ObservationStats.LastIngestion = %v", got.LastIngestion, want.LastIngestion)
	}
}
