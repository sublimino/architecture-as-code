package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Every read-only route answers a non-GET/HEAD with 405, a JSON error body and an
// Allow header naming the methods it accepts (RFC 9110 §15.5.6).
func TestReadOnlyRoutesRejectWritesWithAllowHeader(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	for _, path := range []string{"/quote", "/", "/stats", "/health", "/healthz", "/readyz"} {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
			rec := httptest.NewRecorder()
			a.routes().ServeHTTP(rec, httptest.NewRequest(method, path, nil))
			var body map[string]string
			_ = json.Unmarshal(rec.Body.Bytes(), &body)
			if rec.Code != http.StatusMethodNotAllowed || rec.Header().Get("Allow") != "GET, HEAD" || body["error"] == "" {
				t.Errorf("%s %s = %d Allow=%q body=%q, want 405 Allow=GET, HEAD with a JSON error",
					method, path, rec.Code, rec.Header().Get("Allow"), rec.Body.String())
			}
		}
	}
	if a.requests.Load() != 0 {
		t.Fatal("rejected writes counted towards the hostile cadence")
	}
}

func TestReadOnlyRoutesAcceptHEAD(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	for _, path := range []string{"/quote", "/", "/stats", "/health", "/healthz", "/readyz"} {
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodHead, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("HEAD %s = %d, want 200", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s wrote body: %q", path, rec.Body.String())
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD %s Content-Type = %q, want application/json", path, ct)
		}
	}
	if a.requests.Load() != 0 {
		t.Fatal("HEAD requests counted towards requests count or hostile cadence")
	}
}

func TestActCPUBurnRejectsZeroAndOverflowingDurations(t *testing.T) {
	a, _, _ := actAgent(t)
	for _, q := range []string{"duration=0s", "duration=99999999999h", "threads=65", "threads=-1"} {
		rec, body := post(t, a.routes(), "/act/cpu-burn?"+q)
		if rec.Code != http.StatusBadRequest || body["ok"] != false || body["error"] == nil {
			t.Errorf("%s: code %d body %v, want 400 with an error", q, rec.Code, body)
		}
	}
}

func TestActRoutesRejectHEADWithoutBody(t *testing.T) {
	a, _, _ := actAgent(t)
	actRoutes := []string{
		"/act/read-passwd",
		"/act/read-shadow",
		"/act/cpu-burn",
		"/act/gpu-open",
		"/act/gpu-probe",
		"/act/exfil",
		"/act/kube-enum",
		"/act/recon",
	}
	for _, path := range actRoutes {
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodHead, path, nil))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("HEAD %s = %d, want 405 Method Not Allowed", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s wrote %d body bytes (%q), want 0", path, rec.Body.Len(), rec.Body.String())
		}
		if rec.Header().Get("Allow") != http.MethodPost {
			t.Errorf("HEAD %s Allow header = %q, want POST", path, rec.Header().Get("Allow"))
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD %s Content-Type = %q, want application/json", path, ct)
		}
	}
}

