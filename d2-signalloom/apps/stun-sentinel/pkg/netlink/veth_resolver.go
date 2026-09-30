// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package netlink resolves a container process to the HOST-SIDE veth peer that
// carries its traffic, using NETLINK_ROUTE queries only.
//
// Why not sysfs: /sys/class/net reflects the network namespace sysfs was
// MOUNTED in, not the namespace the calling thread has setns'd into. Reading
// /sys/class/net/eth0/iflink after entering a pod's netns therefore returns
// the HOST eth0's iflink, which resolves to the host NIC — exactly the device a
// drop filter must never be attached to. A netlink socket, by contrast, belongs
// to the netns of the thread that creates it, so an RTM_GETLINK issued on a
// thread inside the pod netns answers about the pod's interfaces (FIX-C).
//
// Resolution, with every hop verified rather than assumed:
//
//  1. enter /proc/<pid>/ns/net on a locked OS thread
//  2. RTM_GETLINK <pod iface> — read its ifindex and IFLA_LINK (the peer's
//     ifindex in the peer's namespace), and require the link type to be veth
//  3. restore the host netns (and abandon the thread if that fails)
//  4. RTM_GETLINK by index IFLA_LINK in the host netns — require type veth and
//     require ITS IFLA_LINK to point back at the pod iface's ifindex
//
// Step 4's back-reference check is what makes an index collision (the peer
// actually living in some other namespace) fail closed instead of silently
// resolving to an unrelated container's veth. The type checks stop ipvlan /
// macvlan pods, whose IFLA_LINK is the host's physical NIC, from ever
// resolving to that NIC.
package netlink

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	vnl "github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/tc"
)

const (
	// DefaultRetryTimeout bounds the wait for a starting container's network
	// to appear. Five seconds covers CNI setup on a loaded kind node without
	// letting a stun request hang on a pod that will never get a network.
	DefaultRetryTimeout = 5 * time.Second
	// DefaultRetryInterval is the pause between resolution attempts.
	DefaultRetryInterval = 100 * time.Millisecond

	linkTypeVeth = "veth"
)

var (
	// ErrVethNotFound means the pod interface or its host peer does not exist
	// (yet, or any more). It wraps tc.ErrInterfaceGone so callers on the tc
	// attach path treat it as the routine teardown race it usually is.
	ErrVethNotFound = fmt.Errorf("netlink: host veth not found: %w", tc.ErrInterfaceGone)
	// ErrProcessGone means the target PID exited before its netns was opened.
	ErrProcessGone = fmt.Errorf("netlink: target process gone: %w", tc.ErrInterfaceGone)
	// ErrNotVeth means a link on the path is not a veth. Never retried: the
	// pod's networking is not something a tc veth filter can isolate.
	ErrNotVeth = fmt.Errorf("netlink: link is not a veth pair: %w", tc.ErrNotVeth)
	// ErrPeerMismatch means the host link at IFLA_LINK does not point back at
	// the pod interface: an ifindex collision across namespaces.
	ErrPeerMismatch = errors.New("netlink: host link does not point back at pod interface")
	// ErrPermission means entering the target netns was refused. Almost always
	// a missing CAP_SYS_ADMIN / CAP_SYS_PTRACE on the DaemonSet.
	ErrPermission = errors.New("netlink: permission denied entering pod netns (need CAP_SYS_ADMIN and CAP_SYS_PTRACE)")
	// ErrThreadAbandoned means the host netns could not be restored; the OS
	// thread was discarded rather than returned to the Go scheduler.
	ErrThreadAbandoned = errors.New("netlink: failed to restore host netns, thread abandoned")
)

// LinkInfo is the subset of RTM_NEWLINK the resolver needs.
type LinkInfo struct {
	Index int
	Name  string
	Type  string
	// PeerIndex is IFLA_LINK: for a veth, the peer's ifindex in the peer's
	// namespace. Zero when the kernel reported none.
	PeerIndex int
}

// NSHandle is an open namespace file descriptor.
type NSHandle interface {
	Fd() uintptr
	Close() error
}

// Ops are the syscall and netlink boundaries, injected so resolution logic is
// unit-testable without root, a container, or a real network namespace.
type Ops struct {
	OpenNS func(path string) (NSHandle, error)
	Setns  func(fd int, nstype int) error
	// LinkByName queries the netns of the CALLING THREAD.
	LinkByName func(name string) (LinkInfo, error)
	// LinkByIndex queries the netns of the CALLING THREAD.
	LinkByIndex func(index int) (LinkInfo, error)
}

// DefaultOps returns the real kernel implementations. The package-level
// vishvananda functions open a fresh NETLINK_ROUTE socket per request, so the
// socket is created in whatever netns the locked thread is in at call time.
func DefaultOps() Ops {
	return Ops{
		OpenNS:      func(p string) (NSHandle, error) { return os.Open(p) },
		Setns:       unix.Setns,
		LinkByName:  func(n string) (LinkInfo, error) { return linkInfo(vnl.LinkByName(n)) },
		LinkByIndex: func(i int) (LinkInfo, error) { return linkInfo(vnl.LinkByIndex(i)) },
	}
}

func linkInfo(l vnl.Link, err error) (LinkInfo, error) {
	if err != nil {
		return LinkInfo{}, err
	}
	a := l.Attrs()
	// vishvananda decodes IFLA_LINK into LinkAttrs.ParentIndex.
	return LinkInfo{Index: a.Index, Name: a.Name, Type: l.Type(), PeerIndex: a.ParentIndex}, nil
}

// Result is a resolved container-to-host veth mapping.
type Result struct {
	PID          int
	PodInterface string
	PodIndex     int
	HostName     string
	HostIndex    int
	Attempts     int
}

// Resolver maps container processes to host veth links.
type Resolver struct {
	ops Ops

	// PodInterface is the interface name inside the container (eth0 unless
	// multus or a mesh renames it).
	PodInterface string
	// ProcRoot is where host PIDs are visible. /proc under hostPID.
	ProcRoot string
	// RetryTimeout bounds retries while a container's network comes up.
	RetryTimeout  time.Duration
	RetryInterval time.Duration
	// Debugf receives debug-level diagnostics (retries, teardown races).
	Debugf func(format string, args ...any)

	sleep func(time.Duration)
	now   func() time.Time
}

// NewResolver returns a Resolver wired to the real kernel.
func NewResolver() *Resolver { return NewResolverWithOps(DefaultOps()) }

// NewResolverWithOps returns a Resolver with injected boundaries.
func NewResolverWithOps(ops Ops) *Resolver {
	return &Resolver{
		ops:           ops,
		PodInterface:  "eth0",
		ProcRoot:      "/proc",
		RetryTimeout:  DefaultRetryTimeout,
		RetryInterval: DefaultRetryInterval,
		sleep:         time.Sleep,
		now:           time.Now,
	}
}

func (r *Resolver) debugf(format string, args ...any) {
	if r.Debugf != nil {
		r.Debugf(format, args...)
	}
}

// HostVethForPID returns the host-side veth name, ready for tc.Loader.Attach.
func (r *Resolver) HostVethForPID(pid int) (string, error) {
	res, err := r.Resolve(context.Background(), pid)
	if err != nil {
		return "", err
	}
	return res.HostName, nil
}

// HostVethForCgroup resolves via any live process beneath a pod cgroup.
func (r *Resolver) HostVethForCgroup(cgroupPath string) (string, error) {
	pid, err := tc.LivePIDFromCgroup(cgroupPath)
	if err != nil {
		return "", err
	}
	return r.HostVethForPID(pid)
}

// Resolve maps pid to its host veth, retrying only on "not there yet"
// (ErrVethNotFound) until RetryTimeout. A vanished process, a non-veth link,
// a peer mismatch or a permission failure is returned immediately: waiting
// cannot fix any of them.
func (r *Resolver) Resolve(ctx context.Context, pid int) (Result, error) {
	if pid <= 0 {
		return Result{}, fmt.Errorf("netlink: invalid pid %d", pid)
	}
	deadline := r.now().Add(r.RetryTimeout)
	var lastErr error
	for attempt := 1; ; attempt++ {
		res, err := r.resolveOnce(pid)
		if err == nil {
			res.Attempts = attempt
			return res, nil
		}
		lastErr = err
		if !errors.Is(err, ErrVethNotFound) {
			return Result{Attempts: attempt}, err
		}
		if !r.now().Add(r.RetryInterval).Before(deadline) {
			return Result{Attempts: attempt}, fmt.Errorf("failed to find host veth for container pid %d after %d attempts: %w", pid, attempt, lastErr)
		}
		r.debugf("netlink: veth for pid %d not ready (attempt %d): %v", pid, attempt, err)
		if ctx.Err() != nil {
			return Result{Attempts: attempt}, fmt.Errorf("failed to find host veth for container pid %d: %w (last: %v)", pid, ctx.Err(), lastErr)
		}
		r.sleep(r.RetryInterval)
	}
}

type podResult struct {
	link          LinkInfo
	restoreFailed bool
	err           error
}

func (r *Resolver) resolveOnce(pid int) (Result, error) {
	iface := r.PodInterface
	if iface == "" {
		iface = "eth0"
	}
	ch := make(chan podResult, 1)
	go func() {
		runtime.LockOSThread()
		link, restoreFailed, err := r.podLinkOnLockedThread(pid, iface)
		ch <- podResult{link: link, restoreFailed: restoreFailed, err: err}
		if !restoreFailed {
			runtime.UnlockOSThread()
		}
		// restoreFailed: exit still locked so the runtime destroys the
		// thread instead of reusing it inside the container's netns.
	}()
	pr := <-ch
	if pr.err != nil {
		return Result{}, pr.err
	}
	pod := pr.link
	if pod.Type != linkTypeVeth {
		return Result{}, fmt.Errorf("%w: pod %s is type %q", ErrNotVeth, iface, pod.Type)
	}
	if pod.PeerIndex <= 0 {
		return Result{}, fmt.Errorf("%w: pod %s has no IFLA_LINK", ErrVethNotFound, iface)
	}

	// Back in the host netns on this goroutine's (unlocked) thread: the
	// locked thread above restored it, and ordinary threads never left it.
	host, err := r.ops.LinkByIndex(pod.PeerIndex)
	if err != nil {
		if isNotFound(err) {
			return Result{}, fmt.Errorf("%w: no host link with index %d", ErrVethNotFound, pod.PeerIndex)
		}
		return Result{}, fmt.Errorf("netlink: RTM_GETLINK index %d in host netns: %w", pod.PeerIndex, err)
	}
	if host.Type != linkTypeVeth {
		return Result{}, fmt.Errorf("%w: host link %s (index %d) is type %q", ErrNotVeth, host.Name, host.Index, host.Type)
	}
	if host.PeerIndex != pod.Index {
		return Result{}, fmt.Errorf("%w: host %s IFLA_LINK=%d, pod %s index=%d", ErrPeerMismatch, host.Name, host.PeerIndex, iface, pod.Index)
	}
	return Result{
		PID:          pid,
		PodInterface: iface,
		PodIndex:     pod.Index,
		HostName:     host.Name,
		HostIndex:    host.Index,
	}, nil
}

func (r *Resolver) podLinkOnLockedThread(pid int, iface string) (link LinkInfo, restoreFailed bool, retErr error) {
	hostNS, err := r.ops.OpenNS("/proc/thread-self/ns/net")
	if err != nil {
		return LinkInfo{}, false, fmt.Errorf("netlink: open host netns: %w", err)
	}
	defer hostNS.Close()

	podNSPath := filepath.Join(r.ProcRoot, strconv.Itoa(pid), "ns/net")
	podNS, err := r.ops.OpenNS(podNSPath)
	if err != nil {
		switch {
		case isNotFound(err):
			return LinkInfo{}, false, fmt.Errorf("%w: pid %d", ErrProcessGone, pid)
		case isPermission(err):
			return LinkInfo{}, false, fmt.Errorf("%w: open %s: %v", ErrPermission, podNSPath, err)
		}
		return LinkInfo{}, false, fmt.Errorf("netlink: open %s: %w", podNSPath, err)
	}
	defer podNS.Close()

	if err := r.ops.Setns(int(podNS.Fd()), unix.CLONE_NEWNET); err != nil {
		if isPermission(err) {
			return LinkInfo{}, false, fmt.Errorf("%w: setns pid %d: %v", ErrPermission, pid, err)
		}
		return LinkInfo{}, false, fmt.Errorf("netlink: setns into pid %d netns: %w", pid, err)
	}

	// Query inside the pod netns, then ALWAYS restore before looking at the
	// query error: an early return here would leave the thread in the pod.
	link, queryErr := r.ops.LinkByName(iface)

	if err := r.ops.Setns(int(hostNS.Fd()), unix.CLONE_NEWNET); err != nil {
		return LinkInfo{}, true, fmt.Errorf("%w: %v", ErrThreadAbandoned, err)
	}
	if queryErr != nil {
		if isNotFound(queryErr) {
			return LinkInfo{}, false, fmt.Errorf("%w: %s not present in pid %d netns", ErrVethNotFound, iface, pid)
		}
		return LinkInfo{}, false, fmt.Errorf("netlink: RTM_GETLINK %s in pid %d netns: %w", iface, pid, queryErr)
	}
	return link, false, nil
}

// DropAttacher is the tc surface the resolver feeds. *tc.Loader satisfies it.
type DropAttacher interface {
	Attach(ifName string) error
}

// AttachDrop resolves pid's host veth and attaches the tc drop program to it
// (clsact ingress+egress, see tc.Loader.Attach). A container that exits
// mid-attach surfaces as an error wrapping tc.ErrInterfaceGone and is logged
// at debug level only: callers treat it as the teardown race, not a failure
// of containment tooling. The error is still returned — reporting "isolated"
// for a link that no longer exists would be a false containment claim.
func (r *Resolver) AttachDrop(ctx context.Context, a DropAttacher, pid int) (Result, error) {
	res, err := r.Resolve(ctx, pid)
	if err != nil {
		if errors.Is(err, tc.ErrInterfaceGone) {
			r.debugf("netlink: skip tc attach, pid %d network gone: %v", pid, err)
		}
		return res, err
	}
	if err := a.Attach(res.HostName); err != nil {
		if errors.Is(err, tc.ErrInterfaceGone) {
			r.debugf("netlink: tc attach raced teardown of %s: %v", res.HostName, err)
		}
		return res, fmt.Errorf("netlink: attach drop to %s: %w", res.HostName, err)
	}
	return res, nil
}

func isNotFound(err error) bool {
	var lnf vnl.LinkNotFoundError
	return errors.As(err, &lnf) ||
		errors.Is(err, os.ErrNotExist) ||
		errors.Is(err, syscall.ENOENT) ||
		errors.Is(err, syscall.ENODEV) ||
		errors.Is(err, syscall.ESRCH)
}

func isPermission(err error) bool {
	return errors.Is(err, os.ErrPermission) ||
		errors.Is(err, syscall.EPERM) ||
		errors.Is(err, syscall.EACCES)
}
