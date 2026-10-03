// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// DefaultRuntimeBinaries are where a node's runc is looked for, read through
// the node's root as /proc/1/root (the sentinel is hostPID).
var DefaultRuntimeBinaries = []string{
	"/usr/local/sbin/runc",
	"/usr/sbin/runc",
	"/usr/bin/runc",
	"/usr/local/bin/runc",
}

// runtimeSetupOpens are the sensitive paths runc itself opens while setting up
// a container: the user database (to resolve the container's user) and the
// ServiceAccount token's mount destination (to mount the projected volume).
var runtimeSetupOpens = map[string]bool{
	"/etc/passwd": true,
	"/etc/group":  true,
	"/var/run/secrets/kubernetes.io/serviceaccount": true,
	"/run/secrets/kubernetes.io/serviceaccount":     true,
}

// WithRuntimeBinaries overrides DefaultRuntimeBinaries.
func WithRuntimeBinaries(paths ...string) Option {
	return func(m *SentinelProbeManager) {
		m.runtimeBinaries = paths
	}
}

// runtimeUserLookup reports whether an open of target by pid is the
// container runtime resolving the container's user: `runc init`, in the
// container's cgroup, before it execs the entrypoint, so no workload code has
// run. It is keyed on the process, not the pod phase (a restart happens in a
// Running pod): pid's executable must be the node's own runc binary, matched
// by inode and size. runc >= 1.2 executes it from a private overlay that
// keeps the inode, and a workload cannot exec a file with that inode because
// the node's runc is not in its root filesystem; a copy shipped in the image
// has its own. Anything unverifiable (no node runc found, the process gone or
// already exec'd) is not exempt: the open is a detection, as before.
//
// With a cgroup root the event's PID cannot be trusted (on kind it is the
// host kernel's, and the sentinel's /proc is the node's), so the process is
// identified by cgroup membership instead: the event's cgroup inode is the
// same in every namespace, and its cgroup.procs lists PIDs in the sentinel's
// own namespace. The open is the runtime's only when every process in that
// cgroup runs the node's runc, so no workload code has run there yet.
//
// Both checks above read the process state when the record is HANDLED, which
// races runc's exec of the entrypoint: live, 2026-10-03, agent-cardvault's
// ServiceAccount mount was opened by runc init at 07:18:42.279 and handled
// 0.73 s later, after the agent had replaced runc in the cgroup, so it froze
// a pod no workload code had touched. The probe now records the caller's
// executable identity (exe_ino, exe_size) at the syscall itself; when it is
// the node's runc, that decides, and atEvent reports it. A record without
// one (0: an older probe, a kernel thread) falls back to the checks above.
func (m *SentinelProbeManager) runtimeUserLookup(target string, pid uint32, cgroupID, exeIno, exeSize uint64) (exempt, atEvent bool) {
	if !runtimeSetupOpens[target] {
		return false, false
	}
	if exeIno != 0 && m.isNodeRuncIdentity(exeIno, exeSize) {
		return true, true
	}
	return m.runtimeProcessLookup(pid, cgroupID), false
}

// runtimeProcessLookup is the handling-time check: pid (or, with a cgroup
// root, every process in the cgroup) runs the node's runc.
func (m *SentinelProbeManager) runtimeProcessLookup(pid uint32, cgroupID uint64) bool {
	if m.cgroupRoot == "" {
		return pid != 0 && m.isNodeRunc(pid)
	}
	m.lookupPodByCgroupID(cgroupID) // indexes the inode's path
	m.cgMu.Lock()
	rel := m.cgroupPaths[cgroupID]
	m.cgMu.Unlock()
	if rel == "" {
		return false
	}
	data, err := os.ReadFile(filepath.Join(m.cgroupRoot, rel, "cgroup.procs"))
	if err != nil {
		return false
	}
	procs := strings.Fields(string(data))
	if len(procs) == 0 {
		return false
	}
	for _, p := range procs {
		n, err := strconv.ParseUint(p, 10, 32)
		if err != nil || !m.isNodeRunc(uint32(n)) {
			return false
		}
	}
	return true
}

// isNodeRunc reports whether pid's executable is the node's runc binary.
func (m *SentinelProbeManager) isNodeRunc(pid uint32) bool {
	exe, err := os.Stat(filepath.Join(m.procRoot, strconv.FormatUint(uint64(pid), 10), "exe"))
	if err != nil {
		return false
	}
	nodeRoot := filepath.Join(m.procRoot, "1", "root")
	for _, p := range m.runtimeBinaries {
		ref, err := os.Stat(filepath.Join(nodeRoot, p))
		if err == nil && ref.Mode().IsRegular() && sameBinary(exe, ref) {
			return true
		}
	}
	return false
}

// isNodeRuncIdentity reports whether (ino, size), taken by the probe from the
// caller's exe_file, is the node's runc binary: same inode and size, the
// identity isNodeRunc uses, without needing the process to still exist.
func (m *SentinelProbeManager) isNodeRuncIdentity(ino, size uint64) bool {
	nodeRoot := filepath.Join(m.procRoot, "1", "root")
	for _, p := range m.runtimeBinaries {
		ref, err := os.Stat(filepath.Join(nodeRoot, p))
		if err != nil || !ref.Mode().IsRegular() {
			continue
		}
		st, ok := ref.Sys().(*syscall.Stat_t)
		if ok && st.Ino == ino && uint64(ref.Size()) == size {
			return true
		}
	}
	return false
}

// sameBinary: same inode and same size. The device is not compared: the
// overlay runc runs from has its own device and keeps the lower inode.
func sameBinary(exe, ref os.FileInfo) bool {
	a, ok := exe.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	b, ok := ref.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	return a.Ino == b.Ino && exe.Size() == ref.Size()
}
