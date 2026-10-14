// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Boot warm-up OOM-killed signal-ingest on kind-osramp (2026-10-13, exit 137, 15 restarts,
// worst container lifetime 21 seconds). Warm reads nothing but rows[i].ID, but it reached
// those IDs through QueryRange, which materialises a full model.Observation per row —
// every string column plus an unconditional Labels map (store/frostdb.go
// recordToObservations). With 192,312 rows in the 24h window the pod went from 147 MiB to
// 1,123 MiB inside the warm-up second and stayed there, leaving under 1 GiB of a 2Gi limit
// for everything else.
//
// The bound the old comment claimed — "bounded twice, by the window and by the capacity" —
// bounds ROWS, not bytes. Capacity is 1,000,000. These tests pin the property that was
// missing: the cost of warming must be a function of how many IDs are warmed, and must not
// be a function of what else is stored on those rows.

// columnarFakeStore models how a columnar store actually answers a read.
//
// It holds rows in decomposed form and BUILDS the observations QueryRange returns, which is
// what FrostDB does: segments are Arrow/Parquet columns, and recordToObservations allocates a
// fresh model.Observation — and a fresh map[string]string — for every row of every scan. A
// fake that handed back a pre-built slice would allocate nothing and would measure the fake
// instead of the code under test.
//
// ScanIDs serves the same rows from the same state without materialising any of it, which is
// the contract store.SignalStore implementations are required to honour.
type columnarFakeStore struct {
	ids         []string
	timestamps  []time.Time
	description string
	labelKeys   []string
	labelVals   []string

	queryRangeCalls       int
	scanIDsCalls          int
	scanObservationsCalls int
}

// newColumnarFakeStore builds n rows whose payload weight is set by descriptionBytes and
// labelCount, so a test can hold the ID count fixed and vary only the weight of the columns
// the warm path does not read.
func newColumnarFakeStore(n, descriptionBytes, labelCount int, base time.Time) *columnarFakeStore {
	s := &columnarFakeStore{
		ids:         make([]string, n),
		timestamps:  make([]time.Time, n),
		description: strings.Repeat("d", descriptionBytes),
		labelKeys:   make([]string, labelCount),
		labelVals:   make([]string, labelCount),
	}
	for i := range s.ids {
		s.ids[i] = fmt.Sprintf("obs-%016x-%016x", i, i*2654435761)
		s.timestamps[i] = base.Add(-time.Duration(i) * time.Millisecond)
	}
	for i := range s.labelKeys {
		s.labelKeys[i] = fmt.Sprintf("label_key_%02d", i)
		s.labelVals[i] = fmt.Sprintf("label-value-%02d-%s", i, strings.Repeat("v", 24))
	}
	return s
}

func (s *columnarFakeStore) rowAt(i int) model.Observation {
	// A fresh copy per row, because decoding a column into a Go string is what costs memory.
	// stringAt's *array.Binary and dictionary branches copy exactly like this. Its
	// *array.String branch is worse and is NOT modelled here: arrow-go returns a string
	// aliasing the record's buffer, so every ID the dedupe set retains pins the entire Arrow
	// record it came from — all columns, for the life of the process. The fake therefore
	// understates production; it never overstates it.
	o := model.Observation{
		ID:                s.ids[i],
		Timestamp:         s.timestamps[i],
		Layer:             model.Layer("cloud"),
		Fidelity:          model.FidelityTier("observed"),
		Source:            "awslogs/cloudtrail/eu-west-2",
		Confidence:        0.9,
		Description:       strings.Clone(s.description),
		SchemaVersion:     "signalloom.observations/v2",
		HMACActorID:       "b3a1c0de" + s.ids[i],
		HMACPrincipalID:   "c4b2d1ef" + s.ids[i],
		HMACSessionID:     "d5c3e2f0" + s.ids[i],
		HMACActorHint:     "e6d4f301" + s.ids[i],
		EvidenceRefDigest: "f7e5a412" + s.ids[i],
		ImpersonatedUser:  "",
		Labels:            make(map[string]string, len(s.labelKeys)),
	}
	for j := range s.labelKeys {
		o.Labels[s.labelKeys[j]] = s.labelVals[j]
	}
	return o
}

func (s *columnarFakeStore) matches(i int, q store.Query) bool {
	if !q.After.IsZero() && s.timestamps[i].Before(q.After) {
		return false
	}
	if !q.Before.IsZero() && !s.timestamps[i].Before(q.Before) {
		return false
	}
	return true
}

func (s *columnarFakeStore) Append(context.Context, []model.Observation) error { return nil }

func (s *columnarFakeStore) QueryRange(_ context.Context, q store.Query) ([]model.Observation, error) {
	s.queryRangeCalls++
	var out []model.Observation
	for i := range s.ids {
		if !s.matches(i, q) {
			continue
		}
		out = append(out, s.rowAt(i))
		if q.Limit > 0 && len(out) >= q.Limit {
			break
		}
	}
	return out, nil
}

func (s *columnarFakeStore) ScanIDs(_ context.Context, q store.Query, fn func(id string) error) error {
	s.scanIDsCalls++
	emitted, skipped := 0, 0
	for i := range s.ids {
		if !s.matches(i, q) {
			continue
		}
		if skipped < q.Offset {
			skipped++
			continue
		}
		if err := fn(s.ids[i]); err != nil {
			return err
		}
		emitted++
		if q.Limit > 0 && emitted >= q.Limit {
			break
		}
	}
	return nil
}

// ScanObservations materialises rows the same way QueryRange does, so a caller that streams
// whole observations is still measured honestly against one that streams IDs.
func (s *columnarFakeStore) ScanObservations(_ context.Context, q store.Query, fn func(o *model.Observation) error) error {
	s.scanObservationsCalls++
	emitted, skipped := 0, 0
	for i := range s.ids {
		if !s.matches(i, q) {
			continue
		}
		if skipped < q.Offset {
			skipped++
			continue
		}
		row := s.rowAt(i)
		if err := fn(&row); err != nil {
			return err
		}
		emitted++
		if q.Limit > 0 && emitted >= q.Limit {
			break
		}
	}
	return nil
}

func (s *columnarFakeStore) ObservationStats(context.Context, store.Query) (store.ObservationStats, error) {
	// Warm never asks for stats; a zero value with initialised maps keeps the fake a valid
	// SignalStore without inventing numbers a test might read.
	return store.ObservationStats{ByLayer: map[string]int{}, ByFidelity: map[string]int{}}, nil
}

// QueryPage and Stats are the paged/aggregate reads GET /api/v1/observations and
// /api/v1/store/stats use. Warm has no business with either: it must stream IDs. Failing loudly
// rather than returning an empty page means a Warm that regressed onto the paging path breaks
// this test instead of warming an empty dedupe set and passing.
func (s *columnarFakeStore) QueryPage(context.Context, store.PageQuery) ([]model.Observation, error) {
	return nil, errors.New("columnarFakeStore: QueryPage is not a warm-up read; Warm must use ScanIDs")
}

func (s *columnarFakeStore) Stats(context.Context, store.StatsQuery) (store.StoreStats, error) {
	return store.StoreStats{}, errors.New("columnarFakeStore: Stats is not a warm-up read")
}

func (s *columnarFakeStore) DropPartition(context.Context, time.Time) error { return nil }
func (s *columnarFakeStore) Close() error                                   { return nil }

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
}

// warmBytesPerRow reports bytes allocated per warmed ID.
//
// TotalAlloc is cumulative and monotonic, so it measures everything the call allocated
// whether or not the collector reclaimed it — which is the right measure here. The peak that
// killed the pod was transient allocation the GC had not yet returned to the OS, so a
// live-heap measurement would have reported the defect as absent.
func warmBytesPerRow(t *testing.T, rows, descriptionBytes, labelCount int) float64 {
	t.Helper()

	base := time.Now()
	st := newColumnarFakeStore(rows, descriptionBytes, labelCount, base)
	// Capacity above the row count so eviction never trims the set and the measurement is of
	// warming, not of eviction.
	d := NewDeduper(rows * 2)

	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	if err := d.Warm(context.Background(), st, time.Hour, base, discardLogger()); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	runtime.ReadMemStats(&after)

	if got := d.WarmedIDs(); got != uint64(rows) {
		t.Fatalf("warmed %d IDs, want %d — the measurement is not of a full warm-up", got, rows)
	}
	return float64(after.TotalAlloc-before.TotalAlloc) / float64(rows)
}

// maxWarmBytesPerRow is the ceiling on the per-ID cost of a warm-up.
//
// The set legitimately retains, per ID, the ID string (~40 B), a container/list element
// (~56 B) and a map entry (~70 B) — a few hundred bytes. The ceiling is set well above that
// and far below what materialising a row costs, so it fails loudly if the warm path ever
// goes back to reading whole observations.
const maxWarmBytesPerRow = 600

func TestWarmAllocatesPerIDNotPerRowPayload(t *testing.T) {
	got := warmBytesPerRow(t, 20_000, 512, 6)
	t.Logf("warm-up cost: %.0f bytes/row", got)
	if got > maxWarmBytesPerRow {
		t.Errorf("warm-up allocated %.0f bytes per warmed ID, want <= %d; the warm path is "+
			"materialising row payload it never reads", got, maxWarmBytesPerRow)
	}
}

// TestWarmCostIsIndependentOfRowPayload is the discriminating test.
//
// Warm reads one field. Its cost must therefore not move when the OTHER columns get heavier.
// The materialising implementation scales directly with description length and label count;
// a streaming one does not move at all.
func TestWarmCostIsIndependentOfRowPayload(t *testing.T) {
	const rows = 20_000

	light := warmBytesPerRow(t, rows, 64, 2)
	heavy := warmBytesPerRow(t, rows, 64*1024, 40)
	t.Logf("light payload: %.0f bytes/row, heavy payload: %.0f bytes/row", light, heavy)

	// A 1024x heavier description and 20x the labels must not change the cost of warming at
	// all, so the tolerance is tight. It has to be: the fixed per-observation cost of
	// materialising a row is itself large enough that a loose ratio passes on the broken
	// implementation — measured 2635 B/row light vs 3540 B/row at an 8 KiB description, a
	// ratio of only 1.34. The defect shows as an absolute blow-up, not a gentle slope.
	if heavy > light*1.25+64 {
		t.Errorf("warm-up cost tracks row payload: %.0f bytes/row on light rows vs %.0f on heavy "+
			"rows; warming must cost the same per ID regardless of what else is on the row",
			light, heavy)
	}
}

// TestWarmCostDoesNotGrowWithRowCount guards the other axis: per-ID cost must stay flat as
// the window fills up, so a pod that has been ingesting for a day costs the same per ID as
// one that has been ingesting for a minute.
//
// This one passes on the broken implementation too (measured 2225 -> 2706 B/row across an 8x
// window), and it is kept deliberately rather than presented as proof of the defect: the
// 2026-10-13 OOM was linear in rows, not quadratic, so this axis was never the fault. It is
// here to catch a different regression — an accidental O(n^2) in the streaming rewrite, where
// per-ID cost climbs with window depth.
func TestWarmCostDoesNotGrowWithRowCount(t *testing.T) {
	small := warmBytesPerRow(t, 5_000, 512, 6)
	large := warmBytesPerRow(t, 40_000, 512, 6)
	t.Logf("5k rows: %.0f bytes/row, 40k rows: %.0f bytes/row", small, large)

	if large > small*1.5+128 {
		t.Errorf("per-ID warm cost grew from %.0f to %.0f bytes/row over an 8x larger window; "+
			"warming must be linear in IDs with a flat per-ID cost", small, large)
	}
}

// TestWarmDoesNotMaterialiseObservations pins the mechanism rather than the symptom: if the
// warm path ever calls QueryRange again, the bytes-per-row tests above would start passing or
// failing on allocator noise, and this one says plainly which door was used.
func TestWarmDoesNotMaterialiseObservations(t *testing.T) {
	base := time.Now()
	st := newColumnarFakeStore(1_000, 512, 6, base)
	d := NewDeduper(10_000)

	if err := d.Warm(context.Background(), st, time.Hour, base, discardLogger()); err != nil {
		t.Fatalf("Warm: %v", err)
	}

	if st.queryRangeCalls != 0 {
		t.Errorf("Warm called QueryRange %d times; it must stream IDs via ScanIDs and never "+
			"materialise observations", st.queryRangeCalls)
	}
	if st.scanIDsCalls != 1 {
		t.Errorf("Warm called ScanIDs %d times, want exactly 1", st.scanIDsCalls)
	}
	if got := d.WarmedIDs(); got != 1_000 {
		t.Errorf("warmed %d IDs, want 1000", got)
	}
}

// TestWarmHonoursCapacityWhileStreaming keeps the streaming rewrite from quietly changing
// which IDs end up in the set: the read is still bounded by capacity, and the set is still
// trimmed to capacity afterwards.
func TestWarmHonoursCapacityWhileStreaming(t *testing.T) {
	base := time.Now()
	st := newColumnarFakeStore(5_000, 128, 2, base)
	d := NewDeduper(1_000)

	if err := d.Warm(context.Background(), st, time.Hour, base, discardLogger()); err != nil {
		t.Fatalf("Warm: %v", err)
	}

	if got := d.Tracked(); got != 1_000 {
		t.Errorf("tracked %d IDs after warming a 5000-row store at capacity 1000, want 1000", got)
	}
}

func BenchmarkDeduperWarm(b *testing.B) {
	base := time.Now()
	const rows = 20_000

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		st := newColumnarFakeStore(rows, 512, 6, base)
		d := NewDeduper(rows * 2)
		b.StartTimer()

		if err := d.Warm(context.Background(), st, time.Hour, base, discardLogger()); err != nil {
			b.Fatalf("Warm: %v", err)
		}
	}
}
