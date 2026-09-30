// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The correlator's direct freeze must be accepted by the engine the reconciler
// configured; a credential mismatch turns every eBPF detection into a silent
// no-op (DirectReaction "none").
func TestCorrelatorFreezeIsAuthorisedByTheReconcilerEngine(t *testing.T) {
	f := newCgroupFreezer(t.TempDir(), true, "freeze-secret", "resume-secret")
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "tenant-kusari", Name: "agent", UID: "771fb437-10ec-47dc-89a0-538e1fc16d3f"},
		Status:     corev1.PodStatus{Phase: corev1.PodRunning},
	}
	if err := newCorrelatorFreezeManager(f).FreezePod(pod); err != nil {
		t.Fatalf("correlator freeze refused by the sentinel's own engine: %v", err)
	}
}
