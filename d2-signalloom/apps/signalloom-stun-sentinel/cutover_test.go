// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestCutoverGateWaitsForPredecessorPodsAndArmsWhenGone(t *testing.T) {
	nodeName := "kind-osramp-control-plane"
	ns := "fe-signalloom-agents"

	predecessor := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "stun-sentinel-old-1234",
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name": "stun-sentinel",
				"signalloom.ai/agent":    "true",
			},
		},
		Spec: corev1.PodSpec{
			NodeName:           nodeName,
			ServiceAccountName: "stun-sentinel",
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
		},
	}

	cs := fake.NewSimpleClientset(predecessor)
	gate := &cutoverGate{
		clientset:           cs,
		namespace:           ns,
		nodeName:            nodeName,
		predecessorSelector: "app.kubernetes.io/name=stun-sentinel",
		pollInterval:        10 * time.Millisecond,
	}

	srv := newHealthServer(":8081", false, "systemd", &atomic.Int64{})
	srv.isReady = gate.isArmed
	handler := srv.Handler()

	// Initial readiness check before arming: should be 503
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("initial /readyz code = %d, want 503", rec.Code)
	}

	// Liveness check should still be 200
	reqLive := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	recLive := httptest.NewRecorder()
	handler.ServeHTTP(recLive, reqLive)
	if recLive.Code != http.StatusOK {
		t.Fatalf("/healthz code = %d, want 200", recLive.Code)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		done <- gate.wait(ctx)
	}()

	// Verify gate is still waiting
	time.Sleep(50 * time.Millisecond)
	if gate.isArmed() {
		t.Fatal("gate armed while predecessor pod is still running")
	}

	// Terminate predecessor pod
	if err := cs.CoreV1().Pods(ns).Delete(ctx, predecessor.Name, metav1.DeleteOptions{}); err != nil {
		t.Fatalf("delete predecessor: %v", err)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("gate.wait returned error: %v", err)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("gate.wait timed out after predecessor deletion")
	}

	if !gate.isArmed() {
		t.Fatal("gate not armed after predecessor deletion")
	}

	// Post-arm readiness check should be 200
	recReady := httptest.NewRecorder()
	handler.ServeHTTP(recReady, req)
	if recReady.Code != http.StatusOK {
		t.Fatalf("post-arm /readyz code = %d, want 200", recReady.Code)
	}
}

func TestCutoverGateDisabledOrEmptySelectorArmsImmediately(t *testing.T) {
	gate := &cutoverGate{
		clientset:           fake.NewSimpleClientset(),
		namespace:           "fe-signalloom-agents",
		nodeName:            "node-1",
		predecessorSelector: "",
		pollInterval:        10 * time.Millisecond,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	if err := gate.wait(ctx); err != nil {
		t.Fatalf("gate.wait with empty selector failed: %v", err)
	}
	if !gate.isArmed() {
		t.Fatal("gate not armed with empty selector")
	}
}

func TestCutoverGateIgnoresPodsOnDifferentNode(t *testing.T) {
	nodeName := "node-1"
	ns := "fe-signalloom-agents"

	otherNodePod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "stun-sentinel-node-2",
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name": "stun-sentinel",
			},
		},
		Spec: corev1.PodSpec{
			NodeName:           "node-2",
			ServiceAccountName: "stun-sentinel",
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
		},
	}

	cs := fake.NewSimpleClientset(otherNodePod)
	gate := &cutoverGate{
		clientset:           cs,
		namespace:           ns,
		nodeName:            nodeName,
		predecessorSelector: "app.kubernetes.io/name=stun-sentinel",
		pollInterval:        10 * time.Millisecond,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	if err := gate.wait(ctx); err != nil {
		t.Fatalf("gate.wait returned error: %v", err)
	}
	if !gate.isArmed() {
		t.Fatal("gate not armed when predecessor is on different node")
	}
}
