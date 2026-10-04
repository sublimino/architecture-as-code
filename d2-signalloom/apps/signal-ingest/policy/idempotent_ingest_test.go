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

// The defect, end to end, through the production composition.
//
// Observed on kind-osramp in fixture mode against the FrostDB store: restarting
// signal-ingest replayed the awslogs fixtures and appended every observation
// and every stage-1 finding a second time although the IDs were identical
// (cloud layer 12 rows -> 24, network 4 -> 8, findings 4 -> 8, id sets
// unchanged). The stage-2 consequence is the one that matters: a burst counter
// reachable by a redelivery rather than by events.
//
// These tests drive the real evaluator, the real shipped kusari bundle, the
// real tenant binder and the real sink chain over a MemoryStore, in the
// production order:
//
//	BindTenant -> DedupeSink -> policy.Sink -> StoreSink -> store
//
// with policy's own output going back out through a second DedupeSink over the
// SAME accepted-ID set.

// countingObserver records what stage 1 and stage 2 actually saw, by ID.
//
// Counting the OBSERVER rather than the stored rows is the point: a dedupe that
// only suppressed the duplicate finding WRITE would leave the burst already
// counted, and no assertion over stored observations could tell the difference.
type countingObserver struct {
	findings  map[string]int
	decisions map[string]int
}

func newCountingObserver() *countingObserver {
	return &countingObserver{findings: map[string]int{}, decisions: map[string]int{}}
}

func (c *countingObserver) OnFinding(f obscel.Finding)   { c.findings[f.ID]++ }
func (c *countingObserver) OnDecision(d obscel.Decision) { c.decisions[d.ID]++ }

// idempotentHarness is the production chain with a shared Deduper, over one store.
type idempotentHarness struct {
	st       *store.MemoryStore
	deduper  *collectors.Deduper
	observer *countingObserver
	bound    collectors.IngestionSink
}

func newIdempotentHarness(t *testing.T, st *store.MemoryStore, deduper *collectors.Deduper) *idempotentHarness {
	t.Helper()

	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}

	observer := newCountingObserver()
	storeSink := collectors.NewStoreSink(st)
	sink := NewSink(storeSink, st, evaluator, StaticBundles(bundles), Options{
		Windows:  NewWindowsWithLogger(bundles, testLogger(t)),
		Metrics:  NewMetrics(),
		Observer: observer,
		Logger:   testLogger(t),
		// Derived records go through the dedupe seam; the source observation
		// does not, because it was claimed upstream and would otherwise be
		// refused as a duplicate of its own claim.
		DerivedSink: collectors.NewDedupeSink(storeSink, deduper),
	})
	return &idempotentHarness{
		st:       st,
		deduper:  deduper,
		observer: observer,
		bound:    collectors.BindTenant(collectors.NewDedupeSink(sink, deduper), e2eTenant),
	}
}

func (h *idempotentHarness) ingest(t *testing.T, corpus []model.Observation) {
	t.Helper()
	for i := range corpus {
		if err := h.bound.IngestObservation(context.Background(), &corpus[i]); err != nil {
			t.Fatalf("IngestObservation(%s): %v", corpus[i].ID, err)
		}
	}
}

func (h *idempotentHarness) rows(t *testing.T) []model.Observation {
	t.Helper()
	rows, err := h.st.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	return rows
}

func countBySource(rows []model.Observation) (observations, findings, decisions int) {
	for _, r := range rows {
		switch r.Source {
		case obscel.SourceFinding:
			findings++
		case obscel.SourceDecision:
			decisions++
		default:
			observations++
		}
	}
	return
}

func TestIdempotentIngest_ASecondPassOfTheCorpusChangesNothing(t *testing.T) {
	st := store.NewMemoryStore()
	h := newIdempotentHarness(t, st, collectors.NewDeduper(4096))
	corpus := e2eCorpus(t)
	SortObservations(corpus)

	h.ingest(t, corpus)
	firstRows := h.rows(t)
	o1, f1, d1 := countBySource(firstRows)
	if o1 == 0 || f1 == 0 {
		t.Fatalf("precondition: the first pass must store observations and findings, got %d/%d", o1, f1)
	}

	h.ingest(t, corpus)
	o2, f2, d2 := countBySource(h.rows(t))

	if o1 != o2 || f1 != f2 || d1 != d2 {
		t.Fatalf("the second pass changed the store: observations %d->%d, findings %d->%d, decisions %d->%d",
			o1, o2, f1, f2, d1, d2)
	}
	if got := h.deduper.Dropped(); got != uint64(len(corpus)) {
		t.Fatalf("want %d dropped replays, got %d", len(corpus), got)
	}

	// Stage 2 saw each finding exactly once. A dedupe that only suppressed the
	// duplicate WRITE would leave this at two and the burst already counted.
	for id, n := range h.observer.findings {
		if n != 1 {
			t.Errorf("stage 2 was offered finding %s %d times", id, n)
		}
	}
	for id, n := range h.observer.decisions {
		if n != 1 {
			t.Errorf("decision %s was emitted %d times", id, n)
		}
	}
	if len(h.observer.findings) != f1 {
		t.Errorf("stage 1 emitted %d distinct findings but %d finding rows are stored",
			len(h.observer.findings), f1)
	}
}

// The restart case: a NEW process, so a new Deduper and a new in-memory window
// set, warmed from the store it inherits. This is literally what happened on
// kind-osramp.
func TestIdempotentIngest_ARestartDoesNotReAdmitTheFixtures(t *testing.T) {
	st := store.NewMemoryStore()
	corpus := e2eCorpus(t)
	SortObservations(corpus)

	first := newIdempotentHarness(t, st, collectors.NewDeduper(4096))
	first.ingest(t, corpus)
	o1, f1, d1 := countBySource(first.rows(t))

	// --- process restart ---
	restarted := collectors.NewDeduper(4096)
	if err := restarted.Warm(context.Background(), st, collectors.DefaultDedupeWarmWindow, newestTimestamp(corpus), testLogger(t)); err != nil {
		t.Fatalf("Warm: %v", err)
	}
	if restarted.WarmedIDs() == 0 {
		t.Fatal("warm-up seeded nothing; the restart would re-admit the whole corpus")
	}
	second := newIdempotentHarness(t, st, restarted)
	second.ingest(t, corpus)

	o2, f2, d2 := countBySource(second.rows(t))
	if o1 != o2 || f1 != f2 || d1 != d2 {
		t.Fatalf("the restart re-admitted the fixtures: observations %d->%d, findings %d->%d, decisions %d->%d",
			o1, o2, f1, f2, d1, d2)
	}
	// The restarted process evaluated nothing, so its windows never advanced.
	if n := len(second.observer.findings); n != 0 {
		t.Fatalf("stage 1 ran over %d replayed observations after the restart", n)
	}
}

// Idempotency must not cost the FIRST write. A dedupe seam on both sides of the
// policy sink sharing one ID set is exactly where that goes wrong, so it is
// asserted rather than assumed.
func TestIdempotentIngest_TheFirstWriteOfEveryRecordLands(t *testing.T) {
	st := store.NewMemoryStore()
	deduper := collectors.NewDeduper(4096)
	h := newIdempotentHarness(t, st, deduper)
	corpus := e2eCorpus(t)
	SortObservations(corpus)
	h.ingest(t, corpus)

	rows := h.rows(t)
	stored := map[string]struct{}{}
	for _, r := range rows {
		stored[r.ID] = struct{}{}
	}
	for i := range corpus {
		if _, ok := stored[corpus[i].ID]; !ok {
			t.Errorf("source observation %s was swallowed on its first write", corpus[i].ID)
		}
	}
	// findingObservation uses the finding's own ID as the observation ID, so an
	// emitted finding must be present under that key.
	for id := range h.observer.findings {
		if _, ok := stored[id]; !ok {
			t.Errorf("finding %s was emitted and not stored", id)
		}
	}
	if deduper.Dropped() != 0 {
		t.Errorf("a clean first pass dropped %d records", deduper.Dropped())
	}
}

// The HTTP door reaches the same set: policy.Store filters the batch ahead of
// its atomic Append, so a redelivered batch is a no-op rather than a second
// landing, and a batch that is entirely a replay succeeds rather than erroring.
func TestIdempotentIngest_HTTPBatchPathSharesTheSameSet(t *testing.T) {
	st := store.NewMemoryStore()
	deduper := collectors.NewDeduper(4096)
	h := newIdempotentHarness(t, st, deduper)

	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
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
	httpStore := NewStoreWithDeduper(st, sink.(*Sink), deduper)

	corpus := e2eCorpus(t)
	SortObservations(corpus)
	if err := httpStore.Append(context.Background(), corpus); err != nil {
		t.Fatalf("first Append: %v", err)
	}
	o1, f1, d1 := countBySource(h.rows(t))

	if err := httpStore.Append(context.Background(), corpus); err != nil {
		t.Fatalf("a redelivered batch must be a successful no-op, got %v", err)
	}
	o2, f2, d2 := countBySource(h.rows(t))
	if o1 != o2 || f1 != f2 || d1 != d2 {
		t.Fatalf("the HTTP path re-landed the batch: observations %d->%d, findings %d->%d, decisions %d->%d",
			o1, o2, f1, f2, d1, d2)
	}

	// And the collector door agrees with it: the same corpus through the sink
	// chain is already accounted for.
	h.ingest(t, corpus)
	o3, _, _ := countBySource(h.rows(t))
	if o3 != o1 {
		t.Fatalf("the collector door re-admitted what the HTTP door had already accepted: %d -> %d", o1, o3)
	}
}

// newestTimestamp is the clock the restarted process warms against. The fixture
// corpus is stamped in 2026-10, which is outside a 24h window measured from
// time.Now() on any machine running this later, so warming from the real clock
// would seed nothing and the test would pass for the wrong reason.
func newestTimestamp(corpus []model.Observation) time.Time {
	var newest time.Time
	for i := range corpus {
		if corpus[i].Timestamp.After(newest) {
			newest = corpus[i].Timestamp
		}
	}
	return newest
}
