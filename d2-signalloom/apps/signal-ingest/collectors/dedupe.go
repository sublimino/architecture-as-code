// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"container/list"
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Observation.ID is derived — a hash of the evidence reference — precisely so a
// record that arrives twice is recognisably the same record (proposal §9, D2/D3:
// "unclean exit is at-least-once by design; derived Observation.ID dedupes").
// Nothing in the ingest path enforced that: store.FrostDBStore.Append is
// append-only, StoreSink forwards blindly, and policy evaluates every arrival.
// So restarting signal-ingest in fixture mode replayed the awslogs corpus and
// appended every observation and every finding a second time with an unchanged
// ID set, and a stage-2 burst counter could be reached by a redelivery rather
// than by events.
//
// Deduper is the enforcement: a bounded, recency-ordered set of accepted IDs,
// warmed at boot from the store so a restart does not re-admit what is already
// durable.
//
// # Why bounded, and what that costs
//
// An unbounded set is a memory leak with the same shape as the problem it
// fixes. The set is therefore an LRU of DedupeCapacityEnv entries, and the
// honest consequence is written into the test: an ID evicted because a million
// newer IDs arrived IS admitted again. Boot warm-up over
// DedupeWarmWindowEnv covers the case that actually happens — a crash, a
// rollout, an SQS redelivery — rather than pretending to cover all of history.
const (
	// DedupeCapacityEnv bounds the in-memory accepted-ID set.
	DedupeCapacityEnv = "SIGNAL_INGEST_DEDUPE_CAPACITY"
	// DedupeWarmWindowEnv is how far back boot warm-up reads accepted IDs.
	DedupeWarmWindowEnv = "SIGNAL_INGEST_DEDUPE_WARM_WINDOW"

	// DefaultDedupeCapacity holds roughly a day of pilot volume in a few tens of MB.
	DefaultDedupeCapacity = 1_000_000
	// DefaultDedupeWarmWindow spans any realistic restart or redelivery gap.
	DefaultDedupeWarmWindow = 24 * time.Hour
)

// Deduper tracks which observation IDs have already been accepted.
//
// A nil *Deduper is a valid, counter-free passthrough: every method admits
// everything. That keeps "dedupe not configured" out of the nil-check business
// on the ingest path.
type Deduper struct {
	mu       sync.Mutex
	capacity int
	window   time.Duration
	index    map[string]*list.Element
	order    *list.List // front = most recently accepted

	dropped uint64
	warmed  uint64
	evicted uint64
}

// NewDeduper returns a Deduper bounded at capacity (non-positive means the
// default) with the default warm window.
func NewDeduper(capacity int) *Deduper {
	if capacity <= 0 {
		capacity = DefaultDedupeCapacity
	}
	return &Deduper{
		capacity: capacity,
		window:   DefaultDedupeWarmWindow,
		index:    make(map[string]*list.Element),
		order:    list.New(),
	}
}

// NewDeduperFromEnv reads DedupeCapacityEnv and DedupeWarmWindowEnv, logging
// the effective values so a restart's dedupe horizon is in the boot log rather
// than inferred from behaviour. An unparseable value falls back to the default
// and warns: refusing to boot over a malformed tuning knob would turn a typo
// into an estate-wide outage, and the default is safe.
func NewDeduperFromEnv(log *slog.Logger) *Deduper {
	if log == nil {
		log = slog.Default()
	}
	capacity := DefaultDedupeCapacity
	if raw := strings.TrimSpace(os.Getenv(DedupeCapacityEnv)); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			log.Warn("ingest dedupe capacity is not a positive integer; using the default",
				"env", DedupeCapacityEnv, "value", raw, "default", DefaultDedupeCapacity)
		} else {
			capacity = n
		}
	}
	window := DefaultDedupeWarmWindow
	if raw := strings.TrimSpace(os.Getenv(DedupeWarmWindowEnv)); raw != "" {
		d, err := time.ParseDuration(raw)
		if err != nil || d <= 0 {
			log.Warn("ingest dedupe warm window is not a positive duration; using the default",
				"env", DedupeWarmWindowEnv, "value", raw, "default", DefaultDedupeWarmWindow.String())
		} else {
			window = d
		}
	}
	d := NewDeduper(capacity)
	d.window = window
	log.Info("ingest idempotency configured",
		"capacity", capacity, "warm_window", window.String(),
		"capacity_env", DedupeCapacityEnv, "warm_window_env", DedupeWarmWindowEnv)
	return d
}

// Capacity is the bound on the accepted-ID set.
func (d *Deduper) Capacity() int {
	if d == nil {
		return 0
	}
	return d.capacity
}

// WarmWindow is how far back Warm reads.
func (d *Deduper) WarmWindow() time.Duration {
	if d == nil {
		return 0
	}
	return d.window
}

// Accept claims id. It returns true when id has not been seen — the caller must
// forward the record — and false when this is a replay.
//
// An empty ID is always accepted. It cannot be keyed, and collapsing every
// unidentified observation onto one slot would discard data to fix duplication.
func (d *Deduper) Accept(id string) bool {
	if d == nil || id == "" {
		return true
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if el, ok := d.index[id]; ok {
		// Refresh recency: a record being redelivered is a record worth
		// remembering, so a hot replay must not be the eviction victim.
		d.order.MoveToFront(el)
		d.dropped++
		return false
	}
	d.index[id] = d.order.PushFront(id)
	d.evictLocked()
	return true
}

// Forget un-claims id, for a caller whose write was refused. Without it a
// transient store fault would be upgraded to permanent loss: the ID would be
// claimed, the row would not exist, and the redelivery that would have fixed it
// would be dropped as a duplicate.
func (d *Deduper) Forget(id string) {
	if d == nil || id == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if el, ok := d.index[id]; ok {
		d.order.Remove(el)
		delete(d.index, id)
	}
}

// FilterObservations returns the observations in batch whose IDs have not been
// seen, claiming each, preserving order, and collapsing a repeat within the
// batch itself. It is the batch door into the same set the sink uses, for the
// HTTP ingest path whose whole point is that a batch lands atomically or not at
// all.
func (d *Deduper) FilterObservations(batch []model.Observation) []model.Observation {
	if d == nil {
		return batch
	}
	out := make([]model.Observation, 0, len(batch))
	for i := range batch {
		if d.Accept(batch[i].ID) {
			out = append(out, batch[i])
		}
	}
	return out
}

// Release un-claims every ID in batch. Pair it with FilterObservations when the
// write that followed failed.
func (d *Deduper) Release(batch []model.Observation) {
	for i := range batch {
		d.Forget(batch[i].ID)
	}
}

// Warm seeds the set from st with the IDs already durable in the last window,
// so a restart does not re-admit them.
//
// The read is bounded twice — by the window and by the capacity — because this
// runs before any collector starts and must not become a full-store scan on a
// pod that has been ingesting for a month. Rows outside the window are
// deliberately NOT warmed: the set is finite, and spending it on history older
// than any plausible redelivery would evict the IDs that are about to arrive.
func (d *Deduper) Warm(ctx context.Context, st store.SignalStore, window time.Duration, now time.Time, log *slog.Logger) error {
	if d == nil || st == nil {
		return nil
	}
	if log == nil {
		log = slog.Default()
	}
	if window <= 0 {
		window = d.window
	}
	rows, err := st.QueryRange(ctx, store.Query{After: now.Add(-window), Limit: d.capacity})
	if err != nil {
		return fmt.Errorf("collectors: dedupe warm-up: %w", err)
	}

	var n uint64
	d.mu.Lock()
	for i := range rows {
		id := rows[i].ID
		if id == "" {
			continue
		}
		if _, ok := d.index[id]; ok {
			continue
		}
		d.index[id] = d.order.PushFront(id)
		n++
	}
	d.evictLocked()
	d.warmed += n
	tracked := len(d.index)
	d.mu.Unlock()

	log.Info("ingest idempotency warmed from the durable store",
		"warmed_ids", n, "tracked_ids", tracked, "rows_read", len(rows),
		"window", window.String(), "capacity", d.capacity)
	return nil
}

// evictLocked trims the set back to capacity from the least-recently-accepted end.
func (d *Deduper) evictLocked() {
	for d.order.Len() > d.capacity {
		back := d.order.Back()
		if back == nil {
			return
		}
		d.order.Remove(back)
		delete(d.index, back.Value.(string))
		d.evicted++
	}
}

// Dropped is the number of records refused as replays.
func (d *Deduper) Dropped() uint64 { return d.read(func() uint64 { return d.dropped }) }

// WarmedIDs is the number of IDs seeded from the store at boot.
func (d *Deduper) WarmedIDs() uint64 { return d.read(func() uint64 { return d.warmed }) }

// Evicted is the number of IDs forgotten to stay within capacity. A non-zero
// value is the honest signal that the dedupe horizon is shorter than the
// capacity suggests.
func (d *Deduper) Evicted() uint64 { return d.read(func() uint64 { return d.evicted }) }

// Tracked is the current set size.
func (d *Deduper) Tracked() int {
	if d == nil {
		return 0
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.index)
}

func (d *Deduper) read(f func() uint64) uint64 {
	if d == nil {
		return 0
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return f()
}

// Render writes the counters in Prometheus text format for composition into
// main.go's single metricsHandler, the same pattern policy.Metrics and
// retention.Metrics follow.
//
// Every series renders at zero rather than being absent: an absent
// dedupe_dropped_total reads as "nothing was duplicated", which is
// indistinguishable from "this control was never wired up" — which is exactly
// the state that produced the defect.
func (d *Deduper) Render() string {
	if d == nil {
		return ""
	}
	d.mu.Lock()
	dropped, warmed, evicted, tracked, capacity := d.dropped, d.warmed, d.evicted, len(d.index), d.capacity
	d.mu.Unlock()

	var b strings.Builder
	b.WriteString("# HELP signalloom_ingest_dedupe_dropped_total Observations refused at the ingestion sink because their derived ID was already accepted.\n")
	b.WriteString("# TYPE signalloom_ingest_dedupe_dropped_total counter\n")
	fmt.Fprintf(&b, "signalloom_ingest_dedupe_dropped_total %d\n", dropped)

	b.WriteString("# HELP signalloom_ingest_dedupe_warmed_ids Observation IDs seeded from the durable store at boot, so a restart does not re-admit them.\n")
	b.WriteString("# TYPE signalloom_ingest_dedupe_warmed_ids gauge\n")
	fmt.Fprintf(&b, "signalloom_ingest_dedupe_warmed_ids %d\n", warmed)

	b.WriteString("# HELP signalloom_ingest_dedupe_evicted_total Observation IDs forgotten to stay within capacity. Non-zero means the dedupe horizon is bounded by capacity, not by the warm window.\n")
	b.WriteString("# TYPE signalloom_ingest_dedupe_evicted_total counter\n")
	fmt.Fprintf(&b, "signalloom_ingest_dedupe_evicted_total %d\n", evicted)

	b.WriteString("# HELP signalloom_ingest_dedupe_tracked_ids Observation IDs currently resident in the accepted-ID set.\n")
	b.WriteString("# TYPE signalloom_ingest_dedupe_tracked_ids gauge\n")
	fmt.Fprintf(&b, "signalloom_ingest_dedupe_tracked_ids %d\n", tracked)

	b.WriteString("# HELP signalloom_ingest_dedupe_capacity Configured bound on the accepted-ID set.\n")
	b.WriteString("# TYPE signalloom_ingest_dedupe_capacity gauge\n")
	fmt.Fprintf(&b, "signalloom_ingest_dedupe_capacity %d\n", capacity)
	return b.String()
}

// DedupeSink drops an observation whose derived ID has already been accepted.
//
// It is the shared seam: the collector path reaches it through the sink chain
// and the HTTP path reaches the SAME Deduper through
// policy.Store/Deduper.FilterObservations, so there is one accepted-ID set and
// not two that can disagree.
type DedupeSink struct {
	inner IngestionSink
	d     *Deduper
}

// NewDedupeSink wraps inner. A nil Deduper yields a passthrough.
func NewDedupeSink(inner IngestionSink, d *Deduper) *DedupeSink {
	return &DedupeSink{inner: inner, d: d}
}

// IngestObservation forwards obs only if its ID has not been accepted before.
//
// A duplicate returns nil, not an error: a redelivered record is a successful
// no-op, and surfacing it as a failure would make an SQS consumer retry the one
// thing that is already correct.
func (s *DedupeSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	if obs == nil {
		return nil
	}
	if !s.d.Accept(obs.ID) {
		return nil
	}
	if err := s.inner.IngestObservation(ctx, obs); err != nil {
		// The claim is only earned by a write that landed.
		s.d.Forget(obs.ID)
		return err
	}
	return nil
}

// Deduper exposes the shared set, for the HTTP path and the metrics handler.
func (s *DedupeSink) Deduper() *Deduper { return s.d }
