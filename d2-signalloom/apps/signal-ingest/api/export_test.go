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
