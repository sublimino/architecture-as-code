package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
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
		readFile: func(path string) ([]byte, error) {
			if path != "/sys/class/net/eth0/iflink" {
				t.Fatalf("iflink path = %q", path)
			}
			return []byte("42\n"), nil
		},
	})
	if err != nil || peerIndex != 42 {
		t.Fatalf("podInterfacePeerIndex = %d, %v; want 42, nil", peerIndex, err)
	}
	if !reflect.DeepEqual(setnsCalls, []int{20, 10}) {
		t.Fatalf("setns calls = %v; want enter pod then restore host", setnsCalls)
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
		readFile: func(string) ([]byte, error) { return []byte("42\n"), nil },
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
		if reflect.DeepEqual(args[:2], []string{"qdisc", "add"}) {
			return []byte("RTNETLINK answers: File exists"), errors.New("exists")
		}
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
		"tc qdisc add dev veth-target clsact",
		"tc filter replace dev veth-target pref 49152 protocol all ingress handle 1 matchall action drop",
		"tc filter replace dev veth-target pref 49153 protocol all egress handle 2 matchall action drop",
		"tc qdisc add dev veth-target clsact",
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
