// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// The probe stamps each event with the KERNEL root-namespace PID
// (bpf_get_current_pid_tgid). On kind the node is itself a container, so that
// PID does not exist in the sentinel's /proc even with hostPID. Measured live
// 2026-10-01: kusari-agent was 2565765 to the kernel, 860672 on the kind node
// and 1 in its container, and the correlator mapped 0 of 946 sensitive opens
// to a pod. The event also carries the cgroup-v2 inode, which is the same in
// every namespace, so the pod is resolved from that first.

// kindCgroupTree builds the systemd-driver hierarchy a kind node uses and
// returns the root and the inode of the pod's container scope.
func kindCgroupTree(t *testing.T, podUID string) (string, uint64) {
	t.Helper()
	root := t.TempDir()
	u := strings.ReplaceAll(podUID, "-", "_")
	scope := filepath.Join(root, "kubelet.slice", "kubelet-kubepods.slice",
		"kubelet-kubepods-burstable.slice", "kubelet-kubepods-burstable-pod"+u+".slice",
		"cri-containerd-715d69b888c61368.scope")
	if err := os.MkdirAll(scope, 0o755); err != nil {
		t.Fatal(err)
	}
	var st syscall.Stat_t
	if err := syscall.Stat(scope, &st); err != nil {
		t.Fatal(err)
	}
	return root, st.Ino
}

// cgroupRecord is rawRecord with the cgroup id set and a PID that does not
// exist in the sentinel's /proc, which is exactly what kind delivers.
func cgroupRecord(cgroupID uint64, filename string) []byte {
	b := rawRecord(ebpf.EventOpenat, 2565765, filename)
	binary.NativeEndian.PutUint64(b[8:], cgroupID)
	return b
}

func TestHandleRecordResolvesPodByCgroupIDWhenThePIDIsInAnotherNamespace(t *testing.T) {
	root, ino := kindCgroupTree(t, pipelinePodUID)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)

	obs, ok := m.handleRecord(cgroupRecord(ino, "/etc/passwd"))
	if !ok || obs.PodName != "agent-1" {
		t.Fatalf("ok=%v obs=%+v: a sensitive open must resolve to its pod by cgroup id", ok, obs)
	}
	if *calls != 1 {
		t.Fatalf("freeze calls = %d, want 1", *calls)
	}
	if s := m.Stats(); s.Matched != 1 || s.NoPod != 0 {
		t.Fatalf("stats = %+v", s)
	}
}

func TestHandleRecordUnknownCgroupIDAndUnknownPIDIsNoPod(t *testing.T) {
	root, _ := kindCgroupTree(t, pipelinePodUID)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)

	if _, ok := m.handleRecord(cgroupRecord(999999999, "/etc/passwd")); ok {
		t.Fatal("an inode that is in no pod's cgroup must not be attributed to a pod")
	}
	if *calls != 0 {
		t.Fatalf("nothing may be frozen, got %d freezes", *calls)
	}
	if s := m.Stats(); s.NoPod != 1 {
		t.Fatalf("stats = %+v", s)
	}
}

func TestCgroupLookupIgnoresAPodSliceWhosePodIsNotInTheIndex(t *testing.T) {
	// An inode that maps to a real pod slice, but the pod is unknown to the
	// informer (another namespace, or already deleted), must not freeze.
	root, ino := kindCgroupTree(t, "11111111-2222-3333-4444-555555555555")
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)

	if _, ok := m.handleRecord(cgroupRecord(ino, "/etc/passwd")); ok || *calls != 0 {
		t.Fatalf("ok=%v freezes=%d: an unindexed pod must not be resolved or frozen", ok, *calls)
	}
}
