// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/filter"
	corev1 "k8s.io/api/core/v1"
)

// Live, 2026-10-03: ebpf_detection reported evasive_syscall_burst (>=20
// execve/s) on the sentinel's OWN pod stun-sentinel-wb6dt: its own tc execs.
// The observation was built and posted before any exclusion applied.
//
// A sentinel only sees its own node's kernel, so the only sentinel pod it can
// observe is itself, and it knows itself by the downward API (POD_UID,
// POD_NAME/POD_NAMESPACE), which the kubelet sets and no tenant can forge.
// Labels and ServiceAccount names are chosen by whoever creates the pod, so
// they never exempt a pod from detection.

func sentinelSelf() filter.Self {
	return filter.Self{PodName: "stun-sentinel-wb6dt", Namespace: "fe-signalloom-agents", PodUID: pipelinePodUID}
}

// theSentinelsPod is the DaemonSet pod as the informer sees it.
func theSentinelsPod() *corev1.Pod {
	pod := agentPod("fe-signalloom-agents")
	pod.Name = "stun-sentinel-wb6dt"
	pod.Labels = map[string]string{
		"app.kubernetes.io/name":  "stun-sentinel",
		"signalloom.ai/agent":     "true",
		"signalloom.ai/role":      "sentinel",
		"signalloom.ai/framework": "custom",
	}
	pod.Spec.ServiceAccountName = "stun-sentinel"
	return pod
}

func burst(t *testing.T, m *SentinelProbeManager, n int) (reported int) {
	t.Helper()
	rec := rawRecord(ebpf.EventExecve, 1001, "/usr/sbin/tc")
	for i := 0; i < n; i++ {
		if _, ok := m.handleRecord(rec); ok {
			reported++
		}
	}
	return reported
}

func TestTheSentinelsOwnExecBurstIsNeverReported(t *testing.T) {
	for name, self := range map[string]filter.Self{
		"by-uid":  {PodUID: pipelinePodUID},
		"by-name": {PodName: "stun-sentinel-wb6dt", Namespace: "fe-signalloom-agents"},
	} {
		t.Run(name, func(t *testing.T) {
			m, calls := pipelineWithOpts(t, theSentinelsPod(), nil,
				WithEvasiveBurstThreshold(3, time.Second), WithSelf(self))
			if got := burst(t, m, 9); got != 0 {
				t.Fatalf("reported %d evasive bursts on the sentinel's own pod", got)
			}
			if *calls != 0 {
				t.Fatalf("freeze calls = %d on the sentinel's own pod", *calls)
			}
			if m.Stats().SelfExcluded == 0 {
				t.Fatal("self_excluded = 0: the drop is invisible")
			}
		})
	}
}

func TestTheSentinelsOwnSensitiveOpenIsNeverReported(t *testing.T) {
	m, calls := pipelineWithOpts(t, theSentinelsPod(), nil, WithSelf(sentinelSelf()))
	if obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow")); ok {
		t.Fatalf("reported %s on the sentinel's own pod: %+v", obs.Syscall, obs)
	}
	if *calls != 0 || m.Stats().SelfExcluded != 1 {
		t.Fatalf("calls=%d self_excluded=%d", *calls, m.Stats().SelfExcluded)
	}
}

// A tenant pod that dresses as the sentinel is still detected.
func TestAPodForgingTheSentinelsLabelsIsStillDetected(t *testing.T) {
	forged := theSentinelsPod()
	forged.Name = "agent-kusari-5685ff664b-mj26p"
	m, _ := pipelineWithOpts(t, forged, nil,
		WithEvasiveBurstThreshold(3, time.Second),
		WithSelf(filter.Self{PodName: "stun-sentinel-wb6dt", Namespace: "fe-signalloom-agents", PodUID: "11111111-2222-3333-4444-555555555555"}))
	if got := burst(t, m, 3); got != 1 {
		t.Fatalf("reported %d bursts for a pod that only claims to be the sentinel; want 1", got)
	}
	if m.Stats().SelfExcluded != 0 {
		t.Fatalf("self_excluded = %d for a forged pod", m.Stats().SelfExcluded)
	}
}

// Without the option the identity comes from the downward API env, as
// deployed.
func TestTheSelfIdentityDefaultsToTheDownwardAPI(t *testing.T) {
	t.Setenv("POD_UID", pipelinePodUID)
	t.Setenv("POD_NAME", "")
	t.Setenv("POD_NAMESPACE", "")
	m, _ := pipelineWithOpts(t, theSentinelsPod(), nil, WithEvasiveBurstThreshold(3, time.Second))
	if got := burst(t, m, 6); got != 0 {
		t.Fatalf("reported %d bursts with POD_UID naming this pod", got)
	}
}
