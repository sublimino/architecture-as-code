// Package store defines the SignalStore interface and its implementations.
package store

import (
	"context"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// SignalStore is the persistence interface for signal observations.
type SignalStore interface {
	Append(ctx context.Context, observations []model.Observation) error
	QueryRange(ctx context.Context, q Query) ([]model.Observation, error)
	DropPartition(ctx context.Context, before time.Time) error
	Close() error
}

// Query specifies filters for observation retrieval.
type Query struct {
	Layers  []model.Layer // filter by layer
	After   time.Time     // start of range
	Before  time.Time     // end of range
	ActorID string        // optional: filter by correlated actor
	Limit   int           // max results (0 = no limit)
}
