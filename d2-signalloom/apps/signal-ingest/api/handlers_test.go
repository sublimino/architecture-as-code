package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func newTestHandlers(t testing.TB) (*Handlers, *http.ServeMux) {
	if t != nil {
		t.Helper()
	}
	return newTestHandlersWithAudit(t, audit.NewFakeWriter())
}

func newTestHandlersWithAudit(t testing.TB, aw audit.AuditWriter) (*Handlers, *http.ServeMux) {
	if t != nil {
		t.Helper()
	}
	s := store.NewMemoryStore()
	e, err := correlation.NewEngine(s)
	if err != nil {
		if t != nil {
			t.Fatal(err)
		} else {
			panic(err)
		}
	}
	h := &Handlers{Store: s, Engine: e, Audit: aw}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	return h, mux
}

func TestHealthz(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("healthz: want 200, got %d", w.Code)
	}
}

func TestHealth_PostureReporting(t *testing.T) {
	// 1. Enforced production posture
	aesEnc, _ := identity.NewAESGCMEncryptor([]byte("01234567890123456789012345678901"))
	fakeAudit := audit.NewFakeWriter()
	h := &Handlers{Encryptor: aesEnc, Audit: fakeAudit}
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("health: want 200, got %d", w.Code)
	}

	var resp HealthResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode HealthResponse: %v", err)
	}
	if resp.Status != "ok" {
		t.Errorf("expected status ok, got %s", resp.Status)
	}
	if resp.Encryption.Algorithm != "AES-256-GCM" || !resp.Encryption.Healthy {
		t.Errorf("unexpected encryption posture: %+v", resp.Encryption)
	}
	if resp.Audit.Backend != "fake_memory" || !resp.Audit.Healthy {
		t.Errorf("unexpected audit posture: %+v", resp.Audit)
	}

	// 2. Degraded insecure dev posture
	noopEnc := identity.NewNoopEncryptor()
	defer noopEnc.Stop()
	hDegraded := &Handlers{Encryptor: noopEnc, Audit: audit.NewNopWriter(true)}
	muxDegraded := http.NewServeMux()
	hDegraded.RegisterRoutes(muxDegraded)

	req2 := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	w2 := httptest.NewRecorder()
	muxDegraded.ServeHTTP(w2, req2)

	if w2.Code != http.StatusOK {
		t.Fatalf("health api: want 200, got %d", w2.Code)
	}

	var respDegraded HealthResponse
	if err := json.Unmarshal(w2.Body.Bytes(), &respDegraded); err != nil {
		t.Fatalf("failed to decode degraded HealthResponse: %v", err)
	}
	if respDegraded.Status != "degraded" {
		t.Errorf("expected status degraded for insecure dev setup, got %s", respDegraded.Status)
	}
	if respDegraded.Encryption.Healthy || !respDegraded.Encryption.DevOptIn {
		t.Errorf("expected encryption healthy=false and dev_opt_in=true, got %+v", respDegraded.Encryption)
	}
}

func TestReadyz(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("readyz: want 200, got %d", w.Code)
	}
}

func TestIngestObservations(t *testing.T) {
	_, mux := newTestHandlers(t)

	obs := []model.Observation{
		{
			ID: "test-1", Layer: model.LayerNetworkEgress, Source: "test",
			Description: "test", Fidelity: model.FidelitySuggestive,
			Timestamp: time.Now().UTC(), Confidence: 0.5, RawEvidenceRef: "ref",
		},
	}
	body, _ := json.Marshal(obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("ingest: want 201, got %d, body: %s", w.Code, w.Body.String())
	}
}

func TestIngestObservations_EmptyArray(t *testing.T) {
	_, mux := newTestHandlers(t)

	body, _ := json.Marshal([]model.Observation{})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty array: want 400, got %d", w.Code)
	}
}

func TestQueryObservations(t *testing.T) {
	h, mux := newTestHandlers(t)

	obs := []model.Observation{
		{ID: "q-1", Layer: model.LayerNetworkEgress, Source: "test"},
		{ID: "q-2", Layer: model.LayerBehavioural, Source: "test"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/observations?layer=network_egress", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("query: want 200, got %d", w.Code)
	}

	var result []model.Observation
	json.NewDecoder(w.Body).Decode(&result)
	if len(result) != 1 {
		t.Errorf("want 1 result, got %d", len(result))
	}
}

func TestListActors_Empty(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("actors: want 200, got %d", w.Code)
	}

	var actors []*model.ProvisionalActor
	json.NewDecoder(w.Body).Decode(&actors)
	if len(actors) != 0 {
		t.Errorf("want 0 actors, got %d", len(actors))
	}
}

func TestGetActor_NotFound(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/nonexistent", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("actor not found: want 404, got %d", w.Code)
	}
}

func TestCoverage(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/coverage", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("coverage: want 200, got %d", w.Code)
	}

	var resp CoverageResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if len(resp.CoveredLayers) != 5 {
		t.Errorf("want 5 covered layers, got %d", len(resp.CoveredLayers))
	}
	if len(resp.BlindSpots) != 5 {
		t.Errorf("want 5 blind spots, got %d", len(resp.BlindSpots))
	}
	if resp.DeploymentCoverage != "5 of 7 layers active" {
		t.Errorf("unexpected coverage: %s", resp.DeploymentCoverage)
	}
}

func TestSeedFixtures(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/collectors/seed", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("seed: want 201, got %d, body: %s", w.Code, w.Body.String())
	}
}

func TestCorrelate(t *testing.T) {
	h, mux := newTestHandlers(t)

	// Seed fixtures first.
	obs := []model.Observation{
		{ID: "c-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "bot"},
		{ID: "c-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "bot"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("correlate: want 200, got %d, body: %s", w.Code, w.Body.String())
	}
}

// TestCorrelate_WritesAuditEvents verifies correlation_run and actor_created
// audit events are emitted when correlation discovers actors.
func TestCorrelate_WritesAuditEvents(t *testing.T) {
	fake := audit.NewFakeWriter()
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "ca-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "audit-bot"},
		{ID: "ca-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "audit-bot"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("correlate: want 200, got %d", w.Code)
	}

	corrEvents := fake.EventsByType(audit.EventCorrelationRun)
	if len(corrEvents) != 1 {
		t.Errorf("want 1 correlation_run event, got %d", len(corrEvents))
	}

	actorEvents := fake.EventsByType(audit.EventActorCreated)
	if len(actorEvents) == 0 {
		t.Error("want at least 1 actor_created event, got 0")
	}
}

// TestSeed_WritesCollectorRunAudit verifies seed emits a collector_run event.
func TestSeed_WritesCollectorRunAudit(t *testing.T) {
	fake := audit.NewFakeWriter()
	_, mux := newTestHandlersWithAudit(t, fake)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/collectors/seed", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("seed: want 201, got %d", w.Code)
	}

	collectorEvents := fake.EventsByType(audit.EventCollectorRun)
	if len(collectorEvents) != 1 {
		t.Errorf("want 1 collector_run event, got %d", len(collectorEvents))
	}
}

// TestAuditFailure_DoesNotBreakCorrelate verifies fail-open on audit errors.
func TestAuditFailure_DoesNotBreakCorrelate(t *testing.T) {
	fake := audit.NewFakeWriter()
	fake.FailWith = errors.New("connection refused")
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "af-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "fail-bot"},
		{ID: "af-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "fail-bot"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("correlate should succeed despite audit failure: want 200, got %d", w.Code)
	}
}

// TestQueryObservationsEmptyIsArrayNotNull pins the contract that broke the
// dashboard: encoding/json marshals a nil slice as `null`, and the Weave page
// declared the field an array and dereferenced it —
//
//	Uncaught TypeError: Cannot read properties of null (reading 'length')
//
// Asserting on the decoded Go value would NOT catch this: json.Unmarshal
// happily decodes both `null` and `[]` into a nil/empty slice, so the test
// would pass against the broken handler. The assertion has to be on the raw
// bytes on the wire, which is what the browser actually receives.
func TestQueryObservationsEmptyIsArrayNotNull(t *testing.T) {
	_, mux := newTestHandlers(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/observations", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}

	body := strings.TrimSpace(w.Body.String())
	if body == "null" {
		t.Fatal("empty observations serialised as `null`; a client that declared this an array will crash on .length")
	}
	if body != "[]" {
		t.Errorf("empty observations: want `[]` on the wire, got %q", body)
	}
}

func TestStream(t *testing.T) {
	_, mux := newTestHandlers(t)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/stream", nil).WithContext(ctx)
	w := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		mux.ServeHTTP(w, req)
		close(done)
	}()

	// Allow connect frame to flush
	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done

	if w.Code != http.StatusOK {
		t.Errorf("stream: want 200, got %d", w.Code)
	}
	contentType := w.Header().Get("Content-Type")
	if !strings.Contains(contentType, "text/event-stream") {
		t.Errorf("stream: want text/event-stream, got %q", contentType)
	}
	body := w.Body.String()
	if !strings.Contains(body, "event: connected") {
		t.Errorf("stream: missing connect frame in %q", body)
	}
}

