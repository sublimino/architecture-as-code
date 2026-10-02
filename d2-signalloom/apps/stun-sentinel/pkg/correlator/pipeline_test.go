// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/cache"
)

const pipelinePodUID = "771fb437-10ec-47dc-89a0-538e1fc16d3f"

// rawRecord lays out a syscall_event_t by the offsets pinned in pkg/ebpf
// (TestSyscallEventLayoutMatchesBTF guards them against the compiled probe).
func rawRecord(typ ebpf.EventType, pid uint32, filename string) []byte {
	b := make([]byte, ebpf.SyscallEventSize)
	binary.NativeEndian.PutUint32(b[16:], pid)
	binary.NativeEndian.PutUint32(b[20:], pid)
	b[28] = byte(typ)
	copy(b[56:72], "agent")
	copy(b[72:72+255], filename)
	return b
}

// pipeline wires a manager to a temp /proc holding one process (pid 1001)
// whose cgroup belongs to pod, and counts freeze attempts.
func pipeline(t *testing.T, pod *corev1.Pod, freezeErr error) (*SentinelProbeManager, *int32) {
	t.Helper()
	proc := t.TempDir()
	dir := filepath.Join(proc, "1001")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	cg := "0::/kubepods/burstable/pod" + pipelinePodUID + "/e3b0c44298fc\n"
	if err := os.WriteFile(filepath.Join(dir, "cgroup"), []byte(cg), 0o644); err != nil {
		t.Fatal(err)
	}
	var calls int32
	fm := NewMockFreezeManager(func(*corev1.Pod) error { atomic.AddInt32(&calls, 1); return freezeErr })
	inf := NewMockSharedIndexInformer()
	m := NewSentinelProbeManager(inf, "", fm, WithProcRoot(proc))
	if pod != nil {
		inf.InjectPod(pod)
	}
	return m, &calls
}

func agentPod(ns string) *corev1.Pod {
	return CreateTestPod(ns, "agent-1", pipelinePodUID, "agent-1", "kusari")
}

func TestHandleRecordFreezesRunningAgentOnSensitiveOpen(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
	if !ok || *calls != 1 {
		t.Fatalf("ok=%v freeze calls=%d, want an observation and exactly one freeze", ok, *calls)
	}
	if obs.DirectReaction != ReactionCgroupFrozen || obs.Target != "/etc/shadow" || obs.PodName != "agent-1" {
		t.Fatalf("obs = %+v", obs)
	}
}

func TestHandleRecordDuplicateEventsEachReportTheirOwnReaction(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	rec := rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd")
	for i := 0; i < 3; i++ {
		if obs, ok := m.handleRecord(rec); !ok || obs.DirectReaction != ReactionCgroupFrozen {
			t.Fatalf("event %d: ok=%v reaction=%q", i, ok, obs.DirectReaction)
		}
	}
	if *calls != 3 {
		t.Fatalf("freeze calls = %d, want 3 (freeze is idempotent at the cgroup, not skipped)", *calls)
	}
}

func TestHandleRecordDropsMalformedRecords(t *testing.T) {
	legacy := make([]byte, 285) // pre-SLDC {pid,tgid,uid,type,comm,filename} layout
	binary.LittleEndian.PutUint32(legacy[0:], 1001)
	legacy[12] = 1
	copy(legacy[29:], "/etc/passwd")
	unknown := rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd")
	unknown[28] = 9
	for name, rec := range map[string][]byte{"legacy-285-bytes": legacy, "unknown-type": unknown, "empty": nil} {
		m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
		if _, ok := m.handleRecord(rec); ok || *calls != 0 {
			t.Errorf("%s: ok=%v freeze calls=%d, want dropped with no freeze", name, ok, *calls)
		}
	}
}

func TestHandleRecordIgnoresBenignAndUnknownProcesses(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/hosts")); ok {
		t.Error("benign path produced an observation")
	}
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 4040, "/etc/shadow")); ok {
		t.Error("process with no /proc entry produced an observation")
	}
	if *calls != 0 {
		t.Fatalf("freeze calls = %d", *calls)
	}
}

func TestHandleRecordRefusesFreezeOutsidePolicy(t *testing.T) {
	notAgent := agentPod("tenant-kusari")
	notAgent.Labels = map[string]string{"app": "web"}
	pending := agentPod("tenant-kusari")
	pending.Status.Phase = corev1.PodPending
	sentinel := agentPod("tenant-kusari")
	sentinel.Labels["app.kubernetes.io/name"] = "stun-sentinel"
	cases := map[string]*corev1.Pod{
		"kube-system":    agentPod("kube-system"),
		"inf-signalloom": agentPod("inf-signalloom"),
		"spire":          agentPod("spire"),
		"pending":        pending,
		"peer-sentinel":  sentinel,
		"not-an-agent":   notAgent,
	}
	for name, pod := range cases {
		m, calls := pipeline(t, pod, nil)
		obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
		if !ok {
			t.Errorf("%s: observation dropped; refused freezes must still be reported", name)
		}
		if *calls != 0 || obs.DirectReaction != ReactionNone {
			t.Errorf("%s: freeze calls=%d reaction=%q, want refused", name, *calls, obs.DirectReaction)
		}
	}
}

func TestHandleRecordFreezeFailureReportsNoReaction(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), errors.New("cgroup gone"))
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow"))
	if !ok || *calls != 1 || obs.DirectReaction != ReactionNone {
		t.Fatalf("ok=%v calls=%d reaction=%q, want attempted and reported as none", ok, *calls, obs.DirectReaction)
	}
}

func TestSensitivePathMatchesWholeComponentsAfterCleaning(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil)
	for _, p := range []string{
		"/etc/passwd", "/etc/passwd/", "//etc/passwd", "/etc/./passwd", "/etc//shadow",
		"/etc/../etc/shadow", "/etc/passwd/../shadow", "/tmp/../../etc/passwd",
		"/root/.ssh", "/root/.ssh/id_rsa",
		"/var/run/secrets/kubernetes.io/serviceaccount/token",
		"/run/secrets/kubernetes.io/serviceaccount/token", // /var/run -> /run
	} {
		if !m.IsSensitivePath(p) {
			t.Errorf("IsSensitivePath(%q) = false, want true", p)
		}
	}
	for _, p := range []string{
		"", "/", "/etc", "/etc/pass", "/etc/passwdX", "/etc/passwd-", "/etc/shadowed",
		"/root/.sshrc", "/var/run/secrets/kubernetes.io/serviceaccountX/token",
		"/etc/passwd/../hosts", "etc/passwd", "/ETC/PASSWD",
	} {
		if m.IsSensitivePath(p) {
			t.Errorf("IsSensitivePath(%q) = true, want false", p)
		}
	}
}

func TestSensitiveTargetResolvesRelativePathsAgainstProcessCwd(t *testing.T) {
	proc := t.TempDir()
	for pid, cwd := range map[int]string{7: "/etc", 8: "/tmp/work"} {
		dir := filepath.Join(proc, strconv.Itoa(pid))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(cwd, filepath.Join(dir, "cwd")); err != nil {
			t.Fatal(err)
		}
	}
	m := NewSentinelProbeManager(nil, "", nil, WithProcRoot(proc))
	cases := []struct {
		pid       uint32
		name, abs string
		sensitive bool
	}{
		{7, "passwd", "/etc/passwd", true},
		{7, "./shadow", "/etc/shadow", true},
		{8, "../../etc/shadow", "/etc/shadow", true},
		{8, "passwd", "/tmp/work/passwd", false},
		{9, "passwd", "", false}, // cwd unreadable: the process is gone, nothing left to freeze
	}
	for _, c := range cases {
		abs, ok := m.sensitiveTarget(c.name, c.pid, 0)
		if ok != c.sensitive || (c.abs != "" && abs != c.abs) {
			t.Errorf("pid %d %q: got (%q, %v), want (%q, %v)", c.pid, c.name, abs, ok, c.abs, c.sensitive)
		}
	}
}

func TestDeletedFinalStateUnknownEvictsPod(t *testing.T) {
	pod := agentPod("tenant-kusari")
	m, _ := pipeline(t, pod, nil)
	inf := m.informer.(*MockSharedIndexInformer)
	_ = inf.store.Delete(pod)
	for _, h := range inf.handlers {
		h.OnDelete(cache.DeletedFinalStateUnknown{Key: "tenant-kusari/agent-1", Obj: pod})
	}
	if got := m.lookupPodByPID(1001); got != nil {
		t.Fatalf("pod deleted via tombstone still resolves: %s/%s", got.Namespace, got.Name)
	}
}
