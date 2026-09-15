// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/tc"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

// Helper to create a fake k8s clientset with agent pods
func newFakeClientsetWithPods() *fake.Clientset {
	podAlpha := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-alpha",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				AgentLabel:     "true",
				AgentNameLabel: "alpha",
				PodStateLabel:  "active",
			},
		},
		Status: corev1.PodStatus{
			PodIP: "10.244.0.15",
		},
	}
	podBeta := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-beta",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				AgentLabel:     "true",
				AgentNameLabel: "beta",
				PodStateLabel:  "active",
			},
		},
		Status: corev1.PodStatus{
			PodIP: "10.244.0.16",
		},
	}
	podIPv6 := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-ipv6",
			Namespace: "fe-signalloom-agents",
			Labels: map[string]string{
				AgentLabel:     "true",
				AgentNameLabel: "ipv6",
				PodStateLabel:  "active",
			},
		},
		Status: corev1.PodStatus{
			PodIP: "2001:db8::42",
		},
	}
	return fake.NewSimpleClientset(podAlpha, podBeta, podIPv6)
}

// ISC-3 & ISC-4: Test IPv4 target isolation flushes conntrack
func TestCiliumMeshClient_Isolate_IPv4Target_FlushesConntrack(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	var flushCalls atomic.Int32
	var lastFlushedIP net.IP

	mockFlusher := func(target net.IP) (int, error) {
		flushCalls.Add(1)
		lastFlushedIP = target
		return 3, nil // 3 TCP connections cut
	}

	var logs []MeshIsolationAuditLogEntry
	mockLogger := func(entry MeshIsolationAuditLogEntry) {
		logs = append(logs, entry)
	}

	client := NewCiliumMeshClientWithFlusher(clientset, mockFlusher, time.Now, mockLogger)

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "test-iso-001",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Reason:         "adversarial prompt injection detected",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	ctx := context.Background()
	resp, err := client.IsolateAgentMesh(ctx, req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if resp.Outcome != OutcomeContained {
		t.Errorf("expected OutcomeContained, got %v", resp.Outcome)
	}
	if !resp.PolicyApplied {
		t.Errorf("expected PolicyApplied=true")
	}
	if resp.ConnectionsCut != 3 {
		t.Errorf("expected ConnectionsCut=3, got %d", resp.ConnectionsCut)
	}
	if flushCalls.Load() != 1 {
		t.Errorf("expected 1 flush call, got %d", flushCalls.Load())
	}
	if lastFlushedIP.String() != "10.244.0.15" {
		t.Errorf("expected flushed IP 10.244.0.15, got %v", lastFlushedIP)
	}

	planeRes := MeshIsolationResponseToPlaneResult(resp, req.Namespace, "10.244.0.15")
	if planeRes.Plane != PlaneMesh {
		t.Errorf("expected PlaneMesh, got %v", planeRes.Plane)
	}
	if planeRes.Details["worst_case_residual_ms"] != MeshIPv4WorstCaseResidualMs {
		t.Errorf("expected 0ms residual for IPv4, got %v", planeRes.Details["worst_case_residual_ms"])
	}
	if planeRes.Details["conntrack_flushed"] != true {
		t.Errorf("expected conntrack_flushed=true")
	}
}

// ISC-5: Test IPv6 target falls back to policy-based denial with documented residual
func TestCiliumMeshClient_Isolate_IPv6Target_FallsBackToPolicyWithDocumentedResidual(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	var flushCalls atomic.Int32

	mockFlusher := func(target net.IP) (int, error) {
		flushCalls.Add(1)
		return 0, nil
	}

	client := NewCiliumMeshClientWithFlusher(clientset, mockFlusher, time.Now, nil)

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "test-iso-ipv6",
		AgentID:        "agent-ipv6",
		Namespace:      "fe-signalloom-agents",
		Reason:         "containment test",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	ctx := context.Background()
	resp, err := client.IsolateAgentMesh(ctx, req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// For IPv6, outcome is Partial because conntrack flush is unsupported
	if resp.Outcome != OutcomePartial {
		t.Errorf("expected OutcomePartial for IPv6 target, got %v", resp.Outcome)
	}
	if !resp.PolicyApplied {
		t.Errorf("expected PolicyApplied=true")
	}
	if resp.ConnectionsCut != 0 {
		t.Errorf("expected ConnectionsCut=0 for IPv6, got %d", resp.ConnectionsCut)
	}
	if flushCalls.Load() != 0 {
		t.Errorf("expected 0 flush calls for IPv6 target, got %d", flushCalls.Load())
	}

	planeRes := MeshIsolationResponseToPlaneResult(resp, req.Namespace, "2001:db8::42")
	if planeRes.Details["worst_case_residual_ms"] != MeshIPv6WorstCaseResidualMs {
		t.Errorf("expected 120000ms residual for IPv6, got %v", planeRes.Details["worst_case_residual_ms"])
	}
	if planeRes.Details["conntrack_flushed"] != false {
		t.Errorf("expected conntrack_flushed=false for IPv6")
	}
}

// ISC-6: Regression test confirming conntrack.FlushIP rejects non-IPv4 targets
func TestCiliumMeshClient_ConntrackFlushIP_RejectsNonIPv4_Regression(t *testing.T) {
	// Nil IP
	_, errNil := tc.FlushIP(nil)
	if errNil == nil {
		t.Fatal("expected error for nil IP, got nil")
	}
	expectedNilMsg := "conntrack: FlushIP requires an IPv4 address, got <nil>"
	if errNil.Error() != expectedNilMsg {
		t.Errorf("expected %q, got %q", expectedNilMsg, errNil.Error())
	}

	// IPv6 IP
	ipv6 := net.ParseIP("2001:db8::8a2e:370:7334")
	_, errIPv6 := tc.FlushIP(ipv6)
	if errIPv6 == nil {
		t.Fatal("expected error for IPv6 IP, got nil")
	}
	expectedIPv6Msg := fmt.Sprintf("conntrack: FlushIP requires an IPv4 address, got %v", ipv6)
	if errIPv6.Error() != expectedIPv6Msg {
		t.Errorf("expected %q, got %q", expectedIPv6Msg, errIPv6.Error())
	}
}

// ISC-7: Idempotency test for double-apply
func TestCiliumMeshClient_Isolate_Idempotency_DoubleApply(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	var flushCalls atomic.Int32

	mockFlusher := func(target net.IP) (int, error) {
		flushCalls.Add(1)
		return 1, nil
	}

	client := NewCiliumMeshClientWithFlusher(clientset, mockFlusher, time.Now, nil)

	req1 := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "idem-key-1",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	ctx := context.Background()
	resp1, err1 := client.IsolateAgentMesh(ctx, req1)
	if err1 != nil {
		t.Fatalf("call 1 failed: %v", err1)
	}
	if resp1.Outcome != OutcomeContained {
		t.Errorf("call 1 expected OutcomeContained, got %v", resp1.Outcome)
	}

	// Retry call with same target
	req2 := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "idem-key-1", // retried key
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	resp2, err2 := client.IsolateAgentMesh(ctx, req2)
	if err2 != nil {
		t.Fatalf("call 2 (retry) failed: %v", err2)
	}
	if resp2.Outcome != OutcomeContained {
		t.Errorf("call 2 expected OutcomeContained, got %v", resp2.Outcome)
	}
}

// ISC-8: Idempotency test for double-remove (restore)
func TestCiliumMeshClient_Restore_Idempotency_DoubleRemove(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	client := NewCiliumMeshClient(clientset)

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "restore-key-1",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	ctx := context.Background()
	// Isolate first
	_, err := client.IsolateAgentMesh(ctx, req)
	if err != nil {
		t.Fatalf("isolate failed: %v", err)
	}

	// First restore
	resp1, err1 := client.RestoreAgentMesh(ctx, req)
	if err1 != nil {
		t.Fatalf("first restore failed: %v", err1)
	}
	if resp1.Outcome != OutcomeContained {
		t.Errorf("first restore expected OutcomeContained, got %v", resp1.Outcome)
	}

	// Second restore (idempotent remove on already un-isolated target)
	resp2, err2 := client.RestoreAgentMesh(ctx, req)
	if err2 != nil {
		t.Fatalf("second restore failed: %v", err2)
	}
	if resp2.Outcome != OutcomeContained {
		t.Errorf("second restore expected OutcomeContained, got %v", resp2.Outcome)
	}
}

// ISC-9: Failure injection (context timeout) returns OutcomeUnavailable
func TestCiliumMeshClient_ContextTimeout_ReturnsUnavailable(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	client := NewCiliumMeshClient(clientset)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-cancel context

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "timeout-key",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	resp, err := client.IsolateAgentMesh(ctx, req)
	if err == nil {
		t.Fatal("expected error on cancelled context, got nil")
	}
	if !errors.Is(err, ErrEnforcementUnavailable) {
		t.Errorf("expected ErrEnforcementUnavailable, got %v", err)
	}
	if resp.Outcome != OutcomeUnavailable {
		t.Errorf("expected OutcomeUnavailable, got %v", resp.Outcome)
	}
}

// ISC-11: Structured logging emits all SharedAttestationEventKeys
func TestCiliumMeshClient_StructuredLogging_EmitsAttestationKeys(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	var emittedLog MeshIsolationAuditLogEntry
	mockLogger := func(entry MeshIsolationAuditLogEntry) {
		emittedLog = entry
	}

	mockFlusher := func(target net.IP) (int, error) {
		return 2, nil
	}

	client := NewCiliumMeshClientWithFlusher(clientset, mockFlusher, time.Now, mockLogger)

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "log-audit-key",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	ctx := context.Background()
	_, err := client.IsolateAgentMesh(ctx, req)
	if err != nil {
		t.Fatalf("isolation failed: %v", err)
	}

	data, err := json.Marshal(emittedLog)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	var rawMap map[string]any
	if err := json.Unmarshal(data, &rawMap); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	// Verify all SharedAttestationEventKeys are present
	for _, key := range SharedAttestationEventKeys {
		if _, ok := rawMap[key]; !ok {
			t.Errorf("missing required SharedAttestationEventKey: %q in %s", key, string(data))
		}
	}

	if emittedLog.Event != MeshIsolationEventName {
		t.Errorf("expected Event=%q, got %q", MeshIsolationEventName, emittedLog.Event)
	}
	if emittedLog.Outcome != OutcomeContained {
		t.Errorf("expected OutcomeContained, got %v", emittedLog.Outcome)
	}
	if emittedLog.EntriesDeleted != 2 {
		t.Errorf("expected EntriesDeleted=2, got %d", emittedLog.EntriesDeleted)
	}
	if emittedLog.TargetIP != "10.244.0.15" {
		t.Errorf("expected TargetIP=10.244.0.15, got %s", emittedLog.TargetIP)
	}
}

// ISC-12: Proving isolating Agent A does not affect Agent B (zero collateral denial)
func TestCiliumMeshClient_ZeroCollateralDenial(t *testing.T) {
	clientset := newFakeClientsetWithPods()
	var flushedIPs []string

	mockFlusher := func(target net.IP) (int, error) {
		flushedIPs = append(flushedIPs, target.String())
		return 1, nil
	}

	client := NewCiliumMeshClientWithFlusher(clientset, mockFlusher, time.Now, nil)

	ctx := context.Background()

	// Isolate Agent Alpha
	reqAlpha := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "iso-alpha",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}
	respAlpha, err := client.IsolateAgentMesh(ctx, reqAlpha)
	if err != nil {
		t.Fatalf("isolate alpha failed: %v", err)
	}
	if respAlpha.Outcome != OutcomeContained {
		t.Errorf("expected alpha contained")
	}

	// Verify only Alpha's IP (10.244.0.15) was flushed, NOT Beta's (10.244.0.16)
	if len(flushedIPs) != 1 || flushedIPs[0] != "10.244.0.15" {
		t.Errorf("expected only 10.244.0.15 flushed, got %v", flushedIPs)
	}

	// Verify Beta remains un-isolated
	client.mu.Lock()
	betaIsolated := client.isolated["fe-signalloom-agents/agent-beta"]
	client.mu.Unlock()

	if betaIsolated {
		t.Errorf("collateral denial detected: agent-beta was marked isolated when only agent-alpha was targeted")
	}
}

// ISC-10: Test k8sFleetClient IsolateMeshPlane marks degraded on failure
func TestK8sFleetClient_IsolateMeshPlane_DegradedRegistry(t *testing.T) {
	clientset := newFakeClientsetWithPods()

	// Failing mesh client that returns error
	failingFlusher := func(target net.IP) (int, error) {
		return 0, fmt.Errorf("netlink: socket connection refused")
	}
	failingMeshClient := NewCiliumMeshClientWithFlusher(clientset, failingFlusher, time.Now, nil)

	k8sClient := newK8sFleetClientWithMesh(clientset, "fe-signalloom-agents", failingMeshClient)

	ctx := context.Background()
	res, err := k8sClient.IsolateMeshPlane(ctx, "fe-signalloom-agents", "agent-alpha", "degraded-test-key")
	if err != nil {
		t.Fatalf("unexpected hard error: %v", err)
	}

	if res.Outcome != OutcomePartial {
		t.Errorf("expected OutcomePartial, got %v", res.Outcome)
	}

	// Now test complete failure with cancelled context
	ctxCancelled, cancel := context.WithCancel(context.Background())
	cancel()

	resUnavailable, errUnavailable := k8sClient.IsolateMeshPlane(ctxCancelled, "fe-signalloom-agents", "agent-alpha", "degraded-test-key-2")
	if errUnavailable == nil {
		t.Fatal("expected error on cancelled context")
	}
	if resUnavailable.Outcome != OutcomeUnavailable {
		t.Errorf("expected OutcomeUnavailable, got %v", resUnavailable.Outcome)
	}

	// Verify degradedRegistry records PlaneMesh as degraded
	if !k8sClient.degraded.isDegradedOnPlane(PlaneMesh, "fe-signalloom-agents", "agent-alpha") {
		t.Errorf("expected agent-alpha to be marked degraded on PlaneMesh")
	}

	// Now recover successfully
	workingMeshClient := NewCiliumMeshClient(clientset)
	k8sClient.SetMeshClient(workingMeshClient)

	restoreRes, restoreErr := k8sClient.RestoreMeshPlane(context.Background(), "fe-signalloom-agents", "agent-alpha", "restore-key")
	if restoreErr != nil {
		t.Fatalf("restore failed: %v", restoreErr)
	}
	if restoreRes.Outcome != OutcomeContained {
		t.Errorf("expected OutcomeContained, got %v", restoreRes.Outcome)
	}

	// Verify degradedRegistry is cleared for PlaneMesh
	if k8sClient.degraded.isDegradedOnPlane(PlaneMesh, "fe-signalloom-agents", "agent-alpha") {
		t.Errorf("expected agent-alpha degraded status to be cleared on PlaneMesh after successful restore")
	}
}

// ISC-13: Benchmark in-flight TCP connection termination latency
func BenchmarkMeshIsolation_TerminationLatency(b *testing.B) {
	clientset := newFakeClientsetWithPods()
	mockFlusher := func(target net.IP) (int, error) {
		return 5, nil // simulated 5 connections cut
	}
	client := NewCiliumMeshClientWithFlusher(clientset, mockFlusher, time.Now, nil)
	ctx := context.Background()

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "bench-key",
		AgentID:        "agent-alpha",
		Namespace:      "fe-signalloom-agents",
		PodName:        "agent-alpha",
		TargetIPs:      []string{"10.244.0.15"},
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		resp, err := client.IsolateAgentMesh(ctx, req)
		if err != nil {
			b.Fatalf("isolation benchmark failed: %v", err)
		}
		if resp.Outcome != OutcomeContained {
			b.Fatalf("expected OutcomeContained, got %v", resp.Outcome)
		}
	}
}
