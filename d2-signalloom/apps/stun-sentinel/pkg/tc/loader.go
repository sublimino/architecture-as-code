// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package tc implements Tier 0 host-side network severance for stunned agent
// pods: an eBPF classifier attached to the clsact qdisc of a container's
// host-side veth peer, plus the conntrack invalidation that makes the drop
// stick for already-established flows.
//
// The package separates two lifetimes deliberately:
//
//	Attach/Detach   — loads the program, creates the qdisc and the two filters.
//	                  Expensive (verifier runs), done once per pod at adoption.
//	Isolate/Release — a single BPF map write. This is the stun critical path,
//	                  and it is a syscall, which is what makes the sub-100ms
//	                  severance budget honest rather than aspirational.
//
// Dropping packets alone does not sever an ESTABLISHED TCP session: the kernel
// keeps the conntrack entry and both peers keep retransmitting. Isolate
// therefore also deletes the matching conntrack tuples (see conntrack.go), so
// any segment that does arrive is treated as INVALID rather than as part of a
// live flow.
package tc

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/rlimit"
	"github.com/vishvananda/netlink"
)

// Sentinel errors. Callers distinguish these rather than matching on strings.
var (
	// ErrNotVeth is returned when the caller asks to attach to a device that
	// is not a container veth. This is the guard against the single most
	// destructive failure mode available to this package: attaching an
	// unconditional drop filter to eth0 or a bridge and cutting the node off
	// the network.
	ErrNotVeth = errors.New("tc: refusing to attach to non-veth interface")

	// ErrInterfaceGone is returned when the target interface disappeared,
	// which happens routinely when a container terminates during a lookup.
	// It is expected, not exceptional.
	ErrInterfaceGone = errors.New("tc: interface no longer exists")

	// ErrPermission indicates a missing capability, almost always
	// CAP_NET_ADMIN or CAP_BPF absent from the DaemonSet securityContext.
	ErrPermission = errors.New("tc: insufficient privileges (need CAP_NET_ADMIN and CAP_BPF)")

	// ErrNotAttached is returned by Isolate when the filter was never
	// attached for the interface. Isolating an unattached interface would
	// write a map entry no program reads — a silent no-op that reads as
	// success, which is exactly the failure this package must not have.
	ErrNotAttached = errors.New("tc: interface has no attached drop filter")
)

// Filter priority and handle. Chosen high (49152) so the Sentinel's filters sit
// after any CNI filter in the chain and cannot be mistaken for CNI state, and
// so they can be identified and removed by exact pref rather than by index.
// These deliberately match the values already used by the sibling
// signalloom-stun-sentinel daemon's iproute2 path so operators reading
// `tc filter show` see one consistent numbering scheme.
const (
	SentinelIngressPref = 49152
	SentinelEgressPref  = 49153
)

// vethPrefixes enumerates the host-side interface name prefixes that a
// container veth peer is permitted to have. This is an allowlist, not a
// denylist: an unrecognised device is refused. A denylist would have to
// enumerate every dangerous device name correctly forever, and would fail open
// the first time it missed one.
var vethPrefixes = []string{
	"veth",  // Docker, kind, generic
	"lxc",   // Cilium
	"cali",  // Calico
	"cni",   // some CNI plugins name the container end cniN
	"tap",   // KubeVirt / firecracker style workloads
	"eni",   // AWS VPC CNI
	"azv",   // Azure CNI
	"vethwe", // Weave
}

// deniedExact names devices that must never be targeted even if some future
// CNI adopts a matching prefix. Belt and braces over the allowlist above.
var deniedExact = []string{"eth0", "eth1", "lo", "docker0", "cni0", "br0", "virbr0"}

// IsolationState mirrors struct stun_isolation_val in bpf/tc_drop.bpf.c.
// Field order and widths are an ABI shared with the C source; changing either
// side alone silently corrupts every counter read.
type IsolationState struct {
	PacketsDropped uint64
	BytesDropped   uint64
	TargetIP       uint32 // network byte order
	Flags          uint32
}

// Stats is the userspace view of what a filter actually destroyed. It is the
// difference between "packets stopped" and "OUR PROGRAM stopped packets", and
// is the attribution evidence the BATS suite asserts on.
type Stats struct {
	Interface      string
	IfIndex        int
	PacketsDropped uint64
	BytesDropped   uint64
	Isolated       bool
}

// Objects holds the loaded BPF program and maps.
type Objects struct {
	Program     *ebpf.Program
	Isolation   *ebpf.Map
	IsolationIP *ebpf.Map
	coll        *ebpf.Collection
}

// DefaultPinPath is where the isolation maps are pinned. Anything under a
// bpffs mount works; this location is namespaced so the Sentinel's maps cannot
// collide with a CNI's.
const DefaultPinPath = "/sys/fs/bpf/stun-sentinel"

// Loader owns the BPF objects and the set of interfaces it has attached to.
// It is safe for concurrent use.
type Loader struct {
	mu       sync.Mutex
	objs     *Objects
	attached map[int]string // ifindex -> interface name
	dryRun   bool

	// PinPath overrides DefaultPinPath. Set before Load.
	PinPath string

	// pinningDisabled records that the bpffs pin was unavailable and the
	// maps are process-lifetime only. Surfaced through Pinned() so an
	// operator can tell the difference between "isolation survives a
	// restart" and "isolation does not", which is not otherwise observable.
	pinningDisabled bool

	// Injection seams. Tests replace these; production leaves them nil and
	// gets the real implementations. Keeping every kernel boundary
	// overridable is what makes this package testable without a cluster.
	linkByName  func(string) (netlink.Link, error)
	qdiscAdd    func(netlink.Qdisc) error
	filterAdd   func(netlink.Filter) error // FilterReplace: add-or-update, idempotent
	filterDel   func(netlink.Filter) error
	filterList  func(netlink.Link, uint32) ([]netlink.Filter, error)
	flushConn   func(net.IP) (int, error)
	now         func() time.Time
	observeDur  func(string, time.Duration)
	observeDrop func(string, uint64, uint64)
}

// NewLoader returns a Loader wired to the real kernel.
func NewLoader() *Loader {
	return &Loader{
		attached:   make(map[int]string),
		linkByName: netlink.LinkByName,
		qdiscAdd:   netlink.QdiscAdd,
		// FilterReplace, not FilterAdd. Attach is called again on every
		// isolate, and FilterAdd returns EEXIST the second time — which
		// made "isolate an already-attached interface" fail outright.
		// Replace is add-or-update, so attach is genuinely idempotent
		// (ISC-52/53) and matches the `tc filter replace` semantics the
		// sibling signalloom-stun-sentinel daemon already uses.
		filterAdd:  netlink.FilterReplace,
		filterDel:  netlink.FilterDel,
		filterList: netlink.FilterList,
		flushConn:  FlushIP,
		now:        time.Now,
	}
}

// NewDryRunLoader returns a Loader that performs no kernel mutation. Every
// method validates its arguments and returns the same errors a real run would,
// so a dry run exercises the guard logic (notably the veth allowlist) without
// touching the packet path.
func NewDryRunLoader() *Loader {
	l := NewLoader()
	l.dryRun = true
	return l
}

// SetMetricsHooks installs the Prometheus observers. Kept as an injection
// rather than an import so pkg/tc has no opinion about the metrics registry.
func (l *Loader) SetMetricsHooks(dur func(string, time.Duration), drop func(string, uint64, uint64)) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.observeDur = dur
	l.observeDrop = drop
}

// ValidateInterfaceName enforces the veth allowlist. Exported because it is a
// safety property worth asserting directly in tests, and because callers may
// want to reject a target before doing any other work.
func ValidateInterfaceName(name string) error {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return fmt.Errorf("%w: empty interface name", ErrNotVeth)
	}
	for _, denied := range deniedExact {
		if trimmed == denied {
			return fmt.Errorf("%w: %q is a host or bridge device", ErrNotVeth, trimmed)
		}
	}
	// Bridge devices frequently carry a generated suffix (br-f7f9142172f6).
	if strings.HasPrefix(trimmed, "br-") || strings.HasPrefix(trimmed, "docker") {
		return fmt.Errorf("%w: %q is a bridge device", ErrNotVeth, trimmed)
	}
	for _, prefix := range vethPrefixes {
		if strings.HasPrefix(trimmed, prefix) {
			return nil
		}
	}
	return fmt.Errorf("%w: %q matches no container veth prefix", ErrNotVeth, trimmed)
}

// Load reads the embedded BPF object, sets the program type explicitly and
// loads it into the kernel. The verifier runs here; a rejection surfaces as an
// error from this call and nowhere else.
func (l *Loader) Load() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs != nil {
		return nil // idempotent
	}
	if l.dryRun {
		l.objs = &Objects{}
		return nil
	}

	// BPF maps and programs are charged against RLIMIT_MEMLOCK on older
	// kernels. Removing it before load avoids an EPERM that looks like a
	// capability problem but is actually an accounting limit.
	if err := rlimit.RemoveMemlock(); err != nil {
		return fmt.Errorf("remove memlock rlimit: %w", err)
	}

	spec, err := loadCollectionSpec()
	if err != nil {
		return fmt.Errorf("load BPF collection spec: %w", err)
	}

	// Pin the program type explicitly rather than relying on the loader's
	// section-name heuristics. The card mandates SEC("classifier/drop");
	// setting the type here means the object keeps working even if a future
	// cilium/ebpf changes how it maps section prefixes.
	for _, prog := range spec.Programs {
		prog.Type = ebpf.SchedCLS
	}

	// The maps declare LIBBPF_PIN_BY_NAME so that isolation state survives a
	// Sentinel restart. That matters for a containment control: if the
	// daemon is OOM-killed while a hostile agent is severed, an unpinned map
	// is destroyed with it and the agent silently returns to the network.
	//
	// Pinning requires a bpffs mount. Where there is none, fall back to
	// unpinned maps rather than refusing to contain anything at all — a
	// Sentinel that will not start is strictly worse than one whose
	// isolation does not survive a restart. The fallback is loud.
	coll, err := ebpf.NewCollectionWithOptions(spec, ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{PinPath: l.pinPath()},
	})
	if err != nil {
		if isPinningProblem(err) {
			for _, m := range spec.Maps {
				m.Pinning = ebpf.PinNone
			}
			l.pinningDisabled = true
			coll, err = ebpf.NewCollection(spec)
		}
	}
	if err != nil {
		// A *ebpf.VerifierError stringifies to the full verifier log,
		// which is the single most useful diagnostic this package can
		// emit. Preserve it verbatim.
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			return fmt.Errorf("BPF verifier rejected tc_drop: %+v", ve)
		}
		return fmt.Errorf("create BPF collection: %w", err)
	}

	prog, ok := coll.Programs["stun_tc_drop"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no program named stun_tc_drop")
	}
	isoMap, ok := coll.Maps["stun_isolation_map"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named stun_isolation_map")
	}
	ipMap, ok := coll.Maps["stun_isolation_ip_map"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named stun_isolation_ip_map")
	}

	l.objs = &Objects{Program: prog, Isolation: isoMap, IsolationIP: ipMap, coll: coll}
	return nil
}

// Attach creates the clsact qdisc and both filters on the named interface.
//
// Ingress and egress are attached together and an egress failure rolls the
// ingress attach back, because a half-attached interface is worse than an
// unattached one: it drops replies while permitting exfiltration, and it reads
// as "isolated" in any check that only looks at one direction.
func (l *Loader) Attach(ifName string) error {
	if err := ValidateInterfaceName(ifName); err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs == nil {
		return errors.New("tc: Load must be called before Attach")
	}

	link, err := l.linkByName(ifName)
	if err != nil {
		if isNotFound(err) {
			return fmt.Errorf("%w: %s", ErrInterfaceGone, ifName)
		}
		return fmt.Errorf("look up interface %s: %w", ifName, err)
	}
	idx := link.Attrs().Index

	if l.dryRun {
		l.attached[idx] = ifName
		return nil
	}

	// clsact is shared infrastructure. Adding it when present returns
	// EEXIST, which is success for our purposes; it is never removed on
	// detach because another controller may be using it.
	qdisc := &netlink.GenericQdisc{
		QdiscAttrs: netlink.QdiscAttrs{
			LinkIndex: idx,
			Handle:    netlink.MakeHandle(0xffff, 0),
			Parent:    netlink.HANDLE_CLSACT,
		},
		QdiscType: "clsact",
	}
	if err := l.qdiscAdd(qdisc); err != nil && !isExist(err) {
		if isPermission(err) {
			return fmt.Errorf("%w: adding clsact to %s", ErrPermission, ifName)
		}
		return fmt.Errorf("add clsact qdisc to %s: %w", ifName, err)
	}

	ingress := l.bpfFilter(idx, netlink.HANDLE_MIN_INGRESS, SentinelIngressPref)
	if err := l.filterAdd(ingress); err != nil {
		if isPermission(err) {
			return fmt.Errorf("%w: adding ingress filter to %s", ErrPermission, ifName)
		}
		return fmt.Errorf("add ingress drop filter to %s: %w", ifName, err)
	}

	egress := l.bpfFilter(idx, netlink.HANDLE_MIN_EGRESS, SentinelEgressPref)
	if err := l.filterAdd(egress); err != nil {
		// Roll the ingress filter back so we never leave the interface
		// asymmetrically filtered.
		if delErr := l.filterDel(ingress); delErr != nil {
			return fmt.Errorf("add egress drop filter to %s: %w (ROLLBACK ALSO FAILED, interface is ingress-only filtered: %v)", ifName, err, delErr)
		}
		if isPermission(err) {
			return fmt.Errorf("%w: adding egress filter to %s", ErrPermission, ifName)
		}
		return fmt.Errorf("add egress drop filter to %s (ingress rolled back): %w", ifName, err)
	}

	l.attached[idx] = ifName
	return nil
}

func (l *Loader) bpfFilter(ifIndex int, parent uint32, pref uint16) *netlink.BpfFilter {
	return &netlink.BpfFilter{
		FilterAttrs: netlink.FilterAttrs{
			LinkIndex: ifIndex,
			Parent:    parent,
			Handle:    netlink.MakeHandle(0, 1),
			Priority:  pref,
			Protocol:  protoAll,
		},
		Fd:           l.progFD(),
		Name:         "stun_tc_drop",
		DirectAction: true, // program's return value IS the verdict
	}
}

// progFD returns the loaded program's file descriptor, or -1 when no program is
// loaded.
//
// In production Load() guarantees a non-nil Program before Attach can run, so
// the nil branch is unreachable there. It exists because the netlink boundary
// is injectable for test, and a bare l.objs.Program.FD() panics the moment a
// test drives Attach through a fake — which is exactly how this was found.
// Returning -1 rather than panicking also means a future refactor that reorders
// Load and Attach produces a netlink EBADF the caller can read, instead of a
// segfault in a daemon that is supposed to be containing a hostile workload.
func (l *Loader) progFD() int {
	if l.objs == nil || l.objs.Program == nil {
		return -1
	}
	return l.objs.Program.FD()
}

// Isolate severs the interface. This is the stun critical path.
//
// Order matters and is not arbitrary: the map write lands FIRST so that no
// further packets escape while conntrack is being flushed. Flushing first
// would open a window in which the flows are invalidated but traffic still
// flows, and TCP would simply re-establish them.
func (l *Loader) Isolate(ifName string, containerIP net.IP) (time.Duration, error) {
	if err := ValidateInterfaceName(ifName); err != nil {
		return 0, err
	}
	start := l.nowOrDefault()

	l.mu.Lock()
	if l.objs == nil {
		l.mu.Unlock()
		return 0, errors.New("tc: Load must be called before Isolate")
	}
	link, err := l.linkByName(ifName)
	if err != nil {
		l.mu.Unlock()
		if isNotFound(err) {
			// Container terminated mid-flight. Drop any map entry we
			// might have written for a recycled ifindex and report
			// the condition; the caller treats it as "already gone".
			return 0, fmt.Errorf("%w: %s", ErrInterfaceGone, ifName)
		}
		return 0, fmt.Errorf("look up interface %s: %w", ifName, err)
	}
	idx := link.Attrs().Index
	if _, ok := l.attached[idx]; !ok {
		l.mu.Unlock()
		return 0, fmt.Errorf("%w: %s", ErrNotAttached, ifName)
	}

	if l.dryRun {
		l.mu.Unlock()
		return l.nowOrDefault().Sub(start), nil
	}

	val := IsolationState{Flags: STUNDirIngress | STUNDirEgress}
	if ip4 := containerIP.To4(); ip4 != nil {
		val.TargetIP = beUint32(ip4)
	}

	key := uint32(idx)
	if err := l.objs.Isolation.Put(key, val); err != nil {
		l.mu.Unlock()
		return 0, fmt.Errorf("write isolation entry for %s (ifindex %d): %w", ifName, idx, err)
	}
	if val.TargetIP != 0 {
		if err := l.objs.IsolationIP.Put(val.TargetIP, val); err != nil {
			// Non-fatal: the ifindex path already severs the
			// interface. Report it but do not undo the severance —
			// failing closed is correct here.
			l.mu.Unlock()
			elapsed := l.nowOrDefault().Sub(start)
			return elapsed, fmt.Errorf("interface isolated but IP-keyed entry failed for %s: %w", containerIP, err)
		}
	}
	flush := l.flushConn
	l.mu.Unlock()

	// Conntrack flush happens outside the lock: it is the slow half and it
	// does not touch loader state.
	if containerIP != nil && flush != nil {
		if _, err := flush(containerIP); err != nil && !errors.Is(err, ErrNoConntrackEntries) {
			elapsed := l.nowOrDefault().Sub(start)
			return elapsed, fmt.Errorf("packets dropped for %s but conntrack flush failed: %w", ifName, err)
		}
	}

	elapsed := l.nowOrDefault().Sub(start)
	if l.observeDur != nil {
		l.observeDur(ifName, elapsed)
	}
	return elapsed, nil
}

// Release restores connectivity by deleting the isolation entries. The filters
// stay attached: an attached filter with no map entry is a no-op, and leaving
// it in place means a subsequent isolate is again just a map write.
//
// Release is fail-open and idempotent. Every step is attempted even if an
// earlier one failed, because a half-released interface is a production
// outage, and deleting an absent key is success.
func (l *Loader) Release(ifName string, containerIP net.IP) error {
	if err := ValidateInterfaceName(ifName); err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs == nil {
		return errors.New("tc: Load must be called before Release")
	}
	if l.dryRun {
		return nil
	}

	var problems []string

	if link, err := l.linkByName(ifName); err == nil {
		key := uint32(link.Attrs().Index)
		if err := l.objs.Isolation.Delete(key); err != nil && !errors.Is(err, ebpf.ErrKeyNotExist) {
			problems = append(problems, fmt.Sprintf("delete ifindex entry: %v", err))
		}
	} else if !isNotFound(err) {
		problems = append(problems, fmt.Sprintf("look up %s: %v", ifName, err))
	}

	if ip4 := containerIP.To4(); ip4 != nil {
		if err := l.objs.IsolationIP.Delete(beUint32(ip4)); err != nil && !errors.Is(err, ebpf.ErrKeyNotExist) {
			problems = append(problems, fmt.Sprintf("delete IP entry: %v", err))
		}
	}

	if len(problems) > 0 {
		return fmt.Errorf("release %s completed with problems: %s", ifName, strings.Join(problems, "; "))
	}
	return nil
}

// Detach removes both Sentinel filters. The clsact qdisc is deliberately left
// in place (see Attach).
//
// Like Release, Detach is fail-open: it attempts every removal and aggregates
// failures rather than returning at the first one.
func (l *Loader) Detach(ifName string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.dryRun {
		if link, err := l.linkByName(ifName); err == nil {
			delete(l.attached, link.Attrs().Index)
		}
		return nil
	}
	if l.objs == nil {
		return nil
	}

	link, err := l.linkByName(ifName)
	if err != nil {
		if isNotFound(err) {
			// Interface already gone: the filters went with it.
			return nil
		}
		return fmt.Errorf("look up interface %s: %w", ifName, err)
	}
	idx := link.Attrs().Index

	var problems []string
	for _, spec := range []struct {
		parent uint32
		pref   uint16
		label  string
	}{
		{netlink.HANDLE_MIN_INGRESS, SentinelIngressPref, "ingress"},
		{netlink.HANDLE_MIN_EGRESS, SentinelEgressPref, "egress"},
	} {
		f := l.bpfFilter(idx, spec.parent, spec.pref)
		if err := l.filterDel(f); err != nil && !isNotFound(err) {
			problems = append(problems, fmt.Sprintf("%s: %v", spec.label, err))
		}
	}

	delete(l.attached, idx)
	if len(problems) > 0 {
		return fmt.Errorf("detach %s completed with problems: %s", ifName, strings.Join(problems, "; "))
	}
	return nil
}

// Stats reads the drop counters back out of the BPF map. This is attribution
// evidence: it distinguishes "the packets stopped" from "our program stopped
// the packets", which no reachability probe can do.
func (l *Loader) Stats(ifName string) (Stats, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := Stats{Interface: ifName}
	if l.objs == nil {
		return out, errors.New("tc: Load must be called before Stats")
	}
	link, err := l.linkByName(ifName)
	if err != nil {
		if isNotFound(err) {
			return out, fmt.Errorf("%w: %s", ErrInterfaceGone, ifName)
		}
		return out, fmt.Errorf("look up interface %s: %w", ifName, err)
	}
	out.IfIndex = link.Attrs().Index
	if l.dryRun {
		return out, nil
	}

	var val IsolationState
	if err := l.objs.Isolation.Lookup(uint32(out.IfIndex), &val); err != nil {
		if errors.Is(err, ebpf.ErrKeyNotExist) {
			return out, nil // attached but not isolated
		}
		return out, fmt.Errorf("read isolation entry for %s: %w", ifName, err)
	}
	out.Isolated = true
	out.PacketsDropped = val.PacketsDropped
	out.BytesDropped = val.BytesDropped
	if l.observeDrop != nil {
		l.observeDrop(ifName, val.PacketsDropped, val.BytesDropped)
	}
	return out, nil
}

// AttachedInterfaces returns the interfaces this Loader has filters on.
func (l *Loader) AttachedInterfaces() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	names := make([]string, 0, len(l.attached))
	for _, n := range l.attached {
		names = append(names, n)
	}
	return names
}

// Close releases every kernel resource the Loader holds. Not calling it leaks
// BPF map and program file descriptors for the lifetime of the process, which
// on a long-running DaemonSet is a genuine kernel memory leak.
func (l *Loader) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs == nil {
		return nil
	}
	if l.objs.coll != nil {
		l.objs.coll.Close()
	}
	l.objs = nil
	l.attached = make(map[int]string)
	return nil
}

// pinPath resolves the bpffs directory for map pinning, creating it if the
// mount exists. Returns "" when pinning is not possible, which makes
// cilium/ebpf skip it.
func (l *Loader) pinPath() string {
	path := l.PinPath
	if path == "" {
		path = DefaultPinPath
	}
	// Only attempt to create the directory if the parent is actually a bpffs
	// mount. Creating it on a normal filesystem would "succeed" and then fail
	// obscurely at pin time.
	parent := filepath.Dir(path)
	var st syscall.Statfs_t
	if err := syscall.Statfs(parent, &st); err != nil {
		return ""
	}
	if st.Type != bpfFSMagic {
		return ""
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return ""
	}
	return path
}

// Pinned reports whether the isolation maps are pinned to bpffs, and therefore
// whether isolation would survive a restart of this process.
func (l *Loader) Pinned() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return !l.pinningDisabled && l.objs != nil
}

// bpfFSMagic is BPF_FS_MAGIC from linux/magic.h.
const bpfFSMagic = 0xcafe4a11

// isPinningProblem reports whether a collection-load failure was caused by map
// pinning rather than by the program itself. Only these are worth retrying
// unpinned; retrying a verifier rejection would just fail twice and bury the
// real diagnostic.
func isPinningProblem(err error) bool {
	if err == nil {
		return false
	}
	var ve *ebpf.VerifierError
	if errors.As(err, &ve) {
		return false
	}
	return containsAny(err.Error(),
		"MapOptions.PinPath",
		"pin by name",
		"pinning",
		"bpffs",
	)
}

func (l *Loader) nowOrDefault() time.Time {
	if l.now != nil {
		return l.now()
	}
	return time.Now()
}

// beUint32 converts a 4-byte IPv4 address to the host-order uint32 whose
// memory representation matches the network byte order the BPF program reads
// out of the IP header. Getting this backwards is a silent mismatch: the map
// write succeeds, the lookup never hits, and the interface reads as isolated
// while passing traffic.
func beUint32(ip4 net.IP) uint32 {
	return uint32(ip4[0]) | uint32(ip4[1])<<8 | uint32(ip4[2])<<16 | uint32(ip4[3])<<24
}

// Direction flags mirroring the C source.
const (
	STUNDirIngress uint32 = 1
	STUNDirEgress  uint32 = 2
)

const protoAll = 3 // htons(ETH_P_ALL)
