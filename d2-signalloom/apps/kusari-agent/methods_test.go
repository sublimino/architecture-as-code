package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Every read-only route answers a non-GET with 405, a JSON error body and an
// Allow header naming the one method it accepts (RFC 9110 §15.5.6).
func TestReadOnlyRoutesRejectWritesWithAllowHeader(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	for _, path := range []string{"/quote", "/", "/stats", "/healthz"} {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
			rec := httptest.NewRecorder()
			a.routes().ServeHTTP(rec, httptest.NewRequest(method, path, nil))
			var body map[string]string
			_ = json.Unmarshal(rec.Body.Bytes(), &body)
			if rec.Code != http.StatusMethodNotAllowed || rec.Header().Get("Allow") != http.MethodGet || body["error"] == "" {
				t.Errorf("%s %s = %d Allow=%q body=%q, want 405 Allow=GET with a JSON error",
					method, path, rec.Code, rec.Header().Get("Allow"), rec.Body.String())
			}
		}
	}
	if a.requests.Load() != 0 {
		t.Fatal("rejected writes counted towards the hostile cadence")
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
