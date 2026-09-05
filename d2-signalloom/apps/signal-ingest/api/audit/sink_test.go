package audit_test

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func TestAuditWebhookReceiver_SinkAdapterSatisfiesIngestionSink(t *testing.T) {
	memStore := store.NewMemoryStore()
	storeSink := collectors.NewStoreSink(memStore)

	var _ audit.IngestionSink = storeSink

	ctx := context.Background()
	obs := &model.Observation{
		ID:             "audit-sink-test-01",
		Timestamp:      time.Now().UTC(),
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityDefinitive,
		Source:         "k8s-apiserver-audit",
		Confidence:     1.0,
		ActorHint:      "system:serviceaccount:default:test-agent",
		RawEvidenceRef: "k8s-audit://default/secrets/test-secret",
		Labels: map[string]string{
			"verb":     "get",
			"resource": "secrets",
		},
		Description: "K8s audit: get secret default/test-secret",
	}

	if err := storeSink.IngestObservation(ctx, obs); err != nil {
		t.Fatalf("IngestObservation failed: %v", err)
	}

	results, err := memStore.QueryRange(ctx, store.Query{Limit: 10})
	if err != nil {
		t.Fatalf("QueryRange failed: %v", err)
	}

	if len(results) != 1 {
		t.Fatalf("expected 1 observation in store, got %d", len(results))
	}

	if results[0].ID != obs.ID {
		t.Errorf("stored observation ID = %s, want %s", results[0].ID, obs.ID)
	}
}
