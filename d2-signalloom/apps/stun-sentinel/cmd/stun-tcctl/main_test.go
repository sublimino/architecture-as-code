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
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
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
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete, http.MethodPatch} {
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

func TestTriggerHandlerMissingInterface(t *testing.T) {
	for _, isolate := range []bool{true, false} {
		handler := triggerHandler(nil, nil, isolate)

		// POST without interface query param -> 400 Bad Request with JSON error
		reqPost := httptest.NewRequest(http.MethodPost, "/v1/isolate", nil)
		recPost := httptest.NewRecorder()
		handler(recPost, reqPost)

		if recPost.Code != http.StatusBadRequest {
			t.Fatalf("POST without interface expected 400, got %d", recPost.Code)
		}
		if ct := recPost.Header().Get("Content-Type"); ct != "application/json" {
			t.Fatalf("POST without interface Content-Type=%q, want application/json", ct)
		}
		if !strings.Contains(recPost.Body.String(), "interface query parameter required") {
			t.Fatalf("POST without interface unexpected body: %q", recPost.Body.String())
		}
	}
}

func TestMuxUnmatchedRoutesHEAD(t *testing.T) {
	mux := newMux(nil, nil)

	for _, path := range []string{"/unknown", "/v1/unknown", "/health/subpath", "/metrics/sub"} {
		req := httptest.NewRequest(http.MethodHead, path, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Errorf("HEAD %s returned status %d, want 404", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s returned body %q, want empty body", path, rec.Body.String())
		}
	}
}

func TestTriggerHandler_DryRunExecutionAndNonVethRejection(t *testing.T) {
	l := tc.NewDryRunLoader()
	if err := l.Load(); err != nil {
		t.Fatalf("failed to load dry-run loader: %v", err)
	}
	defer l.Close()
	reg := tc.NewRegistry()

	// 1. Non-veth device (eth0, lo, docker0) must be rejected with 403 Forbidden
	for _, dev := range []string{"eth0", "lo", "docker0", "br-12345"} {
		handler := triggerHandler(l, reg, true)
		req := httptest.NewRequest(http.MethodPost, "/v1/isolate?interface="+dev, nil)
		rec := httptest.NewRecorder()
		handler(rec, req)

		if rec.Code != http.StatusForbidden {
			t.Errorf("POST isolate non-veth %s: want 403, got %d", dev, rec.Code)
		}
		if !strings.Contains(rec.Body.String(), "device") && !strings.Contains(rec.Body.String(), "veth") {
			t.Errorf("POST isolate non-veth %s: unexpected body %q", dev, rec.Body.String())
		}

		// HEAD on non-veth direct handler call must suppress body
		reqHead := httptest.NewRequest(http.MethodHead, "/v1/isolate?interface="+dev, nil)
		recHead := httptest.NewRecorder()
		handler(recHead, reqHead)
		// Method gate rejects HEAD before handler body logic
		if recHead.Code != http.StatusMethodNotAllowed {
			t.Errorf("HEAD isolate: want 405, got %d", recHead.Code)
		}
		if recHead.Body.Len() != 0 {
			t.Errorf("HEAD isolate: want empty body, got %d bytes", recHead.Body.Len())
		}
	}

	// 2. Non-existent veth interface returns 500 Internal Server Error (interface does not exist in host netns)
	isoHandler := triggerHandler(l, reg, true)
	reqIso := httptest.NewRequest(http.MethodPost, "/v1/isolate?interface=veth12345&ip=10.244.0.12", nil)
	recIso := httptest.NewRecorder()
	isoHandler(recIso, reqIso)

	if recIso.Code != http.StatusInternalServerError {
		t.Fatalf("POST isolate missing veth: want 500, got %d: %s", recIso.Code, recIso.Body.String())
	}
	if !strings.Contains(recIso.Body.String(), "interface no longer exists") {
		t.Errorf("POST isolate missing veth unexpected body: %s", recIso.Body.String())
	}

	// 3. Release on valid veth in dryRun mode succeeds (fail-open idempotent semantics)
	relHandler := triggerHandler(l, reg, false)
	reqRel := httptest.NewRequest(http.MethodPost, "/v1/release?interface=veth12345&ip=10.244.0.12", nil)
	recRel := httptest.NewRecorder()
	relHandler(recRel, reqRel)

	if recRel.Code != http.StatusOK {
		t.Fatalf("POST release dry-run veth: want 200, got %d: %s", recRel.Code, recRel.Body.String())
	}
	if !strings.Contains(recRel.Body.String(), `"action":"release"`) {
		t.Errorf("POST release dry-run veth unexpected body: %s", recRel.Body.String())
	}
}


