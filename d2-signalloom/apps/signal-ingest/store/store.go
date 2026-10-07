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
	QueryPage(ctx context.Context, q PageQuery) ([]model.Observation, error)
	Stats(ctx context.Context, q StatsQuery) (StoreStats, error)
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

// PageQuery specifies filters, tenant scope, and cursor for bounded, ordered observation retrieval.
type PageQuery struct {
	Layers          []model.Layer // filter by layer
	After           time.Time     // start of range
	Before          time.Time     // end of range
	ActorID         string        // optional: filter by correlated actor
	SubjectID       string        // optional: filter by data subject identity across pseudonymised columns
	Tenant          string        // tenant scope (if !AllTenants)
	AllTenants      bool          // if true, cross-tenant read
	CursorTimestamp time.Time     // cursor timestamp (exclusive with CursorID)
	CursorID        string        // cursor observation ID
	Limit           int           // max results (0 = no limit, otherwise at most Limit)
}

// StoreStats contains aggregate metrics over observations.
type StoreStats struct {
	TotalObservations      int
	ObservationsByLayer    map[string]int
	ObservationsByFidelity map[string]int
	LastIngestion          *time.Time
}

// StatsQuery specifies filters for calculating store aggregates.
type StatsQuery struct {
	Tenant     string
	AllTenants bool
}
