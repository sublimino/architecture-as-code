//go:build frostdb

package store

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestFrostDBStore_Append(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Skipf("FrostDB unavailable: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC()
	obs := []model.Observation{
		{
			ID:             "frost-1",
			Timestamp:      now,
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "test",
			Confidence:     0.4,
			ActorHint:      "actor-x",
			RawEvidenceRef: "ref-1",
			Description:    "test observation",
			Labels:         map[string]string{"workload": "api", "namespace": "prod"},
		},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append failed: %v", err)
	}
}

func TestFrostDBStore_AppendMultiple(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Skipf("FrostDB unavailable: %v", err)
	}
	defer s.Close()

	now := time.Now().UTC()
	obs := []model.Observation{
		{ID: "f1", Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test", Labels: map[string]string{"k": "v1"}},
		{ID: "f2", Timestamp: now.Add(time.Second), Layer: model.LayerBehavioural, Source: "test", Labels: map[string]string{"k": "v2"}},
		{ID: "f3", Timestamp: now.Add(2 * time.Second), Layer: model.LayerIdentityAuth, Source: "test"},
	}

	if err := s.Append(context.Background(), obs); err != nil {
		t.Fatalf("Append multiple failed: %v", err)
	}
}
