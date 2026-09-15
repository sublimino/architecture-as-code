// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package webhook_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/node-capability-guard/pkg/webhook"
)

func TestNonAgentPodAllowed(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "normal-app",
			Namespace: "default",
		},
	}
	allowed, msg := webhook.ValidatePod(pod)
	if !allowed {
		t.Fatalf("expected non-agent pod to be allowed, got: %s", msg)
	}
	if !strings.Contains(msg, "non-agent pod allowed") {
		t.Fatalf("unexpected message: %s", msg)
	}
}

func TestUnconfinedAgentPodRejected(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "rogue-agent",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
			},
		},
	}
	allowed, msg := webhook.ValidatePod(pod)
	if allowed {
		t.Fatalf("expected unconfined agent pod to be rejected")
	}
	if !strings.Contains(msg, "cgroup-v2=true, landlock=true") {
		t.Fatalf("expected message to mention containment capabilities, got: %s", msg)
	}
}

func TestCompliantAgentPodAllowed(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "compliant-agent",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
			},
		},
		Spec: webhook.PodSpec{
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}
	allowed, msg := webhook.ValidatePod(pod)
	if !allowed {
		t.Fatalf("expected compliant agent pod to be allowed, got: %s", msg)
	}
}

func TestContainedAgentPodRejected_StoreMatch(t *testing.T) {
	store := webhook.NewMemoryIdentityStore()
	ctx := context.Background()

	// Add agent-cardvault to contained store
	err := store.AddContained(ctx, webhook.ContainedEntry{
		AgentID:     "agent-cardvault",
		Namespace:   "fe-signalloom-agents",
		SPIFFEID:    "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault",
		ContainedAt: time.Now().UTC().Format(time.RFC3339),
		Reason:      "cascade containment",
	})
	if err != nil {
		t.Fatalf("failed to add contained agent: %v", err)
	}

	tests := []struct {
		name       string
		pod        *webhook.Pod
		operation  string
		wantDeny   bool
		wantReason string
	}{
		{
			name: "deny CREATE by agent-name label",
			pod: &webhook.Pod{
				Metadata: webhook.Metadata{
					Name:      "agent-cardvault-pod-1",
					Namespace: "fe-signalloom-agents",
					Labels: map[string]string{
						"signalloom.ai/agent":      "true",
						"signalloom.ai/agent-name": "cardvault",
					},
				},
				Spec: webhook.PodSpec{
					ServiceAccountName: "agent-cardvault",
					NodeSelector: map[string]string{
						"node.signalloom.ai/cgroup-v2": "true",
						"node.signalloom.ai/landlock":  "true",
					},
				},
			},
			operation:  "CREATE",
			wantDeny:   true,
			wantReason: "currently contained/stunned",
		},
		{
			name: "deny UPDATE (reschedule / restart) by SPIFFE ID",
			pod: &webhook.Pod{
				Metadata: webhook.Metadata{
					Name:      "agent-cardvault-pod-2",
					Namespace: "fe-signalloom-agents",
					Labels: map[string]string{
						"signalloom.ai/agent": "true",
					},
				},
				Spec: webhook.PodSpec{
					ServiceAccountName: "agent-cardvault",
					NodeSelector: map[string]string{
						"node.signalloom.ai/cgroup-v2": "true",
						"node.signalloom.ai/landlock":  "true",
					},
				},
			},
			operation:  "UPDATE",
			wantDeny:   true,
			wantReason: "currently contained/stunned",
		},
		{
			name: "allow sibling non-contained agent",
			pod: &webhook.Pod{
				Metadata: webhook.Metadata{
					Name:      "agent-monitor-pod-1",
					Namespace: "fe-signalloom-agents",
					Labels: map[string]string{
						"signalloom.ai/agent":      "true",
						"signalloom.ai/agent-name": "monitor",
					},
				},
				Spec: webhook.PodSpec{
					ServiceAccountName: "agent-monitor",
					NodeSelector: map[string]string{
						"node.signalloom.ai/cgroup-v2": "true",
						"node.signalloom.ai/landlock":  "true",
					},
				},
			},
			operation: "CREATE",
			wantDeny:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			allowed, msg, outcome := webhook.ValidatePodWithContext(ctx, tt.pod, tt.operation, store, "signalloom.demo")
			if tt.wantDeny {
				if allowed {
					t.Fatalf("expected pod to be denied, but was allowed: %s", msg)
				}
				if outcome != webhook.OutcomeDeniedContainedIdentity {
					t.Fatalf("expected outcome %s, got %s", webhook.OutcomeDeniedContainedIdentity, outcome)
				}
				if !strings.Contains(msg, tt.wantReason) {
					t.Fatalf("expected reason to contain %q, got: %s", tt.wantReason, msg)
				}
			} else {
				if !allowed {
					t.Fatalf("expected pod to be allowed, but was denied: %s", msg)
				}
				if outcome != webhook.OutcomeAllowed {
					t.Fatalf("expected outcome %s, got %s", webhook.OutcomeAllowed, outcome)
				}
			}
		})
	}
}

func TestContainedAgentPodRejected_ManifestStunnedLabel(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "stunned-agent-restart",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
				"signalloom.ai/state": "stunned",
			},
		},
		Spec: webhook.PodSpec{
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}

	allowed, msg, outcome := webhook.ValidatePodWithContext(context.Background(), pod, "CREATE", webhook.NewMemoryIdentityStore(), "signalloom.demo")
	if allowed {
		t.Fatalf("expected pod with stunned state label to be denied admission")
	}
	if outcome != webhook.OutcomeDeniedContainedIdentity {
		t.Fatalf("expected outcome %s, got %s", webhook.OutcomeDeniedContainedIdentity, outcome)
	}
	if !strings.Contains(msg, "pod manifest specifies contained/stunned state") {
		t.Fatalf("unexpected denial message: %s", msg)
	}
}

func TestContainedAgentPod_StoreFailure_FailsClosed(t *testing.T) {
	failingStore := webhook.NewFailingIdentityStore(errors.New("connection timeout to contained-agents configmap"))

	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "compliant-agent",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				"signalloom.ai/agent":      "true",
				"signalloom.ai/agent-name": "compliant",
			},
		},
		Spec: webhook.PodSpec{
			ServiceAccountName: "agent-compliant",
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}

	allowed, msg, outcome := webhook.ValidatePodWithContext(context.Background(), pod, "CREATE", failingStore, "signalloom.demo")
	if allowed {
		t.Fatalf("expected store failure to result in fail-closed denial, but pod was allowed")
	}
	if outcome != webhook.OutcomeDeniedStoreUnavailable {
		t.Fatalf("expected outcome %s, got %s", webhook.OutcomeDeniedStoreUnavailable, outcome)
	}
	if !strings.Contains(msg, "fail-closed") {
		t.Fatalf("expected message to note fail-closed policy, got: %s", msg)
	}
}

func TestHTTPWebhookValidation(t *testing.T) {
	store := webhook.NewMemoryIdentityStore()
	ctx := context.Background()
	_ = store.AddContained(ctx, webhook.ContainedEntry{
		AgentID:   "agent-isolated",
		Namespace: "fe-signalloom-agents",
	})

	server := webhook.NewWebhookServer(store, "signalloom.demo")

	// 1. Test Contained Pod Denied via HTTP
	containedPod := webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "agent-isolated-xyz",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				"signalloom.ai/agent":      "true",
				"signalloom.ai/agent-name": "isolated",
			},
		},
		Spec: webhook.PodSpec{
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}
	rawContained, _ := json.Marshal(containedPod)

	reqReview := webhook.AdmissionReview{
		APIVersion: "admission.k8s.io/v1",
		Kind:       "AdmissionReview",
		Request: &webhook.AdmissionRequest{
			UID:       "test-uid-contained",
			Operation: "CREATE",
			Namespace: "fe-signalloom-agents",
			Name:      "agent-isolated-xyz",
			Object:    rawContained,
		},
	}
	body, _ := json.Marshal(reqReview)

	req := httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	server.HandleValidate(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200 response envelope, got %d", rec.Code)
	}

	var respReview webhook.AdmissionReview
	if err := json.Unmarshal(rec.Body.Bytes(), &respReview); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if respReview.Response == nil {
		t.Fatalf("expected admission response, got nil")
	}
	if respReview.Response.Allowed {
		t.Fatalf("expected contained agent request to be denied")
	}
	if respReview.Response.Result.Code != http.StatusForbidden {
		t.Fatalf("expected 403 status code in admission response, got %d", respReview.Response.Result.Code)
	}

	// 2. Test Compliant Uncontained Pod Allowed via HTTP
	compliantPod := webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "agent-active-xyz",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				"signalloom.ai/agent":      "true",
				"signalloom.ai/agent-name": "active",
			},
		},
		Spec: webhook.PodSpec{
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}
	rawCompliant, _ := json.Marshal(compliantPod)

	reqReviewAllowed := webhook.AdmissionReview{
		APIVersion: "admission.k8s.io/v1",
		Kind:       "AdmissionReview",
		Request: &webhook.AdmissionRequest{
			UID:       "test-uid-allowed",
			Operation: "CREATE",
			Namespace: "fe-signalloom-agents",
			Name:      "agent-active-xyz",
			Object:    rawCompliant,
		},
	}
	bodyAllowed, _ := json.Marshal(reqReviewAllowed)

	reqAllowed := httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(bodyAllowed))
	recAllowed := httptest.NewRecorder()
	server.HandleValidate(recAllowed, reqAllowed)

	var respReviewAllowed webhook.AdmissionReview
	_ = json.Unmarshal(recAllowed.Body.Bytes(), &respReviewAllowed)

	if !respReviewAllowed.Response.Allowed {
		t.Fatalf("expected compliant agent request to be allowed")
	}
	if respReviewAllowed.Response.Result.Code != http.StatusOK {
		t.Fatalf("expected 200 status code, got %d", respReviewAllowed.Response.Result.Code)
	}
}

func TestHTTPWebhookValidation_MetricsExport(t *testing.T) {
	// Execute a known set of requests to increment counters
	store := webhook.NewMemoryIdentityStore()
	ctx := context.Background()
	_ = store.AddContained(ctx, webhook.ContainedEntry{AgentID: "agent-target"})

	server := webhook.NewWebhookServer(store, "signalloom.demo")

	// Pod 1: Contained -> Denied
	pod1 := webhook.Pod{
		Metadata: webhook.Metadata{Labels: map[string]string{"signalloom.ai/agent-name": "target"}},
		Spec:     webhook.PodSpec{NodeSelector: map[string]string{"node.signalloom.ai/cgroup-v2": "true", "node.signalloom.ai/landlock": "true"}},
	}
	raw1, _ := json.Marshal(pod1)
	r1 := webhook.AdmissionReview{Request: &webhook.AdmissionRequest{UID: "uid-1", Object: raw1}}
	b1, _ := json.Marshal(r1)
	server.HandleValidate(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(b1)))

	// Check metrics output
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	webhook.HandleMetrics(rec, req)

	metricsText := rec.Body.String()

	// Assert presence of legacy counters
	if !strings.Contains(metricsText, "node_capability_rejections_total") {
		t.Errorf("missing legacy metric node_capability_rejections_total")
	}
	if !strings.Contains(metricsText, "node_capability_admissions_total") {
		t.Errorf("missing legacy metric node_capability_admissions_total")
	}

	// Assert presence of new fine-grained counters
	if !strings.Contains(metricsText, "node_capability_rejections_contained_identity_total") {
		t.Errorf("missing metric node_capability_rejections_contained_identity_total")
	}
	if !strings.Contains(metricsText, "node_capability_rejections_store_unavailable_total") {
		t.Errorf("missing metric node_capability_rejections_store_unavailable_total")
	}
	if !strings.Contains(metricsText, "node_capability_rejections_node_capability_total") {
		t.Errorf("missing metric node_capability_rejections_node_capability_total")
	}
	if !strings.Contains(metricsText, "node_capability_admissions_allowed_total") {
		t.Errorf("missing metric node_capability_admissions_allowed_total")
	}
}

func TestHTTPWebhookValidation_StructuredLogging(t *testing.T) {
	var loggedEntries []webhook.AdmissionDecisionLogEntry
	var mu sync.Mutex

	customLogger := func(entry webhook.AdmissionDecisionLogEntry) {
		mu.Lock()
		defer mu.Unlock()
		loggedEntries = append(loggedEntries, entry)
	}

	store := webhook.NewMemoryIdentityStore()
	_ = store.AddContained(context.Background(), webhook.ContainedEntry{AgentID: "agent-bad"})

	server := webhook.NewWebhookServer(store, "signalloom.demo")
	server.Logger = customLogger

	badPod := webhook.Pod{
		Metadata: webhook.Metadata{
			Name:      "agent-bad-pod",
			Namespace: "fe-signalloom-agents",
			Labels:    map[string]string{"signalloom.ai/agent-name": "bad"},
		},
		Spec: webhook.PodSpec{
			ServiceAccountName: "agent-bad",
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}
	rawBad, _ := json.Marshal(badPod)
	reqReview := webhook.AdmissionReview{
		Request: &webhook.AdmissionRequest{
			UID:       "uid-log-test",
			Operation: "CREATE",
			Namespace: "fe-signalloom-agents",
			Name:      "agent-bad-pod",
			Object:    rawBad,
		},
	}
	b, _ := json.Marshal(reqReview)
	server.HandleValidate(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(b)))

	mu.Lock()
	defer mu.Unlock()

	if len(loggedEntries) == 0 {
		t.Fatalf("expected structured log entry to be emitted")
	}

	entry := loggedEntries[0]
	if entry.Event != "admission_decision" {
		t.Errorf("expected event 'admission_decision', got %s", entry.Event)
	}
	if entry.UID != "uid-log-test" {
		t.Errorf("expected UID 'uid-log-test', got %s", entry.UID)
	}
	if entry.Allowed != false {
		t.Errorf("expected Allowed=false")
	}
	if entry.Outcome != webhook.OutcomeDeniedContainedIdentity {
		t.Errorf("expected outcome %s, got %s", webhook.OutcomeDeniedContainedIdentity, entry.Outcome)
	}
	if entry.WorstCaseResidualMs != 0 {
		t.Errorf("expected worst_case_residual_ms=0 for admission block, got %d", entry.WorstCaseResidualMs)
	}
	if entry.SPIFFEID != "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-bad" {
		t.Errorf("unexpected SPIFFE ID: %s", entry.SPIFFEID)
	}
}

func TestWebhookDecisionLatency_ConcurrentLoad(t *testing.T) {
	store := webhook.NewMemoryIdentityStore()
	ctx := context.Background()

	// Seed store with 50 contained agents
	for i := 0; i < 50; i++ {
		_ = store.AddContained(ctx, webhook.ContainedEntry{
			AgentID:   fmt.Sprintf("agent-%03d", i),
			Namespace: "fe-signalloom-agents",
		})
	}

	server := webhook.NewWebhookServer(store, "signalloom.demo")

	concurrency := 100
	var wg sync.WaitGroup
	wg.Add(concurrency)

	latencies := make([]time.Duration, concurrency)
	var deniedCount uint64
	var allowedCount uint64

	for i := 0; i < concurrency; i++ {
		idx := i
		go func() {
			defer wg.Done()
			isContainedTarget := (idx % 2 == 0)
			agentName := fmt.Sprintf("agent-%03d", idx%50)
			if !isContainedTarget {
				agentName = fmt.Sprintf("agent-free-%03d", idx)
			}

			pod := webhook.Pod{
				Metadata: webhook.Metadata{
					Name:      fmt.Sprintf("%s-pod-%d", agentName, idx),
					Namespace: "fe-signalloom-agents",
					Labels: map[string]string{
						"signalloom.ai/agent":      "true",
						"signalloom.ai/agent-name": strings.TrimPrefix(agentName, "agent-"),
					},
				},
				Spec: webhook.PodSpec{
					ServiceAccountName: agentName,
					NodeSelector: map[string]string{
						"node.signalloom.ai/cgroup-v2": "true",
						"node.signalloom.ai/landlock":  "true",
					},
				},
			}
			raw, _ := json.Marshal(pod)
			reqReview := webhook.AdmissionReview{
				Request: &webhook.AdmissionRequest{
					UID:       fmt.Sprintf("uid-stress-%d", idx),
					Operation: "CREATE",
					Namespace: "fe-signalloom-agents",
					Object:    raw,
				},
			}
			b, _ := json.Marshal(reqReview)

			start := time.Now()
			req := httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(b))
			rec := httptest.NewRecorder()
			server.HandleValidate(rec, req)
			lat := time.Since(start)
			latencies[idx] = lat

			var respReview webhook.AdmissionReview
			_ = json.Unmarshal(rec.Body.Bytes(), &respReview)
			if respReview.Response != nil {
				if respReview.Response.Allowed {
					atomic.AddUint64(&allowedCount, 1)
				} else {
					atomic.AddUint64(&deniedCount, 1)
				}
			}
		}()
	}

	wg.Wait()

	// Calculate max latency
	var maxLat time.Duration
	var totalLat time.Duration
	for _, l := range latencies {
		if l > maxLat {
			maxLat = l
		}
		totalLat += l
	}
	avgLat := totalLat / time.Duration(concurrency)

	t.Logf("Concurrent load benchmark (%d requests): avg=%v, max=%v, allowed=%d, denied=%d",
		concurrency, avgLat, maxLat, allowedCount, deniedCount)

	// Decision latency under 100 concurrent requests must stay strictly bounded (< 50ms, timeout budget is 5s)
	if maxLat > 50*time.Millisecond {
		t.Fatalf("decision latency exceeded budget: max=%v (> 50ms)", maxLat)
	}
	if allowedCount == 0 || deniedCount == 0 {
		t.Fatalf("expected both allowed and denied outcomes in concurrent test (allowed=%d, denied=%d)", allowedCount, deniedCount)
	}
}

func TestFileIdentityStore_Lifecycle(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "store-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	filePath := filepath.Join(tmpDir, "contained-agents.json")
	store, err := webhook.NewFileIdentityStore(filePath)
	if err != nil {
		t.Fatalf("failed to create file store: %v", err)
	}

	ctx := context.Background()

	// Initial check: empty
	contained, _, err := store.IsContained(ctx, "fe-signalloom-agents", []string{"agent-alpha"})
	if err != nil || contained {
		t.Fatalf("expected not contained, got contained=%v, err=%v", contained, err)
	}

	// Add entry
	err = store.AddContained(ctx, webhook.ContainedEntry{
		AgentID:     "agent-alpha",
		Namespace:   "fe-signalloom-agents",
		ContainedAt: time.Now().UTC().Format(time.RFC3339),
		Reason:      "test-containment",
	})
	if err != nil {
		t.Fatalf("failed to add contained entry: %v", err)
	}

	// Verify file was written
	if _, err := os.Stat(filePath); err != nil {
		t.Fatalf("expected store file to exist: %v", err)
	}

	// Verify lookup matches
	contained, matched, err := store.IsContained(ctx, "fe-signalloom-agents", []string{"alpha"})
	if err != nil || !contained {
		t.Fatalf("expected contained=true, got contained=%v, matched=%s, err=%v", contained, matched, err)
	}

	// Remove entry
	err = store.RemoveContained(ctx, "fe-signalloom-agents", "agent-alpha")
	if err != nil {
		t.Fatalf("failed to remove contained entry: %v", err)
	}

	contained, _, err = store.IsContained(ctx, "fe-signalloom-agents", []string{"alpha"})
	if err != nil || contained {
		t.Fatalf("expected contained=false after removal, got contained=%v, err=%v", contained, err)
	}
}

func TestHealthz_Endpoint(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	webhook.HandleHealthz(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected healthz 200 OK, got %d", rec.Code)
	}
}
