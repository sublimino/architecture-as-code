// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netlink

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	vnl "github.com/vishvananda/netlink"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/tc"
)

// --- fakes ------------------------------------------------------------------

type fakeHandle struct{ fd uintptr }

func (f *fakeHandle) Fd() uintptr  { return f.fd }
func (f *fakeHandle) Close() error { return nil }

// fakeKernel models two netns: the host (fd 1) and one pod (fd 2). Queries
// answer from whichever namespace the "thread" is currently in, so a resolver
// that forgets to setns, or forgets to restore, gets the wrong answer.
type fakeKernel struct {
	opened     []string
	setns      []int
	current    int // 1 host, 2 pod
	openErr    map[string]error
	setnsErrOn int   // fail the Nth setns call
	setnsErr   error // defaults to EINVAL

	hostLinks map[int]LinkInfo
	podLinks  map[string]LinkInfo
	// podMissingFor makes LinkByName in the pod ns fail with ENODEV for the
	// first N calls, modelling CNI setup still in progress.
	podMissingFor int
	podCalls      int
	podQueryErr   error
}

func newFakeKernel() *fakeKernel {
	return &fakeKernel{
		current: 1,
		hostLinks: map[int]LinkInfo{
			2:  {Index: 2, Name: "eth0", Type: "device"},
			17: {Index: 17, Name: "veth664d764", Type: "veth", PeerIndex: 2},
			18: {Index: 18, Name: "veth9e2282f", Type: "veth", PeerIndex: 2},
			19: {Index: 19, Name: "veth2719e19", Type: "veth", PeerIndex: 2},
		},
		// Pod eth0 is ifindex 2 in its own ns — the SAME number as the host
		// eth0, as it is on every real node. Only IFLA_LINK disambiguates.
		podLinks: map[string]LinkInfo{
			"eth0": {Index: 2, Name: "eth0", Type: "veth", PeerIndex: 19},
		},
	}
}

func (k *fakeKernel) ops() Ops {
	return Ops{
		OpenNS: func(p string) (NSHandle, error) {
			k.opened = append(k.opened, p)
			if err, ok := k.openErr[p]; ok {
				return nil, err
			}
			if p == "/proc/thread-self/ns/net" {
				return &fakeHandle{fd: 1}, nil
			}
			return &fakeHandle{fd: 2}, nil
		},
		Setns: func(fd, nstype int) error {
			k.setns = append(k.setns, fd)
			if len(k.setns) == k.setnsErrOn {
				if k.setnsErr != nil {
					return k.setnsErr
				}
				return syscall.EINVAL
			}
			k.current = fd
			return nil
		},
		LinkByName: func(name string) (LinkInfo, error) {
			if k.current != 2 {
				// Querying the host ns by name "eth0" is the sysfs bug in
				// netlink clothing: it would find the HOST NIC.
				for _, l := range k.hostLinks {
					if l.Name == name {
						return l, nil
					}
				}
				return LinkInfo{}, vnl.LinkNotFoundError{}
			}
			k.podCalls++
			if k.podQueryErr != nil {
				return LinkInfo{}, k.podQueryErr
			}
			if k.podCalls <= k.podMissingFor {
				return LinkInfo{}, fmt.Errorf("link not found: %w", syscall.ENODEV)
			}
			l, ok := k.podLinks[name]
			if !ok {
				return LinkInfo{}, vnl.LinkNotFoundError{}
			}
			return l, nil
		},
		LinkByIndex: func(i int) (LinkInfo, error) {
			if k.current != 1 {
				return LinkInfo{}, errors.New("LinkByIndex called while still inside the pod netns")
			}
			l, ok := k.hostLinks[i]
			if !ok {
				return LinkInfo{}, vnl.LinkNotFoundError{}
			}
			return l, nil
		},
	}
}

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time        { return c.t }
func (c *fakeClock) sleep(d time.Duration) { c.t = c.t.Add(d) }
func withClock(r *Resolver, c *fakeClock) *Resolver {
	r.now, r.sleep = c.now, c.sleep
	return r
}

func newTestResolver(k *fakeKernel) (*Resolver, *fakeClock) {
	c := &fakeClock{t: time.Unix(1_700_000_000, 0)}
	return withClock(NewResolverWithOps(k.ops()), c), c
}

// --- TestNetlinkVethResolution ---------------------------------------------

func TestNetlinkVethResolution(t *testing.T) {
	k := newFakeKernel()
	r, _ := newTestResolver(k)

	res, err := r.Resolve(context.Background(), 4242)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if res.HostName != "veth2719e19" || res.HostIndex != 19 {
		t.Fatalf("resolved %s/%d, want veth2719e19/19 (IFLA_LINK of pod eth0)", res.HostName, res.HostIndex)
	}
	if res.PodIndex != 2 || res.PodInterface != "eth0" || res.PID != 4242 || res.Attempts != 1 {
		t.Errorf("unexpected result metadata: %+v", res)
	}
	// Entered the pod ns and came back: exactly two setns, ending on host.
	if got := fmt.Sprint(k.setns); got != "[2 1]" {
		t.Errorf("setns sequence = %s, want [2 1] (enter pod, restore host)", got)
	}
	joined := strings.Join(k.opened, " ")
	if !strings.Contains(joined, "/proc/4242/ns/net") {
		t.Errorf("pod netns never opened: %v", k.opened)
	}
	// thread-self, not self: after LockOSThread the host ns to restore is
	// THIS thread's, not the thread-group leader's.
	if !strings.Contains(joined, "/proc/thread-self/ns/net") {
		t.Errorf("host netns handle not taken from /proc/thread-self: %v", k.opened)
	}
	for _, p := range k.opened {
		if strings.HasPrefix(p, "/sys/") {
			t.Errorf("resolver touched sysfs (%s); sysfs reflects the mount netns, not the thread's", p)
		}
	}

	name, err := r.HostVethForPID(4242)
	if err != nil || name != "veth2719e19" {
		t.Errorf("HostVethForPID = %q, %v", name, err)
	}
}

func TestNetlinkVethResolutionRejectsBackReferenceMismatch(t *testing.T) {
	k := newFakeKernel()
	// Host veth 19 exists but its peer is some other ns's ifindex 7: an index
	// collision. Must fail closed, never attach to an unrelated container.
	k.hostLinks[19] = LinkInfo{Index: 19, Name: "veth2719e19", Type: "veth", PeerIndex: 7}
	r, _ := newTestResolver(k)
	_, err := r.Resolve(context.Background(), 1)
	if !errors.Is(err, ErrPeerMismatch) {
		t.Fatalf("err = %v, want ErrPeerMismatch", err)
	}
}

func TestNetlinkVethResolutionRejectsNonVeth(t *testing.T) {
	t.Run("pod side ipvlan pointing at host NIC", func(t *testing.T) {
		k := newFakeKernel()
		k.podLinks["eth0"] = LinkInfo{Index: 3, Name: "eth0", Type: "ipvlan", PeerIndex: 2}
		r, _ := newTestResolver(k)
		_, err := r.Resolve(context.Background(), 1)
		if !errors.Is(err, ErrNotVeth) || !errors.Is(err, tc.ErrNotVeth) {
			t.Fatalf("err = %v, want ErrNotVeth wrapping tc.ErrNotVeth", err)
		}
	})
	t.Run("host side resolves to physical NIC", func(t *testing.T) {
		k := newFakeKernel()
		k.podLinks["eth0"] = LinkInfo{Index: 5, Name: "eth0", Type: "veth", PeerIndex: 2}
		r, _ := newTestResolver(k)
		_, err := r.Resolve(context.Background(), 1)
		if !errors.Is(err, ErrNotVeth) {
			t.Fatalf("err = %v, want ErrNotVeth — host eth0 must never be a drop target", err)
		}
	})
}

func TestNetlinkVethResolutionRetriesWhileCNIStarting(t *testing.T) {
	k := newFakeKernel()
	k.podMissingFor = 3
	r, c := newTestResolver(k)
	var debug []string
	r.Debugf = func(f string, a ...any) { debug = append(debug, fmt.Sprintf(f, a...)) }
	start := c.t

	res, err := r.Resolve(context.Background(), 1)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if res.Attempts != 4 {
		t.Errorf("attempts = %d, want 4", res.Attempts)
	}
	if waited := c.t.Sub(start); waited != 3*DefaultRetryInterval {
		t.Errorf("waited %v, want %v", waited, 3*DefaultRetryInterval)
	}
	if len(debug) != 3 {
		t.Errorf("debug lines = %d, want 3", len(debug))
	}
	// Every attempt must still restore the host ns: 4 enters + 4 restores.
	if len(k.setns) != 8 {
		t.Errorf("setns calls = %d, want 8", len(k.setns))
	}
}

func TestNetlinkVethResolutionRetryBoundedAtFiveSeconds(t *testing.T) {
	k := newFakeKernel()
	k.podMissingFor = 1 << 30
	r, c := newTestResolver(k)
	start := c.t

	_, err := r.Resolve(context.Background(), 1)
	if err == nil {
		t.Fatal("expected failure when the interface never appears")
	}
	if !strings.Contains(err.Error(), "failed to find host veth for container pid 1") {
		t.Errorf("error lacks the operator diagnostic: %v", err)
	}
	if !errors.Is(err, tc.ErrInterfaceGone) {
		t.Errorf("err = %v, want tc.ErrInterfaceGone in chain", err)
	}
	if waited := c.t.Sub(start); waited > DefaultRetryTimeout {
		t.Errorf("retried for %v, must stop within %v", waited, DefaultRetryTimeout)
	}
	if waited := c.t.Sub(start); waited < DefaultRetryTimeout-2*DefaultRetryInterval {
		t.Errorf("gave up after %v, expected to use most of %v", waited, DefaultRetryTimeout)
	}
}

func TestNetlinkVethResolutionDoesNotRetryTerminalErrors(t *testing.T) {
	cases := map[string]struct {
		mutate func(*fakeKernel)
		want   error
	}{
		"process gone": {
			func(k *fakeKernel) { k.openErr = map[string]error{"/proc/1/ns/net": os.ErrNotExist} },
			ErrProcessGone,
		},
		"permission (missing SYS_PTRACE)": {
			func(k *fakeKernel) { k.openErr = map[string]error{"/proc/1/ns/net": os.ErrPermission} },
			ErrPermission,
		},
		"setns EPERM entering pod ns": {
			func(k *fakeKernel) { k.setnsErrOn, k.setnsErr = 1, syscall.EPERM },
			ErrPermission,
		},
		"restore failure abandons thread": {
			func(k *fakeKernel) { k.setnsErrOn = 2 },
			ErrThreadAbandoned,
		},
	}
	for name, tcase := range cases {
		t.Run(name, func(t *testing.T) {
			k := newFakeKernel()
			tcase.mutate(k)
			r, c := newTestResolver(k)
			start := c.t
			res, err := r.Resolve(context.Background(), 1)
			if !errors.Is(err, tcase.want) {
				t.Fatalf("err = %v, want %v", err, tcase.want)
			}
			if res.Attempts != 1 || c.t != start {
				t.Errorf("terminal error was retried (attempts=%d, waited=%v)", res.Attempts, c.t.Sub(start))
			}
		})
	}
}

func TestNetlinkVethResolutionRestoresHostNSOnQueryError(t *testing.T) {
	k := newFakeKernel()
	k.podQueryErr = syscall.EIO
	r, _ := newTestResolver(k)
	_, err := r.Resolve(context.Background(), 1)
	if err == nil || !errors.Is(err, syscall.EIO) {
		t.Fatalf("err = %v, want EIO", err)
	}
	if got := fmt.Sprint(k.setns); got != "[2 1]" {
		t.Errorf("setns = %s, want [2 1]: host ns must be restored even when the query fails", got)
	}
}

type fakeAttacher struct {
	got []string
	err error
}

func (f *fakeAttacher) Attach(n string) error { f.got = append(f.got, n); return f.err }

func TestNetlinkVethResolutionFeedsTCAttach(t *testing.T) {
	k := newFakeKernel()
	r, _ := newTestResolver(k)
	a := &fakeAttacher{}
	res, err := r.AttachDrop(context.Background(), a, 1)
	if err != nil {
		t.Fatalf("AttachDrop: %v", err)
	}
	if len(a.got) != 1 || a.got[0] != "veth2719e19" || res.HostName != "veth2719e19" {
		t.Errorf("attached to %v, want [veth2719e19]", a.got)
	}
	// The resolved name must pass the tc package's own veth allowlist.
	if err := tc.ValidateInterfaceName(res.HostName); err != nil {
		t.Errorf("resolved name rejected by tc allowlist: %v", err)
	}
}

func TestNetlinkVethResolutionTeardownRaceIsDebugOnly(t *testing.T) {
	k := newFakeKernel()
	r, _ := newTestResolver(k)
	var debug []string
	r.Debugf = func(f string, a ...any) { debug = append(debug, fmt.Sprintf(f, a...)) }
	a := &fakeAttacher{err: fmt.Errorf("%w: veth2719e19", tc.ErrInterfaceGone)}
	_, err := r.AttachDrop(context.Background(), a, 1)
	if !errors.Is(err, tc.ErrInterfaceGone) {
		t.Fatalf("err = %v, want tc.ErrInterfaceGone (reported, not swallowed)", err)
	}
	if len(debug) != 1 || !strings.Contains(debug[0], "raced teardown") {
		t.Errorf("teardown race not logged at debug: %v", debug)
	}
}
