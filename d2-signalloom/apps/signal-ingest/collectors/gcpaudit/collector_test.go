package gcpaudit

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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
	err          error
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.err != nil {
		return m.err
	}
	m.observations = append(m.observations, obs)
	atomic.AddUint64(&m.count, 1)
	return nil
}

func TestGCPAuditCollector_IngestAndDeduplicate(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	collector := NewCollector(ctx, sink, 5*time.Minute)
	defer collector.Close()

	entry := &GCPLogEntry{
		InsertID:  "insert-xyz-12345",
		LogName:   "projects/osramp-demo/logs/cloudaudit.googleapis.com%2Factivity",
		Timestamp: time.Now().UTC(),
		Severity:  "NOTICE",
		Resource: GCPMonitoredResource{
			Type: "gce_instance",
			Labels: map[string]string{
				"project_id":  "osramp-demo",
				"instance_id": "987654321",
			},
		},
		ProtoPayload: &GCPAuditLogPayload{
			Type:         "type.googleapis.com/google.cloud.audit.AuditLog",
			ServiceName:  "compute.googleapis.com",
			MethodName:   "v1.compute.instances.insert",
			ResourceName: "projects/osramp-demo/zones/us-central1-a/instances/worker-node-1",
			AuthenticationInfo: GCPAuthInfo{
				PrincipalEmail: "deployer-sa@osramp-demo.iam.gserviceaccount.com",
			},
			RequestMetadata: GCPRequestMetadata{
				CallerIP: "34.120.45.67",
			},
		},
	}

	// First ingestion should succeed
	if err := collector.IngestLogEntry(ctx, entry); err != nil {
		t.Fatalf("first ingestion failed: %v", err)
	}

	// Duplicate ingestion with exact same insertId
	if err := collector.IngestLogEntry(ctx, entry); err != nil {
		t.Fatalf("duplicate ingestion failed: %v", err)
	}

	metrics := collector.Metrics()
	if metrics["received"].(uint64) != 2 {
		t.Fatalf("expected 2 received, got %v", metrics["received"])
	}
	if metrics["dedup_drop"].(uint64) != 1 {
		t.Fatalf("expected 1 dedup_drop, got %v", metrics["dedup_drop"])
	}
	if metrics["ingested"].(uint64) != 1 {
		t.Fatalf("expected 1 ingested, got %v", metrics["ingested"])
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
	if obs.ActorHint != "deployer-sa@osramp-demo.iam.gserviceaccount.com" {
		t.Errorf("unexpected actor hint: %s", obs.ActorHint)
	}
	if err := obs.Validate(); err != nil {
		t.Errorf("observation validation failed: %v", err)
	}
}

func TestGCPAuditCollector_IAMSetPolicy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	collector := NewCollector(ctx, sink, 5*time.Minute)
	defer collector.Close()

	rawJSON := []byte(`{
		"insertId": "iam-audit-001",
		"logName": "projects/osramp-demo/logs/cloudaudit.googleapis.com%2Factivity",
		"timestamp": "2026-09-02T08:00:00Z",
		"severity": "NOTICE",
		"resource": {
			"type": "project",
			"labels": { "project_id": "osramp-demo" }
		},
		"protoPayload": {
			"@type": "type.googleapis.com/google.cloud.audit.AuditLog",
			"serviceName": "iam.googleapis.com",
			"methodName": "google.iam.v1.SetIamPolicy",
			"resourceName": "projects/osramp-demo",
			"authenticationInfo": {
				"principalEmail": "admin@controlplane.io"
			},
			"requestMetadata": {
				"callerIp": "192.0.2.1"
			}
		}
	}`)

	if err := collector.IngestJSONBytes(ctx, rawJSON); err != nil {
		t.Fatalf("ingest json failed: %v", err)
	}

	sink.mu.Lock()
	defer sink.mu.Unlock()
	if len(sink.observations) != 1 {
		t.Fatalf("expected 1 observation, got %d", len(sink.observations))
	}

	obs := sink.observations[0]
	if obs.ID != "iam-audit-001" {
		t.Errorf("expected ID iam-audit-001, got %s", obs.ID)
	}
	if obs.Labels["service_name"] != "iam.googleapis.com" {
		t.Errorf("expected iam.googleapis.com, got %s", obs.Labels["service_name"])
	}
	if obs.Labels["method_name"] != "google.iam.v1.SetIamPolicy" {
		t.Errorf("expected google.iam.v1.SetIamPolicy, got %s", obs.Labels["method_name"])
	}
	if err := obs.Validate(); err != nil {
		t.Errorf("observation validation failed: %v", err)
	}
}

func TestGCPAuditCollector_MalformedJSON(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	collector := NewCollector(ctx, &mockSink{}, 5*time.Minute)
	defer collector.Close()

	err := collector.IngestJSONBytes(ctx, []byte(`{invalid-json`))
	if err == nil {
		t.Fatal("expected error on malformed JSON, got nil")
	}

	m := collector.Metrics()
	if m["parse_errors"].(uint64) != 1 {
		t.Errorf("expected parse_errors = 1, got %v", m["parse_errors"])
	}
}

func TestGCPAuditCollector_RegistrationAndHarness(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	col := New(ctx, sink, 5*time.Minute, WithMode("fixture"))
	defer col.Close()

	if col.Name() != "gcpaudit" {
		t.Errorf("expected name gcpaudit, got %s", col.Name())
	}
	if col.Mode() != "fixture" {
		t.Errorf("expected mode fixture, got %s", col.Mode())
	}

	if err := col.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	if err := col.Health(ctx); err != nil {
		t.Fatalf("Health expected nil, got %v", err)
	}

	m := col.Metrics()
	if m["ingested"].(uint64) != 1 {
		t.Errorf("expected ingested = 1 on fixture Start, got %v", m["ingested"])
	}
	if m["received"].(uint64) != 1 {
		t.Errorf("expected received = 1, got %v", m["received"])
	}
}

func TestGCPAuditCollector_OffModeNoOp(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	col := New(ctx, sink, 5*time.Minute, WithMode("off"))
	defer col.Close()

	if err := col.Start(ctx); err != nil {
		t.Fatalf("Start in off mode should return nil, got %v", err)
	}

	if atomic.LoadUint64(&sink.count) != 0 {
		t.Errorf("expected 0 ingested in off mode, got %d", atomic.LoadUint64(&sink.count))
	}

	m := col.Metrics()
	if m["received"].(uint64) != 0 || m["ingested"].(uint64) != 0 {
		t.Errorf("expected 0 metrics in off mode, got received=%v, ingested=%v", m["received"], m["ingested"])
	}
}

func TestGCPAuditCollector_LiveModeSingleEventEndToEnd(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sampleLogEntry := `{
		"insertId": "gcp-live-test-001",
		"logName": "projects/osramp-demo/logs/cloudaudit.googleapis.com%2Factivity",
		"timestamp": "2026-09-05T15:30:00Z",
		"severity": "NOTICE",
		"resource": {
			"type": "gce_instance",
			"labels": {
				"project_id": "osramp-demo",
				"instance_id": "worker-node-1"
			}
		},
		"protoPayload": {
			"@type": "type.googleapis.com/google.cloud.audit.AuditLog",
			"serviceName": "compute.googleapis.com",
			"methodName": "v1.compute.instances.insert",
			"resourceName": "projects/osramp-demo/zones/us-central1-a/instances/worker-node-1",
			"authenticationInfo": {
				"principalEmail": "deployer-sa@osramp-demo.iam.gserviceaccount.com"
			},
			"requestMetadata": {
				"callerIp": "34.120.45.67",
				"callerSuppliedUserAgent": "google-cloud-sdk"
			}
		}
	}`

	encodedData := base64.StdEncoding.EncodeToString([]byte(sampleLogEntry))

	var mu sync.Mutex
	var acknowledgedIDs []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, ":pull"):
			resp := pubSubPullResponse{
				ReceivedMessages: []pubSubReceivedMessage{
					{
						AckID: "ack-live-test-001",
						Message: pubSubMessage{
							Data:        encodedData,
							MessageID:   "msg-live-1001",
							PublishTime: "2026-09-05T15:30:01Z",
						},
					},
				},
			}
			_ = json.NewEncoder(w).Encode(resp)

		case strings.Contains(r.URL.Path, ":acknowledge"):
			body, _ := io.ReadAll(r.Body)
			var ackReq pubSubAckRequest
			_ = json.Unmarshal(body, &ackReq)
			mu.Lock()
			acknowledgedIDs = append(acknowledgedIDs, ackReq.AckIDs...)
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("{}"))

		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	sink := &mockSink{}
	col := New(
		ctx,
		sink,
		5*time.Minute,
		WithEndpoint(server.URL),
		WithProject("osramp-demo"),
		WithSubscription("osramp-audit-sub"),
		WithMode("live"),
	)
	defer col.Close()

	processed, err := col.PullOnce(ctx)
	if err != nil {
		t.Fatalf("PullOnce failed: %v", err)
	}
	if processed != 1 {
		t.Fatalf("expected 1 message processed, got %d", processed)
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
	if obs.ActorHint != "deployer-sa@osramp-demo.iam.gserviceaccount.com" {
		t.Errorf("expected ActorHint deployer-sa@osramp-demo.iam.gserviceaccount.com, got %s", obs.ActorHint)
	}
	if obs.Labels["method_name"] != "v1.compute.instances.insert" {
		t.Errorf("expected method_name v1.compute.instances.insert, got %s", obs.Labels["method_name"])
	}
	if obs.Labels["principal_email"] != "deployer-sa@osramp-demo.iam.gserviceaccount.com" {
		t.Errorf("expected principal_email deployer-sa@osramp-demo.iam.gserviceaccount.com, got %s", obs.Labels["principal_email"])
	}
	if obs.Labels["service_name"] != "compute.googleapis.com" {
		t.Errorf("expected service_name compute.googleapis.com, got %s", obs.Labels["service_name"])
	}
	if obs.Labels["project_id"] != "osramp-demo" {
		t.Errorf("expected project_id osramp-demo, got %s", obs.Labels["project_id"])
	}

	m := col.Metrics()
	if m["received"].(uint64) != 1 {
		t.Errorf("expected received = 1, got %v", m["received"])
	}
	if m["ingested"].(uint64) != 1 {
		t.Errorf("expected ingested = 1, got %v", m["ingested"])
	}
	if m["dedup_drop"].(uint64) != 0 {
		t.Errorf("expected dedup_drop = 0, got %v", m["dedup_drop"])
	}

	mu.Lock()
	defer mu.Unlock()
	if len(acknowledgedIDs) != 1 || acknowledgedIDs[0] != "ack-live-test-001" {
		t.Errorf("expected ack ID ack-live-test-001, got %v", acknowledgedIDs)
	}
}

func TestGCPAuditCollector_AckBeforePersistOrdering_SinkError(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sampleLogEntry := `{"insertId": "gcp-sink-fail-001", "logName": "projects/p/logs/audit"}`
	encodedData := base64.StdEncoding.EncodeToString([]byte(sampleLogEntry))

	var mu sync.Mutex
	var acknowledgedIDs []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, ":pull"):
			resp := pubSubPullResponse{
				ReceivedMessages: []pubSubReceivedMessage{
					{
						AckID: "ack-fail-test",
						Message: pubSubMessage{
							Data: encodedData,
						},
					},
				},
			}
			_ = json.NewEncoder(w).Encode(resp)

		case strings.Contains(r.URL.Path, ":acknowledge"):
			body, _ := io.ReadAll(r.Body)
			var ackReq pubSubAckRequest
			_ = json.Unmarshal(body, &ackReq)
			mu.Lock()
			acknowledgedIDs = append(acknowledgedIDs, ackReq.AckIDs...)
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer server.Close()

	sink := &mockSink{err: errors.New("database connection refused")}
	col := New(
		ctx,
		sink,
		5*time.Minute,
		WithEndpoint(server.URL),
		WithProject("osramp-demo"),
		WithSubscription("osramp-audit-sub"),
		WithMode("live"),
	)
	defer col.Close()

	processed, _ := col.PullOnce(ctx)
	if processed != 0 {
		t.Errorf("expected 0 processed on sink failure, got %d", processed)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(acknowledgedIDs) != 0 {
		t.Errorf("expected 0 acknowledged messages on sink failure, got %v", acknowledgedIDs)
	}
}

func TestGCPAuditCollector_SilentErrorSwallow_ParseErrorCounter(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, ":pull") {
			resp := pubSubPullResponse{
				ReceivedMessages: []pubSubReceivedMessage{
					{
						AckID: "ack-malformed",
						Message: pubSubMessage{
							Data: base64.StdEncoding.EncodeToString([]byte(`not-json`)),
						},
					},
				},
			}
			_ = json.NewEncoder(w).Encode(resp)
		}
	}))
	defer server.Close()

	sink := &mockSink{}
	col := New(
		ctx,
		sink,
		5*time.Minute,
		WithEndpoint(server.URL),
		WithProject("osramp-demo"),
		WithSubscription("osramp-audit-sub"),
		WithMode("live"),
	)
	defer col.Close()

	_, _ = col.PullOnce(ctx)

	m := col.Metrics()
	if m["parse_errors"].(uint64) != 1 {
		t.Errorf("expected parse_errors = 1, got %v", m["parse_errors"])
	}
	if m["ingested"].(uint64) != 0 {
		t.Errorf("expected ingested = 0, got %v", m["ingested"])
	}
}

func TestGCPAuditCollector_NonBlockingStart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	col := New(
		ctx,
		sink,
		5*time.Minute,
		WithEndpoint("http://127.0.0.1:19999"),
		WithProject("osramp-demo"),
		WithSubscription("slow-sub"),
		WithMode("live"),
		WithPullInterval(10*time.Millisecond),
	)
	defer col.Close()

	start := time.Now()
	err := col.Start(ctx)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	if elapsed > 100*time.Millisecond {
		t.Errorf("Start took %v, expected non-blocking startup (<100ms)", elapsed)
	}
}

