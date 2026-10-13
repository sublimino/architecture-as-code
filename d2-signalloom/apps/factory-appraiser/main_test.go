package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fixedNow is the clock every appraise test pins, so a verdict can only move
// with the request body and never with wall-clock time.
var fixedNow = time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)

func postAppraise(t *testing.T, body string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/factory/appraise", bytes.NewBufferString(body))
	rec := httptest.NewRecorder()
	appraiseHandler(func() time.Time { return fixedNow })(rec, req)

	var decoded map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("response is not JSON (status %d): %v: %s", rec.Code, err, rec.Body.String())
	}
	return rec, decoded
}

func appraisalField(t *testing.T, decoded map[string]any, key string) any {
	t.Helper()
	appraisal, ok := decoded["appraisal"].(map[string]any)
	if !ok {
		t.Fatalf("response has no appraisal object: %v", decoded)
	}
	return appraisal[key]
}

// TestAppraiseHandlerFlagsStaleCandidateFromRequestBody is the headline
// regression: a candidate far past the TTL must escalate. Reinstating
// Appraise(nil, nil, ...) turns this red.
func TestAppraiseHandlerFlagsStaleCandidateFromRequestBody(t *testing.T) {
	rec, decoded := postAppraise(t, `{
		"candidates": [
			{"candidate_id": "cand-stale", "intent_id": "intent-1", "created_at": "2020-01-01T00:00:00Z"}
		]
	}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if got := appraisalField(t, decoded, "status"); got != "escalated" {
		t.Fatalf("want status escalated for a 2020 candidate, got %v", got)
	}
	esc, ok := decoded["escalation"].(map[string]any)
	if !ok {
		t.Fatalf("want an escalation record for a stale candidate, got %v", decoded["escalation"])
	}
	if esc["target_oncall"] == nil || esc["target_oncall"] == "" {
		t.Fatalf("escalation must name an oncall target: %v", esc)
	}
	stale, _ := appraisalField(t, decoded, "stale_candidates").([]any)
	if len(stale) != 1 || stale[0] != "cand-stale" {
		t.Fatalf("want cand-stale listed as stale, got %v", stale)
	}
}

// TestAppraiseHandlerKeepsFreshCandidateActive proves the verdict moves with
// the input in both directions, so "escalated" is not simply hardcoded.
func TestAppraiseHandlerKeepsFreshCandidateActive(t *testing.T) {
	fresh := fixedNow.Add(-1 * time.Minute).Format(time.RFC3339)
	_, decoded := postAppraise(t, `{
		"candidates": [
			{"candidate_id": "cand-fresh", "intent_id": "intent-1", "created_at": "`+fresh+`"}
		]
	}`)
	if got := appraisalField(t, decoded, "status"); got != "healthy" {
		t.Fatalf("want status healthy for a 1-minute-old candidate, got %v", got)
	}
	if decoded["escalation"] != nil {
		t.Fatalf("want no escalation for a fresh candidate, got %v", decoded["escalation"])
	}
	active, _ := appraisalField(t, decoded, "active_candidates").([]any)
	if len(active) != 1 || active[0] != "cand-fresh" {
		t.Fatalf("want cand-fresh listed as active, got %v", active)
	}
}

// TestAppraiseHandlerHonoursIntentExpiry proves the intents map is read from
// the body too: an unexpired candidate under an expired intent is stale.
func TestAppraiseHandlerHonoursIntentExpiry(t *testing.T) {
	fresh := fixedNow.Add(-1 * time.Minute).Format(time.RFC3339)
	_, decoded := postAppraise(t, `{
		"candidates": [
			{"candidate_id": "cand-fresh", "intent_id": "intent-1", "created_at": "`+fresh+`"}
		],
		"intents": {
			"intent-1": {"id": "intent-1", "expiry": "2020-06-01T00:00:00Z"}
		}
	}`)
	if got := appraisalField(t, decoded, "status"); got != "escalated" {
		t.Fatalf("want escalated when the candidate's intent has expired, got %v", got)
	}
}

// TestAppraiseHandlerHonoursCallerStaleTTL proves the TTL is a parameter of the
// request, not a constant baked into the verdict.
func TestAppraiseHandlerHonoursCallerStaleTTL(t *testing.T) {
	aged := fixedNow.Add(-45 * time.Minute).Format(time.RFC3339)
	body := `{"stale_ttl_minutes": %d, "candidates": [{"candidate_id": "cand-aged", "intent_id": "i", "created_at": "` + aged + `"}]}`

	if _, decoded := postAppraise(t, strings.Replace(body, "%d", "30", 1)); appraisalField(t, decoded, "status") != "escalated" {
		t.Fatalf("45-minute-old candidate must be stale under a 30-minute TTL")
	}
	if _, decoded := postAppraise(t, strings.Replace(body, "%d", "90", 1)); appraisalField(t, decoded, "status") != "healthy" {
		t.Fatalf("45-minute-old candidate must be active under a 90-minute TTL")
	}
}

// TestAppraiseHandlerRefusesEmptyCandidateSet pins the refusal: no candidates
// is not an all-clear, so the route must not answer "healthy" with no inputs.
func TestAppraiseHandlerRefusesEmptyCandidateSet(t *testing.T) {
	for name, body := range map[string]string{
		"empty object":     `{}`,
		"empty candidates": `{"candidates": []}`,
	} {
		t.Run(name, func(t *testing.T) {
			rec, decoded := postAppraise(t, body)
			if rec.Code != http.StatusUnprocessableEntity {
				t.Fatalf("want 422 with no candidates, got %d: %s", rec.Code, rec.Body.String())
			}
			if decoded["error"] != "insufficient_input" {
				t.Fatalf("want error insufficient_input, got %v", decoded["error"])
			}
			if reason, ok := decoded["reason"].(string); !ok || reason == "" {
				t.Fatalf("a refusal must carry a reason, got %v", decoded["reason"])
			}
			if strings.Contains(rec.Body.String(), "healthy") {
				t.Fatalf("a refusal must never read as healthy: %s", rec.Body.String())
			}
		})
	}
}

// TestAppraiseHandlerRejectsMalformedBody keeps the route from silently
// degrading a bad request into an appraisal of nothing.
func TestAppraiseHandlerRejectsMalformedBody(t *testing.T) {
	rec, _ := postAppraise(t, `{"candidates": "not-a-list"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for a malformed body, got %d: %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "healthy") {
		t.Fatalf("a rejected request must never read as healthy: %s", rec.Body.String())
	}
}

// TestAppraiseHandlerRejectsOversizedBody verifies MaxBytesReader bounds payloads to 4 MiB.
func TestAppraiseHandlerRejectsOversizedBody(t *testing.T) {
	hugeString := strings.Repeat("x", 5<<20)
	body := `{"candidates": [{"candidate_id": "` + hugeString + `", "intent_id": "i", "created_at": "2026-10-12T08:00:00Z"}]}`
	rec, _ := postAppraise(t, body)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for oversized payload, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestHealthProbes(t *testing.T) {
	mux := newMux(func() time.Time { return fixedNow })
	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("path %s returned status %d, want 200", path, rec.Code)
		}
		var resp map[string]string
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatalf("path %s returned invalid json: %v", path, err)
		}
		if resp["status"] != "ok" {
			t.Fatalf("path %s status = %q, want 'ok'", path, resp["status"])
		}

		headReq := httptest.NewRequest(http.MethodHead, path, nil)
		headRec := httptest.NewRecorder()
		mux.ServeHTTP(headRec, headReq)
		if headRec.Code != http.StatusOK {
			t.Fatalf("path %s HEAD returned status %d, want 200", path, headRec.Code)
		}
		if headRec.Body.Len() != 0 {
			t.Fatalf("path %s HEAD returned %d body bytes, want 0", path, headRec.Body.Len())
		}

		// Disallowed methods (POST, PUT, DELETE, PATCH) -> 405 with Allow: GET, HEAD
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			mReq := httptest.NewRequest(method, path, nil)
			mRec := httptest.NewRecorder()
			mux.ServeHTTP(mRec, mReq)
			if mRec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("path %s %s returned status %d, want 405", path, method, mRec.Code)
			}
			if allow := mRec.Header().Get("Allow"); !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") {
				t.Fatalf("path %s %s expected Allow header containing GET, HEAD, got %q", path, method, allow)
			}
		}
	}
}

func TestMethodRejection_FactoryRoutes(t *testing.T) {
	mux := newMux(func() time.Time { return fixedNow })
	factoryRoutes := []string{
		"/api/v1/factory/appraise",
		"/api/v1/factory/validate-promotion",
	}

	for _, path := range factoryRoutes {
		for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req := httptest.NewRequest(method, path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s returned status %d, want 405", method, path, rec.Code)
			}
			if allow := rec.Header().Get("Allow"); !strings.Contains(allow, "POST") {
				t.Errorf("%s %s Allow = %q, want containing POST", method, path, allow)
			}
		}

		// HEAD -> 405 with Allow: POST and 0 body bytes
		headReq := httptest.NewRequest(http.MethodHead, path, nil)
		headRec := httptest.NewRecorder()
		mux.ServeHTTP(headRec, headReq)
		if headRec.Code != http.StatusMethodNotAllowed {
			t.Errorf("HEAD %s returned status %d, want 405", path, headRec.Code)
		}
		if allow := headRec.Header().Get("Allow"); !strings.Contains(allow, "POST") {
			t.Errorf("HEAD %s Allow = %q, want containing POST", path, allow)
		}
		if headRec.Body.Len() != 0 {
			t.Errorf("HEAD %s returned %d body bytes, want 0", path, headRec.Body.Len())
		}
	}
}

func TestValidationErrors_ContentTypeJSON(t *testing.T) {
	mux := newMux(func() time.Time { return fixedNow })

	req := httptest.NewRequest(http.MethodPost, "/api/v1/factory/validate-promotion", bytes.NewBufferString(`{invalid json`))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("want Content-Type application/json, got %q", ct)
	}
}

func TestAppraiseErrors_ContentTypeJSON(t *testing.T) {
	mux := newMux(func() time.Time { return fixedNow })

	for _, tc := range []struct {
		name string
		body string
		want int
	}{
		{"malformed_json", `{invalid`, http.StatusBadRequest},
		{"empty_candidates", `{"candidates":[]}`, http.StatusUnprocessableEntity},
		{"negative_stale_ttl", `{"stale_ttl_minutes": -5, "candidates":[{"candidate_id":"c1"}]}`, http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/factory/appraise", bytes.NewBufferString(tc.body))
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("want status %d, got %d: %s", tc.want, rec.Code, rec.Body.String())
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Fatalf("want Content-Type application/json, got %q", ct)
			}
		})
	}
}

func TestHeadErrorBodySuppression(t *testing.T) {
	mux := newMux(func() time.Time { return fixedNow })

	// 1. Mux-level tests: POST-only routes should return 405 on HEAD with 0 body bytes and Allow header.
	muxCases := []struct {
		name string
		path string
		want int
	}{
		{"appraise_head_405", "/api/v1/factory/appraise", http.StatusMethodNotAllowed},
		{"validate_head_405", "/api/v1/factory/validate-promotion", http.StatusMethodNotAllowed},
		{"unknown_route_head_404", "/api/v1/factory/unknown-route-999", http.StatusNotFound},
	}

	for _, tc := range muxCases {
		t.Run("mux_"+tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodHead, tc.path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)

			if rec.Code != tc.want {
				t.Fatalf("want status %d, got %d", tc.want, rec.Code)
			}
			if rec.Body.Len() != 0 {
				t.Fatalf("expected 0 body bytes on HEAD request, got %d: %q", rec.Body.Len(), rec.Body.String())
			}
			if tc.want == http.StatusMethodNotAllowed {
				if allow := rec.Header().Get("Allow"); !strings.Contains(allow, "POST") {
					t.Fatalf("want Allow header containing POST, got %q", allow)
				}
			}
		})
	}

	// 2. Direct handler invocation with HEAD: verify writeJSON body suppression when handler errors
	handlerCases := []struct {
		name string
		body string
		want int
	}{
		{"empty_candidates", `{"candidates":[]}`, http.StatusUnprocessableEntity},
		{"malformed_json", `{bad-json`, http.StatusBadRequest},
		{"negative_stale_ttl", `{"stale_ttl_minutes": -5, "candidates":[{"candidate_id":"c1"}]}`, http.StatusBadRequest},
	}

	handler := appraiseHandler(func() time.Time { return fixedNow })
	for _, tc := range handlerCases {
		t.Run("handler_"+tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodHead, "/api/v1/factory/appraise", bytes.NewBufferString(tc.body))
			rec := httptest.NewRecorder()
			handler(rec, req)

			if rec.Code != tc.want {
				t.Fatalf("want status %d, got %d", tc.want, rec.Code)
			}
			if rec.Body.Len() != 0 {
				t.Fatalf("expected 0 body bytes on HEAD request, got %d: %q", rec.Body.Len(), rec.Body.String())
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Fatalf("want Content-Type application/json, got %q", ct)
			}
		})
	}
}

func TestOptionsMethods(t *testing.T) {
	mux := newMux(func() time.Time { return fixedNow })

	cases := []struct {
		name      string
		path      string
		wantAllow string
	}{
		{"healthz", "/healthz", "GET, HEAD, OPTIONS"},
		{"readyz", "/readyz", "GET, HEAD, OPTIONS"},
		{"health", "/health", "GET, HEAD, OPTIONS"},
		{"appraise", "/api/v1/factory/appraise", "POST, OPTIONS"},
		{"validate_promotion", "/api/v1/factory/validate-promotion", "POST, OPTIONS"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodOptions, tc.path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)

			if rec.Code != http.StatusNoContent {
				t.Fatalf("want status %d, got %d: %s", http.StatusNoContent, rec.Code, rec.Body.String())
			}
			if rec.Body.Len() != 0 {
				t.Fatalf("expected empty body for OPTIONS, got %d bytes: %q", rec.Body.Len(), rec.Body.String())
			}
			gotAllow := rec.Header().Get("Allow")
			if gotAllow != tc.wantAllow {
				t.Fatalf("want Allow %q, got %q", tc.wantAllow, gotAllow)
			}
		})
	}
}

