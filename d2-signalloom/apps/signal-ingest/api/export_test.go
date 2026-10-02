package api

import (
	"context"
	"net/http"
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
			handler(w, r.WithContext(context.WithValue(r.Context(), principalContextKey{}, operator)))
		})
	}
}
