// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Store wraps a SignalStore so that observations arriving over HTTP are
// evaluated by the same pipeline the collectors flow through (ISC-56).
//
// # Why a store wrapper and not the sink
//
// `POST /api/v1/observations` validates a whole batch and then calls
// Store.Append ONCE, atomically — the handler's own comment calls it "atomic
// reject". Routing that through IngestObservation per observation would turn a
// batch that is accepted or rejected as a unit into one that can half-land, and
// a writer retrying a half-landed batch is a worse failure than no policy at
// all. So Append does exactly what it did before — one batched call to the
// inner store — and only then evaluates each row through Sink.Evaluate.
//
// The deciding half is therefore the SAME code the collector path runs, reached
// by a second door rather than copied. The HTTP handler is unchanged; main.go
// hands this wrapper to api.Handlers.Store instead of the raw store, which is
// the single call site the card permits.
//
// # What is deliberately not wrapped
//
// Only Append. QueryRange, DropPartition and Close delegate untouched: policy
// has nothing to say about a read, a retention sweep, or shutdown, and
// intercepting them would put the evaluator on paths that must stay cheap and
// predictable.
//
// # Ordering
//
// Store first, decide second, exactly as at the sink. An evaluator fault cannot
// fail the Append, because Evaluate returns nothing — there is no policy outcome
// a writer should be told about.
type Store struct {
	inner  store.SignalStore
	sink   *Sink
	dedupe *collectors.Deduper
}

// NewStore wraps inner. The sink's own inner sink must write to the SAME store,
// so findings land next to the observations that produced them.
func NewStore(inner store.SignalStore, sink *Sink) *Store {
	return &Store{inner: inner, sink: sink}
}

// NewStoreWithDeduper is NewStore plus idempotency.
//
// `d` must be the SAME Deduper the collector path's DedupeSink holds. The
// defect is not "the collector path replays" or "the HTTP path replays" — it is
// that the derived ID was never enforced anywhere, and two independent sets
// would let a record admitted by one door be admitted again by the other.
func NewStoreWithDeduper(inner store.SignalStore, sink *Sink, d *collectors.Deduper) *Store {
	return &Store{inner: inner, sink: sink, dedupe: d}
}

// Append stores the batch atomically, then evaluates each observation.
//
// Deduplication happens FIRST, over the whole batch, for the same reason the
// Append is batched at all: a half-landed batch is a worse failure than no
// policy, and filtering before the write keeps the accept-or-reject-as-a-unit
// property while removing records that are already durable. A batch that is
// entirely a replay returns nil — a redelivery is a successful no-op, and
// reporting it as an error would make an SQS consumer retry the one thing that
// is already correct.
//
// A refused Append releases the claims. Otherwise a transient store fault would
// be upgraded to permanent loss: the IDs would be claimed, the rows would not
// exist, and the retry that would have repaired it would read as a duplicate.
func (s *Store) Append(ctx context.Context, observations []model.Observation) error {
	batch := observations
	if s.dedupe != nil {
		batch = s.dedupe.FilterObservations(observations)
		if len(batch) == 0 {
			return nil
		}
	}
	if err := s.inner.Append(ctx, batch); err != nil {
		if s.dedupe != nil {
			s.dedupe.Release(batch)
		}
		return err
	}
	if s.sink == nil {
		return nil
	}
	for i := range batch {
		s.sink.Evaluate(ctx, &batch[i])
	}
	return nil
}

// QueryRange delegates.
func (s *Store) QueryRange(ctx context.Context, q store.Query) ([]model.Observation, error) {
	return s.inner.QueryRange(ctx, q)
}

// ScanIDs delegates. Policy has nothing to say about identity-only reads either.
func (s *Store) ScanIDs(ctx context.Context, q store.Query, fn func(id string) error) error {
	return s.inner.ScanIDs(ctx, q, fn)
}

// ScanObservations delegates.
func (s *Store) ScanObservations(ctx context.Context, q store.Query, fn func(o *model.Observation) error) error {
	return s.inner.ScanObservations(ctx, q, fn)
}

// ObservationStats delegates.
func (s *Store) ObservationStats(ctx context.Context, q store.Query) (store.ObservationStats, error) {
	return s.inner.ObservationStats(ctx, q)
}

// DropPartition delegates.
func (s *Store) DropPartition(ctx context.Context, before time.Time) error {
	return s.inner.DropPartition(ctx, before)
}

// Close delegates.
func (s *Store) Close() error { return s.inner.Close() }

// Unwrap returns the wrapped store, for the few callers that must hold the real
// one (the correlation engine, the retention controller) rather than a decorated
// view of it.
func (s *Store) Unwrap() store.SignalStore { return s.inner }
