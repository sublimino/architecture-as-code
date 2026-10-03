// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strconv"
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

// Live, 2026-10-03: runtime_lookups stayed 0 after the exemption shipped, and
// a new agent-cardvault pod was frozen 1 s after creation by runc opening its
// ServiceAccount mount destination. On kind the probe's PID is the host
// kernel's (pid:[4026531836]) while the sentinel's /proc is the node's
// (pid:[4026534203]), so /proc/<event pid>/exe named no process. The
// runtime is now recognised by cgroup membership: the event's cgroup inode
// is the same in every namespace, and its cgroup.procs lists PIDs in the
// sentinel's own namespace. When every process in that cgroup runs the
// node's runc, no workload code has run there yet.

// kindRuntimeFixture lays out the node runc, a container scope holding the
// given processes (pid -> exe), and returns the manager and scope inode.
func kindRuntimeFixture(t *testing.T, procs map[int]string) (*SentinelProbeManager, *int32, uint64, string) {
	t.Helper()
	root, ino := kindCgroupTree(t, pipelinePodUID)
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	WithCgroupRoot(root)(m)
	nodeRunc := filepath.Join(m.procRoot, "1", "root", "usr", "local", "sbin", "runc")
	if err := os.MkdirAll(filepath.Dir(nodeRunc), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(nodeRunc, []byte("runc 1.4.2 ELF stand-in"), 0o755); err != nil {
		t.Fatal(err)
	}
	var scope string
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.IsDir() && filepath.Ext(p) == ".scope" {
			scope = p
		}
		return nil
	})
	var list string
	for pid, exe := range procs {
		if exe == "runc" {
			exe = nodeRunc
		}
		dir := filepath.Join(m.procRoot, strconv.Itoa(pid))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(exe, filepath.Join(dir, "exe")); err != nil {
			t.Fatal(err)
		}
		list += strconv.Itoa(pid) + "\n"
	}
	if err := os.WriteFile(filepath.Join(scope, "cgroup.procs"), []byte(list), 0o644); err != nil {
		t.Fatal(err)
	}
	return m, calls, ino, nodeRunc
}

func TestOnKindRuncAloneInItsContainerIsTheRuntime(t *testing.T) {
	for _, target := range []string{"/etc/passwd", "/var/run/secrets/kubernetes.io/serviceaccount", "/run/secrets/kubernetes.io/serviceaccount"} {
		m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610948: "runc"})
		if obs, ok := m.handleRecord(cgroupRecord(ino, target)); ok || *calls != 0 {
			t.Fatalf("%s: reported=%v (%+v) freezes=%d: runc setting up the container froze it", target, ok, obs, *calls)
		}
		if m.Stats().RuntimeLookups != 1 {
			t.Fatalf("%s: runtime_lookups = %d", target, m.Stats().RuntimeLookups)
		}
	}
}

func TestOnKindAWorkloadBesideRuncIsStillDetectedAndFrozen(t *testing.T) {
	agentBin := filepath.Join(t.TempDir(), "cardvault-agent")
	if err := os.WriteFile(agentBin, []byte("runc 1.4.2 ELF stand-in"), 0o755); err != nil { // same size as runc
		t.Fatal(err)
	}
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610948: "runc", 3610999: agentBin})
	if obs, ok := m.handleRecord(cgroupRecord(ino, "/var/run/secrets/kubernetes.io/serviceaccount")); !ok || obs.DirectReaction != ReactionCgroupFrozen || *calls != 1 {
		t.Fatalf("ok=%v reaction=%q freezes=%d: workload code is in the cgroup", ok, obs.DirectReaction, *calls)
	}
}

func TestOnKindAnEmptyCgroupIsNotTheRuntime(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{})
	if _, ok := m.handleRecord(cgroupRecord(ino, "/etc/passwd")); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: nothing proves the runtime, so it is detected", ok, *calls)
	}
}

func TestOnKindRuncReadingShadowIsStillDetected(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610948: "runc"})
	if _, ok := m.handleRecord(cgroupRecord(ino, "/etc/shadow")); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d", ok, *calls)
	}
}

// Live, 2026-10-03 07:18: agent-cardvault-95bf5d9dd-q7vpk was frozen 2 s
// after creation by four opens of its ServiceAccount mount destination, made
// at 07:18:42.279 in the cardvault-agent container's cgroup while the pod was
// still Pending -- runc init mounting the projected volume. The record was
// handled 0.73 s later (correlator_freeze_held at 07:18:43.01); by then runc
// init had exec'd the agent, so cgroup.procs listed only the agent and the
// cgroup-membership check, which reads the state at HANDLING time, refused
// the exemption. The opener's identity has to be taken at EVENT time: the
// probe records the exe inode and size of the process that made the call,
// and a match with the node's runc is the runtime whatever the cgroup holds
// by the time userspace looks.

// withExe stamps the opener's executable identity on a raw record, at the
// offsets pkg/ebpf pins (TestSyscallEventLayoutMatchesBTF).
func withExe(b []byte, ino uint64, size int64) []byte {
	binary.NativeEndian.PutUint64(b[328:], ino)
	binary.NativeEndian.PutUint64(b[336:], uint64(size))
	return b
}

func inoSize(t *testing.T, path string) (uint64, int64) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Sys().(*syscall.Stat_t).Ino, fi.Size()
}

func TestRuncsSetupOpenIsExemptEvenOnceTheEntrypointHasExecd(t *testing.T) {
	agentBin := filepath.Join(t.TempDir(), "cardvault-agent")
	if err := os.WriteFile(agentBin, []byte("cardvault agent ELF"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"/var/run/secrets/kubernetes.io/serviceaccount", "/etc/passwd"} {
		// By handling time the cgroup holds only the agent: the live race.
		m, calls, ino, nodeRunc := kindRuntimeFixture(t, map[int]string{3610999: agentBin})
		rIno, rSize := inoSize(t, nodeRunc)
		if obs, ok := m.handleRecord(withExe(cgroupRecord(ino, target), rIno, rSize)); ok || *calls != 0 {
			t.Fatalf("%s: reported=%v (%+v) freezes=%d: runc's own setup open froze the pod", target, ok, obs, *calls)
		}
		if s := m.Stats(); s.RuntimeLookups != 1 || s.RuntimeLookupsAtEvent != 1 {
			t.Fatalf("%s: runtime_lookups=%d at_event=%d, want 1 and 1", target, s.RuntimeLookups, s.RuntimeLookupsAtEvent)
		}
	}
}

func TestAnOpenWhoseExeIsTheWorkloadIsDetectedAndFrozen(t *testing.T) {
	agentBin := filepath.Join(t.TempDir(), "cardvault-agent")
	if err := os.WriteFile(agentBin, []byte("runc 1.4.2 ELF stand-in"), 0o755); err != nil { // same size as runc
		t.Fatal(err)
	}
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: agentBin})
	aIno, aSize := inoSize(t, agentBin)
	obs, ok := m.handleRecord(withExe(cgroupRecord(ino, "/var/run/secrets/kubernetes.io/serviceaccount"), aIno, aSize))
	if !ok || obs.DirectReaction != ReactionCgroupFrozen || *calls != 1 {
		t.Fatalf("ok=%v reaction=%q freezes=%d: the agent's own open must be detected and frozen", ok, obs.DirectReaction, *calls)
	}
	if s := m.Stats(); s.RuntimeLookups != 0 || s.RuntimeLookupsAtEvent != 0 {
		t.Fatalf("runtime_lookups=%d at_event=%d for a workload open", s.RuntimeLookups, s.RuntimeLookupsAtEvent)
	}
}

// The inode alone is not identity: a different file that happens to share
// the inode number (another filesystem) differs in size.
func TestRuncsInodeWithAnotherSizeIsNotTheRuntime(t *testing.T) {
	m, calls, ino, nodeRunc := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	rIno, rSize := inoSize(t, nodeRunc)
	if _, ok := m.handleRecord(withExe(cgroupRecord(ino, "/etc/passwd"), rIno, rSize+1)); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: same inode, other size is not runc", ok, *calls)
	}
}

// Being runc exempts the setup opens only.
func TestRuncsExeIdentityDoesNotExemptOtherPaths(t *testing.T) {
	m, calls, ino, nodeRunc := kindRuntimeFixture(t, map[int]string{3610948: "runc"})
	rIno, rSize := inoSize(t, nodeRunc)
	if _, ok := m.handleRecord(withExe(cgroupRecord(ino, "/etc/shadow"), rIno, rSize)); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: /etc/shadow by runc must still be detected", ok, *calls)
	}
}

// Without the cgroup root (PID path), the event-time identity decides too.
func TestEventTimeIdentityExemptsOnThePIDPathAfterTheExec(t *testing.T) {
	m, calls := pipeline(t, agentPod("tenant-kusari"), nil)
	agentBin := filepath.Join(t.TempDir(), "kusari-agent")
	if err := os.WriteFile(agentBin, []byte("kusari agent ELF"), 0o755); err != nil {
		t.Fatal(err)
	}
	nodeRunc := runtimeFixture(t, procOf(m), agentBin) // pid 1001 now runs the agent
	rIno, rSize := inoSize(t, nodeRunc)
	if _, ok := m.handleRecord(withExe(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd"), rIno, rSize)); ok || *calls != 0 {
		t.Fatalf("ok=%v freezes=%d: runc's lookup, recorded at event time, froze the pod", ok, *calls)
	}
}
