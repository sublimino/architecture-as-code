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
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			rec := httptest.NewRecorder()
			a.routes().ServeHTTP(rec, httptest.NewRequest(method, path, nil))
			var body map[string]string
			_ = json.Unmarshal(rec.Body.Bytes(), &body)
			if rec.Code != http.StatusMethodNotAllowed || rec.Header().Get("Allow") != "GET, HEAD, OPTIONS" || body["error"] == "" {
				t.Errorf("%s %s = %d Allow=%q body=%q, want 405 Allow=GET, HEAD, OPTIONS with a JSON error",
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
		if rec.Header().Get("Allow") != "POST, OPTIONS" {
			t.Errorf("HEAD %s Allow header = %q, want POST, OPTIONS", path, rec.Header().Get("Allow"))
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD %s Content-Type = %q, want application/json", path, ct)
		}
	}
}

func TestNotFoundRouteSuppressesHEADBody(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	for _, path := range []string{"/not-found", "/act/unknown", "/api/v1/missing"} {
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodHead, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Errorf("HEAD %s = %d, want 404", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s wrote %d body bytes, want 0", path, rec.Body.Len())
		}
	}
}

func TestUpstreamMockMethodGatesAndHEADBodySuppression(t *testing.T) {
	srv := upstream(t, goodBody, http.StatusOK)

	// 1. GET returns 200 with quote JSON
	getReq, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	getResp, err := srv.Client().Do(getReq)
	if err != nil {
		t.Fatalf("GET upstream: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		t.Errorf("GET upstream status = %d, want 200", getResp.StatusCode)
	}

	// 2. HEAD returns 200 with 0 body bytes
	headReq, _ := http.NewRequest(http.MethodHead, srv.URL, nil)
	headResp, err := srv.Client().Do(headReq)
	if err != nil {
		t.Fatalf("HEAD upstream: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD upstream status = %d, want 200", headResp.StatusCode)
	}
	var buf [512]byte
	n, _ := headResp.Body.Read(buf[:])
	if n != 0 {
		t.Errorf("HEAD upstream wrote %d body bytes, want 0", n)
	}

	// 3. POST, PUT, DELETE, PATCH return 405 with Allow: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, _ := http.NewRequest(method, srv.URL, nil)
		resp, err := srv.Client().Do(req)
		if err != nil {
			t.Fatalf("%s upstream: %v", method, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s upstream status = %d, want 405", method, resp.StatusCode)
		}
		if got := resp.Header.Get("Allow"); got != "GET, HEAD" {
			t.Errorf("%s upstream Allow = %q, want %q", method, got, "GET, HEAD")
		}
	}
}

func TestActRoutesRejectNonPostMethodsWithAllowHeader(t *testing.T) {
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
		for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			rec := httptest.NewRecorder()
			a.routes().ServeHTTP(rec, httptest.NewRequest(method, path, nil))
			if rec.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s = %d, want 405 Method Not Allowed", method, path, rec.Code)
			}
			if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
				t.Errorf("%s %s Allow = %q, want POST, OPTIONS", method, path, allow)
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("%s %s Content-Type = %q, want application/json", method, path, ct)
			}
			var body map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Errorf("%s %s wrote invalid JSON: %v", method, path, err)
			}
			if body["error"] != "POST only" {
				t.Errorf("%s %s error = %v, want 'POST only'", method, path, body["error"])
			}
		}
	}
}

func TestPostOnlyDirectMethodGatingAndHEAD(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	handlerCalled := false
	handler := a.postOnly("unit-test", func(w http.ResponseWriter, r *http.Request) {
		handlerCalled = true
		writeJSON(w, http.StatusOK, map[string]string{"unit": "pass"})
	})

	// 1. POST invokes handler
	recPost := httptest.NewRecorder()
	handler(recPost, httptest.NewRequest(http.MethodPost, "/act/test", nil))
	if !handlerCalled || recPost.Code != http.StatusOK {
		t.Fatalf("POST did not invoke handler cleanly: code=%d", recPost.Code)
	}

	// 2. HEAD returns 405 with Allow: POST, OPTIONS, Content-Type: application/json, and empty body
	recHead := httptest.NewRecorder()
	handler(recHead, httptest.NewRequest(http.MethodHead, "/act/test", nil))
	if recHead.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD status = %d, want 405", recHead.Code)
	}
	if recHead.Header().Get("Allow") != "POST, OPTIONS" {
		t.Errorf("HEAD Allow = %q, want POST, OPTIONS", recHead.Header().Get("Allow"))
	}
	if ct := recHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD Content-Type = %q, want application/json", ct)
	}
	if recHead.Body.Len() != 0 {
		t.Errorf("HEAD wrote %d body bytes, want 0", recHead.Body.Len())
	}

	// 3. GET, PUT, DELETE, PATCH return 405 with Allow: POST, OPTIONS and JSON error body
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		rec := httptest.NewRecorder()
		handler(rec, httptest.NewRequest(method, "/act/test", nil))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s status = %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s Allow = %q, want POST, OPTIONS", method, allow)
		}
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Errorf("%s wrote invalid JSON: %v", method, err)
		}
		if body["error"] != "POST only" {
			t.Errorf("%s error = %v, want 'POST only'", method, body["error"])
		}
	}
}

func TestRoutesAcceptOPTIONS(t *testing.T) {
	a, _, _ := actAgent(t)

	// 1. Read-only routes answer OPTIONS with 204 No Content, Allow: GET, HEAD, OPTIONS, and empty body
	for _, path := range []string{"/quote", "/", "/stats", "/health", "/healthz", "/readyz"} {
		rec := httptest.NewRecorder()
		a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodOptions, path, nil))
		if rec.Code != http.StatusNoContent {
			t.Errorf("OPTIONS %s code = %d, want 204 No Content", path, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("OPTIONS %s Allow = %q, want GET, HEAD, OPTIONS", path, allow)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("OPTIONS %s wrote %d body bytes (%q), want 0", path, rec.Body.Len(), rec.Body.String())
		}
	}

	// 2. Act routes answer OPTIONS with 204 No Content, Allow: POST, OPTIONS, and empty body
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
		a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodOptions, path, nil))
		if rec.Code != http.StatusNoContent {
			t.Errorf("OPTIONS %s code = %d, want 204 No Content", path, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("OPTIONS %s Allow = %q, want POST, OPTIONS", path, allow)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("OPTIONS %s wrote %d body bytes (%q), want 0", path, rec.Body.Len(), rec.Body.String())
		}
	}

	// 3. Direct postOnly handler answers OPTIONS with 204 No Content, Allow: POST, OPTIONS, and empty body
	handler := a.postOnly("unit-test-options", func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("handler should not be called for OPTIONS request")
	})
	recDirect := httptest.NewRecorder()
	handler(recDirect, httptest.NewRequest(http.MethodOptions, "/act/test", nil))
	if recDirect.Code != http.StatusNoContent {
		t.Errorf("direct postOnly OPTIONS code = %d, want 204", recDirect.Code)
	}
	if allow := recDirect.Header().Get("Allow"); allow != "POST, OPTIONS" {
		t.Errorf("direct postOnly OPTIONS Allow = %q, want POST, OPTIONS", allow)
	}
	if recDirect.Body.Len() != 0 {
		t.Errorf("direct postOnly OPTIONS wrote %d body bytes, want 0", recDirect.Body.Len())
	}
}

