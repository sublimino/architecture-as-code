// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthEndpoints(t *testing.T) {
	mux := newMux(nil, nil)

	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("path %s returned status %d, want 200", path, rec.Code)
		}
		if got := strings.TrimSpace(rec.Body.String()); got != "ok" {
			t.Fatalf("path %s returned body %q, want 'ok'", path, got)
		}
	}
}

func TestMetricsEndpoint(t *testing.T) {
	mux := newMux(nil, nil)

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("path /metrics returned status %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/plain") {
		t.Fatalf("unexpected content-type: %s", ct)
	}
}

func TestHealthAndMetricsMethodNotAllowed(t *testing.T) {
	mux := newMux(nil, nil)

	paths := []string{"/health", "/healthz", "/readyz", "/metrics"}
	for _, path := range paths {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
			req := httptest.NewRequest(method, path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)

			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s expected 405 Method Not Allowed, got %d", method, path, rec.Code)
			}
		}

		// HEAD should succeed
		reqHead := httptest.NewRequest(http.MethodHead, path, nil)
		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, reqHead)

		if recHead.Code != http.StatusOK {
			t.Fatalf("HEAD %s expected 200 OK, got %d", path, recHead.Code)
		}
	}
}

