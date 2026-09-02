package gcpaudit

import (
	"context"
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
}
