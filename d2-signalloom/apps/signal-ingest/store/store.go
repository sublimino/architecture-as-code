// Package store defines the SignalStore interface and its implementations.
package store

import (
	"context"
	"errors"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// MinAggregateGroupSize enforces k-anonymity (small-cell suppression floor) for grouped/statistical queries.
const MinAggregateGroupSize = 5

// ErrGroupSizeBelowAnonymityFloor is returned when aggregate cohort size is smaller than MinAggregateGroupSize.
var ErrGroupSizeBelowAnonymityFloor = errors.New("aggregate group size falls below k-anonymity floor (k=5)")

// SignalStore is the persistence interface for signal observations.
type SignalStore interface {
	Append(ctx context.Context, observations []model.Observation) error
	QueryRange(ctx context.Context, q Query) ([]model.Observation, error)

	// ScanIDs streams the IDs of the observations matching q, in the same order and with the
	// same row SELECTION as QueryRange, without ever materialising a model.Observation. fn is
	// called once per matching row; returning an error from fn aborts the scan and is
	// returned to the caller unwrapped.
	//
	// Offset and Limit are applied in the natural order — skip Offset rows, then emit at most
	// Limit — and every implementation must agree on that, which is more than can currently
	// be said for QueryRange. With {Offset: 2, Limit: 3} over rows a..j, MemoryStore's
	// QueryRange returns [c d e] but FrostDBStore's returns [c]: FrostDB stops collecting at
	// Limit and only then slices Offset off the truncated result, so offset can never reach
	// past the first Limit rows. That is a pre-existing pagination defect in
	// FrostDBStore.QueryRange, reported separately rather than copied here; ScanIDs is
	// specified once so a caller's pagination cannot depend on which store is configured.
	// Warm is unaffected either way — it passes After and Limit and leaves Offset zero.
	//
	// Callers that need only identity must use this and not QueryRange. Boot warm-up read
	// 192,312 rows through QueryRange to look at nothing but their IDs and OOM-killed
	// signal-ingest on kind-osramp (2026-10-13, exit 137, 15 restarts): QueryRange decodes
	// every column into a fresh model.Observation with its own Labels map, which measured
	// 2,635 bytes per row against ~200 for an ID.
	//
	// This is on the interface rather than an optional capability with a QueryRange
	// fallback, deliberately. A fallback would leave the path that caused the outage
	// reachable from a store that simply forgot to implement the fast one; as a required
	// method the compiler proves every implementation streams.
	//
	// Implementations MUST pass fn an ID that owns its own memory. A columnar backend can
	// return strings aliasing a decode buffer, and an ID retained by the caller would then
	// pin that entire buffer — every column of every row — for as long as the ID is held.
	ScanIDs(ctx context.Context, q Query, fn func(id string) error) error

	DropPartition(ctx context.Context, before time.Time) error
	Close() error
}

// Query specifies filters for observation retrieval.
type Query struct {
	Layers    []model.Layer // filter by layer
	After     time.Time     // start of range
	Before    time.Time     // end of range
	ActorID   string        // optional: filter by correlated actor
	SubjectID string        // optional: filter by data subject identity across pseudonymised columns
	Offset    int           // optional: offset for pagination
	Limit     int           // max results (0 = no limit)
}
