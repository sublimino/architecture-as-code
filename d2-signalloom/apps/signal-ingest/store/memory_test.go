package store

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// StoreTestSuite runs the full SignalStore contract against any implementation.
// This is the canonical test suite: both MemoryStore and FrostDBStore must pass it.
func StoreTestSuite(t *testing.T, newStore func() SignalStore) {
	t.Helper()

	t.Run("Append_and_QueryRange_all", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := []model.Observation{
			{ID: "1", Timestamp: now, Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "test", Description: "obs-1"},
			{ID: "2", Timestamp: now.Add(time.Second), Layer: model.LayerBehavioural, Fidelity: model.FidelityStrong, Source: "test", Description: "obs-2"},
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 {
			t.Errorf("want 2 observations, got %d", len(got))
		}
	})

	t.Run("QueryRange_filter_by_layer", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := []model.Observation{
			{ID: "1", Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test"},
			{ID: "2", Timestamp: now, Layer: model.LayerBehavioural, Source: "test"},
			{ID: "3", Timestamp: now, Layer: model.LayerIdentityAuth, Source: "test"},
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{
			Layers: []model.Layer{model.LayerBehavioural},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].ID != "2" {
			t.Errorf("layer filter: want obs 2, got %v", got)
		}
	})

	t.Run("QueryRange_filter_by_time", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		base := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
		obs := []model.Observation{
			{ID: "old", Timestamp: base, Layer: model.LayerNetworkEgress, Source: "test"},
			{ID: "new", Timestamp: base.Add(time.Hour), Layer: model.LayerNetworkEgress, Source: "test"},
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{
			After: base.Add(30 * time.Minute),
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].ID != "new" {
			t.Errorf("time filter: want 'new', got %v", got)
		}
	})

	t.Run("QueryRange_filter_by_actor", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := []model.Observation{
			{ID: "1", Timestamp: now, Layer: model.LayerNetworkEgress, ActorHint: "actor-a", Source: "test"},
			{ID: "2", Timestamp: now, Layer: model.LayerBehavioural, ActorHint: "actor-b", Source: "test"},
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{ActorID: "actor-a"})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].ID != "1" {
			t.Errorf("actor filter: want obs 1, got %v", got)
		}
	})

	t.Run("QueryRange_limit", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := make([]model.Observation, 10)
		for i := range obs {
			obs[i] = model.Observation{ID: string(rune('a' + i)), Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test"}
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{Limit: 3})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 3 {
			t.Errorf("limit: want 3, got %d", len(got))
		}
	})

	t.Run("DropPartition", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		base := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
		obs := []model.Observation{
			{ID: "old", Timestamp: base, Layer: model.LayerNetworkEgress, Source: "test"},
			{ID: "new", Timestamp: base.Add(time.Hour), Layer: model.LayerNetworkEgress, Source: "test"},
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		if err := s.DropPartition(context.Background(), base.Add(30*time.Minute)); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].ID != "new" {
			t.Errorf("after drop: want only 'new', got %v", got)
		}
	})

	t.Run("Append_with_labels", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := []model.Observation{
			{
				ID:        "labelled",
				Timestamp: now,
				Layer:     model.LayerApplicationSaaS,
				Source:    "test",
				Labels:    map[string]string{"workload": "api-server", "namespace": "prod"},
			},
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		got, err := s.QueryRange(context.Background(), Query{})
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 {
			t.Fatalf("want 1, got %d", len(got))
		}
		if got[0].Labels["workload"] != "api-server" {
			t.Errorf("label mismatch: %v", got[0].Labels)
		}
	})
}

func TestMemoryStore(t *testing.T) {
	StoreTestSuite(t, func() SignalStore {
		return NewMemoryStore()
	})
}
