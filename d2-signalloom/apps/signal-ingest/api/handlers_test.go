package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func newTestHandlers(t *testing.T) (*Handlers, *http.ServeMux) {
	t.Helper()
	s := store.NewMemoryStore()
	e, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}
	h := &Handlers{Store: s, Engine: e}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	return h, mux
}

func TestHealthz(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("healthz: want 200, got %d", w.Code)
	}
}

func TestReadyz(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("readyz: want 200, got %d", w.Code)
	}
}

func TestIngestObservations(t *testing.T) {
	_, mux := newTestHandlers(t)

	obs := []model.Observation{
		{ID: "test-1", Layer: model.LayerNetworkEgress, Source: "test", Description: "test"},
	}
	body, _ := json.Marshal(obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("ingest: want 201, got %d, body: %s", w.Code, w.Body.String())
	}
}

func TestIngestObservations_EmptyArray(t *testing.T) {
	_, mux := newTestHandlers(t)

	body, _ := json.Marshal([]model.Observation{})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty array: want 400, got %d", w.Code)
	}
}

func TestQueryObservations(t *testing.T) {
	h, mux := newTestHandlers(t)

	obs := []model.Observation{
		{ID: "q-1", Layer: model.LayerNetworkEgress, Source: "test"},
		{ID: "q-2", Layer: model.LayerBehavioural, Source: "test"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/observations?layer=network_egress", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("query: want 200, got %d", w.Code)
	}

	var result []model.Observation
	json.NewDecoder(w.Body).Decode(&result)
	if len(result) != 1 {
		t.Errorf("want 1 result, got %d", len(result))
	}
}

func TestListActors_Empty(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("actors: want 200, got %d", w.Code)
	}

	var actors []*model.ProvisionalActor
	json.NewDecoder(w.Body).Decode(&actors)
	if len(actors) != 0 {
		t.Errorf("want 0 actors, got %d", len(actors))
	}
}

func TestGetActor_NotFound(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/nonexistent", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("actor not found: want 404, got %d", w.Code)
	}
}

func TestCoverage(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/coverage", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("coverage: want 200, got %d", w.Code)
	}

	var resp CoverageResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.CoveredLayers) != 5 {
		t.Errorf("want 5 covered layers, got %d", len(resp.CoveredLayers))
	}
	if len(resp.BlindSpots) != 5 {
		t.Errorf("want 5 blind spots, got %d", len(resp.BlindSpots))
	}
	if resp.DeploymentCoverage != "5 of 7 layers active" {
		t.Errorf("unexpected coverage: %s", resp.DeploymentCoverage)
	}
}

func TestSeedFixtures(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/collectors/seed", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("seed: want 201, got %d, body: %s", w.Code, w.Body.String())
	}
}

func TestCorrelate(t *testing.T) {
	h, mux := newTestHandlers(t)

	// Seed fixtures first.
	obs := []model.Observation{
		{ID: "c-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "bot"},
		{ID: "c-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "bot"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("correlate: want 200, got %d, body: %s", w.Code, w.Body.String())
	}
}
