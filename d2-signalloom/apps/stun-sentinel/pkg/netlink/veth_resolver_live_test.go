// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netlink

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	vnl "github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

// TestNetlinkVethResolutionLiveKernel builds the exact topology a CNI builds —
// a veth pair with one end renamed eth0 inside a fresh netns, plus decoy veth
// pairs in the host ns — and resolves it with the REAL DefaultOps against the
// real kernel. It needs CAP_NET_ADMIN + CAP_SYS_ADMIN, so it runs only when
// STUN_SENTINEL_LIVE_NETLINK=1 (e.g. inside a privileged kind node container);
// the fake-kernel tests above cover the logic everywhere else.
func TestNetlinkVethResolutionLiveKernel(t *testing.T) {
	if os.Getenv("STUN_SENTINEL_LIVE_NETLINK") != "1" {
		t.Skip("set STUN_SENTINEL_LIVE_NETLINK=1 as root in a disposable netns host (kind node) to run")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	suffix := fmt.Sprintf("%04x", os.Getpid()&0xffff)
	hostName := "slh" + suffix
	peerName := "slp" + suffix

	// Decoys first so the target's host index is not simply "the newest".
	for i := 0; i < 2; i++ {
		decoy := &vnl.Veth{LinkAttrs: vnl.LinkAttrs{Name: fmt.Sprintf("sld%d%s", i, suffix)}, PeerName: fmt.Sprintf("sle%d%s", i, suffix)}
		if err := vnl.LinkAdd(decoy); err != nil {
			t.Fatalf("add decoy veth: %v", err)
		}
		name := decoy.Name
		t.Cleanup(func() {
			if l, err := vnl.LinkByName(name); err == nil {
				_ = vnl.LinkDel(l)
			}
		})
	}
	target := &vnl.Veth{LinkAttrs: vnl.LinkAttrs{Name: hostName}, PeerName: peerName}
	if err := vnl.LinkAdd(target); err != nil {
		t.Fatalf("add target veth: %v", err)
	}
	t.Cleanup(func() {
		if l, err := vnl.LinkByName(hostName); err == nil {
			_ = vnl.LinkDel(l)
		}
	})

	hostNS, err := os.Open("/proc/thread-self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	defer hostNS.Close()

	// Create the "pod" netns on this locked thread, keep a handle, go home.
	if err := unix.Unshare(unix.CLONE_NEWNET); err != nil {
		t.Fatalf("unshare netns: %v", err)
	}
	podNS, err := os.Open("/proc/thread-self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	defer podNS.Close()
	if err := unix.Setns(int(hostNS.Fd()), unix.CLONE_NEWNET); err != nil {
		t.Fatalf("restore host netns: %v", err)
	}

	peer, err := vnl.LinkByName(peerName)
	if err != nil {
		t.Fatal(err)
	}
	if err := vnl.LinkSetNsFd(peer, int(podNS.Fd())); err != nil {
		t.Fatalf("move peer into pod netns: %v", err)
	}
	// Rename to eth0 inside the pod ns — the same name the HOST's primary
	// interface usually has, which is what makes the sysfs approach lethal.
	if err := unix.Setns(int(podNS.Fd()), unix.CLONE_NEWNET); err != nil {
		t.Fatal(err)
	}
	renameErr := func() error {
		l, err := vnl.LinkByName(peerName)
		if err != nil {
			return err
		}
		return vnl.LinkSetName(l, "eth0")
	}()
	if err := unix.Setns(int(hostNS.Fd()), unix.CLONE_NEWNET); err != nil {
		t.Fatal(err)
	}
	if renameErr != nil {
		t.Fatalf("rename peer to eth0: %v", renameErr)
	}

	// Present the pod netns at <ProcRoot>/<pid>/ns/net, as hostPID does.
	procRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(procRoot, "4242", "ns"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), podNS.Fd()), filepath.Join(procRoot, "4242", "ns", "net")); err != nil {
		t.Fatal(err)
	}

	r := NewResolver()
	r.ProcRoot = procRoot
	res, err := r.Resolve(context.Background(), 4242)
	if err != nil {
		t.Fatalf("Resolve against real kernel: %v", err)
	}
	want, err := vnl.LinkByName(hostName)
	if err != nil {
		t.Fatal(err)
	}
	if res.HostName != hostName || res.HostIndex != want.Attrs().Index {
		t.Fatalf("resolved %s/%d, want %s/%d", res.HostName, res.HostIndex, hostName, want.Attrs().Index)
	}
	t.Logf("live kernel: pod eth0 ifindex=%d -> host %s ifindex=%d (attempts=%d)", res.PodIndex, res.HostName, res.HostIndex, res.Attempts)
}
