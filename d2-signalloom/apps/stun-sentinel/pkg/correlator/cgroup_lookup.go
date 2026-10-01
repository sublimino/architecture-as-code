// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// cgroupIndexMinInterval bounds how often a cache miss may re-walk the cgroup
// tree, so a burst of events from an unknown cgroup cannot become a storm of
// filesystem walks.
const cgroupIndexMinInterval = time.Second

// WithCgroupRoot sets the cgroup-v2 mount the correlator walks to map an
// event's cgroup inode to a pod. The sentinel mounts the host's at CGROUP_ROOT.
func WithCgroupRoot(root string) Option {
	return func(m *SentinelProbeManager) {
		m.cgroupRoot = root
	}
}

// lookupPodByCgroupID resolves the pod owning the cgroup whose inode the probe
// stamped on the event. Unlike the PID, the inode is the same in every PID
// namespace, so this works where the sentinel cannot see the kernel's PID.
func (m *SentinelProbeManager) lookupPodByCgroupID(id uint64) *corev1.Pod {
	if id == 0 || m.cgroupRoot == "" {
		return nil
	}
	m.cgMu.Lock()
	uid, ok := m.cgroupIndex[id]
	if !ok && time.Since(m.cgroupIndexedAt) >= cgroupIndexMinInterval {
		m.cgroupIndex, m.cgroupPaths = indexPodCgroups(m.cgroupRoot)
		m.cgroupIndexedAt = time.Now()
		uid, ok = m.cgroupIndex[id]
	}
	m.cgMu.Unlock()
	if !ok {
		return nil
	}
	return m.podByUID(uid)
}

// indexPodCgroups maps the inode of every cgroup directory at or below a pod
// slice to that pod's UID (dashed form).
func indexPodCgroups(root string) (map[uint64]string, map[uint64]string) {
	idx := make(map[uint64]string)
	paths := make(map[uint64]string)
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil
		}
		match := podUIDRegex.FindStringSubmatch(p)
		if len(match) < 2 {
			return nil
		}
		var st syscall.Stat_t
		if syscall.Stat(p, &st) == nil {
			idx[st.Ino] = strings.ReplaceAll(match[1], "_", "-")
			if rel, err := filepath.Rel(root, p); err == nil {
				paths[st.Ino] = "/" + rel
			}
		}
		return nil
	})
	return idx, paths
}

// cgroupPathFor reports the cgroup an event came from: the indexed path for
// its inode, else the cgroup-v2 line of /proc/<pid>/cgroup (real nodes, where
// the PID is visible), else empty.
func (m *SentinelProbeManager) cgroupPathFor(id uint64, pid uint32) string {
	m.cgMu.Lock()
	p := m.cgroupPaths[id]
	m.cgMu.Unlock()
	if p != "" {
		return p
	}
	data, err := os.ReadFile(filepath.Join(m.procRoot, strconv.FormatUint(uint64(pid), 10), "cgroup"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if rest, ok := strings.CutPrefix(line, "0::"); ok {
			return rest
		}
	}
	return ""
}

// podByUID finds an indexed or informer-known pod by UID. A UID the informer
// does not know is not a pod the sentinel watches, and resolves to nil.
func (m *SentinelProbeManager) podByUID(uid string) *corev1.Pod {
	m.mu.RLock()
	pod, ok := m.podMap[uid]
	m.mu.RUnlock()
	if ok {
		return pod
	}
	if m.informer == nil {
		return nil
	}
	for _, obj := range m.informer.GetStore().List() {
		p, ok := obj.(*corev1.Pod)
		if ok && p != nil && strings.EqualFold(string(p.UID), uid) {
			m.indexPod(p)
			return p
		}
	}
	return nil
}
