package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	apiaudit "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func TestLiveMode_EventFlowToStore(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	memStore := store.NewMemoryStore()
	engine, err := correlation.NewEngine(memStore)
	if err != nil {
		t.Fatalf("correlation engine creation failed: %v", err)
	}

	storeSink := collectors.NewStoreSink(memStore)
	receiver := apiaudit.NewWebhookReceiver(ctx, 100, 2, storeSink)
	defer receiver.Close()

	registry := collectors.NewRegistry(
		collectors.NewK8sAuditCollector(collectors.ModeLive, storeSink),
	)
	if err := registry.Start(ctx); err != nil {
		t.Fatalf("registry Start failed: %v", err)
	}
	defer registry.Stop()

	handlers := &Handlers{
		Store:           memStore,
		Engine:          engine,
		AuditReceiver:   receiver,
		CollectorHealth: registry.Health,
	}

	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux)

	// Verify /readyz is 200 ready
	readyRec := httptest.NewRecorder()
	mux.ServeHTTP(readyRec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if readyRec.Code != http.StatusOK {
		t.Fatalf("expected /readyz 200, got %d", readyRec.Code)
	}

	eventPayload := apiaudit.K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items: []apiaudit.K8sEvent{
			{
				AuditID:    "audit-live-flow-001",
				Stage:      "ResponseComplete",
				Verb:       "get",
				RequestURI: "/api/v1/namespaces/default/secrets/vault-token",
				User: apiaudit.K8sUserInfo{
					Username: "system:serviceaccount:kagent:autonomous-agent-1",
					Groups:   []string{"system:serviceaccounts"},
				},
				ObjectRef: &apiaudit.K8sObjRef{
					Resource:  "secrets",
					Namespace: "default",
					Name:      "vault-token",
				},
				ResponseStatus: &apiaudit.K8sRespStat{
					Code:   200,
					Status: "OK",
				},
				StageTimestamp: time.Now().UTC(),
			},
		},
	}

	body, err := json.Marshal(eventPayload)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/audit/webhook", bytes.NewReader(body))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("POST /api/v1/audit/webhook failed: got %d (body %s)", w.Code, w.Body.String())
	}

	// Poll until observation lands in store
	var stored []model.Observation
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		stored, err = memStore.QueryRange(ctx, store.Query{})
		if err == nil && len(stored) > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	if len(stored) != 1 {
		t.Fatalf("expected 1 observation in store after live event flow, got %d", len(stored))
	}

	obs := stored[0]
	if obs.ID != "audit-live-flow-001" {
		t.Errorf("expected ID audit-live-flow-001, got %s", obs.ID)
	}
	if obs.Layer != model.LayerCloudControlPlane {
		t.Errorf("expected LayerCloudControlPlane, got %s", obs.Layer)
	}
	if obs.ActorHint != "system:serviceaccount:kagent:autonomous-agent-1" {
		t.Errorf("expected actor hint system:serviceaccount:kagent:autonomous-agent-1, got %s", obs.ActorHint)
	}

	// Verify receiver telemetry counters
	metrics := receiver.Metrics()
	if metrics["received"].(uint64) != 1 {
		t.Errorf("expected received=1 in telemetry, got %v", metrics["received"])
	}
	if metrics["processed"].(uint64) != 1 {
		t.Errorf("expected processed=1 in telemetry, got %v", metrics["processed"])
	}
}

func TestHandlers_AuditWebhookRouteEndToEnd(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	memStore := store.NewMemoryStore()
	engine, err := correlation.NewEngine(memStore)
	if err != nil {
		t.Fatalf("correlation engine failed: %v", err)
	}

	storeSink := collectors.NewStoreSink(memStore)
	receiver := apiaudit.NewWebhookReceiver(ctx, 100, 2, storeSink)
	defer receiver.Close()

	handlers := &Handlers{
		Store:         memStore,
		Engine:        engine,
		AuditReceiver: receiver,
	}

	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux)

	payload := apiaudit.K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items: []apiaudit.K8sEvent{
			{
				AuditID:    "audit-webhook-e2e-99",
				Stage:      "ResponseComplete",
				Verb:       "create",
				RequestURI: "/api/v1/namespaces/default/configmaps",
				User: apiaudit.K8sUserInfo{
					Username: "system:serviceaccount:default:deployer",
				},
				ObjectRef: &apiaudit.K8sObjRef{
					Resource:  "configmaps",
					Namespace: "default",
					Name:      "app-config",
				},
				StageTimestamp: time.Now().UTC(),
			},
		},
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/audit/webhook", bytes.NewReader(body))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", w.Code)
	}

	// Verify query observations returns the converted observation
	time.Sleep(50 * time.Millisecond)
	queryReq := httptest.NewRequest(http.MethodGet, "/api/v1/observations", nil)
	queryRec := httptest.NewRecorder()
	mux.ServeHTTP(queryRec, queryReq)

	if queryRec.Code != http.StatusOK {
		t.Fatalf("query observations failed: %d", queryRec.Code)
	}

	var results []model.Observation
	if err := json.Unmarshal(queryRec.Body.Bytes(), &results); err != nil {
		t.Fatalf("unmarshal query results: %v", err)
	}

	if len(results) != 1 {
		t.Fatalf("expected 1 observation from /api/v1/observations, got %d", len(results))
	}
	if results[0].ID != "audit-webhook-e2e-99" {
		t.Errorf("observation ID = %s, want audit-webhook-e2e-99", results[0].ID)
	}
}

func TestLiveMode_IdentityCollectors_BaoAndSpire(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	memStore := store.NewMemoryStore()
	storeSink := collectors.NewStoreSink(memStore)

	baoCol := collectors.NewBaoAuditCollector(collectors.ModeLive, storeSink)
	spireCol := collectors.NewSPIREACollector(collectors.ModeLive, storeSink)

	registry := collectors.NewRegistry(baoCol, spireCol)
	if err := registry.Start(ctx); err != nil {
		t.Fatalf("registry.Start failed: %v", err)
	}
	defer registry.Stop()

	if err := registry.Health(ctx); err != nil {
		t.Fatalf("expected healthy status, got %v", err)
	}

	baoReceiver := baoCol.RawReceiver()
	if baoReceiver == nil {
		t.Fatalf("expected baoaudit receiver to be initialized in live mode")
	}

	spireCollector := spireCol.RawCollector()
	if spireCollector == nil {
		t.Fatalf("expected spirea collector to be initialized in live mode")
	}

	// 1. Ingest real-shaped OpenBao audit event
	baoJSON := []byte(`{
		"type": "response",
		"time": "2026-09-02T10:00:00Z",
		"auth": {
			"display_name": "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			"client_token": "hmac-token-live-1",
			"accessor": "acc-live-1",
			"metadata": {
				"spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"role": "cardvault"
			}
		},
		"request": {
			"operation": "read",
			"path": "secret/data/cardvault/master-keys"
		}
	}`)

	if err := baoReceiver.IngestRawBytes(baoJSON); err != nil {
		t.Fatalf("bao IngestRawBytes failed: %v", err)
	}

	// 2. Ingest real-shaped SPIRE issuance event
	now := time.Now().UTC()
	spireEvent := &spirea.SVIDIssuanceEvent{
		Timestamp:      now,
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		TrustDomain:    "cluster.local",
		SVIDType:       spirea.SVIDTypeJWT,
		IssuedAt:       now,
		ExpiresAt:      now.Add(5 * time.Minute),
		TTLSeconds:     300,
		PodNamespace:   "fe-signalloom-agents",
		ServiceAccount: "agent-cardvault-sa",
	}

	if err := spireCollector.IngestIssuanceEvent(ctx, spireEvent); err != nil {
		t.Fatalf("spire IngestIssuanceEvent failed: %v", err)
	}

	// Poll until both observations land in the store
	var stored []model.Observation
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		var queryErr error
		stored, queryErr = memStore.QueryRange(ctx, store.Query{})
		if queryErr == nil && len(stored) >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	if len(stored) != 2 {
		t.Fatalf("expected 2 observations in store (1 OpenBao, 1 SPIRE), got %d", len(stored))
	}

	var baoObs, spireObs *model.Observation
	for i := range stored {
		if stored[i].Source == "openbao-audit" {
			baoObs = &stored[i]
		} else if stored[i].Source == "spire-agent" {
			spireObs = &stored[i]
		}
	}

	if baoObs == nil {
		t.Fatalf("missing openbao-audit observation in store")
	}
	if spireObs == nil {
		t.Fatalf("missing spire-agent observation in store")
	}

	// Validate OpenBao observation fields & SA->SPIFFE correspondence
	if baoObs.Layer != model.LayerIdentityAuth {
		t.Errorf("bao layer = %s, want LayerIdentityAuth", baoObs.Layer)
	}
	if baoObs.Fidelity != model.FidelityDefinitive {
		t.Errorf("bao fidelity = %s, want FidelityDefinitive", baoObs.Fidelity)
	}
	if baoObs.ActorHint != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("bao actor hint = %s, want SPIFFE ID", baoObs.ActorHint)
	}
	if baoObs.PrincipalID != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("bao principal ID = %s, want SA principal", baoObs.PrincipalID)
	}
	if baoObs.Labels["sa_principal"] != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("bao sa_principal label = %s", baoObs.Labels["sa_principal"])
	}
	if baoObs.Labels["spiffe_id"] != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("bao spiffe_id label = %s", baoObs.Labels["spiffe_id"])
	}

	// Validate SPIRE observation fields & SA->SPIFFE correspondence
	if spireObs.Layer != model.LayerIdentityAuth {
		t.Errorf("spire layer = %s, want LayerIdentityAuth", spireObs.Layer)
	}
	if spireObs.Fidelity != model.FidelityStrong {
		t.Errorf("spire fidelity = %s, want FidelityStrong", spireObs.Fidelity)
	}
	if spireObs.ActorHint != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("spire actor hint = %s, want SPIFFE ID", spireObs.ActorHint)
	}
	if spireObs.PrincipalID != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("spire principal ID = %s, want SA principal", spireObs.PrincipalID)
	}
	if spireObs.Labels["sa_principal"] != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("spire sa_principal label = %s", spireObs.Labels["sa_principal"])
	}
	if spireObs.Labels["spiffe_id"] != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("spire spiffe_id label = %s", spireObs.Labels["spiffe_id"])
	}

	// Assert SA->SPIFFE Join binds both observations into a unified resolvable actor
	actorBao, errBao := correlation.Resolve(*baoObs)
	if errBao != nil {
		t.Fatalf("Resolve(baoObs) failed: %v", errBao)
	}
	actorSpire, errSpire := correlation.Resolve(*spireObs)
	if errSpire != nil {
		t.Fatalf("Resolve(spireObs) failed: %v", errSpire)
	}

	if actorBao.ID != actorSpire.ID {
		t.Errorf("actor IDs do not match: bao=%s, spire=%s", actorBao.ID, actorSpire.ID)
	}
	if actorBao.PrincipalID != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" &&
		actorBao.PrincipalID != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("unexpected actor principal ID: %s", actorBao.PrincipalID)
	}

	// Verify operational stats incremented
	baoRec, baoIng, baoDrp, baoErrs := baoReceiver.Stats()
	if baoRec != 1 || baoIng != 1 || baoDrp != 0 || baoErrs != 0 {
		t.Errorf("unexpected bao stats: rec=%d, ing=%d, drp=%d, errs=%d", baoRec, baoIng, baoDrp, baoErrs)
	}

	spireRec, spireIng, spireAnom := spireCollector.Stats()
	if spireRec != 1 || spireIng != 1 || spireAnom != 0 {
		t.Errorf("unexpected spire stats: rec=%d, ing=%d, anom=%d", spireRec, spireIng, spireAnom)
	}
}

