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

// TestPromoteActor_AuditFailureFailsClosed verifies that when the audit writer fails,
// the high-stakes promote operation fails closed with HTTP 503 Service Unavailable
// and refuses the promotion.
func TestPromoteActor_AuditFailureFailsClosed(t *testing.T) {
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

	// The handler must fail closed (503) when audit persistence fails.
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("promote should fail closed on audit error: want 503, got %d, body: %s", w.Code, w.Body.String())
	}
}

// TestPromoteActor_RespectsAuthenticatedTenantAudit verifies promote emits actor_promoted with caller's tenant.
func TestPromoteActor_RespectsAuthenticatedTenantAudit(t *testing.T) {
	fake := audit.NewFakeWriter()
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "p-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "bot-acme"},
		{ID: "p-2", Layer: model.LayerIdentityAuth, Source: "other", ActorHint: "bot-acme"},
	}
	h.Store.Append(context.Background(), obs)

	actors, err := h.Engine.Correlate(context.Background())
	if err != nil || len(actors) == 0 {
		t.Fatalf("correlate setup failed: err=%v, count=%d", err, len(actors))
	}
	fake.Reset()

	actorID := actors[0].ID
	req := httptest.NewRequest(http.MethodPost, "/api/v1/actors/"+actorID+"/promote", nil)
	req = req.WithContext(WithTenantContext(req.Context(), TenantContext{
		TenantID:  "tenant-acme",
		Principal: "user-acme",
	}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("promote: want 200, got %d", w.Code)
	}

	promoted := fake.EventsByType(audit.EventActorPromoted)
	if len(promoted) != 1 {
		t.Fatalf("want 1 actor_promoted event, got %d", len(promoted))
	}
	if promoted[0].TenantID != "tenant-acme" {
		t.Errorf("actor_promoted tenant: want tenant-acme, got %q", promoted[0].TenantID)
	}
}

func TestPromoteActor_MethodNotAllowedAndHEADBodySuppression(t *testing.T) {
	h, _ := newTestHandlers(t)

	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(method, "/api/v1/actors/some-actor/promote", nil)
		w := httptest.NewRecorder()
		h.handlePromoteActor(w, req)

		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handlePromoteActor got %d, want 405", method, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != "POST" {
			t.Errorf("%s Allow header = %q, want 'POST'", method, allow)
		}
		if w.Body.Len() == 0 {
			t.Errorf("%s expected error body, got empty", method)
		}
	}

	// Direct unwrapped HEAD request must return 405 with Allow: POST and 0-byte body per RFC 9110 Section 6.4.1
	headReq := httptest.NewRequest(http.MethodHead, "/api/v1/actors/some-actor/promote", nil)
	headRec := httptest.NewRecorder()
	h.handlePromoteActor(headRec, headReq)

	if headRec.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD handlePromoteActor got %d, want 405", headRec.Code)
	}
	if allow := headRec.Header().Get("Allow"); allow != "POST" {
		t.Errorf("HEAD Allow header = %q, want 'POST'", allow)
	}
	if headRec.Body.Len() != 0 {
		t.Errorf("HEAD response body not suppressed: got %d bytes %q", headRec.Body.Len(), headRec.Body.String())
	}

	// Middleware-wrapped HEAD response recorder check
	headRecWrapped := httptest.NewRecorder()
	wrappedRec := &headResponseWriter{ResponseWriter: headRecWrapped}
	h.handlePromoteActor(wrappedRec, headReq)
	if headRecWrapped.Code != http.StatusMethodNotAllowed {
		t.Errorf("wrapped HEAD handlePromoteActor got %d, want 405", headRecWrapped.Code)
	}
	if headRecWrapped.Body.Len() != 0 {
		t.Errorf("wrapped HEAD response body not suppressed: got %d bytes", headRecWrapped.Body.Len())
	}
}
