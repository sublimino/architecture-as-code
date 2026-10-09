// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
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

// tcMonitorObject is the compiled BPF ELF for the TC monitor program.
//
//go:embed tc_monitor.bpf.o
var tcMonitorObject []byte

// BPFMonitorObject returns a copy of the embedded monitor BPF object.
func BPFMonitorObject() []byte {
	out := make([]byte, len(tcMonitorObject))
	copy(out, tcMonitorObject)
	return out
}

// loadMonitorCollectionSpec parses the embedded ELF into an ebpf.CollectionSpec.
func loadMonitorCollectionSpec() (*ebpf.CollectionSpec, error) {
	if len(tcMonitorObject) == 0 {
		return nil, errors.New("embedded monitor BPF object is empty: run bpf/build.sh")
	}
	spec, err := ebpf.LoadCollectionSpecFromReader(bytes.NewReader(tcMonitorObject))
	if err != nil {
		return nil, fmt.Errorf("parse embedded monitor BPF ELF: %w", err)
	}
	return spec, nil
}

// Filter priority, handle, and filter name for the monitor program.
//
// Priorities are chosen from the free priority range identified by P1-PRE:
// SentinelIngressPref=49152 and SentinelEgressPref=49153 are reserved by stun_tc_drop.
// MonitorIngressPref=49150 and MonitorEgressPref=49151 are non-colliding and run
// prior to the containment drop filters, observing packet flows without interfering
// with drop verdicts.
const (
	MonitorIngressPref = 49150
	MonitorEgressPref  = 49151

	// MonitorHandle is distinct from stun_tc_drop's handle (1).
	MonitorHandle = 2

	// MonitorFilterName is distinct from stun_tc_drop's name ("stun_tc_drop")
	// so operators reading `tc filter show` see two distinct programs.
	MonitorFilterName = "tc_monitor"

	// DefaultMonitorPinPath is where the monitor maps are pinned.
	// Namespaced under /sys/fs/bpf/stun-sentinel/monitor so they do not
	// collide with stun_tc_drop's isolation maps under /sys/fs/bpf/stun-sentinel.
	DefaultMonitorPinPath = "/sys/fs/bpf/stun-sentinel/monitor"
)

// MonitorObjects holds the loaded monitor BPF programs and maps.
type MonitorObjects struct {
	Program          *ebpf.Program
	ProgramIngress   *ebpf.Program
	ProgramEgress    *ebpf.Program
	DNSEvents        *ebpf.Map
	TLSEvents        *ebpf.Map
	DNSDrops         *ebpf.Map
	TLSDrops         *ebpf.Map
	ParseStatusStats *ebpf.Map
	coll             *ebpf.Collection
}

// MonitorStats represents observable health and drop counters for the monitor.
type MonitorStats struct {
	DNSDrops         uint64
	TLSDrops         uint64
	ParseStatusStats [16]uint64
}

// MonitorLoader owns the BPF monitor objects and the set of interfaces it has attached to.
// It is safe for concurrent use.
type MonitorLoader struct {
	mu       sync.Mutex
	objs     *MonitorObjects
	attached map[int]string // ifindex -> interface name
	dryRun   bool

	// PinPath overrides DefaultMonitorPinPath. Set before Load.
	PinPath string

	// pinningDisabled records that the bpffs pin was unavailable.
	pinningDisabled bool

	// Injection seams for testing without a cluster.
	linkByName func(string) (netlink.Link, error)
	qdiscAdd   func(netlink.Qdisc) error
	filterAdd  func(netlink.Filter) error // FilterReplace: add-or-update, idempotent
	filterDel  func(netlink.Filter) error
	filterList func(netlink.Link, uint32) ([]netlink.Filter, error)
	now        func() time.Time
}

// NewMonitorLoader returns a MonitorLoader wired to the real kernel.
func NewMonitorLoader() *MonitorLoader {
	return &MonitorLoader{
		attached:   make(map[int]string),
		linkByName: netlink.LinkByName,
		qdiscAdd:   netlink.QdiscAdd,
		filterAdd:  netlink.FilterReplace,
		filterDel:  netlink.FilterDel,
		filterList: netlink.FilterList,
		now:        time.Now,
	}
}

// NewDryRunMonitorLoader returns a MonitorLoader that performs no kernel mutation.
func NewDryRunMonitorLoader() *MonitorLoader {
	l := NewMonitorLoader()
	l.dryRun = true
	return l
}

// Load reads the embedded monitor BPF object, sets the program type explicitly to
// ebpf.SchedCLS, and loads it into the kernel.
func (l *MonitorLoader) Load() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs != nil {
		return nil // idempotent
	}
	if l.dryRun {
		l.objs = &MonitorObjects{}
		return nil
	}

	if err := rlimit.RemoveMemlock(); err != nil {
		return fmt.Errorf("remove memlock rlimit: %w", err)
	}

	spec, err := loadMonitorCollectionSpec()
	if err != nil {
		return fmt.Errorf("load monitor BPF collection spec: %w", err)
	}

	// Pin the program type explicitly to SchedCLS.
	for _, prog := range spec.Programs {
		prog.Type = ebpf.SchedCLS
	}

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
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			return fmt.Errorf("BPF verifier rejected tc_monitor: %+v", ve)
		}
		return fmt.Errorf("create monitor BPF collection: %w", err)
	}

	prog, ok := coll.Programs["stun_tc_monitor"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no program named stun_tc_monitor")
	}
	progIngress := coll.Programs["stun_tc_monitor_ingress"]
	progEgress := coll.Programs["stun_tc_monitor_egress"]

	dnsEvents, ok := coll.Maps["dns_events"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named dns_events")
	}
	tlsEvents, ok := coll.Maps["tls_events"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named tls_events")
	}
	dnsDrops, ok := coll.Maps["dns_drops"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named dns_drops")
	}
	tlsDrops, ok := coll.Maps["tls_drops"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named tls_drops")
	}
	parseStats, ok := coll.Maps["parse_status_stats"]
	if !ok {
		coll.Close()
		return errors.New("BPF object has no map named parse_status_stats")
	}

	l.objs = &MonitorObjects{
		Program:          prog,
		ProgramIngress:   progIngress,
		ProgramEgress:    progEgress,
		DNSEvents:        dnsEvents,
		TLSEvents:        tlsEvents,
		DNSDrops:         dnsDrops,
		TLSDrops:         tlsDrops,
		ParseStatusStats: parseStats,
		coll:             coll,
	}
	return nil
}

// Attach creates the clsact qdisc (tolerating EEXIST) and attaches both ingress
// and egress monitor filters with priority MonitorIngressPref and MonitorEgressPref.
//
// Ingress and egress are attached together, and an egress failure rolls back the
// ingress attach.
func (l *MonitorLoader) Attach(ifName string) error {
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

	// clsact is shared infrastructure. Adding it when present returns EEXIST,
	// which is success; it is never removed on detach.
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

	ingress := l.bpfFilter(idx, netlink.HANDLE_MIN_INGRESS, MonitorIngressPref)
	if err := l.filterAdd(ingress); err != nil {
		if isPermission(err) {
			return fmt.Errorf("%w: adding ingress monitor filter to %s", ErrPermission, ifName)
		}
		return fmt.Errorf("add ingress monitor filter to %s: %w", ifName, err)
	}

	egress := l.bpfFilter(idx, netlink.HANDLE_MIN_EGRESS, MonitorEgressPref)
	if err := l.filterAdd(egress); err != nil {
		// Roll back the ingress filter on egress failure.
		if delErr := l.filterDel(ingress); delErr != nil {
			return fmt.Errorf("add egress monitor filter to %s: %w (ROLLBACK ALSO FAILED: %v)", ifName, err, delErr)
		}
		if isPermission(err) {
			return fmt.Errorf("%w: adding egress monitor filter to %s", ErrPermission, ifName)
		}
		return fmt.Errorf("add egress monitor filter to %s (ingress rolled back): %w", ifName, err)
	}

	l.attached[idx] = ifName
	return nil
}

func (l *MonitorLoader) bpfFilter(ifIndex int, parent uint32, pref uint16) *netlink.BpfFilter {
	return &netlink.BpfFilter{
		FilterAttrs: netlink.FilterAttrs{
			LinkIndex: ifIndex,
			Parent:    parent,
			Handle:    netlink.MakeHandle(0, MonitorHandle),
			Priority:  pref,
			Protocol:  protoAll,
		},
		Fd:           l.progFD(),
		Name:         MonitorFilterName,
		DirectAction: true, // program return value TC_ACT_OK passes packet unconditionally
	}
}

func (l *MonitorLoader) progFD() int {
	if l.objs == nil || l.objs.Program == nil {
		return -1
	}
	return l.objs.Program.FD()
}

// Detach removes both monitor filters (ingress and egress). The shared clsact qdisc
// and any existing containment filters (stun_tc_drop) are deliberately left untouched.
//
// Like Loader.Detach, Detach is fail-open: it attempts both removals and aggregates failures.
func (l *MonitorLoader) Detach(ifName string) error {
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
			// Interface vanished; filters went with it.
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
		{netlink.HANDLE_MIN_INGRESS, MonitorIngressPref, "ingress"},
		{netlink.HANDLE_MIN_EGRESS, MonitorEgressPref, "egress"},
	} {
		f := l.bpfFilter(idx, spec.parent, spec.pref)
		if err := l.filterDel(f); err != nil && !isNotFound(err) {
			problems = append(problems, fmt.Sprintf("%s: %v", spec.label, err))
		}
	}

	delete(l.attached, idx)
	if len(problems) > 0 {
		return fmt.Errorf("detach monitor %s completed with problems: %s", ifName, strings.Join(problems, "; "))
	}
	return nil
}

// DNSDrops returns the sum of all DNS ringbuffer drop counters across CPUs.
func (l *MonitorLoader) DNSDrops() (uint64, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs == nil || l.objs.DNSDrops == nil {
		return 0, errors.New("tc: Load must be called before DNSDrops")
	}
	return sumPerCPUMap(l.objs.DNSDrops, "dns_drops")
}

// TLSDrops returns the sum of all TLS ringbuffer drop counters across CPUs.
func (l *MonitorLoader) TLSDrops() (uint64, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.objs == nil || l.objs.TLSDrops == nil {
		return 0, errors.New("tc: Load must be called before TLSDrops")
	}
	return sumPerCPUMap(l.objs.TLSDrops, "tls_drops")
}

// ParseStatusStats reads per-status counts across CPUs.
func (l *MonitorLoader) ParseStatusStats() ([16]uint64, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out [16]uint64
	if l.objs == nil || l.objs.ParseStatusStats == nil {
		return out, errors.New("tc: Load must be called before ParseStatusStats")
	}
	for i := uint32(0); i < 16; i++ {
		var perCPU []uint64
		if err := l.objs.ParseStatusStats.Lookup(i, &perCPU); err != nil {
			return out, fmt.Errorf("read parse_status_stats[%d]: %w", i, err)
		}
		var sum uint64
		for _, v := range perCPU {
			sum += v
		}
		out[i] = sum
	}
	return out, nil
}

// Stats returns combined drop and parse status counts.
func (l *MonitorLoader) Stats() (MonitorStats, error) {
	var st MonitorStats
	dns, err := l.DNSDrops()
	if err != nil {
		return st, err
	}
	tls, err := l.TLSDrops()
	if err != nil {
		return st, err
	}
	parse, err := l.ParseStatusStats()
	if err != nil {
		return st, err
	}
	st.DNSDrops = dns
	st.TLSDrops = tls
	st.ParseStatusStats = parse
	return st, nil
}

func sumPerCPUMap(m *ebpf.Map, what string) (uint64, error) {
	var perCPU []uint64
	if err := m.Lookup(uint32(0), &perCPU); err != nil {
		return 0, fmt.Errorf("read %s counter: %w", what, err)
	}
	var total uint64
	for _, n := range perCPU {
		total += n
	}
	return total, nil
}

// Objects returns the loaded monitor BPF objects.
func (l *MonitorLoader) Objects() *MonitorObjects {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.objs
}

// AttachedInterfaces returns the list of interface names this MonitorLoader has filters on.
func (l *MonitorLoader) AttachedInterfaces() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	names := make([]string, 0, len(l.attached))
	for _, n := range l.attached {
		names = append(names, n)
	}
	return names
}

// Close releases all loaded monitor BPF objects.
func (l *MonitorLoader) Close() error {
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

// Pinned reports whether monitor maps are pinned to bpffs.
func (l *MonitorLoader) Pinned() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return !l.pinningDisabled && l.objs != nil
}

func (l *MonitorLoader) pinPath() string {
	path := l.PinPath
	if path == "" {
		path = DefaultMonitorPinPath
	}
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
