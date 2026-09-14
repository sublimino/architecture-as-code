package api

import "net/http"

// RegisterRoutes is a test-only naked handler mux for focused functional tests.
// Production code cannot access this method and must use NewProtectedRouter.
func (h *Handlers) RegisterRoutes(mux *http.ServeMux) {
	for _, route := range h.routeDefinitions(nil) {
		mux.HandleFunc(route.pattern, route.handler)
	}
}
