//go:build frostdb

package store

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// These tests pin what made signal-ingest's memory track the size of its store rather than the
// size of any request (kind-osramp, 2026-10-15: 22 persisted blocks, 485 MB of Parquet, 28
// restarts, OOM-killed at 2 GiB while nearly idle).
//
// The mechanism, measured here rather than assumed: FrostDB's physical planner fans every scan
// out to runtime.GOMAXPROCS(0) consumer goroutines, captured once at package init
// (query/physicalplan/physicalplan.go, concurrencyHardcoded). Each consumer converts one Parquet
// row group at a time, holding a 5 MiB bufio reader per projected column chunk
// (parquet-go getBufioReader; frostdb opens blocks with ReadBufferSize 5 MiB) plus the decoded
// Arrow builders. A heap profile taken mid-scan puts 94% of live heap under
// Table.Iterator -> ParquetConverter.Convert. So a scan's peak is
// min(row groups it touches, GOMAXPROCS) x per-row-group cost. signal-ingest has no CPU limit,
// so on a 24-core kind node GOMAXPROCS is 24, and as the store grew past 24 row groups every
// unbounded scan saturated all 24 consumers. Measured on the fixture below, live heap after a
// forced GC mid-scan: 206 MiB at GOMAXPROCS=24, 8.9 MiB at GOMAXPROCS=2, same store, same scan.
//
// Two seams bound it. The image sets GOMAXPROCS (Dockerfile), which caps the fan-out of every
// scan that still touches the whole store. And the request paths the dashboard polls stop
// touching the whole store: QueryPage reads newest-first in time slices, and a limited
// QueryRange stops at its limit.

const (
	boundedRowsPerBlock = 2000
	boundedSmallBlocks  = 4
	boundedLargeBlocks  = 24
)

// buildBlockedStore persists oldBlocks blocks of rows timestamped three days before now, then one
// block of 500 rows from the last ten minutes. The old blocks are the store growing; the newest
// block is what a dashboard page asks for.
func buildBlockedStore(t *testing.T, oldBlocks int, now time.Time) *FrostDBStore {
	t.Helper()
	s, err := NewFrostDBStoreWithBucket(t.TempDir(), WithManualFlush(), WithSegmentPseudonymiser(testPseudonymiser(t)))
	if err != nil {
		t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	s.now = func() time.Time { return now }

	desc := strings.Repeat("payload ", 128)
	row := func(prefix string, i int, ts time.Time) model.Observation {
		return model.Observation{
			ID: fmt.Sprintf("%s-%08d", prefix, i), Timestamp: ts,
			Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "bounded-memory",
			Confidence: 0.5, ActorHint: fmt.Sprintf("actor-%d", i%50), RawEvidenceRef: fmt.Sprintf("ref-%s-%d", prefix, i),
			Description: desc,
			Labels:      map[string]string{"tenant_id": "tenant-demo", "workload": fmt.Sprintf("w-%d-%s", i, strings.Repeat("x", 64))},
		}
	}
	base := now.Add(-72 * time.Hour)
	n := 0
	for b := 0; b < oldBlocks; b++ {
		batch := make([]model.Observation, 0, boundedRowsPerBlock)
		for i := 0; i < boundedRowsPerBlock; i++ {
			batch = append(batch, row("old", n, base.Add(time.Duration(n)*time.Second)))
			n++
		}
		if err := s.Append(context.Background(), batch); err != nil {
			t.Fatalf("Append: %v", err)
		}
		if err := s.Flush(context.Background()); err != nil {
			t.Fatalf("Flush: %v", err)
		}
	}
	batch := make([]model.Observation, 0, 500)
	for i := 0; i < 500; i++ {
		batch = append(batch, row("new", i, now.Add(-10*time.Minute+time.Duration(i)*time.Millisecond)))
	}
	if err := s.Append(context.Background(), batch); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := s.Flush(context.Background()); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	return s
}

// allocDuring returns the bytes allocated by fn, the minimum of three trials. Background
// goroutines can only add to a reading, so the minimum is an upper bound on fn's own cost.
func allocDuring(fn func()) uint64 {
	var best uint64
	for trial := 0; trial < 3; trial++ {
		runtime.GC()
		var a, b runtime.MemStats
		runtime.ReadMemStats(&a)
		fn()
		runtime.ReadMemStats(&b)
		if d := b.TotalAlloc - a.TotalAlloc; trial == 0 || d < best {
			best = d
		}
	}
	return best
}

const mib = 1 << 20

// TestFrostDB_QueryPageCostDoesNotGrowWithOlderBlocks: the dashboard's page (newest 101, no
// lower bound) must cost the page. Before slicing it was one scan with no timestamp predicate,
// so its cost tracked every persisted block: 108.8 MiB allocated at 4 old blocks of 3000 rows,
// 368.9 MiB at 16, 801 MiB at 32. Sliced, it is ~11 MiB at all three.
//
// This runs at the test process's own GOMAXPROCS on purpose: the slice bound does not depend on
// the image's GOMAXPROCS setting.
func TestFrostDB_QueryPageCostDoesNotGrowWithOlderBlocks(t *testing.T) {
	now := time.Now().UTC()
	measure := func(blocks int) uint64 {
		s := buildBlockedStore(t, blocks, now)
		var got int
		cost := allocDuring(func() {
			rows, err := s.QueryPage(context.Background(), PageQuery{Limit: 101, AllTenants: true})
			if err != nil {
				t.Fatalf("QueryPage: %v", err)
			}
			got = len(rows)
		})
		if got != 101 {
			t.Fatalf("QueryPage returned %d rows, want 101", got)
		}
		return cost
	}
	small, large := measure(boundedSmallBlocks), measure(boundedLargeBlocks)
	t.Logf("QueryPage(limit=101) allocated %.1f MiB over %d old blocks, %.1f MiB over %d",
		float64(small)/mib, boundedSmallBlocks, float64(large)/mib, boundedLargeBlocks)
	if float64(large) > 1.5*float64(small)+4*mib {
		t.Errorf("QueryPage cost grew from %.1f MiB to %.1f MiB when only OLDER blocks were added: "+
			"the read is scanning blocks the page cannot come from", float64(small)/mib, float64(large)/mib)
	}
}

// TestFrostDB_QueryPageSlicedMatchesFullScan pins that slicing changed the cost and nothing else.
// The fixture puts rows in the future, across multi-day gaps, at slice-boundary instants, in two
// tenants and two layers, with duplicate IDs; every page walked by cursor must equal the same
// page cut from a brute-force sort of every row.
func TestFrostDB_QueryPageSlicedMatchesFullScan(t *testing.T) {
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	s, err := NewFrostDBStoreWithBucket(t.TempDir(), WithManualFlush(), WithSegmentPseudonymiser(testPseudonymiser(t)))
	if err != nil {
		t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
	}
	defer s.Close()
	s.now = func() time.Time { return now }

	offsets := []time.Duration{
		+2 * time.Hour, 0, -time.Nanosecond, -time.Hour, -time.Hour - time.Nanosecond,
		-90 * time.Minute, -3 * time.Hour, -7 * time.Hour, -31 * time.Hour, -4 * 24 * time.Hour,
		-40 * 24 * time.Hour, -400 * 24 * time.Hour, -3 * 365 * 24 * time.Hour,
	}
	var all []model.Observation
	n := 0
	for _, off := range offsets {
		for k := 0; k < 3; k++ {
			tenant := "tenant-a"
			if n%3 == 0 {
				tenant = "tenant-b"
			}
			layer := model.LayerNetworkEgress
			if n%4 == 0 {
				layer = model.LayerIdentityAuth
			}
			all = append(all, model.Observation{
				ID: fmt.Sprintf("obs-%03d", n), Timestamp: now.Add(off), Layer: layer,
				Fidelity: model.FidelitySuggestive, Source: "slice-equivalence", RawEvidenceRef: fmt.Sprintf("ref-%d", n),
				Labels: map[string]string{"tenant_id": tenant},
			})
			n++
		}
	}
	// Two exact duplicates of stored rows, written into a later block.
	dups := []model.Observation{all[4], all[20]}
	for i, chunk := range [][]model.Observation{all[:len(all)/2], all[len(all)/2:], dups} {
		if err := s.Append(context.Background(), chunk); err != nil {
			t.Fatalf("Append chunk %d: %v", i, err)
		}
		if err := s.Flush(context.Background()); err != nil {
			t.Fatalf("Flush chunk %d: %v", i, err)
		}
	}

	expect := func(q PageQuery) []string {
		var ids []string
		var keep []model.Observation
		for _, o := range all {
			if !q.After.IsZero() && o.Timestamp.Before(q.After) {
				continue
			}
			if !q.Before.IsZero() && !o.Timestamp.Before(q.Before) {
				continue
			}
			if len(q.Layers) > 0 && o.Layer != q.Layers[0] {
				continue
			}
			if !q.AllTenants && o.Labels["tenant_id"] != q.Tenant {
				continue
			}
			keep = append(keep, o)
		}
		sortObservations(keep)
		for _, o := range keep {
			ids = append(ids, o.ID)
		}
		return ids
	}
	walk := func(q PageQuery) []string {
		var ids []string
		for pages := 0; pages < 100; pages++ {
			rows, err := s.QueryPage(context.Background(), q)
			if err != nil {
				t.Fatalf("QueryPage: %v", err)
			}
			for _, o := range rows {
				ids = append(ids, o.ID)
			}
			if len(rows) < q.Limit {
				return ids
			}
			last := rows[len(rows)-1]
			q.CursorTimestamp, q.CursorID = last.Timestamp, last.ID
		}
		t.Fatal("cursor walk did not terminate")
		return nil
	}

	cases := map[string]PageQuery{
		"all tenants":     {Limit: 7, AllTenants: true},
		"one tenant":      {Limit: 5, Tenant: "tenant-b"},
		"after bound":     {Limit: 4, AllTenants: true, After: now.Add(-31 * time.Hour)},
		"before bound":    {Limit: 6, AllTenants: true, Before: now.Add(-time.Hour)},
		"layer":           {Limit: 3, AllTenants: true, Layers: []model.Layer{model.LayerIdentityAuth}},
		"page of one":     {Limit: 1, AllTenants: true, After: now.Add(-4 * 24 * time.Hour)},
		"larger than all": {Limit: 500, AllTenants: true},
	}
	for name, q := range cases {
		t.Run(name, func(t *testing.T) {
			want, got := expect(q), walk(q)
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("paged read differs from the full sort\n got: %v\nwant: %v", got, want)
			}
		})
	}
}

// --- Fan-out bound: measured in a child process, because FrostDB reads GOMAXPROCS once at init.

const boundedChildEnv = "SIGNAL_INGEST_BOUNDED_MEMORY_CHILD"

// TestBoundedMemoryChild is the child half of the fan-out tests. It does nothing unless the
// parent set boundedChildEnv to "<case>:<blocks>", and then prints one RESULT line.
func TestBoundedMemoryChild(t *testing.T) {
	spec := os.Getenv(boundedChildEnv)
	if spec == "" {
		t.Skip("child process only")
	}
	parts := strings.SplitN(spec, ":", 2)
	blocks, err := strconv.Atoi(parts[1])
	if err != nil {
		t.Fatalf("bad child spec %q", spec)
	}
	now := time.Now().UTC()
	s := buildBlockedStore(t, blocks, now)
	ctx := context.Background()

	var result uint64
	switch parts[0] {
	case "fullscan-peak":
		// Live heap, after a forced GC, sampled through a full ScanObservations: what the scan
		// actually holds, not what it has churned through.
		var ms runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&ms)
		base := ms.HeapAlloc
		rows := 0
		err := s.ScanObservations(ctx, Query{}, func(*model.Observation) error {
			rows++
			if rows%500 == 0 {
				runtime.GC()
				runtime.ReadMemStats(&ms)
				if ms.HeapAlloc > base && ms.HeapAlloc-base > result {
					result = ms.HeapAlloc - base
				}
			}
			return nil
		})
		if err != nil {
			t.Fatalf("ScanObservations: %v", err)
		}
	case "rangelimit-alloc":
		result = allocDuring(func() {
			rows, err := s.QueryRange(ctx, Query{Limit: 200})
			if err != nil || len(rows) != 200 {
				t.Fatalf("QueryRange: %v, %d rows", err, len(rows))
			}
		})
	default:
		t.Fatalf("unknown child case %q", parts[0])
	}
	fmt.Printf("RESULT %d GOMAXPROCS=%d\n", result, runtime.GOMAXPROCS(0))
}

func runBoundedChild(t *testing.T, gomaxprocs, kase string, blocks int) uint64 {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestBoundedMemoryChild$", "-test.count=1")
	cmd.Env = append(os.Environ(), boundedChildEnv+"="+kase+":"+strconv.Itoa(blocks), "GOMAXPROCS="+gomaxprocs)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("child %s:%d GOMAXPROCS=%s: %v\n%s", kase, blocks, gomaxprocs, err, out)
	}
	m := regexp.MustCompile(`RESULT (\d+) GOMAXPROCS=(\d+)`).FindStringSubmatch(string(out))
	if m == nil {
		t.Fatalf("child printed no RESULT line:\n%s", out)
	}
	if m[2] != gomaxprocs {
		t.Fatalf("child ran with GOMAXPROCS=%s, asked for %s", m[2], gomaxprocs)
	}
	v, _ := strconv.ParseUint(m[1], 10, 64)
	return v
}

// imageGOMAXPROCS is the GOMAXPROCS the signal-ingest image sets. The Dockerfile is the seam:
// the Deployment carries no CPU limit, so without it the Go runtime takes the node's core count.
func imageGOMAXPROCS(t *testing.T) string {
	t.Helper()
	f, err := os.Open("../Dockerfile")
	if err != nil {
		t.Fatalf("open Dockerfile: %v", err)
	}
	defer f.Close()
	re := regexp.MustCompile(`^ENV\s+GOMAXPROCS=(\d+)\s*$`)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := re.FindStringSubmatch(strings.TrimSpace(sc.Text())); m != nil {
			return m[1]
		}
	}
	t.Fatal("the signal-ingest Dockerfile sets no ENV GOMAXPROCS: FrostDB will fan every scan out " +
		"to one consumer per node core, and a full-store scan's peak heap grows with the store")
	return ""
}

// TestFrostDB_FullScanPeakIsBoundedAtTheImageGOMAXPROCS: a scan that must read every block
// (/store/stats, correlation, subject export) holds a bounded amount of live heap however many
// blocks the store has, at the GOMAXPROCS the image runs with. The node-core control is run too
// and must grow, or this test is not measuring the fan-out at all.
func TestFrostDB_FullScanPeakIsBoundedAtTheImageGOMAXPROCS(t *testing.T) {
	procs := imageGOMAXPROCS(t)
	small := runBoundedChild(t, procs, "fullscan-peak", boundedSmallBlocks)
	large := runBoundedChild(t, procs, "fullscan-peak", boundedLargeBlocks)
	t.Logf("GOMAXPROCS=%s: full-scan live peak %.1f MiB at %d blocks, %.1f MiB at %d",
		procs, float64(small)/mib, boundedSmallBlocks, float64(large)/mib, boundedLargeBlocks)

	ctrlSmall := runBoundedChild(t, "24", "fullscan-peak", boundedSmallBlocks)
	ctrlLarge := runBoundedChild(t, "24", "fullscan-peak", boundedLargeBlocks)
	t.Logf("GOMAXPROCS=24 (control): %.1f MiB at %d blocks, %.1f MiB at %d",
		float64(ctrlSmall)/mib, boundedSmallBlocks, float64(ctrlLarge)/mib, boundedLargeBlocks)

	if float64(ctrlLarge) < 2*float64(ctrlSmall) {
		t.Fatalf("control did not grow with the store (%.1f -> %.1f MiB): the fixture no longer "+
			"exercises FrostDB's scan fan-out, so the bounded reading below proves nothing",
			float64(ctrlSmall)/mib, float64(ctrlLarge)/mib)
	}
	if float64(large) > 1.5*float64(small)+8*mib {
		t.Errorf("at the image's GOMAXPROCS=%s a full scan's live peak grew from %.1f to %.1f MiB "+
			"with the store", procs, float64(small)/mib, float64(large)/mib)
	}
}

// TestFrostDB_QueryRangeLimitStopsTheScan: QueryRange{Limit: 200} with no time bound (the
// authorization handlers' evidence lookup) must stop reading once it has 200 rows. Before, it
// discarded every later record but kept scanning: 50 MiB allocated at 4 blocks, 565 MiB at 32,
// for the same 200 rows.
func TestFrostDB_QueryRangeLimitStopsTheScan(t *testing.T) {
	procs := imageGOMAXPROCS(t)
	small := runBoundedChild(t, procs, "rangelimit-alloc", boundedSmallBlocks)
	large := runBoundedChild(t, procs, "rangelimit-alloc", boundedLargeBlocks)
	t.Logf("GOMAXPROCS=%s: QueryRange(limit=200) allocated %.1f MiB at %d blocks, %.1f MiB at %d",
		procs, float64(small)/mib, boundedSmallBlocks, float64(large)/mib, boundedLargeBlocks)
	if float64(large) > 1.5*float64(small)+8*mib {
		t.Errorf("QueryRange(limit=200) cost grew from %.1f to %.1f MiB with the store: the scan "+
			"is not stopping at its limit", float64(small)/mib, float64(large)/mib)
	}
}
