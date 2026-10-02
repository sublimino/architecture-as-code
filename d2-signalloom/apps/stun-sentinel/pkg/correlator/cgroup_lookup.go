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

// cgroupMissTTL is how long an inode that is in no pod's cgroup is remembered
// as a miss. Misses are cached PER INODE: host processes produce a steady
// stream of them, and a global walk throttle let that noise spend every
// re-walk, so a new pod's first sensitive opens were dropped (review M1).
const (
	cgroupMissTTL     = 5 * time.Second
	cgroupMissMaxSize = 4096
)

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
	if !ok {
		now := time.Now()
		if until, known := m.cgroupMisses[id]; !known || now.After(until) {
			m.cgroupIndex, m.cgroupPaths = indexPodCgroups(m.cgroupRoot)
			m.cgroupWalks.Add(1)
			m.cgroupIndexedAt = now
			uid, ok = m.cgroupIndex[id]
			if !ok {
				if m.cgroupMisses == nil || len(m.cgroupMisses) >= cgroupMissMaxSize {
					m.cgroupMisses = make(map[uint64]time.Time)
				}
				m.cgroupMisses[id] = now.Add(cgroupMissTTL)
			}
		}
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
	if p != "" || m.cgroupRoot != "" {
		// With a cgroup root the PID cannot be trusted to be this event's
		// process (review H1), so never describe the event by a PID's cgroup.
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

// pidInEventCgroup reports whether pid really is in the event's cgroup. The
// probe's PID is the kernel root-namespace PID, which on a nested node (kind)
// can name an unrelated process. Inside a cgroup namespace /proc/<pid>/cgroup
// reads "0::/../../<slice>/<scope>", so the check matches the container scope
// directory, which is unique per container, rather than a joined path.
func (m *SentinelProbeManager) pidInEventCgroup(pid uint32, id uint64) bool {
	m.cgMu.Lock()
	p := m.cgroupPaths[id]
	m.cgMu.Unlock()
	if p == "" {
		return false
	}
	data, err := os.ReadFile(filepath.Join(m.procRoot, strconv.FormatUint(uint64(pid), 10), "cgroup"))
	if err != nil {
		return false
	}
	scope := "/" + filepath.Base(p)
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if rest, ok := strings.CutPrefix(line, "0::"); ok {
			return strings.HasSuffix(rest, scope)
		}
	}
	return false
}
