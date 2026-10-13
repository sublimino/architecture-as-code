package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// equalIDs compares two ID sequences element-wise, treating nil and empty as equal.
func equalIDs(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

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

	// ScanIDs is the identity-only read that boot warm-up uses instead of QueryRange, after
	// materialising 192,312 rows to look at their IDs OOM-killed signal-ingest (2026-10-13).
	// It is only safe to substitute if it answers the same question, so the contract is
	// equivalence with QueryRange, asserted here against every implementation rather than
	// against one.
	scanIDs := func(t *testing.T, s SignalStore, q Query) []string {
		t.Helper()
		var got []string
		if err := s.ScanIDs(context.Background(), q, func(id string) error {
			got = append(got, id)
			return nil
		}); err != nil {
			t.Fatalf("ScanIDs: %v", err)
		}
		return got
	}

	queryIDs := func(t *testing.T, s SignalStore, q Query) []string {
		t.Helper()
		rows, err := s.QueryRange(context.Background(), q)
		if err != nil {
			t.Fatalf("QueryRange: %v", err)
		}
		out := make([]string, 0, len(rows))
		for i := range rows {
			out = append(out, rows[i].ID)
		}
		return out
	}

	t.Run("ScanIDs_matches_QueryRange", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := make([]model.Observation, 10)
		for i := range obs {
			obs[i] = model.Observation{
				ID:        string(rune('a' + i)),
				Timestamp: now.Add(-time.Duration(i) * time.Minute),
				Layer:     model.LayerNetworkEgress,
				Source:    "test",
			}
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		for _, tc := range []struct {
			name string
			q    Query
		}{
			// Offset and Limit together are deliberately absent: the two methods are
			// specified to diverge there and ScanIDs_offset_and_limit below pins both
			// behaviours explicitly. Every other combination must agree exactly.
			{"all", Query{}},
			{"limit", Query{Limit: 3}},
			{"offset", Query{Offset: 4}},
			{"after", Query{After: now.Add(-5 * time.Minute)}},
			{"limit_beyond_result", Query{Limit: 1000}},
			{"offset_beyond_result", Query{Offset: 1000}},
		} {
			t.Run(tc.name, func(t *testing.T) {
				want := queryIDs(t, s, tc.q)
				got := scanIDs(t, s, tc.q)
				if len(got) != len(want) {
					t.Fatalf("ScanIDs returned %d ids, QueryRange returned %d: %v vs %v",
						len(got), len(want), got, want)
				}
				for i := range want {
					if got[i] != want[i] {
						t.Errorf("id %d: ScanIDs %q, QueryRange %q", i, got[i], want[i])
					}
				}
			})
		}
	})

	// ScanIDs_offset_and_limit pins the combination the equivalence table above leaves out.
	//
	// QueryRange cannot be asserted here because its two implementations disagree:
	// {Offset: 2, Limit: 3} over a..j gives [c d e] from MemoryStore and [c] from
	// FrostDBStore, which stops collecting at Limit and only then slices Offset off the
	// truncated result. That is a pre-existing pagination defect in FrostDBStore.QueryRange,
	// reported separately and deliberately not copied into ScanIDs.
	//
	// What IS asserted, for every implementation, is that ScanIDs applies them in the natural
	// order. Pagination must not depend on which store is configured.
	t.Run("ScanIDs_offset_and_limit", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := make([]model.Observation, 10)
		for i := range obs {
			obs[i] = model.Observation{
				ID:        string(rune('a' + i)),
				Timestamp: now.Add(-time.Duration(i) * time.Minute),
				Layer:     model.LayerNetworkEgress,
				Source:    "test",
			}
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		q := Query{Offset: 2, Limit: 3}

		if got, want := scanIDs(t, s, q), []string{"c", "d", "e"}; !equalIDs(got, want) {
			t.Errorf("ScanIDs{Offset:2,Limit:3} = %v, want %v (skip offset, then take limit)", got, want)
		}
	})

	t.Run("ScanIDs_propagates_callback_error", func(t *testing.T) {
		s := newStore()
		defer s.Close()

		now := time.Now().UTC()
		obs := make([]model.Observation, 5)
		for i := range obs {
			obs[i] = model.Observation{ID: string(rune('a' + i)), Timestamp: now, Layer: model.LayerNetworkEgress, Source: "test"}
		}
		if err := s.Append(context.Background(), obs); err != nil {
			t.Fatal(err)
		}

		// A caller that aborts must learn that it aborted. Swallowing this would let a
		// partial warm-up report success and silently re-admit replayed records.
		sentinel := errors.New("caller stopped the scan")
		seen := 0
		err := s.ScanIDs(context.Background(), Query{}, func(string) error {
			seen++
			return sentinel
		})
		if !errors.Is(err, sentinel) {
			t.Errorf("ScanIDs returned %v, want the callback's own error", err)
		}
		if seen != 1 {
			t.Errorf("callback ran %d times after returning an error, want 1", seen)
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
