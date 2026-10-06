//go:build frostdb

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// The defect was observed against the FrostDB store, not the MemoryStore, and
// the two differ in the way that matters: FrostDBStore.Append writes Parquet and
// is append-only by construction, so a duplicate is a durable row in a segment
// that nobody is going to rewrite. The MemoryStore test proves the composition;
// this proves it over the store the pod actually runs.
//
// The restart is simulated the way it happens: a NEW Deduper, warmed from the
// store the process inherits, and the same corpus replayed through it.
func TestIdempotentIngest_FrostDBRestartDoesNotReAdmitTheCorpus(t *testing.T) {
	// The segment store fails closed without pseudonymisation key material (the
	// contract that stopped the kind-osramp pod); supply test material as
	// collectors/awslogs/frostdb_contract_test.go does.
	t.Setenv(store.SegmentPseudonymKeyEnv, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	st, err := store.NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer st.Close()

	corpus := e2eCorpus(t)
	SortObservations(corpus)

	first := newFrostDBHarness(t, st, collectors.NewDeduper(4096))
	for i := range corpus {
		if err := first.IngestObservation(context.Background(), &corpus[i]); err != nil {
			t.Fatalf("first pass IngestObservation(%s): %v", corpus[i].ID, err)
		}
	}
	before := frostRows(t, st)
	if len(before) == 0 {
		t.Fatal("precondition: the first pass stored nothing")
	}

	// --- process restart: new accepted-ID set, warmed from the durable store ---
	restarted := collectors.NewDeduper(4096)
	if err := restarted.Warm(context.Background(), st, collectors.DefaultDedupeWarmWindow, newestTimestamp(before), testLogger(t)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if restarted.WarmedIDs() == 0 {
		t.Fatal("warm-up seeded nothing from FrostDB; the restart would re-admit the whole corpus")
	}

	second := newFrostDBHarness(t, st, restarted)
	for i := range corpus {
		if err := second.IngestObservation(context.Background(), &corpus[i]); err != nil {
			t.Fatalf("second pass IngestObservation(%s): %v", corpus[i].ID, err)
		}
	}

	after := frostRows(t, st)
	if len(after) != len(before) {
		t.Fatalf("the restart appended to FrostDB: %d rows -> %d rows (ids unchanged)", len(before), len(after))
	}
	if got := restarted.Dropped(); got != uint64(len(corpus)) {
		t.Fatalf("want %d replays dropped, got %d", len(corpus), got)
	}

	// And the ID set itself is unchanged, which is the half the row count alone
	// would not catch if a projection had changed under us.
	idsBefore, idsAfter := idSet(before), idSet(after)
	if len(idsBefore) != len(idsAfter) {
		t.Fatalf("distinct IDs moved from %d to %d", len(idsBefore), len(idsAfter))
	}
	for id := range idsBefore {
		if _, ok := idsAfter[id]; !ok {
			t.Errorf("observation %s disappeared across the restart", id)
		}
	}
}

// newFrostDBHarness is the production chain over a FrostDB store:
// dedupe -> policy -> StoreSink -> store, with policy's derived records going
// through a second dedupe seam over the SAME set.
func newFrostDBHarness(t *testing.T, st store.SignalStore, deduper *collectors.Deduper) collectors.IngestionSink {
	t.Helper()

	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t), nil)
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}
	storeSink := collectors.NewStoreSink(st)
	sink := NewSink(storeSink, st, evaluator, StaticBundles(bundles), Options{
		Windows:     NewWindowsWithLogger(bundles, testLogger(t)),
		Metrics:     NewMetrics(),
		Logger:      testLogger(t),
		DerivedSink: collectors.NewDedupeSink(storeSink, deduper),
	})
	return collectors.BindTenant(collectors.NewDedupeSink(sink, deduper), e2eTenant)
}

func frostRows(t *testing.T, st store.SignalStore) []model.Observation {
	t.Helper()
	rows, err := st.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	return rows
}

func idSet(rows []model.Observation) map[string]struct{} {
	out := make(map[string]struct{}, len(rows))
	for i := range rows {
		out[rows[i].ID] = struct{}{}
	}
	return out
}

func TestIdempotentReview_FrostDBRestartPreservesDeduplication(t *testing.T) {
	t.Setenv(store.SegmentPseudonymKeyEnv, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	st, err := store.NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer st.Close()

	decObs := decisionFixture()
	if err := st.Append(context.Background(), []model.Observation{*decObs}); err != nil {
		t.Fatalf("Append decision: %v", err)
	}

	reviewedAt := time.Date(2026, 10, 4, 12, 30, 0, 0, time.UTC)
	rv := Review{
		ID:         ReviewID("tenant-a", decObs.ID, "alice@example.com", string(VerdictTruePositive), "initial review"),
		DecisionID: decObs.ID,
		TenantID:   "tenant-a",
		Verdict:    VerdictTruePositive,
		Note:       "initial review",
		Reviewer:   "alice@example.com",
		ReviewedAt: reviewedAt,
	}
	revObs := ReviewObservation(rv, decObs)

	// Ingest review via dedupe sink into store
	deduper := collectors.NewDeduper(4096)
	storeSink := collectors.NewStoreSink(st)
	dedupeSink := collectors.NewDedupeSink(storeSink, deduper)

	if err := dedupeSink.IngestObservation(context.Background(), &revObs); err != nil {
		t.Fatalf("first IngestObservation(review): %v", err)
	}

	rowsBefore := frostRows(t, st)
	reviewCountBefore := 0
	for i := range rowsBefore {
		if IsReview(&rowsBefore[i]) {
			reviewCountBefore++
		}
	}
	if reviewCountBefore != 1 {
		t.Fatalf("expected 1 review row before restart, got %d", reviewCountBefore)
	}

	// Replay exact same review -> dropped by deduper
	if err := dedupeSink.IngestObservation(context.Background(), &revObs); err != nil {
		t.Fatalf("replaying review returned error: %v", err)
	}
	if got := deduper.Dropped(); got != 1 {
		t.Fatalf("expected 1 dropped replay, got %d", got)
	}

	// --- Simulate restart / store reopen: warm a new deduper from FrostDB ---
	restartedDeduper := collectors.NewDeduper(4096)
	if err := restartedDeduper.Warm(context.Background(), st, collectors.DefaultDedupeWarmWindow, newestTimestamp(rowsBefore), testLogger(t)); err != nil {
		t.Fatalf("Warm: %v", err)
	}

	restartedSink := collectors.NewDedupeSink(storeSink, restartedDeduper)
	// Replay the exact same review after restart -> dropped by warmed deduper
	if err := restartedSink.IngestObservation(context.Background(), &revObs); err != nil {
		t.Fatalf("replaying review after restart: %v", err)
	}
	if got := restartedDeduper.Dropped(); got != 1 {
		t.Fatalf("expected 1 dropped replay after restart, got %d", got)
	}

	rowsAfter := frostRows(t, st)
	reviewCountAfter := 0
	for i := range rowsAfter {
		if IsReview(&rowsAfter[i]) {
			reviewCountAfter++
		}
	}
	if reviewCountAfter != 1 {
		t.Fatalf("review count moved from 1 to %d across restart replay", reviewCountAfter)
	}

	// A changed note creates a new review observation and is admitted
	rv2 := Review{
		ID:         ReviewID("tenant-a", decObs.ID, "alice@example.com", string(VerdictTruePositive), "revised note"),
		DecisionID: decObs.ID,
		TenantID:   "tenant-a",
		Verdict:    VerdictTruePositive,
		Note:       "revised note",
		Reviewer:   "alice@example.com",
		ReviewedAt: reviewedAt.Add(time.Hour),
	}
	revObs2 := ReviewObservation(rv2, decObs)
	if err := restartedSink.IngestObservation(context.Background(), &revObs2); err != nil {
		t.Fatalf("ingesting revised review: %v", err)
	}

	rowsWithRevision := frostRows(t, st)
	reviewCountWithRevision := 0
	for i := range rowsWithRevision {
		if IsReview(&rowsWithRevision[i]) {
			reviewCountWithRevision++
		}
	}
	if reviewCountWithRevision != 2 {
		t.Fatalf("expected 2 review rows after revision, got %d", reviewCountWithRevision)
	}
}
