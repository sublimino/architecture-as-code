// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"bytes"
	"debug/elf"
	"errors"
	"net"
	"os"
	"strings"
	"testing"

	"github.com/vishvananda/netlink"
)

// --- containment and monitor coexistence tests ------------------------------

func TestContainmentSurvivesMonitorAttach(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	dropLoader := wireFake(fn)
	monLoader := wireMonitorFake(fn)

	// 1. Attach stun_tc_drop containment loader.
	if err := dropLoader.Attach("veth123"); err != nil {
		t.Fatalf("dropLoader.Attach: %v", err)
	}
	if fn.qdiscAdds != 1 {
		t.Errorf("qdisc adds after dropLoader.Attach = %d, want 1", fn.qdiscAdds)
	}
	if len(fn.filterAdds) != 2 {
		t.Fatalf("filter adds after dropLoader.Attach = %d, want 2", len(fn.filterAdds))
	}

	// 2. Attach MonitorLoader to the SAME interface.
	if err := monLoader.Attach("veth123"); err != nil {
		t.Fatalf("monLoader.Attach: %v", err)
	}

	// 3. Assert qdiscAdds is still 1 (qdisc created once, tolerating monitor's EEXIST).
	if fn.qdiscAdds != 1 {
		t.Errorf("qdisc adds after monLoader.Attach = %d, want 1 (shared clsact qdisc)", fn.qdiscAdds)
	}

	// 4. Assert fn.filterAdds now contains four distinct filter specs.
	if len(fn.filterAdds) != 4 {
		t.Fatalf("total filter adds = %d, want 4 (2 stun_tc_drop + 2 monitor)", len(fn.filterAdds))
	}

	// 5. Assert distinct Priority, Handle, and Name fields for operational distinction in `tc filter show`.
	type filterRecord struct {
		parent   uint32
		pref     uint16
		handle   uint32
		name     string
		dirAct   bool
	}
	var recorded []filterRecord
	for _, f := range fn.filterAdds {
		bf, ok := f.(*netlink.BpfFilter)
		if !ok {
			t.Fatalf("filter is not *netlink.BpfFilter: %T", f)
		}
		recorded = append(recorded, filterRecord{
			parent: bf.Attrs().Parent,
			pref:   bf.Attrs().Priority,
			handle: bf.Attrs().Handle,
			name:   bf.Name,
			dirAct: bf.DirectAction,
		})
	}

	// Verify drop filters
	dropIngress := recorded[0]
	dropEgress := recorded[1]
	if dropIngress.pref != SentinelIngressPref || dropIngress.name != "stun_tc_drop" || dropIngress.handle != netlink.MakeHandle(0, 1) {
		t.Errorf("unexpected drop ingress filter: %+v", dropIngress)
	}
	if dropEgress.pref != SentinelEgressPref || dropEgress.name != "stun_tc_drop" || dropEgress.handle != netlink.MakeHandle(0, 1) {
		t.Errorf("unexpected drop egress filter: %+v", dropEgress)
	}

	// Verify monitor filters
	monIngress := recorded[2]
	monEgress := recorded[3]
	if monIngress.pref != MonitorIngressPref || monIngress.name != MonitorFilterName || monIngress.handle != netlink.MakeHandle(0, MonitorHandle) {
		t.Errorf("unexpected monitor ingress filter: %+v", monIngress)
	}
	if monEgress.pref != MonitorEgressPref || monEgress.name != MonitorFilterName || monEgress.handle != netlink.MakeHandle(0, MonitorHandle) {
		t.Errorf("unexpected monitor egress filter: %+v", monEgress)
	}

	// Ensure all DirectAction flags are true
	for i, r := range recorded {
		if !r.dirAct {
			t.Errorf("filter[%d] DirectAction is false, want true", i)
		}
	}

	// 6. Detach ONLY the monitor.
	if err := monLoader.Detach("veth123"); err != nil {
		t.Fatalf("monLoader.Detach: %v", err)
	}

	// 7. Assert fn.filterDels contains only the monitor's 2 filters.
	if len(fn.filterDels) != 2 {
		t.Fatalf("filter dels after monLoader.Detach = %d, want 2", len(fn.filterDels))
	}
	for _, f := range fn.filterDels {
		bf, ok := f.(*netlink.BpfFilter)
		if !ok {
			t.Fatalf("deleted filter is not *netlink.BpfFilter: %T", f)
		}
		if bf.Name != MonitorFilterName {
			t.Errorf("deleted filter name = %q, want %q (stun_tc_drop filter was touched!)", bf.Name, MonitorFilterName)
		}
		if bf.Attrs().Priority != MonitorIngressPref && bf.Attrs().Priority != MonitorEgressPref {
			t.Errorf("deleted filter pref = %d, want %d or %d", bf.Attrs().Priority, MonitorIngressPref, MonitorEgressPref)
		}
		if bf.Attrs().Handle != netlink.MakeHandle(0, MonitorHandle) {
			t.Errorf("deleted filter handle = %d, want %d", bf.Attrs().Handle, netlink.MakeHandle(0, MonitorHandle))
		}
	}

	// 8. Assert dropLoader still tracks interface as attached and dry-run Stats functions.
	dropAttached := dropLoader.AttachedInterfaces()
	if len(dropAttached) != 1 || dropAttached[0] != "veth123" {
		t.Errorf("dropLoader attached interfaces = %v, want [veth123]", dropAttached)
	}
	monAttached := monLoader.AttachedInterfaces()
	if len(monAttached) != 0 {
		t.Errorf("monLoader attached interfaces = %v, want []", monAttached)
	}

	dryDrop := NewDryRunLoader()
	dryDrop.linkByName = fn.linkByName
	if err := dryDrop.Load(); err != nil {
		t.Fatalf("dryDrop.Load: %v", err)
	}
	if err := dryDrop.Attach("veth123"); err != nil {
		t.Fatalf("dryDrop.Attach: %v", err)
	}
	stats, err := dryDrop.Stats("veth123")
	if err != nil {
		t.Fatalf("dryDrop.Stats: %v", err)
	}
	if stats.Interface != "veth123" || stats.IfIndex != 17 {
		t.Errorf("stats = %+v, want interface veth123 with ifindex 17", stats)
	}
}

func TestMonitorAttachIsIdempotent(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	ml := wireMonitorFake(fn)
	if err := ml.Attach("veth123"); err != nil {
		t.Fatalf("first Attach: %v", err)
	}
	if err := ml.Attach("veth123"); err != nil {
		t.Fatalf("second Attach must be a no-op error-wise, got: %v", err)
	}
	if got := len(ml.AttachedInterfaces()); got != 1 {
		t.Errorf("attached interfaces = %d, want 1", got)
	}
}

func TestMonitorAttachRollsBackIngressWhenEgressFails(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}, filterErrOn: 2}
	ml := wireMonitorFake(fn)

	err := ml.Attach("veth123")
	if err == nil {
		t.Fatal("expected an error when the egress filter fails")
	}
	if len(fn.filterDels) != 1 {
		t.Fatalf("rollback deletes = %d, want 1 (ingress monitor filter removed)", len(fn.filterDels))
	}
	delFilter := fn.filterDels[0].Attrs()
	if delFilter.Parent != netlink.HANDLE_MIN_INGRESS || delFilter.Priority != MonitorIngressPref {
		t.Errorf("rollback removed unexpected filter: %+v", delFilter)
	}
	if len(ml.AttachedInterfaces()) != 0 {
		t.Error("interface recorded as attached after rolled back attach")
	}
}

func TestMonitorAttachRefusesNonVethBeforeAnySyscall(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"eth0": 2}}
	ml := wireMonitorFake(fn)

	err := ml.Attach("eth0")
	if !errors.Is(err, ErrNotVeth) {
		t.Fatalf("error = %v, want ErrNotVeth", err)
	}
	if fn.qdiscAdds != 0 {
		t.Errorf("qdisc adds = %d, want 0", fn.qdiscAdds)
	}
	if len(fn.filterAdds) != 0 {
		t.Errorf("filter adds = %d, want 0", len(fn.filterAdds))
	}
}

func TestMonitorAttachHandlesVanishedInterface(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{}}
	ml := wireMonitorFake(fn)
	err := ml.Attach("veth-gone")
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone", err)
	}
}

func TestMonitorDetachRemovesFiltersButNotQdisc(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	ml := wireMonitorFake(fn)
	if err := ml.Attach("veth123"); err != nil {
		t.Fatalf("Attach: %v", err)
	}
	if err := ml.Detach("veth123"); err != nil {
		t.Fatalf("Detach: %v", err)
	}
	if len(fn.filterDels) != 2 {
		t.Errorf("filter deletes = %d, want 2", len(fn.filterDels))
	}
	if len(ml.AttachedInterfaces()) != 0 {
		t.Error("interface still recorded as attached after Detach")
	}
	if fn.qdiscAdds != 1 {
		t.Errorf("qdisc adds = %d, want 1 and no removal", fn.qdiscAdds)
	}
}

func TestMonitorDetachOfVanishedInterfaceIsNotAnError(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{}}
	ml := wireMonitorFake(fn)
	if err := ml.Detach("veth-gone"); err != nil {
		t.Fatalf("Detach of vanished interface = %v, want nil", err)
	}
}

func TestMonitorDetachAggregatesFailuresRatherThanStopping(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}, delErr: errors.New("synthetic del failure")}
	ml := wireMonitorFake(fn)
	_ = ml.Attach("veth123")
	err := ml.Detach("veth123")
	if err == nil {
		t.Fatal("expected an aggregated error")
	}
	if !strings.Contains(err.Error(), "ingress") || !strings.Contains(err.Error(), "egress") {
		t.Errorf("error %q should name BOTH directions", err)
	}
}

func TestMonitorDryRunMutatesNothingButStillValidates(t *testing.T) {
	ml := NewDryRunMonitorLoader()
	defer ml.Close()
	if err := ml.Load(); err != nil {
		t.Fatalf("dry-run Load: %v", err)
	}
	// The safety guard must still fire in dry run, otherwise a dry run
	// reports success for a command that would take the node offline.
	if err := ml.Attach("eth0"); !errors.Is(err, ErrNotVeth) {
		t.Errorf("dry-run Attach(eth0) = %v, want ErrNotVeth", err)
	}
}

func TestMonitorEmbeddedObjectIsAValidBPFELF(t *testing.T) {
	obj := BPFMonitorObject()
	if len(obj) == 0 {
		t.Fatal("embedded monitor BPF object is empty")
	}
	f, err := elf.NewFile(bytes.NewReader(obj))
	if err != nil {
		t.Fatalf("embedded monitor object is not a valid ELF: %v", err)
	}
	if f.Machine != elf.EM_BPF {
		t.Errorf("ELF machine = %v, want EM_BPF", f.Machine)
	}

	var haveBTF, haveBTFExt, haveProg, haveIngress, haveEgress, haveMaps bool
	for _, s := range f.Sections {
		switch s.Name {
		case ".BTF":
			haveBTF = true
		case ".BTF.ext":
			haveBTFExt = true
		case "classifier/monitor":
			haveProg = true
		case "classifier/monitor_ingress":
			haveIngress = true
		case "classifier/monitor_egress":
			haveEgress = true
		case ".maps":
			haveMaps = true
		}
	}
	if !haveBTF {
		t.Error("missing .BTF section")
	}
	if !haveBTFExt {
		t.Error("missing .BTF.ext section")
	}
	if !haveProg {
		t.Error("missing classifier/monitor section")
	}
	if !haveIngress {
		t.Error("missing classifier/monitor_ingress section")
	}
	if !haveEgress {
		t.Error("missing classifier/monitor_egress section")
	}
	if !haveMaps {
		t.Error("missing .maps section")
	}
}

func TestMonitorCollectionSpecHasRequiredProgramsAndMaps(t *testing.T) {
	spec, err := loadMonitorCollectionSpec()
	if err != nil {
		t.Fatalf("loadMonitorCollectionSpec: %v", err)
	}
	for _, name := range []string{"stun_tc_monitor", "stun_tc_monitor_ingress", "stun_tc_monitor_egress"} {
		if _, ok := spec.Programs[name]; !ok {
			t.Errorf("missing program %q in monitor collection spec", name)
		}
	}
	for _, name := range []string{"dns_events", "tls_events", "dns_drops", "tls_drops", "parse_status_stats"} {
		if _, ok := spec.Maps[name]; !ok {
			t.Errorf("missing map %q in monitor collection spec", name)
		}
	}
}

func TestMonitorFilterPropertiesDistinct(t *testing.T) {
	// Assert that monitor properties do not collide with stun_tc_drop properties.
	if MonitorIngressPref == SentinelIngressPref || MonitorIngressPref == SentinelEgressPref {
		t.Errorf("MonitorIngressPref (%d) collides with Sentinel drop prefs", MonitorIngressPref)
	}
	if MonitorEgressPref == SentinelIngressPref || MonitorEgressPref == SentinelEgressPref {
		t.Errorf("MonitorEgressPref (%d) collides with Sentinel drop prefs", MonitorEgressPref)
	}
	if MonitorFilterName == "stun_tc_drop" {
		t.Errorf("MonitorFilterName matches stun_tc_drop")
	}
	if MonitorHandle == 1 {
		t.Errorf("MonitorHandle (1) collides with stun_tc_drop handle (1)")
	}
	if DefaultMonitorPinPath == DefaultPinPath {
		t.Errorf("DefaultMonitorPinPath collides with DefaultPinPath")
	}
}

// --- Live kernel test (gated on root / CAP_NET_ADMIN) -----------------------

func TestLiveMonitorAndContainmentCoexistence(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("skipping live test: requires root / CAP_NET_ADMIN")
	}

	const hostIf = "veth_slwd_tst0"
	const peerIf = "veth_slwd_tst1"

	// Cleanup existing veth pair if present
	if l, err := netlink.LinkByName(hostIf); err == nil {
		_ = netlink.LinkDel(l)
	}

	veth := &netlink.Veth{
		LinkAttrs: netlink.LinkAttrs{Name: hostIf},
		PeerName:  peerIf,
	}
	if err := netlink.LinkAdd(veth); err != nil {
		t.Fatalf("create test veth pair: %v", err)
	}
	defer func() {
		if l, err := netlink.LinkByName(hostIf); err == nil {
			_ = netlink.LinkDel(l)
		}
	}()

	hostLink, err := netlink.LinkByName(hostIf)
	if err != nil {
		t.Fatalf("lookup host veth %s: %v", hostIf, err)
	}
	peerLink, err := netlink.LinkByName(peerIf)
	if err != nil {
		t.Fatalf("lookup peer veth %s: %v", peerIf, err)
	}
	_ = netlink.LinkSetUp(hostLink)
	_ = netlink.LinkSetUp(peerLink)

	dropLoader := NewLoader()
	defer dropLoader.Close()
	if err := dropLoader.Load(); err != nil {
		t.Fatalf("dropLoader.Load: %v", err)
	}

	monLoader := NewMonitorLoader()
	defer monLoader.Close()
	if err := monLoader.Load(); err != nil {
		t.Fatalf("monLoader.Load: %v", err)
	}

	// Attach dropLoader
	if err := dropLoader.Attach(hostIf); err != nil {
		t.Fatalf("dropLoader.Attach(%s): %v", hostIf, err)
	}

	// Attach monLoader
	if err := monLoader.Attach(hostIf); err != nil {
		t.Fatalf("monLoader.Attach(%s): %v", hostIf, err)
	}

	// Isolate via dropLoader
	targetIP := net.IPv4(10, 244, 1, 99)
	if _, err := dropLoader.Isolate(hostIf, targetIP); err != nil {
		t.Fatalf("dropLoader.Isolate: %v", err)
	}

	// Verify dropLoader stats show isolated
	stats, err := dropLoader.Stats(hostIf)
	if err != nil {
		t.Fatalf("dropLoader.Stats: %v", err)
	}
	if !stats.Isolated {
		t.Errorf("dropLoader.Stats(%s).Isolated = false, want true", hostIf)
	}

	// Detach monLoader
	if err := monLoader.Detach(hostIf); err != nil {
		t.Fatalf("monLoader.Detach: %v", err)
	}

	// Verify dropLoader stats STILL show isolated after monitor detach
	statsAfter, err := dropLoader.Stats(hostIf)
	if err != nil {
		t.Fatalf("dropLoader.Stats after monitor detach: %v", err)
	}
	if !statsAfter.Isolated {
		t.Errorf("dropLoader.Stats(%s).Isolated after monitor detach = false, want true", hostIf)
	}

	// Release isolation
	if err := dropLoader.Release(hostIf, targetIP); err != nil {
		t.Fatalf("dropLoader.Release: %v", err)
	}

	// Detach dropLoader
	if err := dropLoader.Detach(hostIf); err != nil {
		t.Fatalf("dropLoader.Detach: %v", err)
	}
}
