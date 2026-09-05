package audit

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestParseGKEResourceName(t *testing.T) {
	tests := []struct {
		input         string
		wantAPIGroup  string
		wantAPIVer    string
		wantNamespace string
		wantResource  string
		wantName      string
	}{
		{
			input:         "namespaces/default/secrets/vault-token",
			wantAPIGroup:  "",
			wantAPIVer:    "v1",
			wantNamespace: "default",
			wantResource:  "secrets",
			wantName:      "vault-token",
		},
		{
			input:         "core/v1/namespaces/kube-system/configmaps/coredns",
			wantAPIGroup:  "",
			wantAPIVer:    "v1",
			wantNamespace: "kube-system",
			wantResource:  "configmaps",
			wantName:      "coredns",
		},
		{
			input:         "api/v1/namespaces/prod/services/api-gateway",
			wantAPIGroup:  "",
			wantAPIVer:    "v1",
			wantNamespace: "prod",
			wantResource:  "services",
			wantName:      "api-gateway",
		},
		{
			input:         "apis/apps/v1/namespaces/fe-signalloom/deployments/dashboard",
			wantAPIGroup:  "apps",
			wantAPIVer:    "v1",
			wantNamespace: "fe-signalloom",
			wantResource:  "deployments",
			wantName:      "dashboard",
		},
		{
			input:         "apis/rbac.authorization.k8s.io/v1/clusterroles/cluster-admin",
			wantAPIGroup:  "rbac.authorization.k8s.io",
			wantAPIVer:    "v1",
			wantNamespace: "",
			wantResource:  "clusterroles",
			wantName:      "cluster-admin",
		},
		{
			input:         "projects/my-gcp-project/locations/us-central1/clusters/demo-cluster/k8s/namespaces/default/secrets/api-key",
			wantAPIGroup:  "",
			wantAPIVer:    "v1",
			wantNamespace: "default",
			wantResource:  "secrets",
			wantName:      "api-key",
		},
		{
			input:         "nodes/gke-node-1234",
			wantAPIGroup:  "",
			wantAPIVer:    "v1",
			wantNamespace: "",
			wantResource:  "nodes",
			wantName:      "gke-node-1234",
		},
	}

	for _, tc := range tests {
		t.Run(tc.input, func(t *testing.T) {
			apiGroup, apiVer, ns, res, name := ParseGKEResourceName(tc.input)
			if apiGroup != tc.wantAPIGroup {
				t.Errorf("apiGroup = %q, want %q", apiGroup, tc.wantAPIGroup)
			}
			if apiVer != tc.wantAPIVer {
				t.Errorf("apiVersion = %q, want %q", apiVer, tc.wantAPIVer)
			}
			if ns != tc.wantNamespace {
				t.Errorf("namespace = %q, want %q", ns, tc.wantNamespace)
			}
			if res != tc.wantResource {
				t.Errorf("resource = %q, want %q", res, tc.wantResource)
			}
			if name != tc.wantName {
				t.Errorf("name = %q, want %q", name, tc.wantName)
			}
		})
	}
}

func TestGKEAdapter_ConvertGKELogEntryToK8sEvent(t *testing.T) {
	ts := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	entry := &GKELogEntry{
		InsertID:  "gke-log-001",
		Timestamp: ts,
		Severity:  "INFO",
		ProtoPayload: &GKEAuditLogPayload{
			ServiceName:  "k8s.io",
			MethodName:   "io.k8s.core.v1.namespaces.secrets.get",
			ResourceName: "namespaces/default/secrets/master-token",
			AuthenticationInfo: GKEAuthInfo{
				PrincipalEmail: "system:serviceaccount:kagent:autonomous-agent-1",
			},
			RequestMetadata: &GKERequestMetadata{
				CallerIP:                "10.128.0.4",
				CallerSuppliedUserAgent: "kubectl/v1.31.0",
			},
			Status: &GKEStatus{
				Code:    0,
				Message: "OK",
			},
		},
	}

	event := ConvertGKELogEntryToK8sEvent(entry)
	if event == nil {
		t.Fatalf("expected non-nil K8sEvent")
	}

	if event.AuditID != "gke-log-001" {
		t.Errorf("event.AuditID = %s, want gke-log-001", event.AuditID)
	}
	if event.Verb != "get" {
		t.Errorf("event.Verb = %s, want get", event.Verb)
	}
	if event.User.Username != "system:serviceaccount:kagent:autonomous-agent-1" {
		t.Errorf("event.User.Username = %s", event.User.Username)
	}
	if event.ObjectRef == nil {
		t.Fatalf("expected non-nil ObjectRef")
	}
	if event.ObjectRef.Namespace != "default" {
		t.Errorf("ObjectRef.Namespace = %s, want default", event.ObjectRef.Namespace)
	}
	if event.ObjectRef.Resource != "secrets" {
		t.Errorf("ObjectRef.Resource = %s, want secrets", event.ObjectRef.Resource)
	}
	if event.ObjectRef.Name != "master-token" {
		t.Errorf("ObjectRef.Name = %s, want master-token", event.ObjectRef.Name)
	}
}

func TestGKEAdapter_IngestAndHTTPHandler(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	receiver := NewWebhookReceiver(ctx, 100, 2, sink)
	defer receiver.Close()

	ts := time.Now().UTC()
	entry := GKELogEntry{
		InsertID:  "gke-http-test-01",
		Timestamp: ts,
		ProtoPayload: &GKEAuditLogPayload{
			ServiceName:  "k8s.io",
			MethodName:   "io.k8s.apps.v1.namespaces.deployments.create",
			ResourceName: "apis/apps/v1/namespaces/prod/deployments/worker",
			AuthenticationInfo: GKEAuthInfo{
				PrincipalEmail:   "ci-builder@company.internal",
				ImpersonatedUser: "system:serviceaccount:prod:deployer",
			},
			RequestMetadata: &GKERequestMetadata{
				CallerIP:                "10.0.1.5",
				CallerSuppliedUserAgent: "gke-deployer/v1.0",
			},
			Status: &GKEStatus{
				Code: 0,
			},
		},
	}

	body, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, GKEWebhookPath, bytes.NewReader(body))
	w := httptest.NewRecorder()

	receiver.HandleGKECloudLogging(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("HandleGKECloudLogging returned status %d", w.Code)
	}

	// Allow worker drain
	time.Sleep(50 * time.Millisecond)

	obsList := sink.getObservations()
	if len(obsList) != 1 {
		t.Fatalf("expected 1 observation in sink, got %d", len(obsList))
	}

	obs := obsList[0]
	if obs.Layer != model.LayerIdentityAuth {
		t.Errorf("expected layer %s, got %s", model.LayerIdentityAuth, obs.Layer)
	}
	expectedActing := "spiffe://cluster.local/ns/prod/sa/deployer"
	if obs.ActorHint != expectedActing {
		t.Errorf("expected ActorHint %s, got %s", expectedActing, obs.ActorHint)
	}
	if obs.ImpersonatedUser != expectedActing {
		t.Errorf("expected ImpersonatedUser %s, got %s", expectedActing, obs.ImpersonatedUser)
	}
	if obs.DelegationDepth != 1 {
		t.Errorf("expected DelegationDepth 1, got %d", obs.DelegationDepth)
	}
	if obs.DelegationEdge == nil {
		t.Fatalf("expected non-nil DelegationEdge")
	}
	wantContribution := "delegation: ci-builder@company.internal -> spiffe://cluster.local/ns/prod/sa/deployer (basis: impersonation)"
	if obs.DelegationEdge.Contribution != wantContribution {
		t.Errorf("DelegationEdge.Contribution = %q, want %q", obs.DelegationEdge.Contribution, wantContribution)
	}
}

func TestSchemaParity_WebhookAndGKE(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	receiver := NewWebhookReceiver(ctx, 100, 1, &mockSink{})
	defer receiver.Close()

	fixedTime := time.Date(2026, 9, 5, 14, 30, 0, 0, time.UTC)

	// Twin 1: On-cluster Webhook K8sEvent
	webhookEvent := &K8sEvent{
		AuditID:    "audit-parity-100",
		Stage:      "ResponseComplete",
		RequestURI: "/api/v1/namespaces/default/secrets/vault-token",
		Verb:       "get",
		User: K8sUserInfo{
			Username: "admin@company.internal",
		},
		ImpersonatedUser: &K8sUserInfo{
			Username: "system:serviceaccount:kagent:autonomous-agent-1",
		},
		ObjectRef: &K8sObjRef{
			APIVersion: "v1",
			Namespace:  "default",
			Resource:   "secrets",
			Name:       "vault-token",
		},
		ResponseStatus: &K8sRespStat{
			Code: 200,
		},
		StageTimestamp: fixedTime,
	}

	// Twin 2: GKE Cloud Logging GKELogEntry
	gkeEntry := &GKELogEntry{
		InsertID:  "audit-parity-100",
		Timestamp: fixedTime,
		ProtoPayload: &GKEAuditLogPayload{
			ServiceName:  "k8s.io",
			MethodName:   "io.k8s.core.v1.namespaces.secrets.get",
			ResourceName: "namespaces/default/secrets/vault-token",
			AuthenticationInfo: GKEAuthInfo{
				PrincipalEmail:   "admin@company.internal",
				ImpersonatedUser: "system:serviceaccount:kagent:autonomous-agent-1",
			},
			Status: &GKEStatus{
				Code: 200,
			},
		},
	}

	obsFromWebhook := receiver.ConvertToObservation(webhookEvent)
	gkeK8sEvent := ConvertGKELogEntryToK8sEvent(gkeEntry)
	obsFromGKE := receiver.ConvertToObservation(gkeK8sEvent)

	// Parity assertions
	if obsFromWebhook.ID != obsFromGKE.ID {
		t.Errorf("ID mismatch: webhook=%s, gke=%s", obsFromWebhook.ID, obsFromGKE.ID)
	}
	if obsFromWebhook.Layer != obsFromGKE.Layer {
		t.Errorf("Layer mismatch: webhook=%s, gke=%s", obsFromWebhook.Layer, obsFromGKE.Layer)
	}
	if obsFromWebhook.Fidelity != obsFromGKE.Fidelity {
		t.Errorf("Fidelity mismatch: webhook=%s, gke=%s", obsFromWebhook.Fidelity, obsFromGKE.Fidelity)
	}
	if obsFromWebhook.ActorHint != obsFromGKE.ActorHint {
		t.Errorf("ActorHint mismatch: webhook=%s, gke=%s", obsFromWebhook.ActorHint, obsFromGKE.ActorHint)
	}
	if obsFromWebhook.PrincipalID != obsFromGKE.PrincipalID {
		t.Errorf("PrincipalID mismatch: webhook=%s, gke=%s", obsFromWebhook.PrincipalID, obsFromGKE.PrincipalID)
	}
	if obsFromWebhook.ImpersonatedUser != obsFromGKE.ImpersonatedUser {
		t.Errorf("ImpersonatedUser mismatch: webhook=%s, gke=%s", obsFromWebhook.ImpersonatedUser, obsFromGKE.ImpersonatedUser)
	}
	if obsFromWebhook.DelegationDepth != obsFromGKE.DelegationDepth {
		t.Errorf("DelegationDepth mismatch: webhook=%d, gke=%d", obsFromWebhook.DelegationDepth, obsFromGKE.DelegationDepth)
	}
	if obsFromWebhook.RawEvidenceRef != obsFromGKE.RawEvidenceRef {
		t.Errorf("RawEvidenceRef mismatch: webhook=%s, gke=%s", obsFromWebhook.RawEvidenceRef, obsFromGKE.RawEvidenceRef)
	}
	if obsFromWebhook.Description != obsFromGKE.Description {
		t.Errorf("Description mismatch: webhook=%s, gke=%s", obsFromWebhook.Description, obsFromGKE.Description)
	}

	// DelegationEdge parity
	if obsFromWebhook.DelegationEdge == nil || obsFromGKE.DelegationEdge == nil {
		t.Fatalf("expected non-nil DelegationEdge on both")
	}
	if obsFromWebhook.DelegationEdge.Contribution != obsFromGKE.DelegationEdge.Contribution {
		t.Errorf("DelegationEdge.Contribution mismatch:\nwebhook=%s\ngke=%s",
			obsFromWebhook.DelegationEdge.Contribution, obsFromGKE.DelegationEdge.Contribution)
	}

	// Key label parity
	keyLabels := []string{"acting_principal", "delegator", "namespace", "resource", "name", "verb", "status_code", "delegation", "delegation_basis"}
	for _, k := range keyLabels {
		if obsFromWebhook.Labels[k] != obsFromGKE.Labels[k] {
			t.Errorf("Label[%q] mismatch: webhook=%q, gke=%q", k, obsFromWebhook.Labels[k], obsFromGKE.Labels[k])
		}
	}
}
