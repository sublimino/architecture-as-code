//go:build frostdb

package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// These tests cover the live 500 on GET /api/v1/store/stats introduced by b94f42353.
//
// Mechanism. ObservationStats used to push a grouped aggregation — count/max over timestamp,
// grouped by the layer and fidelity STRING columns — into FrostDB. The engine then has to merge
// one per-block group-by result against another, and its merge compares two cursors by
// type-switching on the first array and asserting the second to the same concrete type:
//
//	pqarrow/arrowutils/merge.go:125   arr2 := c2.r.Column(sc.Index).(*array.String)
//
// The two block kinds disagree on that type, and THAT is the selector:
//
//	a rotated (Parquet-backed) block    -> *array.String
//	the un-rotated active block         -> *array.Binary   (still in Arrow builders)
//
// So any store holding both — which every long-lived store does, between rotations — can panic
// with "interface conversion: arrow.Array is *array.Binary, not *array.String".
//
// Measured, with a controlled experiment over 50 calls per configuration:
//
//	active block only (all Binary)            0/50 failures
//	all blocks rotated (all String)           0/50 failures
//	rotated + active (mixed)                  9/50 failures
//
// Heterogeneity is necessary and sufficient. Live sampling of the route on kind-osramp gave
// 18/20 failures; the rate is higher there because the deployed store holds many more blocks,
// so the merge heap has far more cursor pairs and is far likelier to compare a mismatched one.
//
// Why the ENCODING is pinned deterministically but the PANIC is not. The encoding difference is
// a property of the data and reproduces every single run — TestFrostDBStore_StatsGroupBy...
// below asserts it directly. Whether the engine's merge heap actually compares a String cursor
// against a Binary one additionally depends on how that heap drains, which is scheduling- and
// order-dependent. A test that asserts "ObservationStats returns no error" therefore catches the
// regression only most of the time, and a 4-in-5 test is not a regression test. The deterministic
// guard is TestFrostDBStore_StatsQueryPlan_PushesNoStringGroupBy, which asserts the thing we
// actually control: that our code never hands the engine a string group-by to merge.
//
// To confirm by hand against a live deployment:
//
//	kubectl -n <ns> port-forward svc/signal-ingest 8080:8080
//	for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/v1/store/stats; done
//
// Before the fix that returns a mix of 500 and 200; after it, 200 every time.

// statsFixtureTime is fixed so every row lands in one predictable query window.
var statsFixtureTime = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

// statsRows builds n observations spread across two layers and two fidelity tiers, so the
// group-by produces more than one output row. A single group would let a broken merge path pass
// by never having two cursors to compare.
func statsRows(prefix string, n int) []model.Observation {
	layers := []model.Layer{model.LayerKubernetes, model.LayerCloudControlPlane}
	tiers := []model.FidelityTier{model.FidelityStrong, model.FidelitySuggestive}
	rows := make([]model.Observation, 0, n)
	for i := 0; i < n; i++ {
		rows = append(rows, model.Observation{
			ID:          fmt.Sprintf("%s-%d", prefix, i),
			Timestamp:   statsFixtureTime.Add(time.Duration(i) * time.Second),
			Source:      "test",
			Layer:       layers[i%len(layers)],
			Fidelity:    tiers[(i/2)%len(tiers)],
			Description: "stats encoding fixture",
		})
	}
	return rows
}

// appendInBatches writes rows in groups of size, so a block holds several Arrow records rather
// than one.
func appendInBatches(ctx context.Context, t *testing.T, s *FrostDBStore, rows []model.Observation, size int) {
	t.Helper()
	for start := 0; start < len(rows); start += size {
		end := start + size
		if end > len(rows) {
			end = len(rows)
		}
		if err := s.Append(ctx, rows[start:end]); err != nil {
			t.Fatalf("append rows [%d:%d]: %v", start, end, err)
		}
	}
}

// newMixedBlockStore returns a store holding one rotated, Parquet-backed block AND one
// un-rotated active block — the configuration the deployed service is in for most of its life,
// and the only one in which the defect can occur.
func newMixedBlockStore(ctx context.Context, t *testing.T) *FrostDBStore {
	t.Helper()
	s, err := NewFrostDBStoreWithBucket(t.TempDir(), WithManualFlush(), WithSegmentPseudonymiser(testPseudonymiser(t)))
	if err != nil {
		t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })

	appendInBatches(ctx, t, s, statsRows("rotated", 8), 2)
	if err := s.Flush(ctx); err != nil {
		t.Fatalf("flush to rotate the first block: %v", err)
	}
	appendInBatches(ctx, t, s, statsRows("active", 8), 2)
	return s
}

// TestFrostDBStore_StatsGroupByColumnsAreHeterogeneouslyEncoded pins the selector itself.
//
// This is the deterministic half of the root cause: it asserts, every run, that the layer column
// really does come back as two different concrete Arrow types depending on whether the block has
// been rotated. If a future FrostDB or Arrow upgrade makes the encoding uniform, this test fails
// and tells the next person the hazard is gone — at which point the pushdown could be restored.
// If it keeps passing, the pushdown must stay off.
func TestFrostDBStore_StatsGroupByColumnsAreHeterogeneouslyEncoded(t *testing.T) {
	ctx := context.Background()
	s := newMixedBlockStore(ctx, t)

	// Project the group-by column alone and collect the concrete type of every record returned.
	// One record per block source, so a mixed store yields more than one distinct type.
	seen := map[string]int{}
	err := s.engine.ScanTable(tableName).
		Project(colRef(colLayer)).
		Execute(ctx, func(_ context.Context, r arrow.Record) error {
			idx := -1
			for i, fld := range r.Schema().Fields() {
				if fld.Name == colLayer {
					idx = i
				}
			}
			if idx < 0 {
				t.Errorf("projected record has no %s column", colLayer)
				return nil
			}
			seen[fmt.Sprintf("%T", r.Column(idx))] += int(r.NumRows())
			return nil
		})
	if err != nil {
		t.Fatalf("scan the layer column: %v", err)
	}

	if len(seen) < 2 {
		t.Fatalf("expected the %s column to come back under more than one Arrow type across a "+
			"rotated and an active block, got %d: %v\n"+
			"If FrostDB now encodes both block kinds identically the merge hazard is gone and the "+
			"group-by pushdown removed from ObservationStats could be restored.", colLayer, len(seen), seen)
	}
	t.Logf("layer column encodings across a mixed store: %v", seen)
}

// TestFrostDBStore_StatsQueryPlan_PushesNoStringGroupBy is the deterministic regression guard.
//
// It asserts the property we control and that is sufficient to prevent the 500: the read behind
// GET /api/v1/store/stats must not ask the engine to group by a string column, because grouping
// is what forces the merge that cannot type-assert heterogeneous encodings. Restoring the
// aggregation fails this test on every run, which is the whole point — the panic it used to
// cause does not.
func TestFrostDBStore_StatsQueryPlan_PushesNoStringGroupBy(t *testing.T) {
	ctx := context.Background()
	s := newMixedBlockStore(ctx, t)

	builder, err := s.statsQueryBuilder(Query{})
	if err != nil {
		t.Fatalf("statsQueryBuilder: %v", err)
	}
	plan, err := builder.Explain(ctx)
	if err != nil {
		t.Fatalf("explain the stats query: %v", err)
	}
	if strings.Contains(strings.ToLower(plan), "aggregate") {
		t.Fatalf("the store/stats read pushes an aggregation into the engine, which makes it merge "+
			"per-block group-by results whose string columns are encoded differently (Parquet block "+
			"-> *array.String, active block -> *array.Binary) and panic in "+
			"pqarrow/arrowutils/merge.go. Tally in Go over a projection instead.\nplan:\n%s", plan)
	}
}

// TestFrostDBStore_ObservationStats_CorrectOverMixedBlocks checks the numbers the route reports
// are right when the store spans both block kinds, against an independent tally of the same rows.
//
// This is a correctness test, not the regression guard: on the unfixed code it fails most runs
// but not all, for the scheduling reason documented at the top of this file.
func TestFrostDBStore_ObservationStats_CorrectOverMixedBlocks(t *testing.T) {
	ctx := context.Background()
	s := newMixedBlockStore(ctx, t)

	rows, err := s.QueryRange(ctx, Query{})
	if err != nil {
		t.Fatalf("QueryRange tally: %v", err)
	}
	wantByLayer := map[string]int{}
	wantByFidelity := map[string]int{}
	var wantLast time.Time
	for _, o := range rows {
		wantByLayer[string(o.Layer)]++
		wantByFidelity[string(o.Fidelity)]++
		if o.Timestamp.After(wantLast) {
			wantLast = o.Timestamp
		}
	}

	got, err := s.ObservationStats(ctx, Query{})
	if err != nil {
		t.Fatalf("ObservationStats over a rotated plus an active block: %v", err)
	}
	if got.Total != len(rows) {
		t.Fatalf("Total = %d, want %d", got.Total, len(rows))
	}
	for layer, want := range wantByLayer {
		if got.ByLayer[layer] != want {
			t.Fatalf("ByLayer[%q] = %d, want %d (all: %v)", layer, got.ByLayer[layer], want, got.ByLayer)
		}
	}
	if len(got.ByLayer) != len(wantByLayer) {
		t.Fatalf("ByLayer has %d groups, want %d: %v", len(got.ByLayer), len(wantByLayer), got.ByLayer)
	}
	for tier, want := range wantByFidelity {
		if got.ByFidelity[tier] != want {
			t.Fatalf("ByFidelity[%q] = %d, want %d (all: %v)", tier, got.ByFidelity[tier], want, got.ByFidelity)
		}
	}
	if len(got.ByFidelity) != len(wantByFidelity) {
		t.Fatalf("ByFidelity has %d groups, want %d: %v", len(got.ByFidelity), len(wantByFidelity), got.ByFidelity)
	}
	if got.LastIngestion == nil || !got.LastIngestion.Equal(wantLast) {
		t.Fatalf("LastIngestion = %v, want %v", got.LastIngestion, wantLast)
	}
}

// TestFrostDBStore_ObservationStats_ReadStaysBounded pins the constraint the fix had to preserve.
//
// The pushdown was removed to stop the panic, and the obvious wrong way to do that would be to
// materialise the store and tally in Go — which is the OOM this store was changed to avoid. This
// asserts the read still streams: the engine hands back records, and the stats call never holds
// more than one of them, so the group maps stay bounded by the number of distinct
// (layer, fidelity) pairs rather than growing with the row count.
func TestFrostDBStore_ObservationStats_ReadStaysBounded(t *testing.T) {
	ctx := context.Background()
	s := newMixedBlockStore(ctx, t)

	// The stats plan must project exactly the three columns the tally needs. Projecting
	// logicalplan.All() would pull every column of every row across the interface, which is the
	// read this store exists to avoid.
	builder, err := s.statsQueryBuilder(Query{})
	if err != nil {
		t.Fatalf("statsQueryBuilder: %v", err)
	}
	plan, err := builder.Explain(ctx)
	if err != nil {
		t.Fatalf("explain the stats query: %v", err)
	}
	// Asserted as the whole projection clause rather than column-by-column: a substring test is
	// not safe here, because "id" is a substring of "fidelity" and would report a narrow plan as
	// a wide one.
	wantProjection := fmt.Sprintf("Projection (%s, %s, %s)", colTimestamp, colLayer, colFidelity)
	if !strings.Contains(plan, wantProjection) {
		t.Fatalf("stats plan does not project exactly the three columns the tally needs.\nwant to "+
			"contain: %s\nplan: %s", wantProjection, plan)
	}

	// And the group maps must be bounded by distinct pairs, not by rows: appending ten times the
	// rows must not grow them.
	before, err := s.ObservationStats(ctx, Query{})
	if err != nil {
		t.Fatalf("ObservationStats before the bulk append: %v", err)
	}
	for gen := 0; gen < 10; gen++ {
		appendInBatches(ctx, t, s, statsRows(fmt.Sprintf("bulk%d", gen), 16), 4)
	}
	after, err := s.ObservationStats(ctx, Query{})
	if err != nil {
		t.Fatalf("ObservationStats after the bulk append: %v", err)
	}
	if after.Total <= before.Total {
		t.Fatalf("Total did not grow with the appended rows: before %d, after %d", before.Total, after.Total)
	}
	if len(after.ByLayer) != len(before.ByLayer) {
		t.Fatalf("ByLayer grew from %d groups to %d: the tally is keyed by row, not by group",
			len(before.ByLayer), len(after.ByLayer))
	}
	if len(after.ByFidelity) != len(before.ByFidelity) {
		t.Fatalf("ByFidelity grew from %d groups to %d: the tally is keyed by row, not by group",
			len(before.ByFidelity), len(after.ByFidelity))
	}
}
