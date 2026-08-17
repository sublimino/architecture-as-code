package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// adversarialSetup creates a Handlers wired to MemoryStore + default engine + FakeWriter.
func adversarialSetup(t *testing.T) (*Handlers, *http.ServeMux, *store.MemoryStore, *audit.FakeWriter) {
	t.Helper()
	ms := store.NewMemoryStore()
	eng, err := correlation.NewEngine(ms)
	if err != nil {
		t.Fatalf("NewEngine: %v", err)
	}
	fw := audit.NewFakeWriter()
	h := &Handlers{Store: ms, Engine: eng, Audit: fw}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	return h, mux, ms, fw
}

func advIngestBody(t *testing.T, observations []model.Observation) *bytes.Buffer {
	t.Helper()
	b, err := json.Marshal(observations)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return bytes.NewBuffer(b)
}

// advValidObs returns a minimal valid observation.
func advValidObs(id string) model.Observation {
	return model.Observation{
		ID:             id,
		Timestamp:      time.Date(2026, 1, 15, 12, 0, 0, 0, time.UTC),
		Layer:          model.LayerNetworkEgress,
		Fidelity:       model.FidelitySuggestive,
		Source:         "test-source",
		Confidence:     0.5,
		RawEvidenceRef: "ref-" + id,
		Description:    "test observation " + id,
	}
}

// --- Attack Vector 1: Malformed Observations ---

func TestAdv_Ingest_EmptyBody(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)
	req := httptest.NewRequest("POST", "/api/v1/observations", strings.NewReader(""))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("empty body: got %d, want 400", w.Code)
	}
}

func TestAdv_Ingest_InvalidJSON(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)
	req := httptest.NewRequest("POST", "/api/v1/observations", strings.NewReader("{not json"))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("invalid JSON: got %d, want 400", w.Code)
	}
}

func TestAdv_Ingest_EmptyArray(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)
	req := httptest.NewRequest("POST", "/api/v1/observations", strings.NewReader("[]"))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("empty array: got %d, want 400", w.Code)
	}
}

func TestAdv_Ingest_MissingRequiredFields(t *testing.T) {
	// FINDING: The service silently accepts observations with empty ID,
	// empty Layer, empty Fidelity, zero Timestamp — no validation at all.
	// This is a silent-accept bug. We pin the test and fix the handler.
	_, mux, ms, _ := adversarialSetup(t)

	obs := []model.Observation{{}} // all zero values
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, obs))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("missing required fields: got %d, want 400; body: %s", w.Code, w.Body.String())
	}

	// Verify nothing was stored
	all, _ := ms.QueryRange(context.Background(), store.Query{})
	if len(all) != 0 {
		t.Errorf("expected 0 stored observations after rejection, got %d", len(all))
	}
}

func TestAdv_Ingest_EmptyStringID(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("test-1")
	obs.ID = ""
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty ID: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_InvalidLayerName(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("test-invalid-layer")
	obs.Layer = "not_a_real_layer"
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("invalid layer: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_InvalidFidelityTier(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("test-invalid-fidelity")
	obs.Fidelity = "ultra_mega"
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("invalid fidelity: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_ZeroTimestamp(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("test-zero-ts")
	obs.Timestamp = time.Time{} // zero
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("zero timestamp: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_NaNConfidence(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	// Go's json.Marshal rejects NaN, so craft raw JSON with string "NaN"
	raw := `[{"id":"nan-obs","timestamp":"2026-01-15T12:00:00Z","layer":"behavioural","fidelity":"suggestive","source":"s","confidence":"NaN","raw_evidence_ref":"r","description":"d"}]`
	req := httptest.NewRequest("POST", "/api/v1/observations", strings.NewReader(raw))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	// Should reject: NaN is not valid JSON for a float
	if w.Code != http.StatusBadRequest {
		t.Errorf("NaN confidence: got %d, want 400", w.Code)
	}
}

func TestAdv_Ingest_NegativeConfidence(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("neg-conf")
	obs.Confidence = -0.5
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("negative confidence: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_ConfidenceGreaterThanOne(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("over-conf")
	obs.Confidence = 1.5
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("confidence > 1: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_InfinityConfidence(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	// 1e999 overflows to +Inf in Go's JSON decoder
	raw := `[{"id":"inf-obs","timestamp":"2026-01-15T12:00:00Z","layer":"behavioural","fidelity":"suggestive","source":"s","confidence":1e999,"raw_evidence_ref":"r","description":"d"}]`
	req := httptest.NewRequest("POST", "/api/v1/observations", strings.NewReader(raw))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Inf confidence: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_DuplicateObservationIDs(t *testing.T) {
	// FINDING: duplicate IDs are silently accepted and stored.
	// Pin the behaviour — at minimum the service should not panic.
	_, mux, ms, _ := adversarialSetup(t)

	obs := []model.Observation{advValidObs("dup-1"), advValidObs("dup-1")}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, obs))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	// We accept duplicates for now (idempotency is not enforced), but must not panic
	if w.Code >= 500 {
		t.Errorf("duplicate IDs caused 5xx: %d; body: %s", w.Code, w.Body.String())
	}

	all, _ := ms.QueryRange(context.Background(), store.Query{})
	if len(all) == 0 {
		t.Error("expected observations to be stored (duplicate or not)")
	}
}

func TestAdv_Ingest_EmptySource(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("empty-source")
	obs.Source = ""
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty source: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

// --- Attack Vector 2: Boundary Conditions (query params) ---

func TestAdv_Query_AfterGreaterThanBefore(t *testing.T) {
	_, mux, ms, _ := adversarialSetup(t)

	ms.Append(context.Background(), []model.Observation{advValidObs("q-1")})

	req := httptest.NewRequest("GET", "/api/v1/observations?after=2026-06-01T00:00:00Z&before=2026-01-01T00:00:00Z", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("after>before caused 5xx: %d", w.Code)
	}

	if w.Code == http.StatusOK {
		var result []model.Observation
		json.Unmarshal(w.Body.Bytes(), &result)
		if len(result) != 0 {
			t.Errorf("after>before returned %d results, want 0", len(result))
		}
	}
}

func TestAdv_Query_LimitZero(t *testing.T) {
	_, mux, ms, _ := adversarialSetup(t)

	ms.Append(context.Background(), []model.Observation{advValidObs("lim-0")})

	req := httptest.NewRequest("GET", "/api/v1/observations?limit=0", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("limit=0 caused 5xx: %d", w.Code)
	}
}

func TestAdv_Query_LimitMaxInt(t *testing.T) {
	_, mux, ms, _ := adversarialSetup(t)

	ms.Append(context.Background(), []model.Observation{advValidObs("lim-max")})

	req := httptest.NewRequest("GET", fmt.Sprintf("/api/v1/observations?limit=%d", math.MaxInt64), nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("limit=MaxInt64 caused 5xx: %d", w.Code)
	}
}

func TestAdv_Query_NegativeLimit(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	req := httptest.NewRequest("GET", "/api/v1/observations?limit=-1", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("negative limit: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

// --- Attack Vector 3: Label Injection ---

func TestAdv_Ingest_LabelsWithNullBytes(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("null-label")
	obs.Labels = map[string]string{"key\x00evil": "value\x00injection"}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("null-byte labels caused 5xx: %d", w.Code)
	}
}

func TestAdv_Ingest_LabelsWithSQLInjection(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("sqli-label")
	obs.Labels = map[string]string{
		"'; DROP TABLE observations; --": "value",
		"key":                            "'; DROP TABLE observations; --",
	}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("SQL injection labels caused 5xx: %d", w.Code)
	}
}

func TestAdv_Ingest_LabelsWithShellMetacharacters(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("shell-label")
	obs.Labels = map[string]string{
		"$(whoami)": "value",
		"key":       "`cat /etc/passwd`",
		"key2":      "$(rm -rf /)",
		"key3":      "; echo pwned",
		"pipe":      "| cat /etc/shadow",
	}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("shell metacharacter labels caused 5xx: %d", w.Code)
	}
}

func TestAdv_Ingest_LabelsWithUnicodeEdgeCases(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("unicode-label")
	obs.Labels = map[string]string{
		"zero\u200bwidth":       "value",
		"rtl\u202eoverride":     "value",
		"zwj\u200djoiner":       "value",
		"\uFEFFbom":             "value",
		"combining\u0300accent": "value",
	}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("unicode edge case labels caused 5xx: %d", w.Code)
	}
}

func TestAdv_Ingest_LabelsWithEmptyKey(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("empty-key-label")
	obs.Labels = map[string]string{"": "value"}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty label key: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_LabelsWithVeryLongValue(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("long-label")
	obs.Labels = map[string]string{"key": strings.Repeat("A", 10*1024)} // 10KB
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("10KB label value: got %d, want 400; body: %s", w.Code, w.Body.String())
	}
}

func TestAdv_Ingest_LabelsWithPrefixCollision(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("prefix-collision")
	obs.Labels = map[string]string{
		"labels.injected": "evil",
		"normal":          "fine",
	}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("label prefix collision caused 5xx: %d", w.Code)
	}
}

func TestAdv_Ingest_LabelsWithNewlines(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	obs := advValidObs("newline-label")
	obs.Labels = map[string]string{
		"key\ninjected": "value\r\nevil",
	}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, []model.Observation{obs}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("newline labels caused 5xx: %d", w.Code)
	}
}

// --- Attack Vector 5: Promotion Attacks ---

func TestAdv_Promote_NonExistentActor(t *testing.T) {
	_, mux, _, _ := adversarialSetup(t)

	req := httptest.NewRequest("POST", "/api/v1/actors/actor-does-not-exist/promote", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("promote non-existent: got %d, want 404", w.Code)
	}
}

func TestAdv_Promote_AlreadyPromoted(t *testing.T) {
	// FINDING: re-promoting an already-promoted actor succeeds silently,
	// overwriting PromotedAt and generating a duplicate audit event.
	h, mux, ms, fw := adversarialSetup(t)

	now := time.Now().UTC()
	obs := []model.Observation{
		{
			ID: "promo-obs-1", Timestamp: now, Layer: model.LayerNetworkEgress,
			Fidelity: model.FidelityStrong, Source: "s1", Confidence: 0.8,
			ActorHint: "suspect-1", RawEvidenceRef: "r1", Description: "d1",
		},
		{
			ID: "promo-obs-2", Timestamp: now, Layer: model.LayerBehavioural,
			Fidelity: model.FidelityStrong, Source: "s2", Confidence: 0.8,
			ActorHint: "suspect-1", RawEvidenceRef: "r2", Description: "d2",
		},
	}
	ms.Append(context.Background(), obs)

	// Correlate to create the actor
	corrReq := httptest.NewRequest("POST", "/api/v1/correlate", nil)
	corrW := httptest.NewRecorder()
	mux.ServeHTTP(corrW, corrReq)
	if corrW.Code != http.StatusOK {
		t.Fatalf("correlate failed: %d %s", corrW.Code, corrW.Body.String())
	}

	actors := h.Engine.GetActors()
	if len(actors) == 0 {
		t.Fatal("no actors created after correlation")
	}
	actorID := actors[0].ID

	// First promote
	req1 := httptest.NewRequest("POST", fmt.Sprintf("/api/v1/actors/%s/promote", actorID), nil)
	w1 := httptest.NewRecorder()
	mux.ServeHTTP(w1, req1)
	if w1.Code != http.StatusOK {
		t.Fatalf("first promote failed: %d", w1.Code)
	}
	firstPromotedAt := actors[0].PromotedAt

	// Second promote — should be rejected
	fw.Reset()
	req2 := httptest.NewRequest("POST", fmt.Sprintf("/api/v1/actors/%s/promote", actorID), nil)
	w2 := httptest.NewRecorder()
	mux.ServeHTTP(w2, req2)

	if w2.Code != http.StatusConflict {
		t.Errorf("re-promote: got %d, want 409 Conflict; body: %s", w2.Code, w2.Body.String())
	}

	// Verify PromotedAt was not overwritten
	if actors[0].PromotedAt != firstPromotedAt {
		t.Error("re-promote overwrote PromotedAt timestamp")
	}
}

// --- Large batch ---

func TestAdv_Ingest_LargeBatch(t *testing.T) {
	_, mux, ms, _ := adversarialSetup(t)

	obs := make([]model.Observation, 10000)
	for i := range obs {
		obs[i] = advValidObs(fmt.Sprintf("bulk-%d", i))
	}
	req := httptest.NewRequest("POST", "/api/v1/observations", advIngestBody(t, obs))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code >= 500 {
		t.Errorf("10k batch caused 5xx: %d", w.Code)
	}

	all, _ := ms.QueryRange(context.Background(), store.Query{})
	if w.Code < 400 && len(all) != 10000 {
		t.Errorf("stored %d of 10000 observations", len(all))
	}
}

// --- Mixed validity batch ---

func TestAdv_Ingest_MixedValidAndInvalid(t *testing.T) {
	_, mux, ms, _ := adversarialSetup(t)

	good := advValidObs("good-1")
	bad := advValidObs("bad-1")
	bad.Layer = "totally_invalid_layer"

	req := httptest.NewRequest("POST", "/api/v1/observations",
		advIngestBody(t, []model.Observation{good, bad}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("mixed batch: got %d, want 400", w.Code)
	}

	all, _ := ms.QueryRange(context.Background(), store.Query{})
	if len(all) != 0 {
		t.Errorf("mixed batch stored %d observations, want 0 (atomic reject)", len(all))
	}
}
