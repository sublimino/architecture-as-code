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
	if len(resp.BlindSpots) != 6 {
		t.Errorf("want 6 blind spots, got %d", len(resp.BlindSpots))
	}
	if resp.DeploymentCoverage != "5 of 8 layers active" {
		t.Errorf("unexpected coverage: %s", resp.DeploymentCoverage)
	}
}

// TestCoverageDoesNotCallCloudControlPlaneUndeployed: cloud_control_plane IS a deployed layer --
// it is in model.InScopeLayers() and the correlation rules pair against it -- so reporting it as
// "Layer not deployed" told an operator the wrong thing about why they see no cloud events. The
// honest gap is narrower and actionable: the layer is live, no collector is feeding it yet.
//
// It stays a blind spot, and the counts stay at 5/5 and "5 of 8 layers active": no cloud
// observations are arriving, so coverage has not actually changed. Promoting it to a covered layer
// is the separate seven-layer flip (SLAWS v2 §5, P1), which also owns the dashboard's
// "5 of 7 layers instrumented" assertion. This test pins the description only.
func TestCoverageDoesNotCallCloudControlPlaneUndeployed(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/coverage", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	var resp CoverageResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode coverage: %v", err)
	}

	var found bool
	for _, bs := range resp.BlindSpots {
		if bs.ID != "cloud_control_plane" {
			continue
		}
		found = true
		if strings.Contains(bs.Description, "not deployed") {
			t.Errorf("cloud_control_plane gap says %q, but the layer is in model.InScopeLayers()", bs.Description)
		}
		if !strings.Contains(bs.Description, "no collector") {
			t.Errorf("cloud_control_plane gap says %q; it must name the real gap, an absent collector", bs.Description)
		}
	}
	if !found {
		t.Fatal("no cloud_control_plane entry in blind_spots")
	}

	// The sibling entry is the control: protocol genuinely is not deployed (it is absent from
	// InScopeLayers()), so its wording must NOT be softened by the same edit.
	for _, bs := range resp.BlindSpots {
		if bs.ID == "protocol_analysis" && !strings.Contains(bs.Description, "not deployed") {
			t.Errorf("protocol_analysis gap says %q; protocol is out of scope and should still say so", bs.Description)
		}
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

// TestCorrelate_RespectsAuthenticatedTenantAudit verifies correlation and actor creation events use caller's tenant.
func TestCorrelate_RespectsAuthenticatedTenantAudit(t *testing.T) {
	fake := audit.NewFakeWriter()
	h, mux := newTestHandlersWithAudit(t, fake)

	obs := []model.Observation{
		{ID: "c-1", Layer: model.LayerNetworkEgress, Source: "src", ActorHint: "bot-acme"},
		{ID: "c-2", Layer: model.LayerBehavioural, Source: "src", ActorHint: "bot-acme"},
	}
	h.Store.Append(context.Background(), obs)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/correlate", nil)
	req = req.WithContext(WithTenantContext(req.Context(), TenantContext{
		TenantID:  "tenant-acme",
		Principal: "user-acme",
	}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("correlate: want 200, got %d", w.Code)
	}

	corrEvents := fake.EventsByType(audit.EventCorrelationRun)
	if len(corrEvents) != 1 {
		t.Fatalf("want 1 correlation_run event, got %d", len(corrEvents))
	}
	if corrEvents[0].TenantID != "tenant-acme" {
		t.Errorf("correlation_run tenant: want tenant-acme, got %q", corrEvents[0].TenantID)
	}

	actorEvents := fake.EventsByType(audit.EventActorCreated)
	if len(actorEvents) == 0 {
		t.Fatal("want at least 1 actor_created event, got 0")
	}
	if actorEvents[0].TenantID != "tenant-acme" {
		t.Errorf("actor_created tenant: want tenant-acme, got %q", actorEvents[0].TenantID)
	}
}

// TestSeed_RespectsAuthenticatedTenantAudit verifies seed emits collector_run with caller's tenant.
func TestSeed_RespectsAuthenticatedTenantAudit(t *testing.T) {
	fake := audit.NewFakeWriter()
	_, mux := newTestHandlersWithAudit(t, fake)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/collectors/seed", nil)
	req = req.WithContext(WithTenantContext(req.Context(), TenantContext{
		TenantID:  "tenant-acme",
		Principal: "user-acme",
	}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("seed: want 201, got %d", w.Code)
	}

	collectorEvents := fake.EventsByType(audit.EventCollectorRun)
	if len(collectorEvents) != 1 {
		t.Fatalf("want 1 collector_run event, got %d", len(collectorEvents))
	}
	if collectorEvents[0].TenantID != "tenant-acme" {
		t.Errorf("collector_run tenant: want tenant-acme, got %q", collectorEvents[0].TenantID)
	}
}

func TestMethodGatesAllowHeaders(t *testing.T) {
	h, _ := newTestHandlers(t)

	// handleNonoAudit: POST only
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/audit/nono", nil)
		rec := httptest.NewRecorder()
		h.handleNonoAudit(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleNonoAudit got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleNonoAudit got Allow %q, want POST, OPTIONS", method, allow)
		}
	}
	optReq := httptest.NewRequest(http.MethodOptions, "/api/v1/audit/nono", nil)
	optRec := httptest.NewRecorder()
	h.handleNonoAudit(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleNonoAudit got status %d, want 204", optRec.Code)
	}
	if allow := optRec.Header().Get("Allow"); allow != "POST, OPTIONS" {
		t.Errorf("OPTIONS handleNonoAudit got Allow %q, want POST, OPTIONS", allow)
	}

	// handleCreateDelegation: POST only
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/delegations", nil)
		rec := httptest.NewRecorder()
		h.handleCreateDelegation(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleCreateDelegation got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleCreateDelegation got Allow %q, want POST, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/delegations", nil)
	optRec = httptest.NewRecorder()
	h.handleCreateDelegation(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleCreateDelegation got status %d, want 204", optRec.Code)
	}

	// handleClampDelegation: POST, DELETE
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodPatch} {
		req := httptest.NewRequest(method, "/api/v1/delegations/clamp", nil)
		rec := httptest.NewRecorder()
		h.handleClampDelegation(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleClampDelegation got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, DELETE, OPTIONS" {
			t.Errorf("%s handleClampDelegation got Allow %q, want POST, DELETE, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/delegations/clamp", nil)
	optRec = httptest.NewRecorder()
	h.handleClampDelegation(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleClampDelegation got status %d, want 204", optRec.Code)
	}

	// handleRevokeDelegations: POST only
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/delegations/revoke", nil)
		rec := httptest.NewRecorder()
		h.handleRevokeDelegations(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleRevokeDelegations got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleRevokeDelegations got Allow %q, want POST, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/delegations/revoke", nil)
	optRec = httptest.NewRecorder()
	h.handleRevokeDelegations(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleRevokeDelegations got status %d, want 204", optRec.Code)
	}

	// handleHealth: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/health", nil)
		rec := httptest.NewRecorder()
		h.handleHealth(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleHealth got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s handleHealth got Allow %q, want GET, HEAD, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/health", nil)
	optRec = httptest.NewRecorder()
	h.handleHealth(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleHealth got status %d, want 204", optRec.Code)
	}

	// handleHealthz: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/healthz", nil)
		rec := httptest.NewRecorder()
		handleHealthz(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleHealthz got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s handleHealthz got Allow %q, want GET, HEAD, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/healthz", nil)
	optRec = httptest.NewRecorder()
	handleHealthz(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleHealthz got status %d, want 204", optRec.Code)
	}

	// handleCoverage: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/coverage", nil)
		rec := httptest.NewRecorder()
		handleCoverage(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleCoverage got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s handleCoverage got Allow %q, want GET, HEAD, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/coverage", nil)
	optRec = httptest.NewRecorder()
	handleCoverage(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleCoverage got status %d, want 204", optRec.Code)
	}

	// handleIngestObservations: POST only
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/observations", nil)
		rec := httptest.NewRecorder()
		h.handleIngestObservations(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleIngestObservations got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleIngestObservations got Allow %q, want POST, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/observations", nil)
	optRec = httptest.NewRecorder()
	h.handleIngestObservations(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleIngestObservations got status %d, want 204", optRec.Code)
	}

	// handleCorrelate: POST only
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/correlate", nil)
		rec := httptest.NewRecorder()
		h.handleCorrelate(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleCorrelate got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleCorrelate got Allow %q, want POST, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/correlate", nil)
	optRec = httptest.NewRecorder()
	h.handleCorrelate(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleCorrelate got status %d, want 204", optRec.Code)
	}

	// handleSeed: POST only
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/collectors/seed", nil)
		rec := httptest.NewRecorder()
		h.handleSeed(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleSeed got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleSeed got Allow %q, want POST, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/collectors/seed", nil)
	optRec = httptest.NewRecorder()
	h.handleSeed(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleSeed got status %d, want 204", optRec.Code)
	}

	// handleStream: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/v1/stream", nil)
		rec := httptest.NewRecorder()
		h.handleStream(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleStream got status %d, want 405", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s handleStream got Allow %q, want GET, HEAD, OPTIONS", method, allow)
		}
	}
	optReq = httptest.NewRequest(http.MethodOptions, "/api/v1/stream", nil)
	optRec = httptest.NewRecorder()
	h.handleStream(optRec, optReq)
	if optRec.Code != http.StatusNoContent {
		t.Errorf("OPTIONS handleStream got status %d, want 204", optRec.Code)
	}
}

func TestHandlers_HeadBodySuppression(t *testing.T) {
	h, mux := newTestHandlers(t)

	// HEAD /health
	req := httptest.NewRequest(http.MethodHead, "/health", nil)
	rec := httptest.NewRecorder()
	h.handleHealth(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /health got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /health got %d body bytes, want 0", rec.Body.Len())
	}

	// HEAD /healthz
	rec = httptest.NewRecorder()
	handleHealthz(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /healthz got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /healthz got %d body bytes, want 0", rec.Body.Len())
	}

	// HEAD /api/v1/coverage
	req = httptest.NewRequest(http.MethodHead, "/api/v1/coverage", nil)
	rec = httptest.NewRecorder()
	handleCoverage(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /api/v1/coverage got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /api/v1/coverage got %d body bytes, want 0", rec.Body.Len())
	}

	// HEAD /api/v1/stream
	req = httptest.NewRequest(http.MethodHead, "/api/v1/stream", nil)
	rec = httptest.NewRecorder()
	h.handleStream(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /api/v1/stream got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /api/v1/stream got %d body bytes, want 0", rec.Body.Len())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("HEAD /api/v1/stream Content-Type got %q, want text/event-stream", ct)
	}

	// HEAD /api/v1/observations
	req = httptest.NewRequest(http.MethodHead, "/api/v1/observations", nil)
	rec = httptest.NewRecorder()
	h.handleQueryObservations(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /api/v1/observations got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /api/v1/observations got %d body bytes, want 0", rec.Body.Len())
	}

	// HEAD /api/v1/actors
	req = httptest.NewRequest(http.MethodHead, "/api/v1/actors", nil)
	rec = httptest.NewRecorder()
	h.handleListActors(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /api/v1/actors got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /api/v1/actors got %d body bytes, want 0", rec.Body.Len())
	}

	// HEAD through mux /api/v1/observations
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD mux /api/v1/observations got status %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD mux /api/v1/observations got %d body bytes, want 0", rec.Body.Len())
	}
}


