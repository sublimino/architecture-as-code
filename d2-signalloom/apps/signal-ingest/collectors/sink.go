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

// BindTenant wraps an IngestionSink so that every observation passing through it is
// bound to tenantID with the same rules the HTTP path applies (SLAWS v2 D7, ISC-28..30):
// an absent tenant_id label is stamped; a mismatched one is rejected. Collectors that
// know their tenant from configuration (awslogs, one instance per account) wrap their
// sink with this instead of trusting the record.
//
// Seam stub: the binder body is delivered by the tenant-binder card; until then this is
// a passthrough so dependants compile against the frozen signature.
func BindTenant(sink IngestionSink, tenantID string) IngestionSink {
	_ = tenantID
	return sink
}
