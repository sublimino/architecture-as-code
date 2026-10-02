package main

import (
	"encoding/binary"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func TestLivePIDFromCgroupFindsRecursiveLiveProcess(t *testing.T) {
	dir := t.TempDir()
	child := filepath.Join(dir, "container")
	if err := os.Mkdir(child, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(child, "cgroup.procs"), []byte("101\n202\n"), 0644); err != nil {
		t.Fatal(err)
	}

	pid, err := livePIDFromCgroup(dir, func(pid int) bool { return pid == 202 })
	if err != nil || pid != 202 {
		t.Fatalf("livePIDFromCgroup() = %d, %v; want 202, nil", pid, err)
	}
}

func TestLivePIDFromCgroupReportsNoLiveProcess(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cgroup.procs"), []byte("not-a-pid\n99\n"), 0644); err != nil {
		t.Fatal(err)
	}
	_, err := livePIDFromCgroup(dir, func(int) bool { return false })
	if err == nil || !strings.Contains(err.Error(), "no live process") {
		t.Fatalf("error = %v; want no live process", err)
	}
}

func TestHostInterfaceForPeerSelectsExactIndex(t *testing.T) {
	interfaces := []net.Interface{
		{Name: "veth-unrelated", Index: 7},
		{Name: "cali-unrelated", Index: 11},
		{Name: "lxc-unrelated", Index: 13},
		{Name: "veth-target", Index: 42},
	}
	name, err := hostInterfaceForPeer(42, interfaces)
	if err != nil || name != "veth-target" {
		t.Fatalf("hostInterfaceForPeer() = %q, %v; want veth-target, nil", name, err)
	}
}

func TestHostInterfaceForPeerNeverFallsBackToNamePattern(t *testing.T) {
	_, err := hostInterfaceForPeer(99, []net.Interface{{Name: "veth-unrelated", Index: 7}, {Name: "cali-unrelated", Index: 11}})
	if err == nil || !strings.Contains(err.Error(), "peer index 99") {
		t.Fatalf("error = %v; want exact peer-index failure", err)
	}
}

func TestResolveHostVethUsesCgroupPIDAndPeerIndex(t *testing.T) {
	tc := newTCDropFilter()
	tc.pidForCgroup = func(path string) (int, error) {
		if path != "/cgroup/pod" {
			t.Fatalf("cgroup path = %q", path)
		}
		return 123, nil
	}
	tc.peerIndex = func(pid int, iface string) (int, error) {
		if pid != 123 || iface != "eth0" {
			t.Fatalf("peer lookup = (%d, %q)", pid, iface)
		}
		return 42, nil
	}
	tc.interfaces = func() ([]net.Interface, error) {
		return []net.Interface{{Name: "veth-wrong", Index: 7}, {Name: "veth-target", Index: 42}}, nil
	}

	got, err := tc.findHostVeth("/cgroup/pod")
	if err != nil || got != "veth-target" {
		t.Fatalf("findHostVeth() = %q, %v", got, err)
	}
}

type fakeNamespaceHandle struct{ fd uintptr }

func (h fakeNamespaceHandle) Fd() uintptr  { return h.fd }
func (h fakeNamespaceHandle) Close() error { return nil }

func TestPodInterfacePeerIndexRestoresHostNamespace(t *testing.T) {
	var setnsCalls []int
	peerIndex, err := podInterfacePeerIndexWithOps(123, "eth0", namespaceOps{
		open: func(path string) (namespaceHandle, error) {
			if path == "/proc/self/ns/net" {
				return fakeNamespaceHandle{fd: 10}, nil
			}
			return fakeNamespaceHandle{fd: 20}, nil
		},
		setns: func(fd, _ int) error {
			setnsCalls = append(setnsCalls, fd)
			return nil
		},
		linkPeer: func(iface string) (int, error) {
			if iface != "eth0" {
				t.Fatalf("linkPeer iface = %q", iface)
			}
			// Record the query between the two setns calls: it must run while
			// the thread is inside the pod netns.
			setnsCalls = append(setnsCalls, -1)
			return 42, nil
		},
	})
	if err != nil || peerIndex != 42 {
		t.Fatalf("podInterfacePeerIndex = %d, %v; want 42, nil", peerIndex, err)
	}
	if !reflect.DeepEqual(setnsCalls, []int{20, -1, 10}) {
		t.Fatalf("setns/query order = %v; want enter pod, query link, restore host", setnsCalls)
	}
}

func TestPodInterfacePeerIndexFailsClosedWhenHostRestoreFails(t *testing.T) {
	var setnsCalls []int
	_, err := podInterfacePeerIndexWithOps(123, "eth0", namespaceOps{
		open: func(path string) (namespaceHandle, error) {
			if path == "/proc/self/ns/net" {
				return fakeNamespaceHandle{fd: 10}, nil
			}
			return fakeNamespaceHandle{fd: 20}, nil
		},
		setns: func(fd, _ int) error {
			setnsCalls = append(setnsCalls, fd)
			if fd == 10 {
				return errors.New("restore denied")
			}
			return nil
		},
		linkPeer: func(string) (int, error) { return 42, nil },
	})
	if err == nil || !strings.Contains(err.Error(), "restore host network namespace") {
		t.Fatalf("error = %v; want restoration failure", err)
	}
	if !reflect.DeepEqual(setnsCalls, []int{20, 10}) {
		t.Fatalf("setns calls = %v; want attempted host restore", setnsCalls)
	}
}

func TestAttachAndDetachUseOnlySentinelFilters(t *testing.T) {
	var calls [][]string
	tc := newTCDropFilter()
	tc.run = func(name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		return nil, nil
	}

	if err := tc.attachDrop("veth-target"); err != nil {
		t.Fatal(err)
	}
	if err := tc.attachDrop("veth-target"); err != nil {
		t.Fatal(err)
	}
	if err := tc.detachDrop("veth-target"); err != nil {
		t.Fatal(err)
	}

	joined := make([]string, 0, len(calls))
	for _, call := range calls {
		joined = append(joined, strings.Join(call, " "))
	}
	for _, call := range joined {
		if strings.Contains(call, "qdisc del") {
			t.Fatalf("detach removed shared clsact qdisc: %q", call)
		}
	}
	want := []string{
		"tc qdisc replace dev veth-target clsact",
		"tc filter replace dev veth-target pref 49152 protocol all ingress handle 1 matchall action drop",
		"tc filter replace dev veth-target pref 49153 protocol all egress handle 2 matchall action drop",
		"tc qdisc replace dev veth-target clsact",
		"tc filter replace dev veth-target pref 49152 protocol all ingress handle 1 matchall action drop",
		"tc filter replace dev veth-target pref 49153 protocol all egress handle 2 matchall action drop",
		"tc filter del dev veth-target pref 49152 protocol all ingress handle 1 matchall",
		"tc filter del dev veth-target pref 49153 protocol all egress handle 2 matchall",
	}
	if !reflect.DeepEqual(joined, want) {
		t.Fatalf("tc intent = %#v\nwant %#v", joined, want)
	}
}

func TestHasDropFilter(t *testing.T) {
	tc := newTCDropFilter()
	tc.run = func(name string, args ...string) ([]byte, error) {
		direction := args[len(args)-1]
		if direction == "ingress" {
			return []byte("filter protocol all pref 49152 matchall handle 0x1\n  action order 1: gact action drop\n"), nil
		}
		if direction == "egress" {
			return []byte("filter protocol all pref 49153 matchall handle 0x2\n  action order 1: gact action drop\n"), nil
		}
		return []byte(""), nil
	}

	ingress, egress, err := tc.hasDropFilter("veth-target")
	if err != nil || !ingress || !egress {
		t.Fatalf("hasDropFilter() = (%v, %v, %v); want (true, true, nil)", ingress, egress, err)
	}
}

func TestDetachMissingTCObjectsAreIgnored(t *testing.T) {
	tc := newTCDropFilter()
	tc.run = func(name string, args ...string) ([]byte, error) {
		return []byte("RTNETLINK answers: Cannot find device \"veth-gone\""), errors.New("cannot find")
	}

	if err := tc.detachDrop("veth-gone"); err != nil {
		t.Fatalf("detachDrop on missing object returned unexpected error: %v", err)
	}
}

// The W6 bug shape: after setns the sentinel read /sys/class/net/<if>/iflink.
// sysfs stays bound to the netns that mounted it (the node's, hostNetwork),
// so that read returned the NODE's eth0 iflink and no host veth ever matched.
// The pod link must come from a netlink socket created inside the pod netns.
func TestPeerIndexNeverConsultsSysfs(t *testing.T) {
	src, err := os.ReadFile("network.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, banned := range []string{"/sys/class/net", "iflink\")", "ops.readFile", "os.ReadFile(filepath.Join(\"/sys"} {
		if strings.Contains(string(src), banned) {
			t.Fatalf("network.go contains %q: the pod peer index must come from netlink inside the pod netns, never host sysfs", banned)
		}
	}
}

func TestPodInterfacePeerIndexRejectsNonPositivePeer(t *testing.T) {
	_, err := podInterfacePeerIndexWithOps(123, "eth0", namespaceOps{
		open:     func(string) (namespaceHandle, error) { return fakeNamespaceHandle{fd: 10}, nil },
		setns:    func(int, int) error { return nil },
		linkPeer: func(string) (int, error) { return 0, nil },
	})
	if err == nil || !strings.Contains(err.Error(), "invalid peer index") {
		t.Fatalf("error = %v; want invalid peer index", err)
	}
}

// rtmNewLink builds one RTM_NEWLINK reply for parseLinkPeer.
func rtmNewLink(index int32, name string, link int32, withLink bool) []byte {
	attr := func(typ uint16, payload []byte) []byte {
		l := unix.SizeofRtAttr + len(payload)
		b := make([]byte, (l+3)&^3)
		binary.NativeEndian.PutUint16(b[0:2], uint16(l))
		binary.NativeEndian.PutUint16(b[2:4], typ)
		copy(b[unix.SizeofRtAttr:], payload)
		return b
	}
	body := make([]byte, unix.SizeofIfInfomsg)
	binary.NativeEndian.PutUint32(body[4:8], uint32(index))
	body = append(body, attr(unix.IFLA_IFNAME, append([]byte(name), 0))...)
	if withLink {
		v := make([]byte, 4)
		binary.NativeEndian.PutUint32(v, uint32(link))
		body = append(body, attr(unix.IFLA_LINK, v)...)
	}
	hdr := make([]byte, unix.SizeofNlMsghdr)
	binary.NativeEndian.PutUint32(hdr[0:4], uint32(unix.SizeofNlMsghdr+len(body)))
	binary.NativeEndian.PutUint16(hdr[4:6], unix.RTM_NEWLINK)
	return append(hdr, body...)
}

func TestParseLinkPeer(t *testing.T) {
	if got, err := parseLinkPeer(rtmNewLink(3, "eth0", 1245, true)); err != nil || got != 1245 {
		t.Fatalf("veth reply: got %d, %v; want IFLA_LINK 1245", got, err)
	}
	// No IFLA_LINK: the kernel omits it when iflink == ifindex, the same
	// value sysfs iflink reports.
	if got, err := parseLinkPeer(rtmNewLink(1, "lo", 0, false)); err != nil || got != 1 {
		t.Fatalf("no IFLA_LINK: got %d, %v; want ifindex 1", got, err)
	}
	errMsg := make([]byte, unix.SizeofNlMsghdr+4)
	binary.NativeEndian.PutUint32(errMsg[0:4], uint32(len(errMsg)))
	binary.NativeEndian.PutUint16(errMsg[4:6], unix.NLMSG_ERROR)
	enodev := -int32(unix.ENODEV)
	binary.NativeEndian.PutUint32(errMsg[unix.SizeofNlMsghdr:], uint32(enodev))
	if _, err := parseLinkPeer(errMsg); err == nil || !strings.Contains(err.Error(), "no such device") {
		t.Fatalf("NLMSG_ERROR ENODEV: err = %v", err)
	}
}

// Real netlink round-trip in the test's own netns: lo's peer is itself.
func TestNetlinkLinkPeerLoopback(t *testing.T) {
	lo, err := net.InterfaceByName("lo")
	if err != nil {
		t.Skipf("no loopback interface visible: %v", err)
	}
	got, err := netlinkLinkPeer("lo")
	if err != nil {
		t.Fatalf("netlinkLinkPeer(lo): %v", err)
	}
	if got != lo.Index {
		t.Fatalf("netlinkLinkPeer(lo) = %d; want %d", got, lo.Index)
	}
	if _, err := netlinkLinkPeer("fixc-no-such-if0"); err == nil {
		t.Fatal("missing interface returned no error")
	}
}

// W6 re-stun: unstun leaves the shared clsact qdisc in place (by design), and
// iproute2 then refuses a second `qdisc add ... clsact` with "Exclusivity flag
// on, cannot modify" (exit 2) rather than "File exists". Treating that as fatal
// froze the pod but never re-attached the drop filter (53 s of retries).
// The fake answers `qdisc add` the way real tc does on that second attach.
func TestReattachAfterUnstunSurvivesExistingClsact(t *testing.T) {
	var calls []string
	tc := newTCDropFilter()
	tc.run = func(name string, args ...string) ([]byte, error) {
		call := strings.Join(append([]string{name}, args...), " ")
		calls = append(calls, call)
		if strings.HasPrefix(call, "tc qdisc add ") {
			return []byte("Error: Exclusivity flag on, cannot modify.\n"), errors.New("exit status 2")
		}
		return nil, nil
	}
	for i := 0; i < 2; i++ { // first stun, then re-stun after an unstun
		if err := tc.attachDrop("veth-target"); err != nil {
			t.Fatalf("attach %d: %v", i, err)
		}
		if i == 0 {
			if err := tc.detachDrop("veth-target"); err != nil {
				t.Fatal(err)
			}
		}
	}
	filters := 0
	for _, c := range calls {
		if strings.HasPrefix(c, "tc filter replace ") {
			filters++
		}
	}
	if filters != 4 {
		t.Fatalf("filter replaces = %d, want 4 (both directions, both attaches): %q", filters, calls)
	}
}
