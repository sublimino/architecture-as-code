//go:build frostdb

package store

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Cato round 3, ISC-32: the collector's operational records (projection_failure,
// buffer_eviction) carry the label key "type". Under the configured FrostDB store the
// closed allow-list must admit them, otherwise the fail-closed path in the awslogs
// collector refuses to acknowledge and the queue wedges on the first bad object.
func TestFrostDBAdmitsCollectorOperationalRecords(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()
	ts := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	rows := []model.Observation{
		{ID: "pf-1", Timestamp: ts, Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityDefinitive, Source: "aws:collector", Confidence: 1, RawEvidenceRef: "s3://b/k", Description: "awslogs projection failure: x",
			Labels: map[string]string{"tenant_id": "kusari", "provider": "aws", "type": "projection_failure"}},
		{ID: "ev-1", Timestamp: ts, Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityDefinitive, Source: "aws:collector", Confidence: 1, RawEvidenceRef: "awslogs:ring", Description: "awslogs buffer eviction",
			Labels: map[string]string{"tenant_id": "kusari", "provider": "aws", "type": "buffer_eviction", "count": "3"}},
	}
	if err := s.Append(context.Background(), rows); err != nil {
		t.Fatalf("FrostDB refused a collector operational record: %v", err)
	}
}
