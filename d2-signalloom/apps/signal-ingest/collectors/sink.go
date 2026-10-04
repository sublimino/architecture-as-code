package collectors

import (
	"context"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/tenancy"
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
// bound to tenantID with the same rule the HTTP path applies (SLAWS v2 D7, ISC-28..30):
// an absent tenant_id label is stamped; a mismatched one is refused and never forwarded.
// Collectors that know their tenant from configuration (awslogs, one instance per account)
// wrap their sink with this instead of trusting the record.
func BindTenant(sink IngestionSink, tenantID string) IngestionSink {
	return &tenantBoundSink{inner: sink, tenantID: tenantID}
}

type tenantBoundSink struct {
	inner    IngestionSink
	tenantID string
}

// IngestObservation binds then forwards. The caller's observation is not mutated; the bound
// copy is what reaches the inner sink.
func (s *tenantBoundSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	if obs == nil {
		return nil
	}
	batch := []model.Observation{*obs}
	if err := tenancy.BindObservations(s.tenantID, false, batch); err != nil {
		return err
	}
	return s.inner.IngestObservation(ctx, &batch[0])
}
