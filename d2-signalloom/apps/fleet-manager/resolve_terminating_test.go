package main

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// Live, 2026-10-03: right after /recover replaced kusari, the frozen
// predecessor took ~40 s to terminate, and every stun of the replacement
// failed "selector signalloom.ai/agent-name=kusari-agent matched 2 pods,
// target is ambiguous" (fleet-manager 500, four retries). A pod being
// deleted is not the agent's instance any more: the one live pod is.

func replicaPod(name string, deleting bool) *corev1.Pod {
	p := agentPod(name, StateStunned, nil)
	p.Labels[AgentNameLabel] = "kusari-agent"
	if deleting {
		now := metav1.Now()
		p.DeletionTimestamp = &now
		p.Finalizers = []string{"test/keep"} // a deleting object needs one to exist
	}
	return p
}

func resolveKusari(t *testing.T, objs ...runtime.Object) (*corev1.Pod, error) {
	t.Helper()
	c, _ := newTestK8sClient(objs...)
	return c.resolvePod(context.Background(), testNamespace, "agent-kusari-agent")
}

func TestResolvePodPrefersTheLivePodOverATerminatingPredecessor(t *testing.T) {
	pod, err := resolveKusari(t,
		replicaPod("agent-kusari-5685ff664b-f9zxz", true),
		replicaPod("agent-kusari-5685ff664b-khg88", false))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if pod.Name != "agent-kusari-5685ff664b-khg88" {
		t.Fatalf("resolved %s, want the live replacement", pod.Name)
	}
}

func TestResolvePodStillRefusesTwoLivePods(t *testing.T) {
	_, err := resolveKusari(t,
		replicaPod("agent-kusari-5685ff664b-aaaaa", false),
		replicaPod("agent-kusari-5685ff664b-bbbbb", false))
	if err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("err = %v, want ambiguous", err)
	}
}

func TestResolvePodStillFindsALoneTerminatingPod(t *testing.T) {
	pod, err := resolveKusari(t, replicaPod("agent-kusari-5685ff664b-f9zxz", true))
	if err != nil || pod.Name != "agent-kusari-5685ff664b-f9zxz" {
		t.Fatalf("pod %v err %v: the only pod is still the agent's", pod, err)
	}
}

func TestResolvePodStillRefusesTwoTerminatingPods(t *testing.T) {
	_, err := resolveKusari(t,
		replicaPod("agent-kusari-5685ff664b-aaaaa", true),
		replicaPod("agent-kusari-5685ff664b-bbbbb", true))
	if err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("err = %v, want ambiguous", err)
	}
}
