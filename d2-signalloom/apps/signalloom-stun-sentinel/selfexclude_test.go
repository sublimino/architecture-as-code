package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
)

// The DaemonSet pod template carries signalloom.ai/agent=true, the informer's
// own selector, so every sentinel pod is in the watch set. A stun label on a
// sentinel pod must never make it freeze itself (W6 three-node lab).
func sentinelPod(name string, labels map[string]string, sa string) *corev1.Pod {
	pod := kernelTestPod(labels, nil)
	pod.Name = name
	pod.Spec.ServiceAccountName = sa
	return pod
}

func TestSentinelNeverReconcilesItsOwnPods(t *testing.T) {
	cases := map[string]*corev1.Pod{
		"by-name-label": sentinelPod("stun-sentinel-abcde", map[string]string{
			"app.kubernetes.io/name": "stun-sentinel", "signalloom.ai/agent": "true", labelStunnedAI: stunnedValue,
		}, "default"),
		"by-service-account": sentinelPod("stun-sentinel-fghij", map[string]string{
			"signalloom.ai/agent": "true", labelStunnedIO: "true",
		}, sentinelServiceAccount),
	}
	for name, pod := range cases {
		t.Run(name, func(t *testing.T) {
			h := newKernelHarness(t, "populated 1\nfrozen 0\n")
			for i := 0; i < 2; i++ {
				if err := h.reconciler.reconcile(pod); err != nil {
					t.Fatalf("reconcile %d: %v, want a successful skip", i, err)
				}
			}
			if b, _ := os.ReadFile(filepath.Join(h.cgroup, "cgroup.freeze")); strings.TrimSpace(string(b)) != "0" {
				t.Fatalf("sentinel froze its own pod: cgroup.freeze=%q", b)
			}
			if len(h.api.patches) != 0 {
				t.Fatalf("patched own pod: %+v", h.api.patches)
			}
			if got := h.events(t, "self_pod_skipped"); len(got) != 1 {
				t.Fatalf("self_pod_skipped events = %d, want exactly one across two reconciles", len(got))
			}
			if got := h.events(t, "stun"); len(got) != 0 {
				t.Fatalf("stun event for own pod: %+v", got)
			}
		})
	}
}

func TestAgentPodIsNotMistakenForSentinel(t *testing.T) {
	pod := sentinelPod("agent-cardvault-x", map[string]string{"app.kubernetes.io/name": "agent-cardvault"}, "agent-cardvault")
	if isSentinelPod(pod) {
		t.Fatal("agent pod classified as a sentinel pod")
	}
}
