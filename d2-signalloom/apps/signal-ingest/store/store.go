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
	DropPartition(ctx context.Context, before time.Time) error
	Close() error
}

// Query specifies filters for observation retrieval.
type Query struct {
	Layers    []model.Layer // filter by layer
	IDs       []string      // optional: filter by observation ID (empty = no ID filter)
	After     time.Time     // start of range
	Before    time.Time     // end of range
	ActorID   string        // optional: filter by correlated actor
	SubjectID string        // optional: filter by data subject identity across pseudonymised columns
	Offset    int           // optional: offset for pagination
	Limit     int           // max results (0 = no limit)
}

// LookupIDs returns the Query that reads exactly the named observations.
//
// It exists because "fetch one row by its ID" had no expressible form: Query carried a time
// range, a layer, an actor and a subject, but not an identity, so every by-ID read was written
// as an unfiltered QueryRange followed by a linear scan in Go. That materialises the entire
// store to return one row, which is how a decision lookup came to cost 2 GiB of resident
// memory on kind-osramp (see api.Handlers.observationByID). `id` is a real column in the
// FrostDB Arrow schema, so this pushes down to the engine rather than filtering in the caller.
//
// An empty or nil ids slice would be indistinguishable from "no filter" in the Query struct,
// which is the dangerous direction to fail: a lookup whose ID list came back empty would
// silently read everything. Callers must therefore not call this with an empty slice; the
// stores treat a non-nil-but-empty IDs slice as "match nothing" for the same reason.
func LookupIDs(ids ...string) Query {
	return Query{IDs: ids}
}

// matchesIDs reports whether o passes q's ID filter. A nil IDs slice means the filter is absent
// and everything passes; a present-but-empty slice matches nothing, so a caller that computed an
// empty ID set reads zero rows rather than the whole store.
func (q Query) matchesIDs(id string) bool {
	if q.IDs == nil {
		return true
	}
	for _, want := range q.IDs {
		if want == id {
			return true
		}
	}
	return false
}
