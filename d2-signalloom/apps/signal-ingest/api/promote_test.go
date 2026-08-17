package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
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

// TestPromoteActor_WritesAuditEvent verifies that a successful promote writes
// an actor_promoted audit event via the injected AuditWriter.
func TestPromoteActor_WritesAuditEvent(t *testing.T) {
	fake := audit.NewFakeWriter()
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "a-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "audit-test"},
		{ID: "a-2", Layer: model.LayerIdentityAuth, Source: "other", ActorHint: "audit-test"},
	}
	h.Store.Append(context.Background(), obs)

	actors, err := h.Engine.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) == 0 {
		t.Fatal("no actors created")
	}

	// Clear events from the correlation run so we isolate the promote event.
	fake.Reset()

	actorID := actors[0].ID
	req := httptest.NewRequest(http.MethodPost, "/api/v1/actors/"+actorID+"/promote", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("promote: want 200, got %d", w.Code)
	}

	promoted := fake.EventsByType(audit.EventActorPromoted)
	if len(promoted) != 1 {
		t.Fatalf("want 1 actor_promoted event, got %d", len(promoted))
	}
	if promoted[0].ActorID != actorID {
		t.Errorf("audit actor_id: want %s, got %s", actorID, promoted[0].ActorID)
	}
}

// TestPromoteActor_AuditFailureDoesNotCrash verifies that a broken audit
// writer does not prevent the promote from succeeding (fail-open).
func TestPromoteActor_AuditFailureDoesNotCrash(t *testing.T) {
	fake := audit.NewFakeWriter()
	fake.FailWith = errors.New("postgres connection refused")
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "f-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "fail-test"},
		{ID: "f-2", Layer: model.LayerIdentityAuth, Source: "other", ActorHint: "fail-test"},
	}
	h.Store.Append(context.Background(), obs)

	actors, err := h.Engine.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) == 0 {
		t.Fatal("no actors created")
	}

	actorID := actors[0].ID
	req := httptest.NewRequest(http.MethodPost, "/api/v1/actors/"+actorID+"/promote", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	// The handler should succeed even though audit writes fail.
	if w.Code != http.StatusOK {
		t.Errorf("promote should succeed despite audit failure: want 200, got %d", w.Code)
	}
}
