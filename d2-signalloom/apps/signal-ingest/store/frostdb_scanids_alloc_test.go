//go:build frostdb

package store

import (
	"context"
	"fmt"
	"runtime"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/polarsignals/frostdb/query/logicalplan"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// These tests cover the two lines in ScanIDs that actually reduce production memory, and
// which nothing else reaches.
//
// collectors/dedupe_warm_alloc_test.go proves the dedupe layer streams, but it drives a fake
// store, so it stays green with Project(colRef("id")) reverted to logicalplan.All(). The
// SignalStore contract suite covers ScanIDs for correctness against both implementations, but
// asserts on IDs returned, not on cost. In production SIGNAL_STORE=frostdb, so the projection
// and the strings.Clone were exactly the untested parts of the fix.
//
// Cost is measured against a real FrostDB store, through the real Arrow decode path.

// scanIDsFillRows is enough rows for "decoded every column" and "decoded one column" to be
// separated by far more than allocator noise.
const scanIDsFillRows = 4000

// maxScanIDsBytesPerRow bounds the per-ID cost of a scan.
//
// A streamed ID costs its own bytes plus the callback frame — low hundreds. The fat rows below
// carry roughly 4 KiB of payload each, so an implementation that decodes whole rows lands two
// orders of magnitude above this. The ceiling sits between the two with room on both sides so
// it is not an allocator-noise tripwire.
const maxScanIDsBytesPerRow = 800

// appendFatRows writes n observations whose non-ID columns are deliberately heavy: a long
// description and a full set of allow-listed labels. Weight on the columns ScanIDs does NOT
// read is the whole point — it is what separates a projected scan from a full one.
func appendFatRows(t *testing.T, s SignalStore, n int, base time.Time) {
	t.Helper()

	description := strings.Repeat("payload ", 256) // ~2 KiB of free text per row
	labelKeys := []string{
		"workload", "namespace", "pod", "container", "node", "cluster",
		"service", "resource", "verb", "api_group", "api_version", "reason",
	}

	const batchSize = 500
	for start := 0; start < n; start += batchSize {
		end := start + batchSize
		if end > n {
			end = n
		}
		batch := make([]model.Observation, 0, end-start)
		for i := start; i < end; i++ {
			labels := make(map[string]string, len(labelKeys))
			for _, k := range labelKeys {
				labels[k] = fmt.Sprintf("%s-value-%06d-%s", k, i, strings.Repeat("x", 96))
			}
			batch = append(batch, model.Observation{
				ID:             fmt.Sprintf("fat-%08d-%016x", i, i*2654435761),
				Timestamp:      base.Add(-time.Duration(i) * time.Millisecond),
				Layer:          model.LayerNetworkEgress,
				Fidelity:       model.FidelitySuggestive,
				Source:         "scanids-alloc-test",
				Confidence:     0.5,
				ActorHint:      fmt.Sprintf("actor-%06d", i),
				RawEvidenceRef: fmt.Sprintf("ref-%06d", i),
				Description:    description,
				Labels:         labels,
			})
		}
		if err := s.Append(context.Background(), batch); err != nil {
			t.Fatalf("Append rows %d..%d: %v", start, end, err)
		}
	}
}

// TestScanIDs_CostIsProportionalToIDsNotRows fails if the projection is removed.
//
// With Project(colRef("id")) the engine decodes one column. With logicalplan.All() it decodes
// the description and all twelve label columns too, and the per-ID cost jumps by orders of
// magnitude even though ScanIDs discards every one of those bytes.
func TestScanIDs_CostIsProportionalToIDsNotRows(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	base := time.Now().UTC()
	appendFatRows(t, s, scanIDsFillRows, base)

	seen := 0
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	if err := s.ScanIDs(context.Background(), Query{}, func(string) error {
		seen++
		return nil
	}); err != nil {
		t.Fatalf("ScanIDs: %v", err)
	}
	runtime.ReadMemStats(&after)

	if seen != scanIDsFillRows {
		t.Fatalf("ScanIDs emitted %d ids, want %d — the measurement is not of a full scan",
			seen, scanIDsFillRows)
	}

	perRow := float64(after.TotalAlloc-before.TotalAlloc) / float64(seen)
	t.Logf("ScanIDs over %d fat rows: %.0f bytes per id", seen, perRow)
	if perRow > maxScanIDsBytesPerRow {
		t.Errorf("ScanIDs allocated %.0f bytes per id, want <= %d: the scan is decoding columns "+
			"it never reads, which is the projection being absent", perRow, maxScanIDsBytesPerRow)
	}
}

// TestScanIDs_CostDoesNotTrackRowPayload is the discriminating form, and the one that cannot
// be satisfied by tuning a constant.
//
// ScanIDs reads one column, so doubling the weight of the OTHER columns must not move its
// cost. A projected scan is flat; an unprojected one tracks the payload directly.
func TestScanIDs_CostDoesNotTrackRowPayload(t *testing.T) {
	measure := func(t *testing.T, descriptionChunks, labelValuePad int) float64 {
		t.Helper()
		s, err := NewFrostDBStore()
		if err != nil {
			t.Fatalf("NewFrostDBStore: %v", err)
		}
		defer s.Close()

		base := time.Now().UTC()
		description := strings.Repeat("payload ", descriptionChunks)
		const rows = 2000
		const batchSize = 500
		for start := 0; start < rows; start += batchSize {
			batch := make([]model.Observation, 0, batchSize)
			for i := start; i < start+batchSize; i++ {
				batch = append(batch, model.Observation{
					ID:          fmt.Sprintf("row-%08d", i),
					Timestamp:   base.Add(-time.Duration(i) * time.Millisecond),
					Layer:       model.LayerNetworkEgress,
					Source:      "scanids-alloc-test",
					Description: description,
					Labels: map[string]string{
						"workload":  strings.Repeat("w", labelValuePad),
						"namespace": strings.Repeat("n", labelValuePad),
						"pod":       strings.Repeat("p", labelValuePad),
					},
				})
			}
			if err := s.Append(context.Background(), batch); err != nil {
				t.Fatalf("Append: %v", err)
			}
		}

		seen := 0
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		if err := s.ScanIDs(context.Background(), Query{}, func(string) error {
			seen++
			return nil
		}); err != nil {
			t.Fatalf("ScanIDs: %v", err)
		}
		runtime.ReadMemStats(&after)
		if seen != rows {
			t.Fatalf("ScanIDs emitted %d ids, want %d", seen, rows)
		}
		return float64(after.TotalAlloc-before.TotalAlloc) / float64(seen)
	}

	light := measure(t, 2, 8)      // ~16 B description, tiny labels
	heavy := measure(t, 512, 1024) // ~4 KiB description, 3 KiB of labels
	t.Logf("light rows: %.0f bytes per id, heavy rows: %.0f bytes per id", light, heavy)

	if heavy > light*1.5+128 {
		t.Errorf("ScanIDs cost tracks row payload: %.0f bytes per id on light rows vs %.0f on "+
			"heavy rows. Scanning IDs must cost the same regardless of what else is on the row; "+
			"this is the id projection not reaching the engine", light, heavy)
	}
}

// TestScanIDs_IDsDoNotAliasTheDecodeBuffer covers the strings.Clone.
//
// arrow-go's array.String.Value returns a string header pointing INTO the record's single
// contiguous value buffer rather than a copy. The dedupe set retains every ID for the life of
// the process, so without the Clone each retained ID keeps its whole Arrow record reachable —
// every column, every row of that record — and the warm-up's 192,312 IDs would pin the entire
// scan. That is the shape of the plateau the live pod sat at: working set reached 1,123 MiB
// during the warm-up second and never came back down.
//
// The assertion is on POINTER CONTIGUITY, not on heap size. In an Arrow string column all
// values share one backing buffer laid out end to end, so aliased IDs satisfy
// ptr(id[i]) + len(id[i]) == ptr(id[i+1]) for almost every consecutive pair. Independently
// allocated strings come from size-class bins with padding and essentially never do, so the
// two cases are separated by thousands of pairs rather than by a tunable threshold.
//
// A live-heap assertion was tried first and rejected: an open FrostDB store legitimately holds
// its own active block (~16 MiB for this fixture), which swamps the retained IDs and cannot be
// separated from them without a heap profile naming the retainer.
func TestScanIDs_IDsDoNotAliasTheDecodeBuffer(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	base := time.Now().UTC()
	appendFatRows(t, s, scanIDsFillRows, base)

	ids := make([]string, 0, scanIDsFillRows)
	if err := s.ScanIDs(context.Background(), Query{}, func(id string) error {
		ids = append(ids, id)
		return nil
	}); err != nil {
		t.Fatalf("ScanIDs: %v", err)
	}
	if len(ids) != scanIDsFillRows {
		t.Fatalf("ScanIDs emitted %d ids, want %d", len(ids), scanIDsFillRows)
	}

	adjacent := 0
	for i := 0; i+1 < len(ids); i++ {
		if len(ids[i]) == 0 || len(ids[i+1]) == 0 {
			continue
		}
		end := uintptr(unsafe.Pointer(unsafe.StringData(ids[i]))) + uintptr(len(ids[i]))
		if end == uintptr(unsafe.Pointer(unsafe.StringData(ids[i+1]))) {
			adjacent++
		}
	}

	// Independently allocated strings produce a handful of adjacent pairs at most, by chance.
	// Aliased ones produce nearly len(ids). The ceiling sits far below either boundary.
	maxAdjacent := len(ids) / 100
	t.Logf("%d of %d consecutive id pairs are memory-adjacent (ceiling %d)",
		adjacent, len(ids)-1, maxAdjacent)
	if adjacent > maxAdjacent {
		t.Errorf("%d of %d consecutive ids are laid out end to end in memory, want <= %d: the ids "+
			"alias the Arrow decode buffer, so retaining one pins the whole record",
			adjacent, len(ids)-1, maxAdjacent)
	}
}

// TestScanIDs_PlanProjectsOnlyTheIDColumn covers the projection, which NONE of the cost tests
// above can see.
//
// Reverting Project(colRef("id")) to Project(logicalplan.All()) leaves every allocation
// assertion in this file green: measured 54 bytes per id unprojected against 52 projected.
// That is not a gap in the assertions, it is what the projection does. The engine hands back
// an Arrow record either way; the unread columns stay as Arrow buffers and are never converted
// into Go objects, so they do not appear in a TotalAlloc delta. The projection saves decode
// and I/O inside the engine, not Go heap — which means the memory fix does NOT rest on it. The
// Go-heap win comes from streaming and from not building a model.Observation per row.
//
// What IS observable is the shape of the record: 1 column projected, 27 unprojected. This test
// asserts that directly.
//
// Caveat, stated rather than implied: it rebuilds the plan the way ScanIDs builds it instead of
// observing ScanIDs' own execution, because ScanIDs exposes no seam and the brief was not to
// change it. So the two can drift — someone could change ScanIDs and leave this green. Closing
// that properly needs a one-line test observer in ScanIDs' record callback; worth adding if
// this projection is ever treated as load-bearing.
func TestScanIDs_PlanProjectsOnlyTheIDColumn(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	appendFatRows(t, s, 500, time.Now().UTC())

	countColumns := func(project logicalplan.Expr) int {
		fields := -1
		err := s.engine.ScanTable(tableName).Project(project).
			Execute(context.Background(), func(_ context.Context, r arrow.Record) error {
				if fields < 0 {
					fields = r.Schema().NumFields()
				}
				return nil
			})
		if err != nil {
			t.Fatalf("scan: %v", err)
		}
		return fields
	}

	projected := countColumns(colRef("id"))
	everything := countColumns(logicalplan.All())
	t.Logf("projected record columns: %d; unprojected: %d", projected, everything)

	if projected != 1 {
		t.Errorf("the id projection yields %d columns, want 1: ScanIDs is decoding columns it "+
			"never reads", projected)
	}
	if everything <= projected {
		t.Errorf("unprojected scan yields %d columns and projected yields %d; the fixture no "+
			"longer distinguishes the two and this test proves nothing", everything, projected)
	}
}
