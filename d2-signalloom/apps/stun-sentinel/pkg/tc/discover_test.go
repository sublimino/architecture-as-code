// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

type fakeNSHandle struct {
	fd     uintptr
	closed bool
}

func (f *fakeNSHandle) Fd() uintptr  { return f.fd }
func (f *fakeNSHandle) Close() error { f.closed = true; return nil }

type fakeNS struct {
	opened     []string
	setnsCalls []int
	setnsErrOn int // 1 == fail entering pod ns, 2 == fail restoring host ns
	openErr    map[string]error
	files      map[string]string
	readErr    error
	ifaces     []net.Interface
}

func (f *fakeNS) ops() NamespaceOps {
	return NamespaceOps{
		Open: func(p string) (NamespaceHandle, error) {
			f.opened = append(f.opened, p)
			if err, ok := f.openErr[p]; ok {
				return nil, err
			}
			return &fakeNSHandle{fd: uintptr(len(f.opened))}, nil
		},
		Setns: func(fd, nstype int) error {
			f.setnsCalls = append(f.setnsCalls, fd)
			if len(f.setnsCalls) == f.setnsErrOn {
				return syscall.EPERM
			}
			return nil
		},
		ReadFile: func(p string) ([]byte, error) {
			if f.readErr != nil {
				return nil, f.readErr
			}
			v, ok := f.files[p]
			if !ok {
				return nil, os.ErrNotExist
			}
			return []byte(v), nil
		},
		Interfaces: func() ([]net.Interface, error) { return f.ifaces, nil },
	}
}

func TestPeerIndexResolvesFromIflink(t *testing.T) {
	f := &fakeNS{
		files:  map[string]string{"/sys/class/net/eth0/iflink": "17\n"},
		ifaces: []net.Interface{{Index: 17, Name: "veth664d764"}},
	}
	d := NewDiscovererWithOps(f.ops())

	idx, err := d.PeerIndexForPID(4242)
	if err != nil {
		t.Fatalf("PeerIndexForPID: %v", err)
	}
	if idx != 17 {
		t.Errorf("peer index = %d, want 17", idx)
	}

	// Both namespaces must be opened, and setns must be called exactly twice
	// — in and back out. A missing restore leaves the OS thread inside the
	// container's network namespace.
	if len(f.setnsCalls) != 2 {
		t.Errorf("setns calls = %d, want 2 (enter pod ns, restore host ns)", len(f.setnsCalls))
	}
	joined := strings.Join(f.opened, " ")
	if !strings.Contains(joined, "/proc/self/ns/net") {
		t.Error("host namespace was never opened, so there is nothing to restore to")
	}
	if !strings.Contains(joined, "/proc/4242/ns/net") {
		t.Error("pod namespace for pid 4242 was never opened")
	}
}

func TestHostVethResolvedByExactPeerIndexNotName(t *testing.T) {
	// Three plausible veth names; only the index identifies the right one.
	// Resolving by name convention would pick the wrong container here.
	f := &fakeNS{
		files: map[string]string{"/sys/class/net/eth0/iflink": "19\n"},
		ifaces: []net.Interface{
			{Index: 17, Name: "veth664d764"},
			{Index: 18, Name: "veth9e2282f"},
			{Index: 19, Name: "veth2719e19"},
		},
	}
	d := NewDiscovererWithOps(f.ops())
	name, err := d.HostVethForPID(1)
	if err != nil {
		t.Fatalf("HostVethForPID: %v", err)
	}
	if name != "veth2719e19" {
		t.Errorf("resolved %q, want veth2719e19 (index 19)", name)
	}
}

func TestVanishedContainerYieldsInterfaceGone(t *testing.T) {
	f := &fakeNS{
		openErr: map[string]error{"/proc/9999/ns/net": os.ErrNotExist},
	}
	d := NewDiscovererWithOps(f.ops())
	_, err := d.PeerIndexForPID(9999)
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone — a container exiting mid-lookup is routine, not exceptional", err)
	}
}

func TestMissingPodInterfaceYieldsInterfaceGone(t *testing.T) {
	f := &fakeNS{files: map[string]string{}} // iflink read returns ErrNotExist
	d := NewDiscovererWithOps(f.ops())
	_, err := d.PeerIndexForPID(1)
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone", err)
	}
	// Critically: the host namespace must have been restored even though
	// the read failed. Returning early on a read error while still inside
	// the container's namespace is the thread-contamination bug.
	if len(f.setnsCalls) != 2 {
		t.Errorf("setns calls = %d, want 2 — the host namespace must be restored even on a read failure", len(f.setnsCalls))
	}
}

func TestFailedNamespaceRestoreIsReportedDistinctly(t *testing.T) {
	f := &fakeNS{
		files:      map[string]string{"/sys/class/net/eth0/iflink": "17\n"},
		setnsErrOn: 2, // the restore fails
	}
	d := NewDiscovererWithOps(f.ops())
	_, err := d.PeerIndexForPID(1)
	if err == nil {
		t.Fatal("expected an error when the host namespace restore fails")
	}
	if !strings.Contains(err.Error(), "restore host network namespace") {
		t.Errorf("error %q should name the restore failure so the abandoned thread is diagnosable", err)
	}
}

func TestEnterNamespacePermissionErrorIsDistinguishable(t *testing.T) {
	f := &fakeNS{
		files:      map[string]string{"/sys/class/net/eth0/iflink": "17\n"},
		setnsErrOn: 1,
	}
	d := NewDiscovererWithOps(f.ops())
	_, err := d.PeerIndexForPID(1)
	if !errors.Is(err, ErrPermission) {
		t.Fatalf("error = %v, want ErrPermission — the remedy is a securityContext change, not a retry", err)
	}
}

func TestInvalidIflinkIsRejected(t *testing.T) {
	for _, bad := range []string{"0\n", "-1\n", "not-a-number\n", "\n"} {
		f := &fakeNS{files: map[string]string{"/sys/class/net/eth0/iflink": bad}}
		d := NewDiscovererWithOps(f.ops())
		if _, err := d.PeerIndexForPID(1); err == nil {
			t.Errorf("iflink %q was accepted, want an error", strings.TrimSpace(bad))
		}
	}
}

func TestHostInterfaceForPeerReportsGoneWhenAbsent(t *testing.T) {
	_, err := HostInterfaceForPeer(99, []net.Interface{{Index: 1, Name: "lo"}})
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone", err)
	}
}

func TestLivePIDWalksIntoContainerChildCgroups(t *testing.T) {
	// The pod-level cgroup.procs is routinely EMPTY; the processes live in
	// per-container children. Reading only the top level finds nothing and
	// reports the pod as dead.
	root := t.TempDir()
	child := filepath.Join(root, "cri-containerd-abc123.scope")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "cgroup.procs"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(child, "cgroup.procs"), []byte("4242\n4243\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	pid, err := livePIDFromCgroupWith(root, func(p int) bool { return p == 4243 }, os.ReadFile)
	if err != nil {
		t.Fatalf("livePIDFromCgroup: %v", err)
	}
	if pid != 4243 {
		t.Errorf("pid = %d, want 4243 (the live one, skipping the dead 4242)", pid)
	}
}

func TestLivePIDReportsGoneWhenNoLiveProcess(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "cgroup.procs"), []byte("1\n2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := livePIDFromCgroupWith(root, func(int) bool { return false }, os.ReadFile)
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone", err)
	}
}

func TestLivePIDToleratesCgroupVanishingMidWalk(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "cgroup.procs"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A container exiting during the walk makes a read fail with ENOENT.
	// That must not abort the whole walk.
	read := func(p string) ([]byte, error) { return nil, os.ErrNotExist }
	_, err := livePIDFromCgroupWith(root, func(int) bool { return true }, read)
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone (walk completed, found nothing)", err)
	}
}
