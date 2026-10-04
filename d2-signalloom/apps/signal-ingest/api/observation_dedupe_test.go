// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// The store on kind-osramp already holds the duplicates: restarting
// signal-ingest in fixture mode re-appended the awslogs corpus with an
// unchanged ID set (cloud layer 12 rows -> 24). Those Parquet segments are the
// evidence and are not being rebuilt, so GET /api/v1/observations must return
// one row per derived ID over a store that was written before the write-side
// Deduper existed.
func TestQueryObservations_OneRowPerIDOverADuplicatedStore(t *testing.T) {
	h, mux := newTestHandlers(t)

	corpus := []model.Observation{
		{ID: "dup-1", Layer: model.LayerNetworkEgress, Source: "test"},
		{ID: "dup-2", Layer: model.LayerNetworkEgress, Source: "test"},
		{ID: "dup-3", Layer: model.LayerNetworkEgress, Source: "test"},
	}
	// Two passes of the same corpus: exactly what a restart produced.
	for pass := 0; pass < 2; pass++ {
		if err := h.Store.Append(context.Background(), corpus); err != nil {
			t.Fatal(err)
		}
	}

	result := queryObservations(t, mux, "/api/v1/observations?layer=network_egress")
	if len(result) != len(corpus) {
		t.Fatalf("want %d rows for %d distinct IDs, got %d", len(corpus), len(corpus), len(result))
	}
	seen := map[string]int{}
	for _, o := range result {
		seen[o.ID]++
	}
	for id, n := range seen {
		if n != 1 {
			t.Errorf("observation %s returned %d times", id, n)
		}
	}
}

// The dedupe must run before the limit, or a page of `limit` rows is a page of
// fewer than `limit` observations and the caller's pagination silently skips.
func TestQueryObservations_LimitCountsDistinctObservations(t *testing.T) {
	h, mux := newTestHandlers(t)

	var corpus []model.Observation
	for i := 0; i < 6; i++ {
		corpus = append(corpus, model.Observation{
			ID:     "lim-" + strconv.Itoa(i),
			Layer:  model.LayerNetworkEgress,
			Source: "test",
		})
	}
	for pass := 0; pass < 2; pass++ {
		if err := h.Store.Append(context.Background(), corpus); err != nil {
			t.Fatal(err)
		}
	}

	result := queryObservations(t, mux, "/api/v1/observations?layer=network_egress&limit=4")
	if len(result) != 4 {
		t.Fatalf("want 4 distinct observations under limit=4, got %d", len(result))
	}
	seen := map[string]struct{}{}
	for _, o := range result {
		if _, dup := seen[o.ID]; dup {
			t.Fatalf("limit=4 spent a slot on a duplicate of %s", o.ID)
		}
		seen[o.ID] = struct{}{}
	}
}

func queryObservations(t *testing.T, mux *http.ServeMux, target string) []model.Observation {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("GET %s: want 200, got %d (%s)", target, w.Code, w.Body.String())
	}
	var out []model.Observation
	if err := json.NewDecoder(w.Body).Decode(&out); err != nil {
		t.Fatalf("decoding the response: %v", err)
	}
	return out
}
