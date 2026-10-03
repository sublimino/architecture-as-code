// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"path/filepath"
	"strconv"
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

// runtimeUserDatabase is what runc opens to resolve a container's user.
var runtimeUserDatabase = map[string]bool{"/etc/passwd": true, "/etc/group": true}

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
func (m *SentinelProbeManager) runtimeUserLookup(target string, pid uint32) bool {
	if !runtimeUserDatabase[target] || pid == 0 {
		return false
	}
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
