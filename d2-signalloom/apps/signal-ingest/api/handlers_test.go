package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func newTestHandlers(t *testing.T) (*Handlers, *http.ServeMux) {
	t.Helper()
	return newTestHandlersWithAudit(t, audit.NewFakeWriter())
}

func newTestHandlersWithAudit(t *testing.T, aw audit.AuditWriter) (*Handlers, *http.ServeMux) {
	t.Helper()
	s := store.NewMemoryStore()
	e, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}
	h := &Handlers{Store: s, Engine: e, Audit: aw}
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

// TestCorrelate_WritesAuditEvents verifies correlation_run and actor_created
// audit events are emitted when correlation discovers actors.
func TestCorrelate_WritesAuditEvents(t *testing.T) {
	fake := audit.NewFakeWriter()
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "ca-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "audit-bot"},
		{ID: "ca-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "audit-bot"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("correlate: want 200, got %d", w.Code)
	}

	corrEvents := fake.EventsByType(audit.EventCorrelationRun)
	if len(corrEvents) != 1 {
		t.Errorf("want 1 correlation_run event, got %d", len(corrEvents))
	}

	actorEvents := fake.EventsByType(audit.EventActorCreated)
	if len(actorEvents) == 0 {
		t.Error("want at least 1 actor_created event, got 0")
	}
}

// TestSeed_WritesCollectorRunAudit verifies seed emits a collector_run event.
func TestSeed_WritesCollectorRunAudit(t *testing.T) {
	fake := audit.NewFakeWriter()
	_, mux := newTestHandlersWithAudit(t, fake)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/collectors/seed", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("seed: want 201, got %d", w.Code)
	}

	collectorEvents := fake.EventsByType(audit.EventCollectorRun)
	if len(collectorEvents) != 1 {
		t.Errorf("want 1 collector_run event, got %d", len(collectorEvents))
	}
}

// TestAuditFailure_DoesNotBreakCorrelate verifies fail-open on audit errors.
func TestAuditFailure_DoesNotBreakCorrelate(t *testing.T) {
	fake := audit.NewFakeWriter()
	fake.FailWith = errors.New("connection refused")
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "af-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "fail-bot"},
		{ID: "af-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "fail-bot"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("correlate should succeed despite audit failure: want 200, got %d", w.Code)
	}
}
