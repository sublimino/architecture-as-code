// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tests

import (
	"bytes"
	"debug/elf"
	"errors"
	"net"
	"os"
	"strings"
	"testing"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/rlimit"
)

func findMonitorObj(t *testing.T) string {
	t.Helper()
	candidates := []string{
		"../tc_monitor.bpf.o",
		"tc_monitor.bpf.o",
		"bpf/tc_monitor.bpf.o",
		"d2-signalloom/apps/stun-sentinel/bpf/tc_monitor.bpf.o",
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	t.Fatal("cannot find tc_monitor.bpf.o in candidate paths")
	return ""
}

func TestEmbeddedMonitorObjectIsAValidBPFELF(t *testing.T) {
	objPath := findMonitorObj(t)
	data, err := os.ReadFile(objPath)
	if err != nil {
		t.Fatalf("failed to read %s: %v", objPath, err)
	}
	f, err := elf.NewFile(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("tc_monitor.bpf.o is not a valid ELF: %v", err)
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
		case "classifier/monitor":
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
		t.Error(`missing "classifier/monitor" section`)
	}
	if !haveMaps {
		t.Error("missing .maps section")
	}
}

func TestCollectionSpecMonitorMapsAndPrograms(t *testing.T) {
	objPath := findMonitorObj(t)
	spec, err := ebpf.LoadCollectionSpec(objPath)
	if err != nil {
		t.Fatalf("LoadCollectionSpec: %v", err)
	}

	for _, name := range []string{"stun_tc_monitor", "stun_tc_monitor_ingress", "stun_tc_monitor_egress"} {
		p, ok := spec.Programs[name]
		if !ok {
			t.Errorf("missing program %q", name)
			continue
		}
		if p.Type != ebpf.SchedCLS {
			t.Errorf("%s: type = %v, want SchedCLS", name, p.Type)
		}
		if p.SectionName != "classifier/monitor" &&
			p.SectionName != "classifier/monitor_ingress" &&
			p.SectionName != "classifier/monitor_egress" {
			t.Errorf("%s: section = %q", name, p.SectionName)
		}
	}

	for _, name := range []string{"dns_events", "tls_events", "dns_drops", "tls_drops", "parse_status_stats"} {
		m, ok := spec.Maps[name]
		if !ok {
			t.Errorf("missing map %q", name)
			continue
		}
		if name == "dns_events" || name == "tls_events" {
			if m.Type != ebpf.RingBuf {
				t.Errorf("%s: type = %v, want RingBuf", name, m.Type)
			}
			if m.MaxEntries != (1 << 22) { // 4 MiB
				t.Errorf("%s: max_entries = %d, want %d (4 MiB)", name, m.MaxEntries, 1<<22)
			}
		}
	}
}

func TestVerifierAccepts(t *testing.T) {
	_ = rlimit.RemoveMemlock()
	objPath := findMonitorObj(t)
	spec, err := ebpf.LoadCollectionSpec(objPath)
	if err != nil {
		t.Fatalf("LoadCollectionSpec: %v", err)
	}

	opts := ebpf.CollectionOptions{
		Programs: ebpf.ProgramOptions{
			LogLevel: ebpf.LogLevelStats,
		},
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			_ = os.WriteFile("../verifier_err.log", []byte(strings.Join(ve.Log, "\n")), 0644)
			_ = os.WriteFile("verifier_err.log", []byte(strings.Join(ve.Log, "\n")), 0644)
			t.Fatalf("BPF verifier rejected tc_monitor:\n%s", ve.Error())
		}
		if errors.Is(err, os.ErrPermission) || strings.Contains(err.Error(), "operation not permitted") {
			t.Skipf("skipping live kernel verifier test (unprivileged): %v", err)
			return
		}
		t.Fatalf("NewCollectionWithOptions: %v", err)
	}
	defer coll.Close()

	prog := coll.Programs["stun_tc_monitor"]
	if prog == nil {
		t.Fatal("program stun_tc_monitor not loaded")
	}

	if prog.VerifierLog != "" {
		t.Logf("=== VERIFIER LOG for stun_tc_monitor ===\n%s\n=== END VERIFIER LOG ===", strings.TrimSpace(prog.VerifierLog))
	} else {
		t.Log("stun_tc_monitor successfully accepted by kernel verifier (stats log empty)")
	}

	// Also verify ingress and egress entry points
	for _, entry := range []string{"stun_tc_monitor_ingress", "stun_tc_monitor_egress"} {
		p := coll.Programs[entry]
		if p == nil {
			t.Errorf("program %s not loaded", entry)
		}
	}
}

func TestSyntheticFrameFixtures(t *testing.T) {
	_ = rlimit.RemoveMemlock()
	objPath := findMonitorObj(t)
	spec, err := ebpf.LoadCollectionSpec(objPath)
	if err != nil {
		t.Fatalf("LoadCollectionSpec: %v", err)
	}

	opts := ebpf.CollectionOptions{
		Programs: ebpf.ProgramOptions{
			LogLevel: ebpf.LogLevelStats,
		},
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			t.Fatalf("BPF verifier rejected tc_monitor:\n%+v", ve)
		}
		if errors.Is(err, os.ErrPermission) || strings.Contains(err.Error(), "operation not permitted") {
			t.Skipf("skipping live packet injection test (unprivileged): %v", err)
			return
		}
		t.Fatalf("NewCollectionWithOptions: %v", err)
	}
	defer coll.Close()

	prog := coll.Programs["stun_tc_monitor"]
	if prog == nil {
		t.Fatal("program stun_tc_monitor not found")
	}

	// 1. Multi-answer DNS response fixture
	t.Run("DNS_MultiAnswer", func(t *testing.T) {
		answers := []DNSAnswerSpec{
			{Type: TypeA, TTL: 300, IP: net.IPv4(93, 184, 216, 34)},
			{Type: TypeA, TTL: 300, IP: net.IPv4(93, 184, 216, 35)},
			{Type: TypeA, TTL: 300, IP: net.IPv4(93, 184, 216, 36)},
		}
		dnsPayload := BuildDNSResponsePayload(0x1234, 0, "example.com", TypeA, answers)
		frame := BuildEthIPv4UDP(nil, nil, net.IPv4(10, 96, 0, 10), net.IPv4(10, 244, 0, 5), 53, 54321, dnsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 { // TC_ACT_OK == 0
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 2. CNAME chain fixture
	t.Run("DNS_CNAME_Chain", func(t *testing.T) {
		answers := []DNSAnswerSpec{
			{Type: TypeCNAME, TTL: 300, CNAME: "example.com"},
			{Type: TypeA, TTL: 300, IP: net.IPv4(93, 184, 216, 34)},
		}
		dnsPayload := BuildDNSResponsePayload(0x2345, 0, "www.example.com", TypeA, answers)
		frame := BuildEthIPv4UDP(nil, nil, net.IPv4(10, 96, 0, 10), net.IPv4(10, 244, 0, 5), 53, 54321, dnsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 3. NXDOMAIN response fixture
	t.Run("DNS_NXDOMAIN", func(t *testing.T) {
		dnsPayload := BuildDNSResponsePayload(0x3456, 3, "nonexistent.example.com", TypeA, nil)
		frame := BuildEthIPv4UDP(nil, nil, net.IPv4(10, 96, 0, 10), net.IPv4(10, 244, 0, 5), 53, 54321, dnsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 4. Truncated DNS packet fixture
	t.Run("DNS_Truncated", func(t *testing.T) {
		dnsPayload := BuildDNSQueryPayload(0x4567, "verylongname.example.com", TypeA)
		if len(dnsPayload) > 18 {
			dnsPayload = dnsPayload[:18]
		}
		frame := BuildEthIPv4UDP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, dnsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 5. DNS name compression pointer beyond supported offset
	t.Run("DNS_Compressed_Deep", func(t *testing.T) {
		dnsPayload := []byte{
			0x56, 0x78, // ID
			0x01, 0x00, // Flags
			0x00, 0x01, // QDCount=1
			0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			0xC0, 0x40, // Pointer to offset 0x40
			0x00, 0x01, 0x00, 0x01,
		}
		frame := BuildEthIPv4UDP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, dnsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 6. TLS ClientHello with valid SNI
	t.Run("TLS_ClientHello_SNI", func(t *testing.T) {
		tlsPayload := BuildTLSClientHelloPayload("api.example.com", false)
		frame := BuildEthIPv4TCP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, tlsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 7. TLS ClientHello segmented across TCP sends
	t.Run("TLS_ClientHello_Segmented", func(t *testing.T) {
		tlsPayload := BuildTLSClientHelloPayload("api.example.com", false)
		if len(tlsPayload) > 20 {
			tlsPayload = tlsPayload[:20]
		}
		frame := BuildEthIPv4TCP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, tlsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 8. TLS ClientHello with ECH
	t.Run("TLS_ClientHello_ECH", func(t *testing.T) {
		tlsPayload := BuildTLSClientHelloPayload("outer.example.com", true)
		frame := BuildEthIPv4TCP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, tlsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 9. TLS ClientHello with NO SNI
	t.Run("TLS_ClientHello_NoSNI", func(t *testing.T) {
		tlsPayload := BuildTLSClientHelloPayload("", false)
		frame := BuildEthIPv4TCP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, tlsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})

	// 10. TCP DNS Query (2-byte length prefix)
	t.Run("DNS_TCP_Query", func(t *testing.T) {
		dnsPayload := BuildDNSQueryPayload(0x789a, "tcp.example.com", TypeA)
		tcpDNSPayload := make([]byte, 2+len(dnsPayload))
		tcpDNSPayload[0] = byte((len(dnsPayload) >> 8) & 0xff)
		tcpDNSPayload[1] = byte(len(dnsPayload) & 0xff)
		copy(tcpDNSPayload[2:], dnsPayload)

		frame := BuildEthIPv4TCP(nil, nil, net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, tcpDNSPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("return code = %d, want TC_ACT_OK (0)", ret)
		}
	})
}
