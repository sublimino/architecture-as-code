package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestPromoteActor_NotFound(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/actors/nonexistent/promote", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("promote not found: want 404, got %d", w.Code)
	}
}

func TestPromoteActor_Success(t *testing.T) {
	h, mux := newTestHandlers(t)

	// Seed and correlate to create an actor.
	obs := []model.Observation{
		{ID: "p-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "promote-test"},
		{ID: "p-2", Layer: model.LayerIdentityAuth, Source: "other", ActorHint: "promote-test"},
	}
	h.Store.Append(context.Background(), obs)

	// Run correlation to create the actor.
	actors, err := h.Engine.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) == 0 {
		t.Fatal("no actors created from correlation")
	}

	actorID := actors[0].ID
	req := httptest.NewRequest(http.MethodPost, "/api/v1/actors/"+actorID+"/promote", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("promote: want 200, got %d, body: %s", w.Code, w.Body.String())
	}
}
