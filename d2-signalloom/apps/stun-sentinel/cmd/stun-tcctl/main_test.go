// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/tc"
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
		if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("path %s returned Content-Type %q, want text/plain; charset=utf-8", path, ct)
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
			if rec.Header().Get("Allow") != "GET, HEAD" {
				t.Fatalf("%s %s expected Allow: GET, HEAD, got %q", method, path, rec.Header().Get("Allow"))
			}
		}

		// HEAD should succeed
		reqHead := httptest.NewRequest(http.MethodHead, path, nil)
		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, reqHead)

		if recHead.Code != http.StatusOK {
			t.Fatalf("HEAD %s expected 200 OK, got %d", path, recHead.Code)
		}
		if ct := recHead.Header().Get("Content-Type"); !strings.Contains(ct, "text/plain") {
			t.Fatalf("HEAD %s unexpected content-type: %s", path, ct)
		}
		if recHead.Body.Len() != 0 {
			t.Fatalf("HEAD %s expected empty body, got %q", path, recHead.Body.String())
		}
	}
}

func TestTriggerHandlerMethodNotAllowed(t *testing.T) {
	for _, isolate := range []bool{true, false} {
		handler := triggerHandler(nil, nil, isolate)
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete} {
			req := httptest.NewRequest(method, "/v1/isolate", nil)
			rec := httptest.NewRecorder()
			handler(rec, req)

			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s expected 405 Method Not Allowed, got %d", method, rec.Code)
			}
			if rec.Header().Get("Allow") != "POST" {
				t.Fatalf("%s expected Allow: POST, got %q", method, rec.Header().Get("Allow"))
			}
			if method == http.MethodHead && rec.Body.Len() != 0 {
				t.Fatalf("%s expected empty body on 405 Method Not Allowed, got %d bytes: %q", method, rec.Body.Len(), rec.Body.String())
			}
		}
	}
}

func TestMuxTriggerRoutesHEAD(t *testing.T) {
	mux := newMux(&tc.Loader{}, tc.NewRegistry())

	// HEAD /v1/isolate and /v1/release on the mux should return 405 with empty body
	for _, path := range []string{"/v1/isolate", "/v1/release"} {
		req := httptest.NewRequest(http.MethodHead, path, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("HEAD %s returned status %d, want 405", path, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST" {
			t.Fatalf("HEAD %s returned Allow %q, want POST", path, allow)
		}
		if rec.Body.Len() != 0 {
			t.Fatalf("HEAD %s returned body %q, want empty body", path, rec.Body.String())
		}
	}
}


