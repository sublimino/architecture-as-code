package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestStoreStats_Empty(t *testing.T) {
	_, mux := newTestHandlers(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/store/stats", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("store/stats empty: want 200, got %d, body: %s", w.Code, w.Body.String())
	}

	var resp StoreStatsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.TotalObservations != 0 {
		t.Errorf("empty store: want 0 observations, got %d", resp.TotalObservations)
	}
	if resp.ActorCount != 0 {
		t.Errorf("empty store: want 0 actors, got %d", resp.ActorCount)
	}
	if resp.LastIngestion != nil {
		t.Errorf("empty store: want nil last_ingestion, got %v", resp.LastIngestion)
	}
	if resp.StoreType == "" {
		t.Error("store type must not be empty")
	}
}

func TestStoreStats_WithData(t *testing.T) {
	h, mux := newTestHandlers(t)

	// Seed some observations.
	now := time.Now().UTC()
	obs := []model.Observation{
		{
			ID: "s1", Layer: model.LayerNetworkEgress, Source: "test",
			Description: "net obs", Fidelity: model.FidelityStrong,
			Timestamp: now.Add(-10 * time.Minute), Confidence: 0.8, RawEvidenceRef: "ref",
		},
		{
			ID: "s2", Layer: model.LayerNetworkEgress, Source: "test",
			Description: "net obs 2", Fidelity: model.FidelitySuggestive,
			Timestamp: now.Add(-5 * time.Minute), Confidence: 0.6, RawEvidenceRef: "ref",
		},
		{
			ID: "s3", Layer: model.LayerIdentityAuth, Source: "test",
			Description: "id obs", Fidelity: model.FidelityDefinitive,
			Timestamp: now, Confidence: 0.95, RawEvidenceRef: "ref",
			ActorHint: "sa-test",
		},
	}

	body, _ := json.Marshal(obs)
	ingestReq := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	ingestW := httptest.NewRecorder()
	mux.ServeHTTP(ingestW, ingestReq)

	if ingestW.Code != http.StatusCreated {
		t.Fatalf("ingest: want 201, got %d", ingestW.Code)
	}

	// Run correlation to create actors.
	corrReq := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	corrW := httptest.NewRecorder()
	mux.ServeHTTP(corrW, corrReq)
	if corrW.Code != http.StatusOK {
		t.Fatalf("correlate: want 200, got %d", corrW.Code)
	}

	// Now query stats.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/store/stats", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("store/stats: want 200, got %d, body: %s", w.Code, w.Body.String())
	}

	var resp StoreStatsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.TotalObservations != 3 {
		t.Errorf("want 3 observations, got %d", resp.TotalObservations)
	}

	if got := resp.ObservationsByLayer["network_egress"]; got != 2 {
		t.Errorf("want 2 network_egress observations, got %d", got)
	}

	if got := resp.ObservationsByLayer["identity_authorization"]; got != 1 {
		t.Errorf("want 1 identity_authorization observation, got %d", got)
	}

	if got := resp.ObservationsByFidelity["strong"]; got != 1 {
		t.Errorf("want 1 strong observation, got %d", got)
	}

	if got := resp.ObservationsByFidelity["definitive"]; got != 1 {
		t.Errorf("want 1 definitive observation, got %d", got)
	}

	if resp.LastIngestion == nil {
		t.Fatal("last_ingestion must not be nil when there are observations")
	}

	// The handler records the actual store type.
	_ = h // ensure h is used
	if resp.StoreType == "" {
		t.Error("store type must not be empty")
	}
}
