// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"bytes"
	"debug/elf"
	"errors"
	"net"
	"strings"
	"syscall"
	"testing"

	"github.com/vishvananda/netlink"
)

// --- veth allowlist ---------------------------------------------------------
//
// This is the highest-consequence guard in the package. An unconditional drop
// filter on eth0 takes the node off the network, and there is no in-cluster
// recovery path from that. The test enumerates the dangerous names explicitly
// rather than trusting the prefix logic to be self-evidently correct.

func TestValidateInterfaceNameRefusesHostDevices(t *testing.T) {
	dangerous := []string{
		"eth0", "eth1", "lo", "docker0", "cni0", "br0", "virbr0",
		"br-f7f9142172f6", "docker1", "ens5", "enp0s3", "wlan0", "bond0", "",
		"  ", "tunl0", "flannel.1",
	}
	for _, name := range dangerous {
		t.Run("refuse/"+name, func(t *testing.T) {
			err := ValidateInterfaceName(name)
			if err == nil {
				t.Fatalf("ValidateInterfaceName(%q) returned nil — this device would be filtered and could take the node offline", name)
			}
			if !errors.Is(err, ErrNotVeth) {
				t.Errorf("error = %v, want ErrNotVeth", err)
			}
		})
	}
}

func TestValidateInterfaceNameAcceptsContainerVeths(t *testing.T) {
	ok := []string{
		"veth664d764", "veth9e2282f", "vethabc", "lxc1a2b3c", "cali0e7f",
		"eni8badf00d", "azv1234", "tap0", "vethwe-bridge",
	}
	for _, name := range ok {
		t.Run("accept/"+name, func(t *testing.T) {
			if err := ValidateInterfaceName(name); err != nil {
				t.Errorf("ValidateInterfaceName(%q) = %v, want nil", name, err)
			}
		})
	}
}

// --- fake netlink -----------------------------------------------------------

type fakeLink struct{ attrs netlink.LinkAttrs }

func (f *fakeLink) Attrs() *netlink.LinkAttrs { return &f.attrs }
func (f *fakeLink) Type() string              { return "veth" }

type fakeNetlink struct {
	links       map[string]int
	qdiscAdds   int
	filterAdds  []netlink.Filter
	filterDels  []netlink.Filter
	qdiscErr    error
	filterErrOn int // 1 == fail ingress, 2 == fail egress, 0 == never
	filterCalls int
	delErr      error
}

func (f *fakeNetlink) linkByName(name string) (netlink.Link, error) {
	idx, ok := f.links[name]
	if !ok {
		return nil, syscall.ENODEV
	}
	return &fakeLink{attrs: netlink.LinkAttrs{Index: idx, Name: name}}, nil
}

func (f *fakeNetlink) qdiscAdd(q netlink.Qdisc) error {
	if f.qdiscErr != nil {
		return f.qdiscErr
	}
	f.qdiscAdds++
	return nil
}

func (f *fakeNetlink) filterAdd(filt netlink.Filter) error {
	f.filterCalls++
	if f.filterErrOn == f.filterCalls {
		return errors.New("synthetic filter add failure")
	}
	f.filterAdds = append(f.filterAdds, filt)
	return nil
}

func (f *fakeNetlink) filterDel(filt netlink.Filter) error {
	if f.delErr != nil {
		return f.delErr
	}
	f.filterDels = append(f.filterDels, filt)
	return nil
}

// wireFake builds a Loader with kernel boundaries replaced, and a non-nil objs
// so Attach proceeds past its Load check. objs.Program stays nil; Loader.progFD
// returns -1 for that case. An earlier version of this comment claimed the fake
// never touched Program — it did, via bpfFilter, and the resulting segfault is
// what prompted progFD to exist.
func wireFake(fn *fakeNetlink) *Loader {
	l := NewLoader()
	l.linkByName = fn.linkByName
	l.qdiscAdd = fn.qdiscAdd
	l.filterAdd = fn.filterAdd
	l.filterDel = fn.filterDel
	l.objs = &Objects{}
	l.flushConn = func(net.IP) (int, error) { return 0, ErrNoConntrackEntries }
	return l
}

func TestAttachAddsQdiscAndBothFilters(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	l := wireFake(fn)

	if err := l.Attach("veth123"); err != nil {
		t.Fatalf("Attach: %v", err)
	}
	if fn.qdiscAdds != 1 {
		t.Errorf("qdisc adds = %d, want 1", fn.qdiscAdds)
	}
	if len(fn.filterAdds) != 2 {
		t.Fatalf("filter adds = %d, want 2 (ingress AND egress)", len(fn.filterAdds))
	}

	// ISC-56: both directions, in one operation. An ingress-only attach
	// drops replies while permitting exfiltration and still reads as
	// "filtered" to any one-sided check.
	var sawIngress, sawEgress bool
	for _, f := range fn.filterAdds {
		switch f.Attrs().Parent {
		case netlink.HANDLE_MIN_INGRESS:
			sawIngress = true
			if f.Attrs().Priority != SentinelIngressPref {
				t.Errorf("ingress pref = %d, want %d", f.Attrs().Priority, SentinelIngressPref)
			}
		case netlink.HANDLE_MIN_EGRESS:
			sawEgress = true
			if f.Attrs().Priority != SentinelEgressPref {
				t.Errorf("egress pref = %d, want %d", f.Attrs().Priority, SentinelEgressPref)
			}
		}
	}
	if !sawIngress {
		t.Error("no ingress filter attached")
	}
	if !sawEgress {
		t.Error("no egress filter attached — traffic could still leave the container")
	}
}

func TestAttachToleratesExistingQdisc(t *testing.T) {
	// clsact is shared infrastructure; EEXIST is the normal case on any
	// interface a CNI has already touched.
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}, qdiscErr: syscall.EEXIST}
	l := wireFake(fn)
	if err := l.Attach("veth123"); err != nil {
		t.Fatalf("Attach with existing clsact: %v", err)
	}
	if len(fn.filterAdds) != 2 {
		t.Errorf("filter adds = %d, want 2", len(fn.filterAdds))
	}
}

func TestAttachIsIdempotent(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	l := wireFake(fn)
	if err := l.Attach("veth123"); err != nil {
		t.Fatalf("first Attach: %v", err)
	}
	if err := l.Attach("veth123"); err != nil {
		t.Fatalf("second Attach must be a no-op error-wise, got: %v", err)
	}
	if got := len(l.AttachedInterfaces()); got != 1 {
		t.Errorf("attached interfaces = %d, want 1 (not duplicated)", got)
	}
}

func TestAttachRollsBackIngressWhenEgressFails(t *testing.T) {
	// The asymmetric-attach failure mode named on the card. If egress fails
	// and ingress is left in place, the pod drops its replies while its
	// outbound traffic continues — the worst of both states.
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}, filterErrOn: 2}
	l := wireFake(fn)

	err := l.Attach("veth123")
	if err == nil {
		t.Fatal("expected an error when the egress filter fails")
	}
	if len(fn.filterDels) != 1 {
		t.Fatalf("rollback deletes = %d, want 1 (the ingress filter must be removed)", len(fn.filterDels))
	}
	if fn.filterDels[0].Attrs().Parent != netlink.HANDLE_MIN_INGRESS {
		t.Error("rollback removed the wrong filter")
	}
	if len(l.AttachedInterfaces()) != 0 {
		t.Error("interface recorded as attached after a failed, rolled-back attach")
	}
}

func TestAttachRefusesNonVethBeforeAnySyscall(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"eth0": 2}}
	l := wireFake(fn)

	err := l.Attach("eth0")
	if !errors.Is(err, ErrNotVeth) {
		t.Fatalf("error = %v, want ErrNotVeth", err)
	}
	// ISC-63: refused means NOTHING was attached, not "attached then undone".
	if fn.qdiscAdds != 0 {
		t.Errorf("qdisc adds = %d, want 0 — the guard must fire before any kernel call", fn.qdiscAdds)
	}
	if len(fn.filterAdds) != 0 {
		t.Errorf("filter adds = %d, want 0", len(fn.filterAdds))
	}
}

func TestAttachHandlesVanishedInterface(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{}}
	l := wireFake(fn)
	err := l.Attach("veth-gone")
	if !errors.Is(err, ErrInterfaceGone) {
		t.Fatalf("error = %v, want ErrInterfaceGone (container terminated mid-lookup is routine)", err)
	}
}

func TestIsolateRefusesUnattachedInterface(t *testing.T) {
	// Writing a map entry for an interface with no attached program is a
	// silent no-op that reads as a successful isolation. It must be an error.
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	l := wireFake(fn)
	_, err := l.Isolate("veth123", net.IPv4(10, 244, 0, 7))
	if !errors.Is(err, ErrNotAttached) {
		t.Fatalf("error = %v, want ErrNotAttached", err)
	}
}

func TestDetachRemovesFiltersButNotQdisc(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}}
	l := wireFake(fn)
	if err := l.Attach("veth123"); err != nil {
		t.Fatalf("Attach: %v", err)
	}
	if err := l.Detach("veth123"); err != nil {
		t.Fatalf("Detach: %v", err)
	}
	if len(fn.filterDels) != 2 {
		t.Errorf("filter deletes = %d, want 2", len(fn.filterDels))
	}
	if len(l.AttachedInterfaces()) != 0 {
		t.Error("interface still recorded as attached after Detach")
	}
	// ISC-72: the qdisc is shared and must survive. There is no qdiscDel
	// seam on the Loader at all, which is the structural guarantee; this
	// assertion pins the intent so a future refactor cannot quietly add one.
	if fn.qdiscAdds != 1 {
		t.Errorf("qdisc adds = %d, want 1 and no removal", fn.qdiscAdds)
	}
}

func TestDetachOfVanishedInterfaceIsNotAnError(t *testing.T) {
	fn := &fakeNetlink{links: map[string]int{}}
	l := wireFake(fn)
	if err := l.Detach("veth-gone"); err != nil {
		t.Fatalf("Detach of a vanished interface = %v, want nil (the filters went with it)", err)
	}
}

func TestDetachAggregatesFailuresRatherThanStopping(t *testing.T) {
	// Fail-open: a stuck filter is a production outage, so every removal is
	// attempted even after one fails.
	fn := &fakeNetlink{links: map[string]int{"veth123": 17}, delErr: errors.New("synthetic del failure")}
	l := wireFake(fn)
	_ = l.Attach("veth123")
	err := l.Detach("veth123")
	if err == nil {
		t.Fatal("expected an aggregated error")
	}
	if !strings.Contains(err.Error(), "ingress") || !strings.Contains(err.Error(), "egress") {
		t.Errorf("error %q should name BOTH directions, proving both were attempted", err)
	}
}

// --- dry run ----------------------------------------------------------------

func TestDryRunMutatesNothingButStillValidates(t *testing.T) {
	l := NewDryRunLoader()
	defer l.Close()
	if err := l.Load(); err != nil {
		t.Fatalf("dry-run Load: %v", err)
	}
	// The safety guard must still fire in dry run, otherwise a dry run
	// reports success for a command that would take the node offline.
	if err := l.Attach("eth0"); !errors.Is(err, ErrNotVeth) {
		t.Errorf("dry-run Attach(eth0) = %v, want ErrNotVeth", err)
	}
}

// --- embedded artifact ------------------------------------------------------

func TestEmbeddedObjectIsAValidBPFELF(t *testing.T) {
	obj := BPFObject()
	if len(obj) == 0 {
		t.Fatal("embedded BPF object is empty — run bpf/build.sh")
	}
	f, err := elf.NewFile(bytes.NewReader(obj))
	if err != nil {
		t.Fatalf("embedded object is not a valid ELF: %v", err)
	}
	if f.Machine != elf.EM_BPF {
		t.Errorf("ELF machine = %v, want EM_BPF", f.Machine)
	}

	var haveBTF, haveBTFExt, haveProg, haveMaps bool
	for _, s := range f.Sections {
		switch s.Name {
		case ".BTF":
			haveBTF = true
		case ".BTF.ext":
			haveBTFExt = true
		case "classifier/drop":
			haveProg = true
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
		t.Error(`missing "classifier/drop" section — the card mandates this exact section name`)
	}
	if !haveMaps {
		t.Error("missing .maps section")
	}
}

func TestCollectionSpecHasRequiredProgramsAndMaps(t *testing.T) {
	// Parsing the spec exercises the ELF reader without needing a kernel,
	// so this runs everywhere including unprivileged CI.
	spec, err := loadCollectionSpec()
	if err != nil {
		t.Fatalf("loadCollectionSpec: %v", err)
	}
	for _, name := range []string{"stun_tc_drop", "stun_tc_drop_ingress", "stun_tc_drop_egress"} {
		if _, ok := spec.Programs[name]; !ok {
			t.Errorf("missing program %q", name)
		}
	}
	for _, name := range []string{"stun_isolation_map", "stun_isolation_ip_map"} {
		if _, ok := spec.Maps[name]; !ok {
			t.Errorf("missing map %q", name)
		}
	}
}

// --- byte-order -------------------------------------------------------------

func TestBEUint32MatchesPacketByteOrder(t *testing.T) {
	// The BPF program reads ip->saddr straight out of the packet, so it sees
	// 10.244.0.7 as the little-endian uint32 0x0700f40a. Encoding it the
	// other way round is a silent miss: the map write succeeds, the lookup
	// never matches, and the interface reads as isolated while passing
	// traffic.
	got := beUint32(net.IPv4(10, 244, 0, 7).To4())
	const want = uint32(0x0700f40a)
	if got != want {
		t.Errorf("beUint32(10.244.0.7) = 0x%08x, want 0x%08x", got, want)
	}
}

func TestErrorClassifiers(t *testing.T) {
	if !isNotFound(syscall.ENODEV) {
		t.Error("ENODEV should classify as not-found")
	}
	if !isNotFound(syscall.ENOENT) {
		t.Error("ENOENT should classify as not-found")
	}
	if !isExist(syscall.EEXIST) {
		t.Error("EEXIST should classify as exists")
	}
	if !isPermission(syscall.EPERM) {
		t.Error("EPERM should classify as permission")
	}
	if isNotFound(nil) || isExist(nil) || isPermission(nil) {
		t.Error("nil must not classify as any error condition")
	}
	if isPermission(syscall.ENODEV) {
		t.Error("ENODEV must not classify as a permission problem — the remedies differ entirely")
	}
}
