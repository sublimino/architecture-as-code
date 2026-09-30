// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package filter

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func pod(ns, name, uid string, phase corev1.PodPhase, labels map[string]string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name, UID: types.UID(uid), Labels: labels},
		Status:     corev1.PodStatus{Phase: phase},
	}
}

var testSelf = Self{
	PodName:    "stun-sentinel-x7k2p",
	Namespace:  "fe-signalloom-agents",
	PodUID:     "5f0c3a1e-0000-4000-8000-00000000beef",
	PID:        31337,
	CgroupPath: "/kubepods.slice/kubepods-pod5f0c3a1e_0000_4000_8000_00000000beef.slice/cri-containerd-abc.scope",
}

func newTestFilter(lines *[]string) *Filter {
	return New(testSelf, WithAuditLog(func(l string) { *lines = append(*lines, l) }))
}

func TestSelfPodExclusion(t *testing.T) {
	var audit []string
	f := newTestFilter(&audit)

	t.Run("own UID", func(t *testing.T) {
		p := pod("fe-signalloom-agents", "renamed", testSelf.PodUID, corev1.PodRunning, nil)
		if d := f.Evaluate(p); !d.Excluded || d.Reason != ReasonSelfPod {
			t.Fatalf("decision = %+v, want self-pod", d)
		}
	})
	t.Run("own name and namespace", func(t *testing.T) {
		p := pod("fe-signalloom-agents", testSelf.PodName, "other-uid", corev1.PodRunning, nil)
		if d := f.Evaluate(p); !d.Excluded || d.Reason != ReasonSelfPod {
			t.Fatalf("decision = %+v, want self-pod", d)
		}
	})
	t.Run("same name other namespace is not self", func(t *testing.T) {
		p := pod("tenant-demo", testSelf.PodName, "other-uid", corev1.PodRunning, nil)
		if d := f.Evaluate(p); d.Excluded {
			t.Fatalf("decision = %+v, a same-named agent elsewhere must remain containable", d)
		}
	})
	t.Run("peer sentinel on another node", func(t *testing.T) {
		p := pod("fe-signalloom-agents", "stun-sentinel-q9zz1", "peer-uid", corev1.PodRunning,
			map[string]string{SentinelNameLabel: SentinelName})
		if d := f.Evaluate(p); !d.Excluded || d.Reason != ReasonSentinelPod {
			t.Fatalf("decision = %+v, want sentinel-pod", d)
		}
	})
	t.Run("own PID inside target cgroup", func(t *testing.T) {
		d := f.ContainsSelf("/sys/fs/cgroup", "/sys/fs/cgroup/kubepods.slice/some-pod.slice", []int{1, 99, testSelf.PID})
		if !d.Excluded || d.Reason != ReasonSelfProcess {
			t.Fatalf("decision = %+v, want self-process", d)
		}
	})
	t.Run("own host cgroup beneath target", func(t *testing.T) {
		target := "/sys/fs/cgroup/kubepods.slice/kubepods-pod5f0c3a1e_0000_4000_8000_00000000beef.slice"
		d := f.ContainsSelf("/sys/fs/cgroup", target, nil)
		if !d.Excluded || d.Reason != ReasonSelfCgroup {
			t.Fatalf("decision = %+v, want self-cgroup", d)
		}
	})
	t.Run("sibling cgroup sharing a prefix is not self", func(t *testing.T) {
		// kubepods-pod5f0c... must not match kubepods-pod5f0 by string prefix.
		d := f.ContainsSelf("/sys/fs/cgroup", "/sys/fs/cgroup/kubepods.slice/kubepods-pod5f0", []int{4, 5})
		if d.Excluded {
			t.Fatalf("decision = %+v, prefix match without a path boundary", d)
		}
	})
	t.Run("private cgroupns falls back to PID only", func(t *testing.T) {
		g := New(Self{PID: 7, CgroupPath: "/"}, WithAuditLog(func(string) {}))
		if d := g.ContainsSelf("/sys/fs/cgroup", "/sys/fs/cgroup", nil); d.Excluded {
			t.Fatalf("root cgroup \"/\" must not make every target look like self: %+v", d)
		}
		if d := g.ContainsSelf("/sys/fs/cgroup", "/x", []int{7}); !d.Excluded {
			t.Fatal("PID match must still exclude")
		}
	})
	t.Run("ordinary agent pod is containable", func(t *testing.T) {
		p := pod("fe-signalloom-agents", "agent-kusari-agent-6c9d", "agent-uid", corev1.PodRunning,
			map[string]string{"app.kubernetes.io/name": "kusari-agent"})
		if err := f.CheckFreezable(p); err != nil {
			t.Fatalf("CheckFreezable: %v", err)
		}
		if d := f.ContainsSelf("/sys/fs/cgroup", "/sys/fs/cgroup/kubepods.slice/kubepods-podagent.slice", []int{4242}); d.Excluded {
			t.Fatalf("agent cgroup wrongly treated as self: %+v", d)
		}
	})
}

func TestInfrastructureNamespaceExclusion(t *testing.T) {
	var audit []string
	f := newTestFilter(&audit)
	for _, ns := range []string{"kube-system", "spire", "flux-system", "cert-manager", "envoy-gateway-system", "inf-signalloom"} {
		p := pod(ns, "victim", "uid-"+ns, corev1.PodRunning, nil)
		if !f.IsExcludedPod(p) {
			t.Errorf("namespace %s must be excluded", ns)
		}
		if err := f.CheckFreezable(p); !errors.Is(err, ErrExcluded) {
			t.Errorf("%s: CheckFreezable = %v, want ErrExcluded", ns, err)
		}
	}
	if got := len(audit); got != 12 {
		t.Errorf("audit lines = %d, want 12 (one per evaluation, IsExcludedPod and CheckFreezable)", got)
	}
	if !strings.Contains(audit[0], "audit: stun-sentinel skip pod=kube-system/victim") ||
		!strings.Contains(audit[0], "reason=infrastructure-namespace") {
		t.Errorf("audit line lacks pod and reason: %q", audit[0])
	}
	for _, ns := range []string{"fe-signalloom-agents", "tenant-demo", "eap-4b53ab6b", "kube-systemx", ""} {
		if f.IsExcludedPod(pod(ns, "a", "u", corev1.PodRunning, nil)) {
			t.Errorf("namespace %q must NOT be excluded (exact match only)", ns)
		}
	}
}

func TestExtraNamespacesCanOnlyWiden(t *testing.T) {
	f := New(testSelf, WithExtraNamespaces("observability", " "), WithAuditLog(func(string) {}))
	got := strings.Join(f.ExcludedNamespaces(), ",")
	for _, want := range append(DefaultExcludedNamespaces, "observability") {
		if !strings.Contains(got, want) {
			t.Errorf("effective set %q lacks %q", got, want)
		}
	}
	if strings.Contains(got, ",,") {
		t.Errorf("blank namespace added: %q", got)
	}
}

func TestPhaseGate(t *testing.T) {
	var audit []string
	f := newTestFilter(&audit)
	for _, phase := range []corev1.PodPhase{corev1.PodPending, corev1.PodSucceeded, corev1.PodFailed, corev1.PodUnknown, ""} {
		err := f.CheckFreezable(pod("tenant-demo", "agent", "u", phase, nil))
		if !errors.Is(err, ErrNotRunning) {
			t.Errorf("phase %q: err = %v, want ErrNotRunning", phase, err)
		}
	}
	if len(audit) != 5 || !strings.Contains(audit[0], "reason=not-running") {
		t.Errorf("phase refusals not audited: %v", audit)
	}
}

func TestNilPodFailsClosed(t *testing.T) {
	var audit []string
	f := newTestFilter(&audit)
	if !f.IsExcludedPod(nil) {
		t.Fatal("nil pod must be excluded")
	}
	if err := f.CheckFreezable(nil); !errors.Is(err, ErrExcluded) {
		t.Fatalf("CheckFreezable(nil) = %v", err)
	}
}

func TestSelfFromEnvReadsDownwardAPIAndCgroup(t *testing.T) {
	t.Setenv("POD_NAME", "stun-sentinel-abc")
	t.Setenv("POD_NAMESPACE", "fe-signalloom-agents")
	t.Setenv("POD_UID", "uid-1")
	s := SelfFromEnv()
	if s.PodName != "stun-sentinel-abc" || s.Namespace != "fe-signalloom-agents" || s.PodUID != "uid-1" {
		t.Errorf("downward API not read: %+v", s)
	}
	if s.PID != os.Getpid() {
		t.Errorf("PID = %d, want os.Getpid() %d", s.PID, os.Getpid())
	}

	cg := filepath.Join(t.TempDir(), "cgroup")
	if err := os.WriteFile(cg, []byte("1:name=systemd:/x\n0::/kubepods.slice/pod-a.slice/cri-1.scope\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := readOwnCgroup(cg); got != "/kubepods.slice/pod-a.slice/cri-1.scope" {
		t.Errorf("readOwnCgroup = %q", got)
	}
	if got := readOwnCgroup(filepath.Join(t.TempDir(), "missing")); got != "" {
		t.Errorf("missing file = %q, want empty", got)
	}
}
