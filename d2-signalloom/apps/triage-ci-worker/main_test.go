package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthAndProbeEndpoints(t *testing.T) {
	mux := newMux()

	for _, endpoint := range []string{"/health", "/healthz", "/readyz"} {
		// GET
		req := httptest.NewRequest(http.MethodGet, endpoint, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s expected 200, got %d", endpoint, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("GET %s expected Content-Type text/plain; charset=utf-8, got %q", endpoint, ct)
		}
		if !strings.Contains(rec.Body.String(), "ok") {
			t.Fatalf("GET %s expected body containing ok, got %s", endpoint, rec.Body.String())
		}

		// HEAD
		reqHead := httptest.NewRequest(http.MethodHead, endpoint, nil)
		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, reqHead)

		if recHead.Code != http.StatusOK {
			t.Fatalf("HEAD %s expected 200, got %d", endpoint, recHead.Code)
		}
		if ct := recHead.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("HEAD %s expected Content-Type text/plain; charset=utf-8, got %q", endpoint, ct)
		}
		if recHead.Body.Len() != 0 {
			t.Fatalf("HEAD %s expected empty body, got %q", endpoint, recHead.Body.String())
		}

		// POST -> 405
		reqPost := httptest.NewRequest(http.MethodPost, endpoint, nil)
		recPost := httptest.NewRecorder()
		mux.ServeHTTP(recPost, reqPost)

		if recPost.Code != http.StatusMethodNotAllowed {
			t.Fatalf("POST %s expected 405 Method Not Allowed, got %d", endpoint, recPost.Code)
		}
		if recPost.Header().Get("Allow") != "GET, HEAD" {
			t.Fatalf("POST %s expected Allow: GET, HEAD, got %q", endpoint, recPost.Header().Get("Allow"))
		}
	}
}

func TestUnmatchedPathsReturn404(t *testing.T) {
	mux := newMux()

	unmatched := []string{
		"/unknown",
		"/api/v1/check",
		"/health/subpath",
		"/gate/request",
	}

	for _, path := range unmatched {
		// GET
		reqGet := httptest.NewRequest(http.MethodGet, path, nil)
		recGet := httptest.NewRecorder()
		mux.ServeHTTP(recGet, reqGet)

		if recGet.Code != http.StatusNotFound {
			t.Errorf("GET %s expected 404, got %d", path, recGet.Code)
		}

		// POST
		reqPost := httptest.NewRequest(http.MethodPost, path, bytes.NewReader([]byte(`{"test":true}`)))
		recPost := httptest.NewRecorder()
		mux.ServeHTTP(recPost, reqPost)

		if recPost.Code != http.StatusNotFound {
			t.Errorf("POST %s expected 404, got %d", path, recPost.Code)
		}

		// HEAD
		reqHead := httptest.NewRequest(http.MethodHead, path, nil)
		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, reqHead)

		if recHead.Code != http.StatusNotFound {
			t.Errorf("HEAD %s expected 404, got %d", path, recHead.Code)
		}
		if recHead.Body.Len() != 0 {
			t.Errorf("HEAD %s expected empty body, got %q", path, recHead.Body.String())
		}
	}
}

func TestRootMethodNotAllowed(t *testing.T) {
	mux := newMux()

	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(m, "/", nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s / expected 405 Method Not Allowed, got %d", m, rec.Code)
		}
		if rec.Header().Get("Allow") != "POST" {
			t.Fatalf("%s / expected Allow: POST, got %q", m, rec.Header().Get("Allow"))
		}
		if rec.Body.Len() == 0 {
			t.Fatalf("%s / expected non-empty error body", m)
		}
	}

	// HEAD -> 405 with Allow: POST and empty body
	reqHead := httptest.NewRequest(http.MethodHead, "/", nil)
	recHead := httptest.NewRecorder()
	mux.ServeHTTP(recHead, reqHead)
	if recHead.Code != http.StatusMethodNotAllowed {
		t.Fatalf("HEAD / expected 405 Method Not Allowed, got %d", recHead.Code)
	}
	if recHead.Header().Get("Allow") != "POST" {
		t.Fatalf("HEAD / expected Allow: POST, got %q", recHead.Header().Get("Allow"))
	}
	if recHead.Body.Len() != 0 {
		t.Fatalf("HEAD / expected empty body, got %q", recHead.Body.String())
	}
}

func TestRootCloudEventFiltering(t *testing.T) {
	mux := newMux()

	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Ce-Type", "unrelated.event.type")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 No Content for unhandled Ce-Type, got %d", rec.Code)
	}
}

func TestRootInvalidJSON(t *testing.T) {
	mux := newMux()

	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(`{invalid-json`)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request, got %d", rec.Code)
	}
}

func TestRootNonFailureSkipped(t *testing.T) {
	mux := newMux()

	body := `{"check_run":{"id":123,"conclusion":"success"}}`
	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 No Content for non-failure check run, got %d", rec.Code)
	}
}
