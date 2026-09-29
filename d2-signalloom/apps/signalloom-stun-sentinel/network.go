package main

import (
	"encoding/binary"
	"errors"
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
	open  func(string) (namespaceHandle, error)
	setns func(int, int) error
	// linkPeer returns the peer ifindex of the named link, queried on the
	// calling thread's CURRENT network namespace. It must not read sysfs:
	// /sys stays bound to the netns that mounted it, which for this
	// hostNetwork DaemonSet is the node's.
	linkPeer func(iface string) (int, error)
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
	dryRun       bool
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
		if t.dryRun {
			return "veth-dryrun-host", nil
		}
		return "", fmt.Errorf("find pod PID: %w", err)
	}
	peerIndex, err := t.peerIndex(pid, "eth0")
	if err != nil {
		if t.dryRun {
			return "veth-dryrun-host", nil
		}
		return "", fmt.Errorf("read eth0 peer index for PID %d: %w", pid, err)
	}
	interfaces, err := t.interfaces()
	if err != nil {
		if t.dryRun {
			return "veth-dryrun-host", nil
		}
		return "", fmt.Errorf("list host interfaces: %w", err)
	}
	veth, err := hostInterfaceForPeer(peerIndex, interfaces)
	if err != nil && t.dryRun {
		return fmt.Sprintf("veth-peer%d", peerIndex), nil
	}
	return veth, err
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
		linkPeer: netlinkLinkPeer,
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

	peerIndex, queryErr := ops.linkPeer(iface)
	if err := ops.setns(int(hostNS.Fd()), unix.CLONE_NEWNET); err != nil {
		return 0, true, fmt.Errorf("restore host network namespace: %w", err)
	}
	if queryErr != nil {
		return 0, false, fmt.Errorf("netlink RTM_GETLINK %s in pod netns: %w", iface, queryErr)
	}
	if peerIndex <= 0 {
		return 0, false, fmt.Errorf("pod interface %s has invalid peer index %d", iface, peerIndex)
	}
	return peerIndex, false, nil
}

// netlinkLinkPeer asks the kernel for one link by name over NETLINK_ROUTE.
// A netlink socket belongs to the netns of the thread that creates it, so
// called after setns it answers for the pod netns. Raw x/sys/unix: the image
// is distroless-static and must not exec ip(8).
func netlinkLinkPeer(iface string) (int, error) {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err != nil {
		return 0, fmt.Errorf("netlink socket: %w", err)
	}
	defer unix.Close(fd)
	if err := unix.Sendto(fd, rtmGetLinkRequest(iface), 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return 0, fmt.Errorf("netlink send: %w", err)
	}
	buf := make([]byte, 1<<16)
	n, _, err := unix.Recvfrom(fd, buf, 0)
	if err != nil {
		return 0, fmt.Errorf("netlink recv: %w", err)
	}
	return parseLinkPeer(buf[:n])
}

func rtmGetLinkRequest(iface string) []byte {
	name := append([]byte(iface), 0)
	attrLen := unix.SizeofRtAttr + len(name)
	msgLen := unix.SizeofNlMsghdr + unix.SizeofIfInfomsg + nlmAlign(attrLen)
	b := make([]byte, msgLen)
	binary.NativeEndian.PutUint32(b[0:4], uint32(msgLen))
	binary.NativeEndian.PutUint16(b[4:6], unix.RTM_GETLINK)
	binary.NativeEndian.PutUint16(b[6:8], unix.NLM_F_REQUEST)
	binary.NativeEndian.PutUint32(b[8:12], 1) // seq
	// ifinfomsg left zero: family AF_UNSPEC, index 0 (select by IFLA_IFNAME).
	a := b[unix.SizeofNlMsghdr+unix.SizeofIfInfomsg:]
	binary.NativeEndian.PutUint16(a[0:2], uint16(attrLen))
	binary.NativeEndian.PutUint16(a[2:4], unix.IFLA_IFNAME)
	copy(a[unix.SizeofRtAttr:], name)
	return b
}

func nlmAlign(n int) int { return (n + 3) &^ 3 }

// parseLinkPeer returns IFLA_LINK (the veth peer's ifindex) from an
// RTM_NEWLINK reply. The kernel omits IFLA_LINK when iflink == ifindex; the
// ifindex is then the answer, matching sysfs iflink semantics.
func parseLinkPeer(buf []byte) (int, error) {
	for len(buf) >= unix.SizeofNlMsghdr {
		msgLen := int(binary.NativeEndian.Uint32(buf[0:4]))
		msgType := binary.NativeEndian.Uint16(buf[4:6])
		if msgLen < unix.SizeofNlMsghdr || msgLen > len(buf) {
			return 0, fmt.Errorf("netlink: malformed message length %d", msgLen)
		}
		payload := buf[unix.SizeofNlMsghdr:msgLen]
		switch msgType {
		case unix.NLMSG_ERROR:
			if len(payload) < 4 {
				return 0, errors.New("netlink: short NLMSG_ERROR")
			}
			if code := int32(binary.NativeEndian.Uint32(payload[0:4])); code != 0 {
				return 0, unix.Errno(-code)
			}
		case unix.RTM_NEWLINK:
			if len(payload) < unix.SizeofIfInfomsg {
				return 0, errors.New("netlink: short ifinfomsg")
			}
			index := int(int32(binary.NativeEndian.Uint32(payload[4:8])))
			attrs := payload[unix.SizeofIfInfomsg:]
			for len(attrs) >= unix.SizeofRtAttr {
				l := int(binary.NativeEndian.Uint16(attrs[0:2]))
				typ := binary.NativeEndian.Uint16(attrs[2:4])
				if l < unix.SizeofRtAttr || l > len(attrs) {
					return 0, fmt.Errorf("netlink: malformed attribute length %d", l)
				}
				if typ == unix.IFLA_LINK && l >= unix.SizeofRtAttr+4 {
					return int(int32(binary.NativeEndian.Uint32(attrs[unix.SizeofRtAttr:]))), nil
				}
				attrs = attrs[min(nlmAlign(l), len(attrs)):]
			}
			return index, nil
		case unix.NLMSG_DONE:
			return 0, errors.New("netlink: no RTM_NEWLINK in reply")
		}
		buf = buf[min(nlmAlign(msgLen), len(buf)):]
	}
	return 0, errors.New("netlink: no RTM_NEWLINK in reply")
}

func (t *tcDropFilter) attachDrop(iface string) error {
	if t.dryRun {
		return nil
	}
	// replace, not add: clsact is shared and outlives an unstun, and a second
	// `add` fails "Exclusivity flag on, cannot modify" (exit 2) on re-stun.
	if out, err := t.run("tc", "qdisc", "replace", "dev", iface, "clsact"); err != nil {
		return tcError("replace clsact", iface, out, err)
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
	if t.dryRun {
		return nil
	}
	if out, err := t.run("tc", "filter", "del", "dev", iface, "pref", sentinelIngressPref, "protocol", "all", "ingress", "handle", sentinelIngressHandle, "matchall"); err != nil && !missingTCObject(out) {
		return tcError("delete Sentinel ingress filter", iface, out, err)
	}
	if out, err := t.run("tc", "filter", "del", "dev", iface, "pref", sentinelEgressPref, "protocol", "all", "egress", "handle", sentinelEgressHandle, "matchall"); err != nil && !missingTCObject(out) {
		return tcError("delete Sentinel egress filter", iface, out, err)
	}
	return nil
}

func (t *tcDropFilter) hasDropFilter(iface string) (ingress bool, egress bool, err error) {
	if t.dryRun {
		return true, true, nil
	}
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
