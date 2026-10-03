// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// Live, 2026-10-03: a replacement kusari pod was frozen before its agent
// ever ran. The container runtime opens the container's /etc/passwd to
// resolve its user: `runc init`, inside the container's cgroup, before it
// execs the entrypoint. The phase gate refused two such opens (Pending) and
// froze the third, made as the container started; the pod could never start.
//
// What separates them is the process, not the phase. Until it execs the
// entrypoint, runc init runs the node's runc binary; runc >= 1.2 runs it
// from a private overlay, which keeps the binary's inode (measured: ino
// 86810274, 15906368 bytes, on and off the overlay). A workload cannot exec
// a file with that inode: the node's runc is not in its root filesystem.

// runtimeFixture lays out a node runc under <proc>/1/root and points pid
// 1001's exe at exe.
func runtimeFixture(t *testing.T, proc string, exe string) (nodeRunc string) {
	t.Helper()
	nodeRunc = filepath.Join(proc, "1", "root", "usr", "local", "sbin", "runc")
	if err := os.MkdirAll(filepath.Dir(nodeRunc), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(nodeRunc, []byte("runc 1.4.2 ELF stand-in"), 0o755); err != nil {
		t.Fatal(err)
	}
	if exe == "" {
		exe = nodeRunc
	}
	if err := os.Symlink(exe, filepath.Join(proc, "1001", "exe")); err != nil {
		t.Fatal(err)
	}
	return nodeRunc
}

func procOf(m *SentinelProbeManager) string { return m.procRoot }

func TestRuncsOwnUserLookupNeitherFreezesNorReports(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	runtimeFixture(t, procOf(m), "")
	for _, target := range []string{"/etc/passwd", "/etc/group"} {
		if obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, target)); ok {
			t.Fatalf("%s by runc init reported as a detection: %+v", target, obs)
		}
	}
	if *calls != 0 {
		t.Fatalf("freeze calls = %d: the runtime's lookup froze the pod", *calls)
	}
	if got := m.Stats().RuntimeLookups; got == 0 {
		t.Fatal("runtime_lookups = 0: the exemption is invisible")
	}
}

func TestTheAgentsOwnOpenIsStillDetectedAndFrozen(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	agentBin := filepath.Join(t.TempDir(), "kusari-agent")
	if err := os.WriteFile(agentBin, []byte("runc 1.4.2 ELF stand-in"), 0o755); err != nil { // same size as the fixture runc
		t.Fatal(err)
	}
	runtimeFixture(t, procOf(m), agentBin)
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd"))
	if !ok || obs.DirectReaction != ReactionCgroupFrozen || *calls != 1 {
		t.Fatalf("ok=%v reaction=%q calls=%d: the agent's open must be detected and frozen", ok, obs.DirectReaction, *calls)
	}
	if m.Stats().RuntimeLookups != 0 {
		t.Fatal("an agent open counted as a runtime lookup")
	}
}

// Shipping runc's bytes in the image does not make a process the runtime.
func TestACopyOfRuncInTheImageIsStillDetected(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	nodeRunc := runtimeFixture(t, procOf(m), filepath.Join(t.TempDir(), "placeholder"))
	copyPath := filepath.Join(t.TempDir(), "runc")
	b, err := os.ReadFile(nodeRunc)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(copyPath, b, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(procOf(m), "1001", "exe")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(copyPath, filepath.Join(procOf(m), "1001", "exe")); err != nil {
		t.Fatal(err)
	}
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd")); !ok || *calls != 1 {
		t.Fatalf("ok=%v calls=%d: a runc copy with its own inode is not the node's runtime", ok, *calls)
	}
}

// The exemption covers the user lookup only: runc opening anything else
// sensitive is still a detection.
func TestRuncOpeningAnythingButTheUserDatabaseIsStillDetected(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	runtimeFixture(t, procOf(m), "")
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/shadow")); !ok || *calls != 1 {
		t.Fatalf("ok=%v calls=%d: /etc/shadow by runc must still be detected", ok, *calls)
	}
}

// No node runc to compare against (an unknown runtime, an unreadable root):
// nothing is exempt, as before.
func TestWithoutANodeRuncNothingIsExempt(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	// The exe is a hard link to runc (same inode), so it stays readable once
	// the node root is gone: only the missing reference decides.
	nodeRunc := runtimeFixture(t, procOf(m), filepath.Join(procOf(m), "runc-link"))
	if err := os.Link(nodeRunc, filepath.Join(procOf(m), "runc-link")); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(procOf(m), "1", "root")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(procOf(m), "1001", "exe")); err != nil {
		t.Fatalf("exe must stay readable: %v", err)
	}
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd")); !ok || *calls != 1 {
		t.Fatalf("ok=%v calls=%d: an unverifiable process must fail closed", ok, *calls)
	}
}

// A process that has already exited (no exe to read) fails closed too.
func TestAnUnreadableExeFailsClosed(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	runtimeFixture(t, procOf(m), filepath.Join(t.TempDir(), "gone"))
	if _, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd")); !ok || *calls != 1 {
		t.Fatalf("ok=%v calls=%d", ok, *calls)
	}
}

type statInfo struct {
	os.FileInfo
	st   syscall.Stat_t
	size int64
}

func (s statInfo) Sys() any    { return &s.st }
func (s statInfo) Size() int64 { return s.size }

func TestSameBinaryNeedsInodeAndSizeNotDevice(t *testing.T) {
	runc := statInfo{st: syscall.Stat_t{Dev: 84, Ino: 86810274}, size: 15906368}
	cases := []struct {
		name string
		exe  statInfo
		want bool
	}{
		{"overlay runc: other device, same inode and size", statInfo{st: syscall.Stat_t{Dev: 5243050, Ino: 86810274}, size: 15906368}, true},
		{"same inode number, different size", statInfo{st: syscall.Stat_t{Dev: 77, Ino: 86810274}, size: 735760}, false},
		{"same size, different inode", statInfo{st: syscall.Stat_t{Dev: 84, Ino: 86155215}, size: 15906368}, false},
	}
	for _, c := range cases {
		if got := sameBinary(c.exe, runc); got != c.want {
			t.Errorf("%s: sameBinary = %v, want %v", c.name, got, c.want)
		}
	}
}
