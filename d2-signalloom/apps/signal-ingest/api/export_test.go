package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
)

// RegisterRoutes is a test-only naked handler mux for focused functional tests.
// Production code cannot access this method and must use NewProtectedRouter.
//
// The naked mux bypasses authentication entirely, so it stands in an operator principal holding
// PermissionCrossTenantRead: these tests are about handler behaviour over the whole store, and a
// handler reached with no principal now reads nothing (observationReadScope). Tenancy itself is
// tested through NewProtectedRouter (tenancy_test.go), never through this mux.
func (h *Handlers) RegisterRoutes(mux *http.ServeMux) {
	operator := Principal{Subject: "test/naked-mux-operator", TenantID: "tenant-demo",
		Permissions: map[Permission]bool{PermissionCrossTenantRead: true}}
	for _, route := range h.routeDefinitions(nil) {
		handler := route.handler
		mux.HandleFunc(route.pattern, func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodHead {
				w = &headResponseWriter{ResponseWriter: w}
			}
			ctx := r.Context()
			if _, ok := PrincipalFromContext(ctx); !ok {
				if tc, ok := TenantContextFromContext(ctx); ok && tc.TenantID != "" {
					p := Principal{
						Subject:     tc.Principal,
						TenantID:    tc.TenantID,
						Permissions: map[Permission]bool{PermissionCrossTenantRead: true},
					}
					ctx = context.WithValue(ctx, principalContextKey{}, p)
				} else {
					ctx = context.WithValue(ctx, principalContextKey{}, operator)
				}
			}
			handler(w, r.WithContext(ctx))
		})
	}
}

func TestExportSubject_MethodGatesAndHEAD(t *testing.T) {
	h, _ := newTestHandlers(t)

	obs := collectors.SeedAll(time.Now().UTC())
	_ = h.Store.Append(context.Background(), obs)
	actors, _ := h.Engine.Correlate(context.Background())
	if len(actors) == 0 {
		t.Fatal("no actors")
	}
	actorID := actors[0].ID

	testCtx := WithTenantContext(context.Background(), TenantContext{
		TenantID:  "tenant-demo",
		Principal: actorID,
	})
	testCtx = context.WithValue(testCtx, principalContextKey{}, Principal{
		Subject:     actorID,
		TenantID:    "tenant-demo",
		Permissions: map[Permission]bool{PermissionCrossTenantRead: true, PermissionPrivacyExport: true},
		ActorIDs:    map[string]bool{actorID: true},
	})

	// 1. Disallowed methods return 405 with Allow: GET, HEAD and non-empty error body
	for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/api/v1/privacy/export/"+actorID, nil).WithContext(testCtx)
		req.SetPathValue("id", actorID)
		w := httptest.NewRecorder()
		h.handleExportSubject(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleExportSubject got %d, want 405", m, w.Code)
		}
		if allow := w.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Errorf("%s handleExportSubject got Allow %q, want 'GET, HEAD'", m, allow)
		}
		if w.Body.Len() == 0 {
			t.Errorf("%s handleExportSubject expected non-empty error body", m)
		}
	}

	// 2. HEAD on valid subject returns 200 with 0 body bytes and Content-Type: application/json
	reqHead := httptest.NewRequest(http.MethodHead, "/api/v1/privacy/export/"+actorID, nil).WithContext(testCtx)
	reqHead.SetPathValue("id", actorID)
	wHead := httptest.NewRecorder()
	h.handleExportSubject(wHead, reqHead)
	if wHead.Code != http.StatusOK {
		t.Fatalf("HEAD handleExportSubject got %d, want 200 (body: %s)", wHead.Code, wHead.Body.String())
	}
	if wHead.Body.Len() != 0 {
		t.Errorf("HEAD handleExportSubject got %d body bytes, want 0", wHead.Body.Len())
	}
	if ct := wHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD handleExportSubject Content-Type = %q, want 'application/json'", ct)
	}

	// 3. GET on valid subject returns 200 or processed payload
	reqGet := httptest.NewRequest(http.MethodGet, "/api/v1/privacy/export/"+actorID, nil).WithContext(testCtx)
	reqGet.SetPathValue("id", actorID)
	wGet := httptest.NewRecorder()
	h.handleExportSubject(wGet, reqGet)
	if wGet.Code != http.StatusOK {
		t.Fatalf("GET handleExportSubject got %d, want 200 (body: %s)", wGet.Code, wGet.Body.String())
	}
	if wGet.Body.Len() == 0 {
		t.Errorf("GET handleExportSubject expected non-empty body")
	}

	// 4. Missing subject id returns 400
	reqNoID := httptest.NewRequest(http.MethodGet, "/api/v1/privacy/export/", nil).WithContext(testCtx)
	wNoID := httptest.NewRecorder()
	h.handleExportSubject(wNoID, reqNoID)
	if wNoID.Code != http.StatusBadRequest {
		t.Errorf("missing subject ID got %d, want 400", wNoID.Code)
	}

	// 5. Non-existent subject returns 403 or 404
	reqNotFound := httptest.NewRequest(http.MethodGet, "/api/v1/privacy/export/non-existent-actor", nil).WithContext(testCtx)
	reqNotFound.SetPathValue("id", "non-existent-actor")
	wNotFound := httptest.NewRecorder()
	h.handleExportSubject(wNotFound, reqNotFound)
	if wNotFound.Code != http.StatusForbidden && wNotFound.Code != http.StatusNotFound {
		t.Errorf("non-existent subject ID got %d, want 403 or 404", wNotFound.Code)
	}
}

