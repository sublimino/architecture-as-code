package collectors

import (
	"context"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// StoreSink adapts a store.SignalStore to satisfy IngestionSink.
type StoreSink struct {
	store store.SignalStore
}

// NewStoreSink creates an IngestionSink backed directly by the SignalStore.
func NewStoreSink(s store.SignalStore) *StoreSink {
	return &StoreSink{store: s}
}

// IngestObservation appends a single observation to the underlying SignalStore.
func (s *StoreSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	if obs == nil {
		return nil
	}
	return s.store.Append(ctx, []model.Observation{*obs})
}
