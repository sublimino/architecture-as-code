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
