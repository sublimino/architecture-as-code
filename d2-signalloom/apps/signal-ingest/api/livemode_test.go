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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/kagent"
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

func TestLiveMode_KAgentTraceFlowToStore(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	memStore := store.NewMemoryStore()
	storeSink := collectors.NewStoreSink(memStore)
	kagentCol := collectors.NewKAgentCollector(collectors.ModeLive, storeSink)

	registry := collectors.NewRegistry(kagentCol)
	if err := registry.Start(ctx); err != nil {
		t.Fatalf("registry Start failed: %v", err)
	}
	defer registry.Stop()

	span := kagent.TelemetrySpan{
		SpanID:         "live-kagent-flow-001",
		TraceID:        "live-kagent-trace-001",
		Name:           kagent.SpanNameToolExecution,
		Timestamp:      time.Now().UTC(),
		RuntimeVersion: kagent.RuntimeVersion0_9_9,
		Attributes: map[string]string{
			kagent.AttrAgentNamespace: "fe-signalloom-agents",
			kagent.AttrAgentName:      "kagent-k8s-reader",
			kagent.AttrToolName:       "k8s_get_resources",
			kagent.AttrContextID:      "ctx-live-k8s-001",
			kagent.AttrTaskID:         "task-live-k8s-001",
			kagent.AttrUserID:         "admin@kagent.dev",
		},
	}

	rawCol := kagentCol.RawCollector()
	if rawCol == nil {
		t.Fatalf("expected non-nil raw collector in live mode")
	}

	res, err := rawCol.IngestSpan(ctx, span)
	if err != nil {
		t.Fatalf("IngestSpan failed: %v", err)
	}

	if res.Observation == nil {
		t.Fatalf("expected observation to be returned")
	}

	stored, err := memStore.QueryRange(ctx, store.Query{Layers: []model.Layer{model.LayerIdentityAuth}})
	if err != nil {
		t.Fatalf("QueryRange failed: %v", err)
	}

	if len(stored) != 1 {
		t.Fatalf("expected 1 observation in store, got %d", len(stored))
	}

	obs := stored[0]
	if obs.ID != "kagent-obs-live-kagent-flow-001" {
		t.Errorf("unexpected ID: %s", obs.ID)
	}
	if obs.ActorHint != "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader" {
		t.Errorf("unexpected ActorHint: %s", obs.ActorHint)
	}
	if obs.Labels["tool_name"] != "k8s_get_resources" {
		t.Errorf("unexpected tool_name: %s", obs.Labels["tool_name"])
	}
	if obs.Labels["invoked_action"] != "tool:k8s_get_resources" {
		t.Errorf("unexpected invoked_action: %s", obs.Labels["invoked_action"])
	}
	if obs.Labels["delegation_tag"] != "inferred" {
		t.Errorf("unexpected delegation_tag: %s", obs.Labels["delegation_tag"])
	}
}


