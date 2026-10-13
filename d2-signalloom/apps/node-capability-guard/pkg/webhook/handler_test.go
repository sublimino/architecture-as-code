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

// concurrentLoadReview builds request idx of the concurrent load test: even
// indices target one of the 50 contained agents, odd ones a free agent.
func concurrentLoadReview(idx int) (body []byte, uid string, wantAllowed bool) {
	isContainedTarget := idx%2 == 0
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
	uid = fmt.Sprintf("uid-stress-%d", idx)
	b, _ := json.Marshal(webhook.AdmissionReview{
		Request: &webhook.AdmissionRequest{
			UID:       uid,
			Operation: "CREATE",
			Namespace: "fe-signalloom-agents",
			Object:    raw,
		},
	})
	return b, uid, !isContainedTarget
}

func concurrentLoadServer() *webhook.WebhookServer {
	store := webhook.NewMemoryIdentityStore()
	for i := 0; i < 50; i++ {
		_ = store.AddContained(context.Background(), webhook.ContainedEntry{
			AgentID:   fmt.Sprintf("agent-%03d", i),
			Namespace: "fe-signalloom-agents",
		})
	}
	return webhook.NewWebhookServer(store, "signalloom.demo")
}

// TestWebhookDecisionLatency_ConcurrentLoad sends 100 concurrent admission
// reviews, half for contained agents, and asserts every one gets the right
// decision for its own request: contained agents denied, free agents allowed,
// each response answering its own UID.
//
// It asserts no latency. A max over 100 goroutines measured the scheduler; the
// 50 ms decision budget lives in BenchmarkWebhookDecision, which nothing in the
// estate runs.
func TestWebhookDecisionLatency_ConcurrentLoad(t *testing.T) {
	server := concurrentLoadServer()

	const concurrency = 100
	var wg sync.WaitGroup
	wg.Add(concurrency)
	errs := make(chan error, concurrency)

	for i := 0; i < concurrency; i++ {
		go func(idx int) {
			defer wg.Done()
			body, uid, wantAllowed := concurrentLoadReview(idx)
			rec := httptest.NewRecorder()
			server.HandleValidate(rec, httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(body)))

			var resp webhook.AdmissionReview
			if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || resp.Response == nil {
				errs <- fmt.Errorf("request %d: no admission response (status %d, err %v): %s", idx, rec.Code, err, rec.Body.String())
				return
			}
			if resp.Response.UID != uid {
				errs <- fmt.Errorf("request %d: response answers UID %q, want %q", idx, resp.Response.UID, uid)
			}
			if resp.Response.Allowed != wantAllowed {
				errs <- fmt.Errorf("request %d: allowed=%v, want %v", idx, resp.Response.Allowed, wantAllowed)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}

// BenchmarkWebhookDecision carries the 50 ms per-decision budget the
// concurrent load test used to assert.
func BenchmarkWebhookDecision(b *testing.B) {
	server := concurrentLoadServer()
	b.RunParallel(func(pb *testing.PB) {
		idx := 0
		for pb.Next() {
			body, _, _ := concurrentLoadReview(idx % 100)
			idx++
			start := time.Now()
			server.HandleValidate(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(body)))
			if lat := time.Since(start); lat > 50*time.Millisecond {
				b.Errorf("decision latency %v exceeded the 50 ms budget", lat)
			}
		}
	})
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
	if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
		t.Fatalf("expected healthz Content-Type %q, got %q", "text/plain; charset=utf-8", ct)
	}

	// HEAD should succeed
	reqHead := httptest.NewRequest(http.MethodHead, "/healthz", nil)
	recHead := httptest.NewRecorder()
	webhook.HandleHealthz(recHead, reqHead)

	if recHead.Code != http.StatusOK {
		t.Fatalf("expected healthz HEAD 200 OK, got %d", recHead.Code)
	}
	if ct := recHead.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
		t.Fatalf("expected healthz HEAD Content-Type %q, got %q", "text/plain; charset=utf-8", ct)
	}
	if recHead.Body.Len() != 0 {
		t.Fatalf("expected healthz HEAD empty body, got %q", recHead.Body.String())
	}
}

func TestMethodNotAllowed_ProbesAndMetrics(t *testing.T) {
	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			reqH := httptest.NewRequest(method, path, nil)
			recH := httptest.NewRecorder()
			webhook.HandleHealthz(recH, reqH)
			if recH.Code != http.StatusMethodNotAllowed {
				t.Errorf("HandleHealthz %s %s expected 405 Method Not Allowed, got %d", method, path, recH.Code)
			}
			if recH.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
				t.Errorf("HandleHealthz %s %s expected Allow: GET, HEAD, OPTIONS, got %q", method, path, recH.Header().Get("Allow"))
			}
			if recH.Body.Len() == 0 {
				t.Errorf("HandleHealthz %s %s expected non-empty body", method, path)
			}
		}
	}

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		reqM := httptest.NewRequest(method, "/metrics", nil)
		recM := httptest.NewRecorder()
		webhook.HandleMetrics(recM, reqM)
		if recM.Code != http.StatusMethodNotAllowed {
			t.Errorf("HandleMetrics %s expected 405 Method Not Allowed, got %d", method, recM.Code)
		}
		if recM.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
			t.Errorf("HandleMetrics %s expected Allow: GET, HEAD, OPTIONS, got %q", method, recM.Header().Get("Allow"))
		}
		if recM.Body.Len() == 0 {
			t.Errorf("HandleMetrics %s expected non-empty body", method)
		}
	}
}

func TestMethodNotAllowed_HandleValidate(t *testing.T) {
	server := webhook.NewWebhookServer(nil, "signalloom.demo")
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(method, "/validate", nil)
		rec := httptest.NewRecorder()
		server.HandleValidate(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("HandleValidate %s expected 405 Method Not Allowed, got %d", method, rec.Code)
		}
		if rec.Header().Get("Allow") != "POST, OPTIONS" {
			t.Errorf("HandleValidate %s expected Allow: POST, OPTIONS, got %q", method, rec.Header().Get("Allow"))
		}
		if method == http.MethodHead {
			if rec.Body.Len() != 0 {
				t.Errorf("HandleValidate HEAD expected empty body, got %q", rec.Body.String())
			}
		} else {
			if rec.Body.Len() == 0 {
				t.Errorf("HandleValidate %s expected non-empty error body", method)
			}
		}

		// Also check package-level HandleValidate
		reqPkg := httptest.NewRequest(method, "/validate", nil)
		recPkg := httptest.NewRecorder()
		webhook.HandleValidate(recPkg, reqPkg)
		if recPkg.Code != http.StatusMethodNotAllowed {
			t.Errorf("package HandleValidate %s expected 405, got %d", method, recPkg.Code)
		}
		if recPkg.Header().Get("Allow") != "POST, OPTIONS" {
			t.Errorf("package HandleValidate %s expected Allow: POST, OPTIONS, got %q", method, recPkg.Header().Get("Allow"))
		}
		if method == http.MethodHead {
			if recPkg.Body.Len() != 0 {
				t.Errorf("package HandleValidate HEAD expected empty body, got %q", recPkg.Body.String())
			}
		} else {
			if recPkg.Body.Len() == 0 {
				t.Errorf("package HandleValidate %s expected non-empty error body", method)
			}
		}
	}
}

func TestNewMux_RoutesAndHeadParity(t *testing.T) {
	server := webhook.NewWebhookServer(nil, "signalloom.demo")
	mux := webhook.NewMux(server)

	// Test probes
	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		recGet := httptest.NewRecorder()
		mux.ServeHTTP(recGet, httptest.NewRequest(http.MethodGet, path, nil))
		if recGet.Code != http.StatusOK {
			t.Errorf("GET %s got status %d, want 200", path, recGet.Code)
		}

		recHead := httptest.NewRecorder()
		mux.ServeHTTP(recHead, httptest.NewRequest(http.MethodHead, path, nil))
		if recHead.Code != http.StatusOK {
			t.Errorf("HEAD %s got status %d, want 200", path, recHead.Code)
		}
		if recHead.Body.Len() != 0 {
			t.Errorf("HEAD %s got body %q, want empty", path, recHead.Body.String())
		}

		// Rejection on non-GET/HEAD methods across mux
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			recMethod := httptest.NewRecorder()
			mux.ServeHTTP(recMethod, httptest.NewRequest(method, path, nil))
			if recMethod.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s got status %d, want 405", method, path, recMethod.Code)
			}
			if allow := recMethod.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
				t.Errorf("%s %s Allow = %q, want GET, HEAD, OPTIONS", method, path, allow)
			}
			if recMethod.Body.Len() == 0 {
				t.Errorf("%s %s expected non-empty body", method, path)
			}
		}
	}

	// Test /metrics HEAD parity and method rejection
	recMetHead := httptest.NewRecorder()
	mux.ServeHTTP(recMetHead, httptest.NewRequest(http.MethodHead, "/metrics", nil))
	if recMetHead.Code != http.StatusOK {
		t.Errorf("HEAD /metrics got status %d, want 200", recMetHead.Code)
	}
	if ct := recMetHead.Header().Get("Content-Type"); ct != "text/plain; version=0.0.4; charset=utf-8" {
		t.Errorf("HEAD /metrics Content-Type = %q, want text/plain; version=0.0.4; charset=utf-8", ct)
	}
	if recMetHead.Body.Len() != 0 {
		t.Errorf("HEAD /metrics got body %q, want empty", recMetHead.Body.String())
	}

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		recMethod := httptest.NewRecorder()
		mux.ServeHTTP(recMethod, httptest.NewRequest(method, "/metrics", nil))
		if recMethod.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /metrics got status %d, want 405", method, recMethod.Code)
		}
		if allow := recMethod.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Errorf("%s /metrics Allow = %q, want GET, HEAD, OPTIONS", method, allow)
		}
	}

	// Test /validate HEAD method rejection and empty body
	recValHead := httptest.NewRecorder()
	mux.ServeHTTP(recValHead, httptest.NewRequest(http.MethodHead, "/validate", nil))
	if recValHead.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD /validate got status %d, want 405", recValHead.Code)
	}
	if allow := recValHead.Header().Get("Allow"); allow != "POST, OPTIONS" {
		t.Errorf("HEAD /validate Allow = %q, want POST, OPTIONS", allow)
	}
	if recValHead.Body.Len() != 0 {
		t.Errorf("HEAD /validate got body %q, want empty", recValHead.Body.String())
	}

	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		recMethod := httptest.NewRecorder()
		mux.ServeHTTP(recMethod, httptest.NewRequest(method, "/validate", nil))
		if recMethod.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /validate got status %d, want 405", method, recMethod.Code)
		}
		if allow := recMethod.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s /validate Allow = %q, want POST, OPTIONS", method, allow)
		}
		if recMethod.Body.Len() == 0 {
			t.Errorf("%s /validate expected non-empty error body", method)
		}
	}

	// Test unknown route HEAD 404 body suppression
	rec404Head := httptest.NewRecorder()
	mux.ServeHTTP(rec404Head, httptest.NewRequest(http.MethodHead, "/unknown-route", nil))
	if rec404Head.Code != http.StatusNotFound {
		t.Errorf("HEAD /unknown-route got status %d, want 404", rec404Head.Code)
	}
	if rec404Head.Body.Len() != 0 {
		t.Errorf("HEAD /unknown-route got body %q, want empty", rec404Head.Body.String())
	}

	// Test WebhookServer.ServeHTTP direct invocation with HEAD
	recSrvHead := httptest.NewRecorder()
	server.ServeHTTP(recSrvHead, httptest.NewRequest(http.MethodHead, "/validate", nil))
	if recSrvHead.Code != http.StatusMethodNotAllowed {
		t.Errorf("server.ServeHTTP HEAD got status %d, want 405", recSrvHead.Code)
	}
	if recSrvHead.Body.Len() != 0 {
		t.Errorf("server.ServeHTTP HEAD got body %q, want empty", recSrvHead.Body.String())
	}
}

func TestOPTIONS_Endpoints(t *testing.T) {
	server := webhook.NewWebhookServer(nil, "signalloom.demo")
	mux := webhook.NewMux(server)

	// Test /validate OPTIONS
	for _, target := range []string{"direct", "mux"} {
		req := httptest.NewRequest(http.MethodOptions, "/validate", nil)
		rec := httptest.NewRecorder()
		if target == "direct" {
			server.HandleValidate(rec, req)
		} else {
			mux.ServeHTTP(rec, req)
		}
		if rec.Code != http.StatusNoContent {
			t.Errorf("/validate OPTIONS (%s) expected status 204, got %d", target, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("/validate OPTIONS (%s) expected Allow: POST, OPTIONS, got %q", target, allow)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("/validate OPTIONS (%s) expected empty body, got %q", target, rec.Body.String())
		}
	}

	// Test /metrics and health probes OPTIONS
	for _, path := range []string{"/metrics", "/health", "/healthz", "/readyz"} {
		for _, target := range []string{"direct", "mux"} {
			req := httptest.NewRequest(http.MethodOptions, path, nil)
			rec := httptest.NewRecorder()
			if target == "direct" {
				if path == "/metrics" {
					webhook.HandleMetrics(rec, req)
				} else {
					webhook.HandleHealthz(rec, req)
				}
			} else {
				mux.ServeHTTP(rec, req)
			}
			if rec.Code != http.StatusNoContent {
				t.Errorf("%s OPTIONS (%s) expected status 204, got %d", path, target, rec.Code)
			}
			if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
				t.Errorf("%s OPTIONS (%s) expected Allow: GET, HEAD, OPTIONS, got %q", path, target, allow)
			}
			if rec.Body.Len() != 0 {
				t.Errorf("%s OPTIONS (%s) expected empty body, got %q", path, target, rec.Body.String())
			}
		}
	}
}

func TestHandleValidate_MissingUID(t *testing.T) {
	server := webhook.NewWebhookServer(nil, "signalloom.demo")

	// Missing UID
	body := []byte(`{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"","operation":"CREATE"}}`)
	req := httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	server.HandleValidate(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request for missing UID, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "missing request uid") {
		t.Fatalf("expected error body to mention missing request uid, got %q", rec.Body.String())
	}
}

