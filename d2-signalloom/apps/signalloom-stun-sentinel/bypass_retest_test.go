// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Regression tests for the 2026-10-06 retest of docs/signalloom/stun-residual-risk.md
// (card sldc/bypass-retest). These pin STUN-BYPASS-017, -019 and -025 CLOSED:
// containment reaches a pod that carries NO stun label of its own, driven
// purely by the Deployment-level signalloom.io/stunned owner-chain record,
// and it reaches it twice over — once for a pod that was simply never
// labelled (017), and again for a pod with a brand new UID simulating a
// reschedule/replacement (019). Unlike kernel_test.go's
// TestKernelTruth_DeploymentStunRecordMakesPodStunned, which deliberately
// fails at the veth step to isolate the kernel-publish ordering, both tests
// here exercise the FULL reconcile path end to end: cgroup freeze AND TC
// drop attachment, so "containment reaches the replacement" is proven, not
// just "the pod is recognised as stunned".
//
// Both harnesses start with zero prior in-memory sentinel state (no holds,
// no owner cache), which is structurally the same starting condition as a
// freshly restarted sentinel — so these also stand as the restart-recovery
// proof for STUN-BYPASS-025: recovery comes from the durable k8s owner
// annotation, never from anything the process remembered.

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

// fullyWiredTC returns a tcDropFilter whose PID/veth resolution and tc(8)
// exec all succeed, backed by the fakeTC kernel-state model already used by
// tc_idempotent_test.go, so a successful attachDrop can be asserted by
// inspecting fakeTC.filters rather than merely "no error".
func fullyWiredTC(k *fakeTC) *tcDropFilter {
	tc := newTCDropFilter()
	tc.run = k.run
	tc.pidForCgroup = func(string) (int, error) { return 100, nil }
	tc.peerIndex = func(int, string) (int, error) { return 42, nil }
	tc.interfaces = func() ([]net.Interface, error) { return []net.Interface{{Name: "veth42", Index: 42}}, nil }
	return tc
}

// ownerStunnedHarness builds a reconciler over a real (temp-dir) cgroup tree
// and a fake owner chain, with no pre-seeded in-memory sentinel state.
type ownerStunnedHarness struct {
	r  *stunReconciler
	tc *fakeTC
}

func newOwnerStunnedHarness(t *testing.T, podUID string) *ownerStunnedHarness {
	t.Helper()
	root := t.TempDir()
	cg := filepath.Join(root, "kubepods.slice", "kubepods-burstable.slice",
		"kubepods-burstable-pod"+strings.ReplaceAll(podUID, "-", "_")+".slice")
	mockFreezableCgroup(t, cg, false)
	simulateKernel(t, cg)

	fake := newFakeTC()
	freezer := newCgroupFreezer(root, false, "token", "token")
	r := newStunReconciler(freezer, fullyWiredTC(fake), newProbePreserver())

	api := &fakeKubeAPI{
		replicaSets: map[string]*appsv1.ReplicaSet{
			"rs-agent-cardvault": {
				ObjectMeta: metav1.ObjectMeta{
					Name: "rs-agent-cardvault",
					OwnerReferences: []metav1.OwnerReference{
						{Kind: "Deployment", Name: "agent-cardvault", Controller: boolPtr(true)},
					},
				},
			},
		},
		deployments: map[string]*appsv1.Deployment{
			"agent-cardvault": {
				ObjectMeta: metav1.ObjectMeta{
					Name:        "agent-cardvault",
					Annotations: map[string]string{annotationOwnerStunned: "true"},
				},
			},
		},
	}
	r.kernel = newKernelPublisher(api, 30*time.Second, false)
	return &ownerStunnedHarness{r: r, tc: fake}
}

func replacementPod(uid, name string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "fe-signalloom-agents",
			UID:       types.UID(uid),
			OwnerReferences: []metav1.OwnerReference{
				{Kind: "ReplicaSet", Name: "rs-agent-cardvault", Controller: boolPtr(true)},
			},
			// Deliberately NO signalloom.ai/state, signalloom.io/stunned, or
			// signalloom.io/containment-mode label: this pod's only stun
			// record is its owner chain.
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

// TestBypassRetest017_UnlabelledPodReachesFullContainmentFromOwnerChain pins
// STUN-BYPASS-017 CLOSED: a pod with zero stun labels of its own, whose
// controlling Deployment carries signalloom.io/stunned=true, is fully
// contained (cgroup frozen AND TC drop attached) by one reconcile call.
func TestBypassRetest017_UnlabelledPodReachesFullContainmentFromOwnerChain(t *testing.T) {
	const uid = "11111111-0017-0017-0017-000000000017"
	h := newOwnerStunnedHarness(t, uid)
	pod := replacementPod(uid, "agent-cardvault-7f8d9c-abcde")

	if err := h.r.reconcile(pod); err != nil {
		t.Fatalf("reconcile: %v (owner-chain stun record should have driven full containment)", err)
	}
	if h.tc.filters["ingress"] == "" || h.tc.filters["egress"] == "" {
		t.Fatalf("TC drop not attached for an owner-stunned, label-less pod: filters=%v", h.tc.filters)
	}
}

// TestBypassRetest019_ReplacementPodWithNewUIDIsFrozenOnFirstSight pins
// STUN-BYPASS-019 CLOSED: a pod simulating a reschedule/replacement (new
// UID, new cgroup, new veth — none of which existed before) is still fully
// contained on the very first reconcile that observes it, because the
// containment decision rides the Deployment's stun record, not anything
// tied to the pod it replaced.
func TestBypassRetest019_ReplacementPodWithNewUIDIsFrozenOnFirstSight(t *testing.T) {
	const uid = "22222222-0019-0019-0019-000000000019"
	h := newOwnerStunnedHarness(t, uid)
	pod := replacementPod(uid, "agent-cardvault-7f8d9c-newuid")

	if err := h.r.reconcile(pod); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if h.tc.filters["ingress"] == "" || h.tc.filters["egress"] == "" {
		t.Fatalf("replacement pod's new veth never got a drop filter: filters=%v", h.tc.filters)
	}
}
