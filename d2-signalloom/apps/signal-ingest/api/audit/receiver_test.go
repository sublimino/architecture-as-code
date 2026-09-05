package audit

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	m.observations = append(m.observations, obs)
	m.mu.Unlock()
	atomic.AddUint64(&m.count, 1)
	return nil
}

func (m *mockSink) getObservations() []*model.Observation {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*model.Observation, len(m.observations))
	copy(out, m.observations)
	return out
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

	req := httptest.NewRequest(http.MethodPost, WebhookPath, bytes.NewReader(body))
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

	obsList := sink.getObservations()
	if len(obsList) != 1 {
		t.Fatalf("expected 1 observation in sink, got %d", len(obsList))
	}

	obs := obsList[0]
	if obs.Layer != model.LayerIdentityAuth {
		t.Errorf("expected layer %s, got %s", model.LayerIdentityAuth, obs.Layer)
	}
	expectedSPIFFE := "spiffe://cluster.local/ns/kagent/sa/autonomous-agent-1"
	if obs.ActorHint != expectedSPIFFE {
		t.Errorf("expected actor hint %s, got %s", expectedSPIFFE, obs.ActorHint)
	}
	if obs.PrincipalID != expectedSPIFFE {
		t.Errorf("expected principal ID %s, got %s", expectedSPIFFE, obs.PrincipalID)
	}
	if obs.DelegationDepth != 0 {
		t.Errorf("expected delegation depth 0, got %d", obs.DelegationDepth)
	}
	if obs.DelegationEdge != nil {
		t.Errorf("expected nil delegation edge for non-impersonated event")
	}
	if err := obs.Validate(); err != nil {
		t.Errorf("observation validation failed: %v", err)
	}
}

func TestAuditWebhookReceiver_ImpersonationPrecedence(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	receiver := NewWebhookReceiver(ctx, 100, 1, &mockSink{})
	defer receiver.Close()

	tests := []struct {
		name                 string
		event                K8sEvent
		wantActingPrincipal  string
		wantDelegator        string
		wantDelegationDepth  int
		wantDelegationEdge   bool
		wantEdgeContribution string
		wantImpersonatedUser string
	}{
		{
			name: "impersonated SA by human user: impersonatedUser wins and emits delegation edge",
			event: K8sEvent{
				AuditID:    "audit-imp-001",
				Verb:       "create",
				RequestURI: "/api/v1/namespaces/prod/pods",
				User: K8sUserInfo{
					Username: "alice@company.internal",
				},
				ImpersonatedUser: &K8sUserInfo{
					Username: "system:serviceaccount:kagent:autonomous-agent-1",
				},
				ObjectRef: &K8sObjRef{
					Namespace: "prod",
					Resource:  "pods",
					Name:      "test-pod",
				},
				StageTimestamp: time.Now().UTC(),
			},
			wantActingPrincipal:  "spiffe://cluster.local/ns/kagent/sa/autonomous-agent-1",
			wantDelegator:        "alice@company.internal",
			wantDelegationDepth:  1,
			wantDelegationEdge:   true,
			wantEdgeContribution: "delegation: alice@company.internal -> spiffe://cluster.local/ns/kagent/sa/autonomous-agent-1 (basis: impersonation)",
			wantImpersonatedUser: "spiffe://cluster.local/ns/kagent/sa/autonomous-agent-1",
		},
		{
			name: "impersonated human by human user: impersonatedUser wins and emits delegation edge",
			event: K8sEvent{
				AuditID:    "audit-imp-002",
				Verb:       "delete",
				RequestURI: "/api/v1/namespaces/prod/secrets/db-pass",
				User: K8sUserInfo{
					Username: "alice@company.internal",
				},
				ImpersonatedUser: &K8sUserInfo{
					Username: "bob@company.internal",
				},
				ObjectRef: &K8sObjRef{
					Namespace: "prod",
					Resource:  "secrets",
					Name:      "db-pass",
				},
				StageTimestamp: time.Now().UTC(),
			},
			wantActingPrincipal:  "bob@company.internal",
			wantDelegator:        "alice@company.internal",
			wantDelegationDepth:  1,
			wantDelegationEdge:   true,
			wantEdgeContribution: "delegation: alice@company.internal -> bob@company.internal (basis: impersonation)",
			wantImpersonatedUser: "bob@company.internal",
		},
		{
			name: "negative case: no impersonatedUser present, user wins with zero delegation edge",
			event: K8sEvent{
				AuditID:    "audit-imp-003",
				Verb:       "get",
				RequestURI: "/api/v1/namespaces/default/configmaps",
				User: K8sUserInfo{
					Username: "alice@company.internal",
				},
				ImpersonatedUser: nil,
				ObjectRef: &K8sObjRef{
					Namespace: "default",
					Resource:  "configmaps",
					Name:      "cfg",
				},
				StageTimestamp: time.Now().UTC(),
			},
			wantActingPrincipal:  "alice@company.internal",
			wantDelegator:        "alice@company.internal",
			wantDelegationDepth:  0,
			wantDelegationEdge:   false,
			wantEdgeContribution: "",
			wantImpersonatedUser: "",
		},
		{
			name: "self-impersonation: impersonatedUser equals user, emits NO delegation edge",
			event: K8sEvent{
				AuditID:    "audit-imp-004",
				Verb:       "list",
				RequestURI: "/api/v1/namespaces/kube-system/services",
				User: K8sUserInfo{
					Username: "system:serviceaccount:kube-system:admin-sa",
				},
				ImpersonatedUser: &K8sUserInfo{
					Username: "system:serviceaccount:kube-system:admin-sa",
				},
				ObjectRef: &K8sObjRef{
					Namespace: "kube-system",
					Resource:  "services",
				},
				StageTimestamp: time.Now().UTC(),
			},
			wantActingPrincipal:  "spiffe://cluster.local/ns/kube-system/sa/admin-sa",
			wantDelegator:        "spiffe://cluster.local/ns/kube-system/sa/admin-sa",
			wantDelegationDepth:  0,
			wantDelegationEdge:   false,
			wantEdgeContribution: "",
			wantImpersonatedUser: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			obs := receiver.ConvertToObservation(&tc.event)
			if obs == nil {
				t.Fatalf("expected non-nil observation")
			}

			if obs.ActorHint != tc.wantActingPrincipal {
				t.Errorf("ActorHint = %q, want %q", obs.ActorHint, tc.wantActingPrincipal)
			}
			if obs.PrincipalID != tc.wantActingPrincipal {
				t.Errorf("PrincipalID = %q, want %q", obs.PrincipalID, tc.wantActingPrincipal)
			}
			if obs.DelegationDepth != tc.wantDelegationDepth {
				t.Errorf("DelegationDepth = %d, want %d", obs.DelegationDepth, tc.wantDelegationDepth)
			}
			if obs.ImpersonatedUser != tc.wantImpersonatedUser {
				t.Errorf("ImpersonatedUser = %q, want %q", obs.ImpersonatedUser, tc.wantImpersonatedUser)
			}

			if tc.wantDelegationEdge {
				if obs.DelegationEdge == nil {
					t.Fatalf("expected non-nil DelegationEdge")
				}
				if obs.DelegationEdge.Contribution != tc.wantEdgeContribution {
					t.Errorf("DelegationEdge.Contribution = %q, want %q", obs.DelegationEdge.Contribution, tc.wantEdgeContribution)
				}
				if obs.DelegationEdge.Layer != model.LayerIdentityAuth {
					t.Errorf("DelegationEdge.Layer = %s, want %s", obs.DelegationEdge.Layer, model.LayerIdentityAuth)
				}
				if obs.DelegationEdge.Fidelity != model.FidelityDefinitive {
					t.Errorf("DelegationEdge.Fidelity = %s, want %s", obs.DelegationEdge.Fidelity, model.FidelityDefinitive)
				}
				if obs.Labels["delegation_basis"] != "impersonation" {
					t.Errorf("Labels[delegation_basis] = %q, want impersonation", obs.Labels["delegation_basis"])
				}
			} else {
				if obs.DelegationEdge != nil {
					t.Errorf("expected nil DelegationEdge, got %+v", obs.DelegationEdge)
				}
				if obs.Labels["delegation_basis"] != "" {
					t.Errorf("unexpected delegation_basis label: %q", obs.Labels["delegation_basis"])
				}
			}

			if err := obs.Validate(); err != nil {
				t.Errorf("observation validation failed: %v", err)
			}
		})
	}
}

func TestSAGuardPredicate(t *testing.T) {
	tests := []struct {
		username   string
		isSA       bool
		wantSPIFFE string
	}{
		{
			username:   "system:serviceaccount:kagent:autonomous-agent-1",
			isSA:       true,
			wantSPIFFE: "spiffe://cluster.local/ns/kagent/sa/autonomous-agent-1",
		},
		{
			username:   "system:serviceaccount:default:deployer",
			isSA:       true,
			wantSPIFFE: "spiffe://cluster.local/ns/default/sa/deployer",
		},
		{
			username:   "alice@company.com",
			isSA:       false,
			wantSPIFFE: "alice@company.com",
		},
		{
			username:   "admin",
			isSA:       false,
			wantSPIFFE: "admin",
		},
		{
			username:   "system:node:worker-node-1",
			isSA:       false,
			wantSPIFFE: "system:node:worker-node-1",
		},
		{
			username:   "system:anonymous",
			isSA:       false,
			wantSPIFFE: "system:anonymous",
		},
		{
			username:   "system:serviceaccount",
			isSA:       false,
			wantSPIFFE: "system:serviceaccount",
		},
		{
			username:   "system:serviceaccount:only-namespace",
			isSA:       false,
			wantSPIFFE: "system:serviceaccount:only-namespace",
		},
	}

	for _, tc := range tests {
		t.Run(tc.username, func(t *testing.T) {
			gotSA := IsServiceAccount(tc.username)
			if gotSA != tc.isSA {
				t.Errorf("IsServiceAccount(%q) = %v, want %v", tc.username, gotSA, tc.isSA)
			}

			spiffe, mapped := MapSAToSPIFFE(tc.username)
			if mapped != tc.isSA {
				t.Errorf("MapSAToSPIFFE(%q) mapped = %v, want %v", tc.username, mapped, tc.isSA)
			}
			if spiffe != tc.wantSPIFFE {
				t.Errorf("MapSAToSPIFFE(%q) = %q, want %q", tc.username, spiffe, tc.wantSPIFFE)
			}
			if !tc.isSA && strings.HasPrefix(spiffe, "spiffe://") {
				t.Errorf("human username %q produced malformed SPIFFE id: %q", tc.username, spiffe)
			}
		})
	}
}

func TestAuditWebhookReceiver_BatchProcessing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	receiver := NewWebhookReceiver(ctx, 100, 2, sink)
	defer receiver.Close()

	payload := K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items: []K8sEvent{
			{AuditID: "batch-1", Verb: "get", User: K8sUserInfo{Username: "user1@example.com"}, StageTimestamp: time.Now()},
			{AuditID: "batch-2", Verb: "create", User: K8sUserInfo{Username: "system:serviceaccount:ns1:sa1"}, StageTimestamp: time.Now()},
			{
				AuditID:          "batch-3",
				Verb:             "patch",
				User:             K8sUserInfo{Username: "admin@example.com"},
				ImpersonatedUser: &K8sUserInfo{Username: "system:serviceaccount:ns2:sa2"},
				StageTimestamp:   time.Now(),
			},
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, WebhookPath, bytes.NewReader(body))
	w := httptest.NewRecorder()
	receiver.HandleAuditWebhook(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	// Wait for processing
	time.Sleep(50 * time.Millisecond)

	obsList := sink.getObservations()
	if len(obsList) != 3 {
		t.Fatalf("expected 3 observations, got %d", len(obsList))
	}

	byID := make(map[string]*model.Observation)
	for _, o := range obsList {
		byID[o.ID] = o
	}

	// Validate items by ID
	if o1, ok := byID["batch-1"]; !ok || o1.ActorHint != "user1@example.com" {
		t.Errorf("batch-1: actor = %v, want user1@example.com", o1)
	}
	if o2, ok := byID["batch-2"]; !ok || o2.ActorHint != "spiffe://cluster.local/ns/ns1/sa/sa1" {
		t.Errorf("batch-2: actor = %v, want spiffe://cluster.local/ns/ns1/sa/sa1", o2)
	}
	if o3, ok := byID["batch-3"]; !ok {
		t.Fatalf("batch-3 missing from observations")
	} else {
		if o3.ActorHint != "spiffe://cluster.local/ns/ns2/sa/sa2" {
			t.Errorf("batch-3: actor = %s, want spiffe://cluster.local/ns/ns2/sa/sa2", o3.ActorHint)
		}
		if o3.DelegationEdge == nil {
			t.Errorf("batch-3: expected delegation edge")
		}
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

	req := httptest.NewRequest(http.MethodPost, WebhookPath, bytes.NewReader(body))
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

func TestAuditWebhookReceiver_CloseDrainsWorkers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	receiver := NewWebhookReceiver(ctx, 100, 2, sink)

	// Send 10 events directly to buffer
	for i := 0; i < 10; i++ {
		receiver.buffer <- &model.Observation{
			ID:        fmt.Sprintf("queued-%d", i),
			Timestamp: time.Now().UTC(),
			Layer:     model.LayerIdentityAuth,
			Fidelity:  model.FidelityDefinitive,
			Source:    "k8s-apiserver-audit",
		}
	}

	// Call Close, which must drain all 10 events
	receiver.Close()

	if metrics := receiver.Metrics(); metrics["processed"].(uint64) != 10 {
		t.Errorf("expected 10 processed events after Close, got %v", metrics["processed"])
	}

	obsList := sink.getObservations()
	if len(obsList) != 10 {
		t.Fatalf("expected 10 observations in sink after Close, got %d", len(obsList))
	}
}

func TestAuditWebhookReceiver_MalformedPayload(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	receiver := NewWebhookReceiver(ctx, 100, 1, &mockSink{})
	defer receiver.Close()

	// Test GET method rejected
	reqGet := httptest.NewRequest(http.MethodGet, WebhookPath, nil)
	wGet := httptest.NewRecorder()
	receiver.HandleAuditWebhook(wGet, reqGet)
	if wGet.Result().StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 Method Not Allowed, got %d", wGet.Result().StatusCode)
	}

	// Test invalid JSON
	reqBad := httptest.NewRequest(http.MethodPost, WebhookPath, bytes.NewReader([]byte("{invalid-json")))
	wBad := httptest.NewRecorder()
	receiver.HandleAuditWebhook(wBad, reqBad)
	if wBad.Result().StatusCode != http.StatusBadRequest {
		t.Errorf("expected 400 Bad Request, got %d", wBad.Result().StatusCode)
	}
}
