// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

// discover.go maps a running container to the HOST-SIDE veth peer that carries
// its traffic.
//
// The naive approach — guess the host interface from a CNI naming convention —
// is wrong on every cluster that does not use the CNI you guessed, and fails
// silently by attaching a drop filter to the wrong container. This
// implementation resolves the peer by exact interface index instead:
//
//	1. find a live PID inside the pod's cgroup
//	2. enter that PID's network namespace on a locked OS thread
//	3. read /sys/class/net/eth0/iflink — the peer's ifindex in the HOST ns
//	4. return to the host namespace
//	5. find the host interface whose Index equals that iflink
//
// Step 4 is where this gets dangerous. If the setns back to the host namespace
// fails, the calling OS thread is permanently contaminated: it is still in the
// container's network namespace, and returning it to Go's thread pool would
// silently execute unrelated goroutines in the wrong netns. The mitigation is
// to exit the goroutine WITHOUT calling runtime.UnlockOSThread, which makes the
// Go runtime destroy the thread rather than reuse it.

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// NamespaceHandle is an open namespace file descriptor.
type NamespaceHandle interface {
	Fd() uintptr
	Close() error
}

// NamespaceOps are the syscall boundaries of namespace traversal, injected so
// the discovery logic is unit-testable without root or a real container.
type NamespaceOps struct {
	Open       func(string) (NamespaceHandle, error)
	Setns      func(fd int, nstype int) error
	ReadFile   func(string) ([]byte, error)
	Interfaces func() ([]net.Interface, error)
}

// DefaultNamespaceOps returns the real syscall implementations.
func DefaultNamespaceOps() NamespaceOps {
	return NamespaceOps{
		Open:       func(p string) (NamespaceHandle, error) { return os.Open(p) },
		Setns:      unix.Setns,
		ReadFile:   os.ReadFile,
		Interfaces: net.Interfaces,
	}
}

// Discoverer resolves containers to host veth names.
type Discoverer struct {
	ops NamespaceOps

	// PodInterface is the interface name inside the container. Effectively
	// always eth0, but configurable because multus and some service meshes
	// change it.
	PodInterface string
}

// NewDiscoverer returns a Discoverer wired to the real kernel.
func NewDiscoverer() *Discoverer {
	return &Discoverer{ops: DefaultNamespaceOps(), PodInterface: "eth0"}
}

// NewDiscovererWithOps returns a Discoverer with injected syscall boundaries.
func NewDiscovererWithOps(ops NamespaceOps) *Discoverer {
	return &Discoverer{ops: ops, PodInterface: "eth0"}
}

type peerResult struct {
	peerIndex int
	err       error
}

// HostVethForPID resolves the host-side veth name for a process.
func (d *Discoverer) HostVethForPID(pid int) (string, error) {
	peerIndex, err := d.PeerIndexForPID(pid)
	if err != nil {
		return "", err
	}
	ifaces, err := d.ops.Interfaces()
	if err != nil {
		return "", fmt.Errorf("list host interfaces: %w", err)
	}
	return HostInterfaceForPeer(peerIndex, ifaces)
}

// HostVethForCgroup resolves the host-side veth name for a pod cgroup path.
func (d *Discoverer) HostVethForCgroup(cgroupPath string) (string, error) {
	pid, err := LivePIDFromCgroup(cgroupPath)
	if err != nil {
		return "", err
	}
	return d.HostVethForPID(pid)
}

// PeerIndexForPID reads the container's eth0 iflink, which is the host-side
// peer's interface index.
func (d *Discoverer) PeerIndexForPID(pid int) (int, error) {
	iface := d.PodInterface
	if iface == "" {
		iface = "eth0"
	}
	resultCh := make(chan peerResult, 1)
	go func() {
		runtime.LockOSThread()
		idx, restoreFailed, err := d.peerIndexOnLockedThread(pid, iface)
		resultCh <- peerResult{peerIndex: idx, err: err}
		if !restoreFailed {
			runtime.UnlockOSThread()
		}
		// If restoreFailed, we return WITHOUT unlocking. The goroutine
		// exits, and the Go runtime destroys the contaminated OS thread
		// instead of handing it back to the pool still inside the
		// container's network namespace.
	}()
	r := <-resultCh
	return r.peerIndex, r.err
}

func (d *Discoverer) peerIndexOnLockedThread(pid int, iface string) (peerIndex int, restoreFailed bool, retErr error) {
	hostNS, err := d.ops.Open("/proc/self/ns/net")
	if err != nil {
		return 0, false, fmt.Errorf("open host network namespace: %w", err)
	}
	defer hostNS.Close()

	podNSPath := filepath.Join("/proc", strconv.Itoa(pid), "ns/net")
	podNS, err := d.ops.Open(podNSPath)
	if err != nil {
		if isNotFound(err) {
			// Container exited between selection and lookup. Routine.
			return 0, false, fmt.Errorf("%w: pid %d netns", ErrInterfaceGone, pid)
		}
		return 0, false, fmt.Errorf("open pod network namespace for pid %d: %w", pid, err)
	}
	defer podNS.Close()

	if err := d.ops.Setns(int(podNS.Fd()), unix.CLONE_NEWNET); err != nil {
		if isPermission(err) {
			return 0, false, fmt.Errorf("%w: entering netns of pid %d", ErrPermission, pid)
		}
		return 0, false, fmt.Errorf("enter pod network namespace for pid %d: %w", pid, err)
	}

	// Read inside the pod namespace, then ALWAYS attempt the restore before
	// inspecting the read error. Returning early on a read failure while
	// still inside the container's namespace is the contamination bug.
	data, readErr := d.ops.ReadFile(filepath.Join("/sys/class/net", iface, "iflink"))

	if err := d.ops.Setns(int(hostNS.Fd()), unix.CLONE_NEWNET); err != nil {
		return 0, true, fmt.Errorf("restore host network namespace (thread abandoned): %w", err)
	}

	if readErr != nil {
		if isNotFound(readErr) {
			return 0, false, fmt.Errorf("%w: %s inside pid %d", ErrInterfaceGone, iface, pid)
		}
		return 0, false, fmt.Errorf("read /sys/class/net/%s/iflink for pid %d: %w", iface, pid, readErr)
	}

	raw := strings.TrimSpace(string(data))
	peerIndex, err = strconv.Atoi(raw)
	if err != nil {
		return 0, false, fmt.Errorf("parse iflink %q for %s: %w", raw, iface, err)
	}
	if peerIndex <= 0 {
		return 0, false, fmt.Errorf("interface %s reported invalid iflink %d", iface, peerIndex)
	}
	return peerIndex, false, nil
}

// HostInterfaceForPeer resolves an interface index to its name.
func HostInterfaceForPeer(peerIndex int, interfaces []net.Interface) (string, error) {
	for _, iface := range interfaces {
		if iface.Index == peerIndex {
			return iface.Name, nil
		}
	}
	return "", fmt.Errorf("%w: no host interface has peer index %d", ErrInterfaceGone, peerIndex)
}

// LivePIDFromCgroup finds a running process anywhere beneath a pod cgroup.
//
// Walks the whole subtree rather than reading the pod-level cgroup.procs,
// because on most runtimes the pod cgroup itself is empty and the processes
// live in per-container child cgroups.
func LivePIDFromCgroup(cgroupPath string) (int, error) {
	return livePIDFromCgroupWith(cgroupPath, processExists, os.ReadFile)
}

func livePIDFromCgroupWith(cgroupPath string, exists func(int) bool, readFile func(string) ([]byte, error)) (int, error) {
	var found int
	err := filepath.WalkDir(cgroupPath, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || entry.Name() != "cgroup.procs" {
			return nil
		}
		contents, err := readFile(path)
		if err != nil {
			// A cgroup can vanish mid-walk when a container exits.
			// That is not a failure of the walk.
			if isNotFound(err) {
				return nil
			}
			return fmt.Errorf("read %s: %w", path, err)
		}
		for _, line := range strings.Fields(string(contents)) {
			pid, err := strconv.Atoi(line)
			if err == nil && pid > 0 && exists(pid) {
				found = pid
				return filepath.SkipAll
			}
		}
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("walk pod cgroup %s: %w", cgroupPath, err)
	}
	if found == 0 {
		return 0, fmt.Errorf("%w: no live process beneath %s", ErrInterfaceGone, cgroupPath)
	}
	return found, nil
}

func processExists(pid int) bool {
	_, err := os.Stat(filepath.Join("/proc", strconv.Itoa(pid)))
	return err == nil
}
