package audit

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
	count        uint64
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	m.observations = append(m.observations, obs)
	m.mu.Unlock()
	atomic.AddUint64(&m.count, 1)
	return nil
}

func TestAuditWebhookReceiver_BasicIngest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	receiver := NewWebhookReceiver(ctx, 1000, 2, sink)
	defer receiver.Close()

	payload := K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items: []K8sEvent{
			{
				AuditID:    "audit-101",
				Stage:      "ResponseComplete",
				Verb:       "create",
				RequestURI: "/api/v1/namespaces/default/secrets",
				User: K8sUserInfo{
					Username: "system:serviceaccount:kagent:autonomous-agent-1",
					Groups:   []string{"system:serviceaccounts"},
				},
				ObjectRef: &K8sObjRef{
					Resource:  "secrets",
					Namespace: "default",
					Name:      "vault-master-token",
				},
				ResponseStatus: &K8sRespStat{
					Code:   201,
					Status: "Created",
				},
				StageTimestamp: time.Now().UTC(),
			},
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/audit/webhook", bytes.NewReader(body))
	w := httptest.NewRecorder()

	receiver.HandleAuditWebhook(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d", resp.StatusCode)
	}

	// Allow worker drain
	time.Sleep(50 * time.Millisecond)

	metrics := receiver.Metrics()
	if metrics["received"].(uint64) != 1 {
		t.Fatalf("expected 1 received, got %v", metrics["received"])
	}
	if metrics["dropped"].(uint64) != 0 {
		t.Fatalf("expected 0 dropped, got %v", metrics["dropped"])
	}

	sink.mu.Lock()
	defer sink.mu.Unlock()
	if len(sink.observations) != 1 {
		t.Fatalf("expected 1 observation in sink, got %d", len(sink.observations))
	}

	obs := sink.observations[0]
	if obs.Layer != model.LayerCloudControlPlane {
		t.Errorf("expected layer %s, got %s", model.LayerCloudControlPlane, obs.Layer)
	}
	if obs.ActorHint != "system:serviceaccount:kagent:autonomous-agent-1" {
		t.Errorf("unexpected actor hint: %s", obs.ActorHint)
	}
	if err := obs.Validate(); err != nil {
		t.Errorf("observation validation failed: %v", err)
	}
}

func TestAuditWebhookReceiver_FailOpen(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Zero workers and tiny buffer of size 2 to force saturation
	receiver := &WebhookReceiver{
		buffer:   make(chan *model.Observation, 2),
		capacity: 2,
		workers:  0,
		ctx:      ctx,
		cancel:   cancel,
	}
	defer receiver.Close()

	// Fill buffer completely
	receiver.buffer <- &model.Observation{ID: "fill-1"}
	receiver.buffer <- &model.Observation{ID: "fill-2"}

	payload := K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items: []K8sEvent{
			{AuditID: "overflow-1", Verb: "get", StageTimestamp: time.Now()},
			{AuditID: "overflow-2", Verb: "list", StageTimestamp: time.Now()},
		},
	}
	body, _ := json.Marshal(payload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/audit/webhook", bytes.NewReader(body))
	w := httptest.NewRecorder()

	start := time.Now()
	receiver.HandleAuditWebhook(w, req)
	elapsed := time.Since(start)

	if elapsed > 10*time.Millisecond {
		t.Fatalf("fail-open took too long: %v (expected <10ms)", elapsed)
	}

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected HTTP 200 on fail-open, got %d", resp.StatusCode)
	}

	metrics := receiver.Metrics()
	if metrics["dropped"].(uint64) != 2 {
		t.Fatalf("expected 2 dropped events recorded, got %v", metrics["dropped"])
	}
}

func TestAuditWebhookReceiver_Throughput(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	receiver := NewWebhookReceiver(ctx, 50000, 8, sink)
	defer receiver.Close()

	numRequests := 100
	eventsPerReq := 50
	totalEvents := numRequests * eventsPerReq

	var wg sync.WaitGroup
	start := time.Now()

	for i := 0; i < numRequests; i++ {
		wg.Add(1)
		go func(reqID int) {
			defer wg.Done()
			var items []K8sEvent
			for j := 0; j < eventsPerReq; j++ {
				items = append(items, K8sEvent{
					AuditID: fmt.Sprintf("evt-%d-%d", reqID, j),
					Verb:    "patch",
					User:    K8sUserInfo{Username: "system:admin"},
					ObjectRef: &K8sObjRef{
						Resource:  "rolebindings",
						Namespace: "kube-system",
					},
					StageTimestamp: time.Now(),
				})
			}
			body, _ := json.Marshal(K8sEventList{Items: items})
			req := httptest.NewRequest(http.MethodPost, "/api/v1/audit/webhook", bytes.NewReader(body))
			w := httptest.NewRecorder()
			receiver.HandleAuditWebhook(w, req)
			if w.Result().StatusCode != http.StatusOK {
				t.Errorf("non-200 status: %d", w.Result().StatusCode)
			}
		}(i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	eps := float64(totalEvents) / elapsed.Seconds()
	t.Logf("Ingested %d events across %d concurrent requests in %v (%.2f events/sec)", totalEvents, numRequests, elapsed, eps)

	metrics := receiver.Metrics()
	if metrics["received"].(uint64) != uint64(totalEvents) {
		t.Fatalf("expected %d received, got %v", totalEvents, metrics["received"])
	}
	if metrics["dropped"].(uint64) != 0 {
		t.Fatalf("unexpected dropped events: %v", metrics["dropped"])
	}
}

func TestAuditWebhookReceiver_MalformedPayload(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	receiver := NewWebhookReceiver(ctx, 100, 1, &mockSink{})
	defer receiver.Close()

	// Test GET method rejected
	reqGet := httptest.NewRequest(http.MethodGet, "/api/v1/audit/webhook", nil)
	wGet := httptest.NewRecorder()
	receiver.HandleAuditWebhook(wGet, reqGet)
	if wGet.Result().StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 Method Not Allowed, got %d", wGet.Result().StatusCode)
	}

	// Test invalid JSON
	reqBad := httptest.NewRequest(http.MethodPost, "/api/v1/audit/webhook", bytes.NewReader([]byte("{invalid-json")))
	wBad := httptest.NewRecorder()
	receiver.HandleAuditWebhook(wBad, reqBad)
	if wBad.Result().StatusCode != http.StatusBadRequest {
		t.Errorf("expected 400 Bad Request, got %d", wBad.Result().StatusCode)
	}
}
