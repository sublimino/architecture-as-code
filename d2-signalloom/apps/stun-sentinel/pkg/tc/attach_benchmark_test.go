// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"net"
	"testing"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/rlimit"
)

// BenchmarkPacketTraversal_Detached measures the baseline packet traversal latency
// through the TC classifier when the monitor is detached (baseline passthrough).
func BenchmarkPacketTraversal_Detached(b *testing.B) {
	_ = rlimit.RemoveMemlock()
	spec, err := loadCollectionSpec()
	if err != nil {
		b.Fatalf("loadCollectionSpec: %v", err)
	}
	for _, m := range spec.Maps {
		m.Pinning = ebpf.PinNone
	}
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		b.Skipf("skipping live kernel packet benchmark (unprivileged): %v", err)
		return
	}
	defer coll.Close()

	prog := coll.Programs["stun_tc_drop"]
	if prog == nil {
		b.Fatal("stun_tc_drop program not found")
	}

	frame := BuildEthIPv4UDPFrame(
		net.IPv4(10, 244, 0, 5),
		net.IPv4(10, 96, 0, 10),
		54321,
		53,
		BuildDNSQueryPayload(0x1234, "bench.example.com", 1),
	)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		ret, _, err := prog.Test(frame)
		if err != nil {
			b.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			b.Fatalf("ret = %d, want TC_ACT_OK (0)", ret)
		}
	}
}

// BenchmarkPacketTraversal_Attached_DNS measures the packet traversal latency
// through the TC classifier with the DNS monitor attached evaluating DNS query packets.
func BenchmarkPacketTraversal_Attached_DNS(b *testing.B) {
	_ = rlimit.RemoveMemlock()
	spec, err := loadMonitorCollectionSpec()
	if err != nil {
		b.Fatalf("loadMonitorCollectionSpec: %v", err)
	}
	for _, m := range spec.Maps {
		m.Pinning = ebpf.PinNone
	}
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		b.Skipf("skipping live kernel packet benchmark (unprivileged): %v", err)
		return
	}
	defer coll.Close()

	prog := coll.Programs["stun_tc_monitor"]
	if prog == nil {
		b.Fatal("stun_tc_monitor program not found")
	}

	frame := BuildEthIPv4UDPFrame(
		net.IPv4(10, 244, 0, 5),
		net.IPv4(10, 96, 0, 10),
		54321,
		53,
		BuildDNSQueryPayload(0x1234, "bench.example.com", 1),
	)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		ret, _, err := prog.Test(frame)
		if err != nil {
			b.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			b.Fatalf("ret = %d, want TC_ACT_OK (0)", ret)
		}
	}
}

// BenchmarkPacketTraversal_Attached_TLS measures the packet traversal latency
// through the TC classifier with the TLS monitor attached evaluating TLS ClientHello packets.
func BenchmarkPacketTraversal_Attached_TLS(b *testing.B) {
	_ = rlimit.RemoveMemlock()
	spec, err := loadMonitorCollectionSpec()
	if err != nil {
		b.Fatalf("loadMonitorCollectionSpec: %v", err)
	}
	for _, m := range spec.Maps {
		m.Pinning = ebpf.PinNone
	}
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		b.Skipf("skipping live kernel packet benchmark (unprivileged): %v", err)
		return
	}
	defer coll.Close()

	prog := coll.Programs["stun_tc_monitor"]
	if prog == nil {
		b.Fatal("stun_tc_monitor program not found")
	}

	frame := BuildEthIPv4TCPFrame(
		net.IPv4(10, 244, 0, 5),
		net.IPv4(1, 1, 1, 1),
		43210,
		443,
		BuildTLSClientHelloRaw("bench.example.com", false),
	)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		ret, _, err := prog.Test(frame)
		if err != nil {
			b.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			b.Fatalf("ret = %d, want TC_ACT_OK (0)", ret)
		}
	}
}

// BenchmarkPacketTraversal_Attached_Passthrough measures packet traversal latency
// for non-monitored traffic (TCP port 8080) passing through the attached monitor.
func BenchmarkPacketTraversal_Attached_Passthrough(b *testing.B) {
	_ = rlimit.RemoveMemlock()
	spec, err := loadMonitorCollectionSpec()
	if err != nil {
		b.Fatalf("loadMonitorCollectionSpec: %v", err)
	}
	for _, m := range spec.Maps {
		m.Pinning = ebpf.PinNone
	}
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		b.Skipf("skipping live kernel packet benchmark (unprivileged): %v", err)
		return
	}
	defer coll.Close()

	prog := coll.Programs["stun_tc_monitor"]
	if prog == nil {
		b.Fatal("stun_tc_monitor program not found")
	}

	frame := BuildEthIPv4TCPFrame(
		net.IPv4(10, 244, 0, 5),
		net.IPv4(1, 1, 1, 1),
		43210,
		8080,
		[]byte("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"),
	)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		ret, _, err := prog.Test(frame)
		if err != nil {
			b.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			b.Fatalf("ret = %d, want TC_ACT_OK (0)", ret)
		}
	}
}

// BenchmarkMonitorAttach measures the CPU and wall-clock latency of the
// MonitorLoader.Attach operation across mock netlink interfaces.
func BenchmarkMonitorAttach(b *testing.B) {
	fn := &fakeNetlink{links: map[string]int{"veth_bench": 17}}
	ml := wireMonitorFake(fn)

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		fn.filterAdds = fn.filterAdds[:0]
		fn.qdiscs = make(map[int]bool)
		ml.attached = make(map[int]string)

		if err := ml.Attach("veth_bench"); err != nil {
			b.Fatalf("Attach failed: %v", err)
		}
	}
}

// BenchmarkMonitorDetach measures the CPU and wall-clock latency of the
// MonitorLoader.Detach operation across mock netlink interfaces.
func BenchmarkMonitorDetach(b *testing.B) {
	fn := &fakeNetlink{links: map[string]int{"veth_bench": 17}}
	ml := wireMonitorFake(fn)
	_ = ml.Attach("veth_bench")

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		fn.filterDels = fn.filterDels[:0]
		ml.attached[17] = "veth_bench"

		if err := ml.Detach("veth_bench"); err != nil {
			b.Fatalf("Detach failed: %v", err)
		}
	}
}

// BenchmarkMonitorAttachedInterfaces measures the latency of querying attached interfaces.
func BenchmarkMonitorAttachedInterfaces(b *testing.B) {
	fn := &fakeNetlink{links: map[string]int{"veth_bench": 17}}
	ml := wireMonitorFake(fn)
	_ = ml.Attach("veth_bench")

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		attached := ml.AttachedInterfaces()
		if len(attached) != 1 {
			b.Fatalf("unexpected attached count: %d", len(attached))
		}
	}
}
