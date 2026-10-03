// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"

	"golang.org/x/sys/unix"
)

// DefaultBundleRoots hold each container's OCI bundle, whose config.json
// lists exactly the hooks the runtime runs for that container. This is the
// primary source: it is root-owned 0700/0644 and readable by the sentinel,
// while kind's /etc/containerd is 0644 (no search bit) and the sentinel holds
// no DAC capability to traverse it.
var DefaultBundleRoots = []string{"/run/containerd/io.containerd.runtime.v2.task/k8s.io"}

// DefaultContainerdConfigs are where the node's containerd config is read
// (through the node root) for its base_runtime_spec hooks: a second source,
// for nodes where it is readable.
var DefaultContainerdConfigs = []string{"/etc/containerd/config.toml"}

// WithBundleRoots overrides DefaultBundleRoots.
func WithBundleRoots(paths ...string) Option {
	return func(m *SentinelProbeManager) {
		m.bundleRoots = paths
	}
}

// WithContainerdConfigs overrides DefaultContainerdConfigs.
func WithContainerdConfigs(paths ...string) Option {
	return func(m *SentinelProbeManager) {
		m.containerdConfigs = paths
	}
}

// nodeRuntimeBinary is one node binary the runtime itself runs inside a new
// container's cgroup: runc, or an OCI hook. Comm, when set, must also match
// the caller's comm: a script hook runs as its INTERPRETER, so the
// interpreter's inode is shared with every other script on the node, and only
// the comm the kernel takes from the script's name (truncated to 15 bytes)
// says it is this hook.
type nodeRuntimeBinary struct {
	BinaryIdentity
	Comm string
}

// isNodeRuntimeIdentity reports whether the caller -- exe (ino, size) and
// comm, as the probe saw them at the syscall -- is one of the node's runtime
// binaries. Live, 2026-10-03, kind's createContainer hook
// /kind/bin/mount-product-files.sh (#!/bin/bash) opened /etc/passwd in
// cpai-engineer-0's new containers as comm "mount-product-f", exe the node's
// /usr/bin/bash: node code, run by the runtime, frozen as a detection.
func (m *SentinelProbeManager) isNodeRuntimeIdentity(ino, size uint64, comm string, cgroupID uint64) bool {
	for _, b := range m.nodeRuntimeBinaries(cgroupID) {
		if b.Ino == ino && b.Size == size && (b.Comm == "" || b.Comm == comm) {
			return true
		}
	}
	return false
}

// nodeRuntimeBinaries lists runc and every OCI hook configured for the
// container in cgroupID (its bundle) or by the node's containerd config, each
// by inode and size, read through the node root. Anything it cannot read or
// verify is simply absent, so the exemption fails closed.
func (m *SentinelProbeManager) nodeRuntimeBinaries(cgroupID uint64) []nodeRuntimeBinary {
	var out []nodeRuntimeBinary
	for _, p := range m.runtimeBinaries {
		if id, ok := m.nodeBinaryIdentity(p); ok {
			out = append(out, nodeRuntimeBinary{BinaryIdentity: id})
		}
	}
	for _, hook := range m.configuredHooks(cgroupID) {
		head, err := m.readInNodeRoot(hook, 256)
		if err != nil {
			continue
		}
		if interp, ok := shebangInterpreter(head); ok {
			if resolved, ok := m.resolveInterpreter(interp); ok {
				if id, ok := m.nodeBinaryIdentity(resolved); ok {
					out = append(out, nodeRuntimeBinary{BinaryIdentity: id, Comm: kernelComm(path.Base(hook))})
				}
			}
			continue
		}
		if id, ok := m.nodeBinaryIdentity(hook); ok {
			out = append(out, nodeRuntimeBinary{BinaryIdentity: id})
		}
	}
	return out
}

// nodeRuntimeIdentities is nodeRuntimeBinaries for a detection's
// node_runtime field.
func (m *SentinelProbeManager) nodeRuntimeIdentities(cgroupID uint64) []BinaryIdentity {
	bins := m.nodeRuntimeBinaries(cgroupID)
	out := make([]BinaryIdentity, 0, len(bins))
	for _, b := range bins {
		id := b.BinaryIdentity
		id.Comm = b.Comm
		out = append(out, id)
	}
	return out
}

var baseRuntimeSpec = regexp.MustCompile(`(?m)^\s*base_runtime_spec\s*=\s*"([^"]+)"`)

var criContainerScope = regexp.MustCompile(`cri-containerd-([0-9a-f]+)\.scope$`)

// configuredHooks returns the OCI hook paths configured for the container in
// cgroupID -- its bundle's spec -- and in every base_runtime_spec the node's
// containerd config names, deduplicated. A hook is configured, not assumed:
// nothing is exempt by name, and another container's hooks do not count.
func (m *SentinelProbeManager) configuredHooks(cgroupID uint64) []string {
	seen := map[string]bool{}
	var hooks []string
	add := func(spec []byte) {
		for _, h := range hooksInSpec(spec) {
			if !seen[h] {
				seen[h] = true
				hooks = append(hooks, h)
			}
		}
	}
	if id := m.containerIDOf(cgroupID); id != "" {
		for _, root := range m.bundleRoots {
			if spec, err := m.readInNodeRoot(path.Join(root, id, "config.json"), 1<<20); err == nil {
				add(spec)
			}
		}
	}
	for _, cfg := range m.containerdConfigs {
		data, err := m.readInNodeRoot(cfg, 1<<20)
		if err != nil {
			continue
		}
		for _, mm := range baseRuntimeSpec.FindAllSubmatch(data, -1) {
			if spec, err := m.readInNodeRoot(string(mm[1]), 1<<20); err == nil {
				add(spec)
			}
		}
	}
	return hooks
}

// hooksInSpec returns the absolute hook paths of an OCI runtime spec, of
// every hook kind; nil for a spec that does not parse.
func hooksInSpec(spec []byte) []string {
	var s struct {
		Hooks map[string][]struct {
			Path string `json:"path"`
		} `json:"hooks"`
	}
	if json.Unmarshal(spec, &s) != nil {
		return nil
	}
	var out []string
	for _, list := range s.Hooks {
		for _, h := range list {
			if path.IsAbs(h.Path) {
				out = append(out, h.Path)
			}
		}
	}
	return out
}

// containerIDOf returns the CRI container id of the cgroup (its
// cri-containerd-<id>.scope), or "" when it is not a container scope or the
// sentinel runs without a cgroup root.
func (m *SentinelProbeManager) containerIDOf(cgroupID uint64) string {
	if m.cgroupRoot == "" || cgroupID == 0 {
		return ""
	}
	m.lookupPodByCgroupID(cgroupID) // indexes the inode's path
	m.cgMu.Lock()
	rel := m.cgroupPaths[cgroupID]
	m.cgMu.Unlock()
	if mm := criContainerScope.FindStringSubmatch(rel); mm != nil {
		return mm[1]
	}
	return ""
}

// shebangInterpreter returns a script's interpreter path, following
// `#!/usr/bin/env NAME` to NAME.
func shebangInterpreter(head []byte) (string, bool) {
	if !bytes.HasPrefix(head, []byte("#!")) {
		return "", false
	}
	line := string(head[2:])
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	f := strings.Fields(line)
	if len(f) == 0 {
		return "", false
	}
	if path.Base(f[0]) == "env" && len(f) > 1 {
		return f[1], true
	}
	return f[0], true
}

var nodeExecPath = []string{"/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"}

func (m *SentinelProbeManager) resolveInterpreter(interp string) (string, bool) {
	if path.IsAbs(interp) {
		return interp, true
	}
	for _, dir := range nodeExecPath {
		p := path.Join(dir, interp)
		if _, ok := m.nodeBinaryIdentity(p); ok {
			return p, true
		}
	}
	return "", false
}

// kernelComm is the comm the kernel gives a process exec'd from a file of
// this name: the name truncated to TASK_COMM_LEN-1 (15) bytes.
func kernelComm(name string) string {
	if len(name) > 15 {
		return name[:15]
	}
	return name
}

// nodeBinaryIdentity is a regular node file's inode and size.
func (m *SentinelProbeManager) nodeBinaryIdentity(p string) (BinaryIdentity, bool) {
	f, err := m.openInNodeRoot(p, unix.O_PATH)
	if err != nil {
		return BinaryIdentity{}, false
	}
	defer f.Close()
	var st unix.Stat_t
	if unix.Fstat(int(f.Fd()), &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFREG {
		return BinaryIdentity{}, false
	}
	return BinaryIdentity{Path: filepath.Join(m.procRoot, "1", "root", p), Ino: st.Ino, Size: uint64(st.Size)}, true
}

func (m *SentinelProbeManager) readInNodeRoot(p string, max int64) ([]byte, error) {
	f, err := m.openInNodeRoot(p, unix.O_RDONLY)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, max))
}

// openInNodeRoot opens p inside the node's root (<procRoot>/1/root) with
// RESOLVE_IN_ROOT, so an absolute symlink on the node (/bin -> /usr/bin)
// resolves against the node's root -- a plain path join through
// /proc/1/root would follow it into the sentinel's own root, a different
// file.
func (m *SentinelProbeManager) openInNodeRoot(p string, flags uint64) (*os.File, error) {
	root, err := unix.Open(filepath.Join(m.procRoot, "1", "root"), unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(root)
	fd, err := unix.Openat2(root, strings.TrimPrefix(p, "/"), &unix.OpenHow{
		Flags:   flags | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_IN_ROOT | unix.RESOLVE_NO_MAGICLINKS,
	})
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), p), nil
}
