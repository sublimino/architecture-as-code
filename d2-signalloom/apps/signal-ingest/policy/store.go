// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"time"

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
	inner store.SignalStore
	sink  *Sink
}

// NewStore wraps inner. The sink's own inner sink must write to the SAME store,
// so findings land next to the observations that produced them.
func NewStore(inner store.SignalStore, sink *Sink) *Store {
	return &Store{inner: inner, sink: sink}
}

// Append stores the batch atomically, then evaluates each observation.
func (s *Store) Append(ctx context.Context, observations []model.Observation) error {
	if err := s.inner.Append(ctx, observations); err != nil {
		return err
	}
	if s.sink == nil {
		return nil
	}
	for i := range observations {
		s.sink.Evaluate(ctx, &observations[i])
	}
	return nil
}

// QueryRange delegates.
func (s *Store) QueryRange(ctx context.Context, q store.Query) ([]model.Observation, error) {
	return s.inner.QueryRange(ctx, q)
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
