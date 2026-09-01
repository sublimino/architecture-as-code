package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const (
	sentinelIngressPref   = "49152"
	sentinelIngressHandle = "1"
	sentinelEgressPref    = "49153"
	sentinelEgressHandle  = "2"
)

type tcRunner func(name string, args ...string) ([]byte, error)

type namespaceHandle interface {
	Fd() uintptr
	Close() error
}

type namespaceOps struct {
	open     func(string) (namespaceHandle, error)
	setns    func(int, int) error
	readFile func(string) ([]byte, error)
}

type peerIndexResult struct {
	peerIndex int
	err       error
}

// tcDropFilter manages only the filters created by this Sentinel. The clsact
// qdisc is shared infrastructure and is deliberately never removed.
type tcDropFilter struct {
	run          tcRunner
	interfaces   func() ([]net.Interface, error)
	pidForCgroup func(string) (int, error)
	peerIndex    func(int, string) (int, error)
}

func newTCDropFilter() *tcDropFilter {
	return &tcDropFilter{
		run:          runTC,
		interfaces:   net.Interfaces,
		pidForCgroup: findLivePID,
		peerIndex:    podInterfacePeerIndex,
	}
}

func runTC(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

// findHostVeth finds the host interface by its exact peer index, never by a
// CNI naming convention. eth0 is the expected pod interface.
func (t *tcDropFilter) findHostVeth(cgroupPath string) (string, error) {
	pid, err := t.pidForCgroup(cgroupPath)
	if err != nil {
		return "", fmt.Errorf("find pod PID: %w", err)
	}
	peerIndex, err := t.peerIndex(pid, "eth0")
	if err != nil {
		return "", fmt.Errorf("read eth0 peer index for PID %d: %w", pid, err)
	}
	interfaces, err := t.interfaces()
	if err != nil {
		return "", fmt.Errorf("list host interfaces: %w", err)
	}
	return hostInterfaceForPeer(peerIndex, interfaces)
}

func hostInterfaceForPeer(peerIndex int, interfaces []net.Interface) (string, error) {
	for _, iface := range interfaces {
		if iface.Index == peerIndex {
			return iface.Name, nil
		}
	}
	return "", fmt.Errorf("no host interface has pod peer index %d", peerIndex)
}

func findLivePID(cgroupPath string) (int, error) {
	return livePIDFromCgroup(cgroupPath, processExists)
}

// livePIDFromCgroup reads cgroup.procs throughout the resolved pod cgroup so
// it can find a process in a container child cgroup, not just the pod parent.
func livePIDFromCgroup(cgroupPath string, exists func(int) bool) (int, error) {
	var found int
	err := filepath.WalkDir(cgroupPath, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || entry.Name() != "cgroup.procs" {
			return nil
		}
		contents, err := os.ReadFile(path)
		if err != nil {
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
		return 0, fmt.Errorf("no live process found beneath pod cgroup %s", cgroupPath)
	}
	return found, nil
}

func processExists(pid int) bool {
	_, err := os.Stat(filepath.Join("/proc", strconv.Itoa(pid)))
	return err == nil
}

// podInterfacePeerIndex isolates setns on a dedicated locked OS thread. If
// restoration fails, that goroutine exits without UnlockOSThread; the runtime
// terminates the contaminated thread rather than returning it to the pool.
func podInterfacePeerIndex(pid int, iface string) (int, error) {
	return podInterfacePeerIndexWithOps(pid, iface, namespaceOps{
		open:     openNamespace,
		setns:    unix.Setns,
		readFile: os.ReadFile,
	})
}

func openNamespace(path string) (namespaceHandle, error) {
	return os.Open(path)
}

func podInterfacePeerIndexWithOps(pid int, iface string, ops namespaceOps) (int, error) {
	resultCh := make(chan peerIndexResult, 1)
	go func() {
		runtime.LockOSThread()
		peerIndex, restoreFailed, err := peerIndexOnLockedThread(pid, iface, ops)
		resultCh <- peerIndexResult{peerIndex: peerIndex, err: err}
		if !restoreFailed {
			runtime.UnlockOSThread()
		}
	}()
	result := <-resultCh
	return result.peerIndex, result.err
}

func peerIndexOnLockedThread(pid int, iface string, ops namespaceOps) (peerIndex int, restoreFailed bool, retErr error) {
	hostNS, err := ops.open("/proc/self/ns/net")
	if err != nil {
		return 0, false, fmt.Errorf("open host network namespace: %w", err)
	}
	defer hostNS.Close()
	podNS, err := ops.open(filepath.Join("/proc", strconv.Itoa(pid), "ns/net"))
	if err != nil {
		return 0, false, fmt.Errorf("open pod network namespace: %w", err)
	}
	defer podNS.Close()

	if err := ops.setns(int(podNS.Fd()), unix.CLONE_NEWNET); err != nil {
		return 0, false, fmt.Errorf("enter pod network namespace: %w", err)
	}

	data, readErr := ops.readFile(filepath.Join("/sys/class/net", iface, "iflink"))
	if err := ops.setns(int(hostNS.Fd()), unix.CLONE_NEWNET); err != nil {
		return 0, true, fmt.Errorf("restore host network namespace: %w", err)
	}
	if readErr != nil {
		return 0, false, fmt.Errorf("read /sys/class/net/%s/iflink (pod interface missing): %w", iface, readErr)
	}
	peerIndex, err = strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0, false, fmt.Errorf("parse pod interface %s iflink %q: %w", iface, strings.TrimSpace(string(data)), err)
	}
	if peerIndex <= 0 {
		return 0, false, fmt.Errorf("pod interface %s has invalid iflink %d", iface, peerIndex)
	}
	return peerIndex, false, nil
}

func (t *tcDropFilter) attachDrop(iface string) error {
	if out, err := t.run("tc", "qdisc", "add", "dev", iface, "clsact"); err != nil && !strings.Contains(string(out), "File exists") {
		return tcError("add clsact", iface, out, err)
	}
	if out, err := t.run("tc", "filter", "replace", "dev", iface, "pref", sentinelIngressPref, "protocol", "all", "ingress", "handle", sentinelIngressHandle, "matchall", "action", "drop"); err != nil {
		return tcError("replace Sentinel ingress filter", iface, out, err)
	}
	if out, err := t.run("tc", "filter", "replace", "dev", iface, "pref", sentinelEgressPref, "protocol", "all", "egress", "handle", sentinelEgressHandle, "matchall", "action", "drop"); err != nil {
		return tcError("replace Sentinel egress filter", iface, out, err)
	}
	return nil
}

func (t *tcDropFilter) detachDrop(iface string) error {
	if out, err := t.run("tc", "filter", "del", "dev", iface, "pref", sentinelIngressPref, "protocol", "all", "ingress", "handle", sentinelIngressHandle, "matchall"); err != nil && !missingTCObject(out) {
		return tcError("delete Sentinel ingress filter", iface, out, err)
	}
	if out, err := t.run("tc", "filter", "del", "dev", iface, "pref", sentinelEgressPref, "protocol", "all", "egress", "handle", sentinelEgressHandle, "matchall"); err != nil && !missingTCObject(out) {
		return tcError("delete Sentinel egress filter", iface, out, err)
	}
	return nil
}

func (t *tcDropFilter) hasDropFilter(iface string) (ingress bool, egress bool, err error) {
	inOut, err := t.run("tc", "filter", "show", "dev", iface, "ingress")
	if err != nil && !missingTCObject(inOut) {
		return false, false, tcError("show ingress filters", iface, inOut, err)
	}
	egOut, err := t.run("tc", "filter", "show", "dev", iface, "egress")
	if err != nil && !missingTCObject(egOut) {
		return false, false, tcError("show egress filters", iface, egOut, err)
	}
	hasIngress := strings.Contains(string(inOut), sentinelIngressPref) || (strings.Contains(string(inOut), "action drop") && strings.Contains(string(inOut), "ingress"))
	hasEgress := strings.Contains(string(egOut), sentinelEgressPref) || (strings.Contains(string(egOut), "action drop") && strings.Contains(string(egOut), "egress"))
	return hasIngress, hasEgress, nil
}

func missingTCObject(output []byte) bool {
	message := string(output)
	return strings.Contains(message, "No such file") ||
		strings.Contains(message, "Cannot find") ||
		strings.Contains(message, "No such process") ||
		strings.Contains(message, "Invalid argument")
}

func tcError(operation, iface string, output []byte, err error) error {
	return fmt.Errorf("tc %s on %s: %s (%w)", operation, iface, strings.TrimSpace(string(output)), err)
}
