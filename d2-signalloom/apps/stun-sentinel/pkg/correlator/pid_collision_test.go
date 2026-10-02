// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// Independent review (2026-10-02, H1): on kind the probe's root-namespace PID
// can name a DIFFERENT process in the node's namespace (node PIDs reach 3.9M of
// a 4.2M pid_max). When the cgroup-inode lookup missed, the correlator fell
// back to /proc/<pid>/cgroup and froze whatever pod that unrelated process was
// in. With a cgroup root configured the inode is authoritative.

func hostInode(t *testing.T, root string) uint64 {
	t.Helper()
	dir := filepath.Join(root, "system.slice", "kubelet.service")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var st syscall.Stat_t
	if err := syscall.Stat(dir, &st); err != nil {
		t.Fatal(err)
	}
	return st.Ino
}

func TestHostEventWithCollidingPIDNeverFreezesAPod(t *testing.T) {
	root, _ := kindCgroupTree(t, pipelinePodUID)
	host := hostInode(t, root)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil) // /proc/1001/cgroup names the agent pod
	WithCgroupRoot(root)(m)

	rec := cgroupRecord(host, "/etc/passwd")
	rec = withPID(rec, 1001)
	if obs, ok := m.handleRecord(rec); ok || *calls != 0 {
		t.Fatalf("ok=%v pod=%q freezes=%d: an event from a host cgroup must not be attributed to the pod a colliding PID happens to name",
			ok, obs.PodName, *calls)
	}
}

func TestRelativePathIsResolvedOnlyWhenThePIDIsInTheEventsCgroup(t *testing.T) {
	root, podIno := kindCgroupTree(t, pipelinePodUID)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)
	// pid 1001's /proc entry claims the agent pod, but in a cgroupfs layout
	// that does not exist under root: it cannot be proven to be this event's
	// process, so its cwd must not be trusted to make "passwd" sensitive.
	if err := os.Symlink("/etc", filepath.Join(m.procRoot, "1001", "cwd")); err != nil {
		t.Fatal(err)
	}
	rec := withPID(cgroupRecord(podIno, "passwd"), 1001)
	if _, ok := m.handleRecord(rec); ok || *calls != 0 {
		t.Fatalf("ok=%v freezes=%d: a relative path resolved through an unverified PID's cwd", ok, *calls)
	}
}

func TestNewPodIsResolvedEvenRightAfterHostNoiseTriggeredAWalk(t *testing.T) {
	root := t.TempDir()
	host := hostInode(t, root)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)

	// Host noise first: a miss that walks the tree and finds nothing.
	m.handleRecord(cgroupRecord(host, "/etc/passwd"))
	// The agent pod's cgroup appears immediately afterwards.
	podRoot, podIno := kindCgroupTree(t, pipelinePodUID)
	if err := os.Rename(filepath.Join(podRoot, "kubelet.slice"), filepath.Join(root, "kubelet.slice")); err != nil {
		t.Fatal(err)
	}
	if _, ok := m.handleRecord(cgroupRecord(podIno, "/etc/passwd")); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: a new pod's first sensitive open was dropped because host noise had just spent the re-walk", ok, *calls)
	}
}

func TestRepeatedHostNoiseDoesNotReWalkTheTree(t *testing.T) {
	root := t.TempDir()
	host := hostInode(t, root)
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)
	for i := 0; i < 50; i++ {
		m.handleRecord(cgroupRecord(host, "/etc/passwd"))
	}
	if w := m.cgroupWalks.Load(); w != 1 {
		t.Fatalf("walks = %d, want 1: a known non-pod cgroup must be remembered as a miss", w)
	}
}

func TestRelativePathResolvesWhenThePIDIsProvenInTheEventsCgroup(t *testing.T) {
	root, podIno := kindCgroupTree(t, pipelinePodUID)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)
	// Exactly what a kind node shows through a cgroup namespace.
	line := "0::/../../kubelet-kubepods-burstable-pod" + strings.ReplaceAll(pipelinePodUID, "-", "_") +
		".slice/cri-containerd-715d69b888c61368.scope\n"
	if err := os.WriteFile(filepath.Join(m.procRoot, "1001", "cgroup"), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc", filepath.Join(m.procRoot, "1001", "cwd")); err != nil {
		t.Fatal(err)
	}
	if _, ok := m.handleRecord(withPID(cgroupRecord(podIno, "passwd"), 1001)); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: a relative open by a process proven to be in the pod's cgroup must be detected", ok, *calls)
	}
}
