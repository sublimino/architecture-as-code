// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// This file measures what EAPCI-P1-6 claims, in bytes per request, and it is deliberately
// separate from the behavioural paging tests beside it.
//
// WHAT WAS ALREADY PROVEN, AND WHAT WAS NOT. The store package proves the bound STRUCTURALLY:
// TestFrostDBStore_ObservationStats_ReadStaysBounded asserts the query plan projects exactly three
// columns and that the tally's group maps stay keyed by group rather than by row. That is the right
// test for the store and a strong proof of the mechanism. It cannot, however, answer the question
// the deployment memory limit is actually stated in -- how many bytes a request costs, and whether
// that figure moves when the store gets ten times larger. A plan can project three columns and
// still allocate per row somewhere the plan does not describe. That is not hypothetical: writing
// this file found two such places, one of which is fixed in store/memory.go's Stats and one of
// which is characterised below.
//
// WHY THE UNBOUNDED PATH IS KEPT IN THE TREE. A flatness assertion is vacuous on a fixture too
// small to strain anything: "allocation did not grow" is exactly what you measure when neither
// shape was under load. Three separate proofs on this estate passed for precisely that reason --
// they could not fail. So the legacy shape (QueryRange over everything, dedupe, scope, then limit)
// is measured alongside the bounded one as a CONTROL, and this test FAILS if the control does not
// itself scale with the store. The control's job is to show the instrument can tell the two apart;
// without it the real assertions certify nothing.
//
// A NOTE ON WHAT IS MEASURED, because the first version of this file got it wrong. The request is
// measured in its REAL shape -- a tenant that owns rows, asking for a page of 100. Measuring a
// tenant that owns nothing looks tidier (it isolates the scan) and is near-vacuous: with nothing
// matched the cost is 40,984 B flat whether the limit is honoured or not, and 0 B if the limit is
// removed, so the headline mutation leaves it green. Measured on the real shape the same mutation
// moves the figure from 70 B/row to 2,394 B/row. Isolation that removes the thing under test is
// not isolation.

// allocFixture builds a MemoryStore of n rows for one tenant, spread one second apart, with
// dupPerTS rows sharing each timestamp so the id tie-break is exercised rather than bypassed.
//
// The id ordering is deliberately the REVERSE of the insertion ordering within a timestamp group,
// so "insertion order" and "(timestamp DESC, id DESC)" are different answers. A paging
// implementation that returns rows in insertion order cannot pass by accident.
func allocFixture(t *testing.T, n, dupPerTS int) *store.MemoryStore {
	t.Helper()
	if dupPerTS < 1 {
		dupPerTS = 1
	}
	s := store.NewMemoryStore()
	base := time.Unix(1_700_000_000, 0).UTC()
	batch := make([]model.Observation, 0, n)
	for i := 0; i < n; i++ {
		batch = append(batch, model.Observation{
			ID:        fmt.Sprintf("row-%06d", n-i),
			Timestamp: base.Add(time.Duration(i/dupPerTS) * time.Second),
			Layer:     model.LayerNetworkEgress,
			Fidelity:  model.FidelityTier("inferred"),
			Labels:    map[string]string{ObservationTenantLabel: "tenant-a"},
		})
	}
	if err := s.Append(context.Background(), batch); err != nil {
		t.Fatal(err)
	}
	return s
}

// Per-request allocation window for a page of 100 over a store where the caller owns every row,
// in bytes per row in the store.
//
// It is a WINDOW and not a ceiling, which is the unusual part and is deliberate. The floor exists
// because the figure is not flat and should not be asserted as flat: QueryPage's dedupe set still
// holds one map entry per matched row (see TestObservationsPageDedupeSetIsStillUnbounded). Pinning
// a floor turns that residual from an unstated fact into a tripwire -- fix it and this test fails,
// pointing at itself, instead of the fix landing silently and the residual being forgotten.
//
// Measured: 91.5 B/row at 10k rows, 70.3 B/row at 100k, which is one small-string map entry. The
// headline mutation (drop the Limit, so the page materialises every matched row the way the
// pre-P1-6 handler did) reads 2,148 then 2,394 B/row, an order of magnitude outside the ceiling.
const (
	pageAllocFloorBytesPerRow   = 30.0
	pageAllocCeilingBytesPerRow = 200.0
)

// TestObservationsPagedReadCostsOneMapEntryPerRow measures the per-request allocation of the two
// reads EAPCI-P1-6 bounded, against the unbounded shape it replaced, over a 10x store range.
//
// Mutation targets, all three confirmed to fire:
//   - drop Limit from the QueryPage call (how the handler used to ask, limit applied after dedupe
//     and tenancy) -> 2,394 B/row, blows the ceiling;
//   - restore the per-row `&t` escape in store/memory.go's Stats -> Stats allocation grows 9.94x;
//   - bound the unbounded control -> the control assertion fires, which is what stops the other
//     two from being measured on a fixture too small to distinguish them.
func TestObservationsPagedReadCostsOneMapEntryPerRow(t *testing.T) {
	sizes := []int{10_000, 50_000, 100_000}
	type sample struct {
		size   int
		page   uint64
		stats  uint64
		legacy uint64
	}
	var samples []sample

	for _, n := range sizes {
		s := allocFixture(t, n, 3)
		ctx := context.Background()

		var pageRows []model.Observation
		pageAlloc := measureAllocChurn(t, func() {
			var err error
			pageRows, err = s.QueryPage(ctx, store.PageQuery{Tenant: "tenant-a", Limit: 100})
			if err != nil {
				t.Fatal(err)
			}
		})
		// Asserted so the measurement cannot be of a request that returned nothing. A page that
		// came back short is a different bug, and would read here as an excellent allocation
		// figure.
		if len(pageRows) != 100 {
			t.Fatalf("store of %d rows: QueryPage returned %d rows, want the requested 100; the "+
				"allocation figure below would be measuring the wrong request", n, len(pageRows))
		}

		var stats store.StoreStats
		statsAlloc := measureAllocChurn(t, func() {
			var err error
			stats, err = s.Stats(ctx, store.StatsQuery{Tenant: "tenant-a"})
			if err != nil {
				t.Fatal(err)
			}
		})
		// The count must stay EXACT. The cheap way to make an aggregate flat is to window it,
		// which silently turns total_observations into a subtotal -- the one number on that
		// endpoint a viewer trusts. A bound that costs correctness is not the fix.
		if stats.TotalObservations != n {
			t.Fatalf("store of %d rows: Stats counted %d; a bounded count must still be exact",
				n, stats.TotalObservations)
		}

		// The BEFORE measurement, kept in the tree so the claim is reproducible rather than
		// quoted. This is what both handlers used to do: read everything, dedupe it, scope it,
		// and only then apply the limit.
		legacyAlloc := measureAllocChurn(t, func() {
			rows, err := s.QueryRange(ctx, store.Query{})
			if err != nil {
				t.Fatal(err)
			}
			rows = store.DedupeByID(rows)
			rows = scopeObservations(rows, "tenant-a", false, 100)
			if len(rows) != 100 {
				t.Fatalf("unbounded baseline returned %d rows, want 100", len(rows))
			}
		})

		perRow := float64(pageAlloc) / float64(n)
		samples = append(samples, sample{size: n, page: pageAlloc, stats: statsAlloc, legacy: legacyAlloc})
		t.Logf("store=%d rows  QueryPage(limit=100)=%d B (%.1f B/row)  Stats=%d B  UNBOUNDED baseline=%d B",
			n, pageAlloc, perRow, statsAlloc, legacyAlloc)

		if perRow > pageAllocCeilingBytesPerRow {
			t.Errorf("at %d rows a page of 100 cost %.1f B/row, above the %.0f B/row ceiling: the "+
				"read is materialising rows it does not return. The pre-P1-6 shape (no Limit, so "+
				"the limit applies after dedupe and tenancy) measures ~2,400 B/row.",
				n, perRow, pageAllocCeilingBytesPerRow)
		}
		if perRow < pageAllocFloorBytesPerRow {
			t.Errorf("at %d rows a page of 100 cost %.1f B/row, BELOW the %.0f B/row floor. This "+
				"is probably good news: the O(matched) dedupe set on the QueryPage path appears "+
				"to have been bounded. Confirm against "+
				"TestObservationsPageDedupeSetIsStillUnbounded, then drop this floor to assert "+
				"flatness outright and delete that test.",
				n, perRow, pageAllocFloorBytesPerRow)
		}
	}

	first, last := samples[0], samples[len(samples)-1]
	grew := float64(last.size) / float64(first.size) // 10x
	const tolerance = 2.0

	// Stats must be flat outright -- it has no dedupe set and no per-row residual, so there is
	// nothing to concede. Measured at 536 B regardless of store size.
	if ratio := float64(last.stats) / float64(first.stats+1); ratio > tolerance {
		t.Errorf("Stats allocation grew %.2fx for a %.0fx larger store (%d B -> %d B): the count "+
			"is allocating per row. The known cause is taking the address of a loop-local "+
			"timestamp on every improvement, which escapes to the heap.",
			ratio, grew, first.stats, last.stats)
	}

	// THE CONTROL. The unbounded shape this card removed must be the thing that scales. If it
	// does not, the fixture cannot distinguish a bounded read from an unbounded one and every
	// assertion above is vacuous -- they would pass against the very defect they exist to catch.
	//
	// Its own blind spot, stated because a control nobody has probed is just another claim.
	// Replacing the baseline with a genuinely flat read (a page for a tenant owning nothing) DOES
	// fire this. Replacing it with the bounded page itself does NOT: that still grows 7.69x for a
	// 10x store, because the dedupe set characterised below is O(matched), which is over the 5x
	// bar. So this control detects a baseline that has gone flat, not one that has merely got
	// cheaper -- and it will get sharper on its own if and when the dedupe residual is fixed.
	if ratio := float64(last.legacy) / float64(first.legacy+1); ratio < grew/tolerance {
		t.Errorf("the unbounded baseline grew only %.2fx for a %.0fx larger store (%d B -> %d B): "+
			"the fixture is too small to tell a bounded read from an unbounded one, so every "+
			"assertion in this test is vacuous", ratio, grew, first.legacy, last.legacy)
	}

	t.Logf("QueryPage is %.0fx cheaper than the unbounded baseline at %d rows (%d B vs %d B)",
		float64(last.legacy)/float64(last.page+1), last.size, last.page, last.legacy)
}

// TestObservationsPageDedupeSetIsStillUnbounded CHARACTERISES a residual on the EAPCI-P1-6 path.
// It asserts what the code does today, not what it should do, and exists to force a decision
// rather than to protect the behaviour.
//
// WHAT IS LEFT. QueryPage bounds the rows it RETURNS to Limit, via a min-heap of exactly that
// capacity. But the dedupe set is a `map[string]struct{}` holding one entry per MATCHED row, so it
// is still O(matched) in live memory for the duration of the request. Both implementations carry
// it: store/memory.go's QueryPage and store/frostdb.go's QueryPage (the `seen` map at line ~837).
// On the estate that OOM-killed signal-ingest -- a 10Gi store holding roughly 2.5 days of
// continuous warden ingest -- a single-tenant unfiltered page still builds a set of every row that
// tenant owns.
//
// MEASURED, by subtracting the scan from the real request: 87.4 B/row at 10k rows and 69.9 B/row
// at 100k, against a scan-only cost of 40,984 B flat at both. The dedupe set is the ENTIRE O(n)
// term; nothing else in the path scales.
//
// WHY IT IS NOT FIXED HERE. It is not a one-line change. A correct bounded dedupe has to decide
// which row wins for a repeated ID, and the current global set already answers that by SCAN ORDER
// rather than by the (timestamp DESC, id DESC) order the endpoint claims -- so bounding it is a
// semantic change to the page contract. That belongs to whoever owns EAPCI-P1-6, not to a
// measurement branch. Deduping within the heap would be O(Limit) and deterministic, and is the
// obvious candidate.
//
// WHEN THIS TEST FAILS, DELETE IT. It fails in both directions on purpose. Below the floor, the
// residual has been fixed: delete this test and drop the floor in the test above. Above the
// ceiling, something new is allocating per matched row. A characterisation that can only pass is a
// waiver, not a test.
func TestObservationsPageDedupeSetIsStillUnbounded(t *testing.T) {
	for _, n := range []int{10_000, 100_000} {
		s := allocFixture(t, n, 3)
		ctx := context.Background()

		matchAll := measureAllocChurn(t, func() {
			if _, err := s.QueryPage(ctx, store.PageQuery{Tenant: "tenant-a", Limit: 100}); err != nil {
				t.Fatal(err)
			}
		})
		// A tenant owning nothing still pays the full scan and filter, and nothing else. The
		// subtraction is what makes the remainder attributable to the dedupe set rather than to
		// the scan.
		scanOnly := measureAllocChurn(t, func() {
			rows, err := s.QueryPage(ctx, store.PageQuery{Tenant: "tenant-none", Limit: 100})
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != 0 {
				t.Fatalf("a tenant owning nothing got %d rows; the scope filter is not applied "+
					"and this subtraction is meaningless", len(rows))
			}
		})

		perRow := (float64(matchAll) - float64(scanOnly)) / float64(n)
		t.Logf("n=%d  match-all=%d B  scan-only=%d B  dedupe term=%.1f B/row",
			n, matchAll, scanOnly, perRow)

		if perRow < pageAllocFloorBytesPerRow {
			t.Errorf("at %d rows the dedupe term is %.1f B/row, below the characterised floor of "+
				"%.0f B/row. This is GOOD NEWS: the O(matched) dedupe set appears to have been "+
				"bounded. Delete this test and drop the floor in "+
				"TestObservationsPagedReadCostsOneMapEntryPerRow.",
				n, perRow, pageAllocFloorBytesPerRow)
		}
		if perRow > pageAllocCeilingBytesPerRow {
			t.Errorf("at %d rows the dedupe term is %.1f B/row, above the characterised ceiling "+
				"of %.0f B/row: something beyond the dedupe set is now allocating per matched row",
				n, perRow, pageAllocCeilingBytesPerRow)
		}
	}
}

// TestObservationsUnderConcurrentPolling measures the quantity the deployment memory limit is
// stated in: heap residency while several clients poll both reads at once, which is the load that
// OOM-killed signal-ingest on 2026-10-06 (the dashboard polls /observations and /store/stats
// together).
//
// READ THE BOUND IT DOES NOT PROVE. This measures the Go heap of THIS PROCESS over a MemoryStore.
// That is a floor on the container's working set and not the whole of it: the FrostDB path adds
// Arrow buffers and a WAL this fixture has none of. The figure is therefore evidence for the
// direction and magnitude of the fix, and is NOT on its own sufficient to lower
// deploy_memory_test.go's 2Gi pin -- that threshold is stated as peak working set of the CONTAINER
// under concurrent polling, which only a cluster measurement can answer.
func TestObservationsUnderConcurrentPolling(t *testing.T) {
	const (
		rows    = 100_000
		pollers = 16
		rounds  = 10
	)
	s := allocFixture(t, rows, 3)
	ctx := context.Background()

	runtime.GC()
	var before, peak runtime.MemStats
	runtime.ReadMemStats(&before)

	done := make(chan error, pollers)
	for p := 0; p < pollers; p++ {
		go func() {
			for i := 0; i < rounds; i++ {
				if _, err := s.QueryPage(ctx, store.PageQuery{Tenant: "tenant-a", Limit: 100}); err != nil {
					done <- err
					return
				}
				if _, err := s.Stats(ctx, store.StatsQuery{Tenant: "tenant-a"}); err != nil {
					done <- err
					return
				}
			}
			done <- nil
		}()
	}
	for p := 0; p < pollers; p++ {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	runtime.ReadMemStats(&peak)

	fixtureBytes := before.HeapAlloc
	t.Logf("concurrent polling: %d pollers x %d rounds over %d rows; fixture heap=%s, "+
		"HeapInuse peak=%s, total churn=%s",
		pollers, rounds, rows, mibStr(fixtureBytes), mibStr(peak.HeapInuse),
		mibStr(peak.TotalAlloc-before.TotalAlloc))

	// 320 requests over a 100k-row store must not have cost the heap a multiple of the store.
	// Under the unbounded shape each request retained a copy of the whole store for its duration,
	// which is how 16 concurrent pollers reached 2 GiB.
	if grown := peak.HeapInuse; grown > fixtureBytes*3+64<<20 {
		t.Errorf("heap in use after concurrent polling is %s against a fixture of %s: the reads "+
			"are still proportional to the store", mibStr(grown), mibStr(fixtureBytes))
	}
}

func mibStr(b uint64) string {
	return fmt.Sprintf("%.1f MiB", float64(b)/(1<<20))
}

// measureAllocChurn returns the bytes fn allocated, via the process-wide cumulative counter with
// the GC quiesced either side.
//
// TotalAlloc is cumulative and monotonic, so this measures allocation CHURN rather than
// instantaneous residency. Churn is the right quantity here: an OOM under concurrent polling is
// made of per-request allocation the collector cannot keep up with, and residency sampled at any
// single instant understates it. It is also the more stable of the two inside a shared test binary.
func measureAllocChurn(t *testing.T, fn func()) uint64 {
	t.Helper()
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	fn()
	runtime.ReadMemStats(&after)
	return after.TotalAlloc - before.TotalAlloc
}
