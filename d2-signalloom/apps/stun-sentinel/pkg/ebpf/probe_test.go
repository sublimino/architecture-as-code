// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestProbeManagerStartStopAndEvents(t *testing.T) {
	mgr := NewProbeManager(100)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := mgr.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	ev := FlowEvent{
		CgroupID:   12345,
		SockCookie: 67890,
		SrcIP:      net.ParseIP("10.244.0.5"),
		DstIP:      net.ParseIP("140.82.121.4"),
		SrcPort:    45678,
		DstPort:    443,
		Family:     AF_INET,
		OldState:   TCPSynSent,
		NewState:   TCPEstablished,
		BytesSent:  1024,
	}

	mgr.SimulateEvent(ev)

	select {
	case received := <-mgr.Events():
		if received.CgroupID != 12345 || received.DstPort != 443 {
			t.Fatalf("unexpected event: %+v", received)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("timed out waiting for flow event")
	}

	stats, err := mgr.GetDropStats()
	if err != nil || stats.TotalEvents != 1 || stats.RingbufDrops != 0 {
		t.Fatalf("unexpected stats: %+v, err: %v", stats, err)
	}

	mgr.SimulateDrop(5)
	stats, _ = mgr.GetDropStats()
	if stats.RingbufDrops != 5 {
		t.Fatalf("RingbufDrops = %d, want 5", stats.RingbufDrops)
	}

	if err := mgr.Stop(); err != nil {
		t.Fatalf("Stop failed: %v", err)
	}
}

func TestDecodeRawEvent(t *testing.T) {
	buf := make([]byte, 64)
	// TimestampNs (uint64): bytes 0..8
	// CgroupID: bytes 8..16
	buf[8] = 42
	// SockCookie: bytes 16..24
	buf[16] = 99
	// SeqNum: bytes 24..32
	buf[24] = 1
	// SrcIP: bytes 32..36 (IPv4 10.0.0.1)
	buf[32] = 10
	buf[33] = 0
	buf[34] = 0
	buf[35] = 1
	// DstIP: bytes 36..40 (IPv4 192.168.1.1)
	buf[36] = 192
	buf[37] = 168
	buf[38] = 1
	buf[39] = 1
	// SrcPort: bytes 40..42
	buf[40] = 0x39
	buf[41] = 0x30 // 12345
	// DstPort: bytes 42..44
	buf[42] = 0xbb
	buf[43] = 0x01 // 443
	// Family: bytes 44..46
	buf[44] = AF_INET
	buf[45] = 0
	// OldState: byte 46
	buf[46] = TCPSynSent
	// NewState: byte 47
	buf[47] = TCPEstablished
	// BytesSent: bytes 48..56
	buf[48] = 100

	ev, err := DecodeRawEvent(buf)
	if err != nil {
		t.Fatalf("DecodeRawEvent failed: %v", err)
	}
	if ev.CgroupID != 42 || ev.SockCookie != 99 || ev.Family != AF_INET {
		t.Fatalf("unexpected decoded event: %+v", ev)
	}
	if ev.SrcIP.String() != "10.0.0.1" || ev.DstIP.String() != "192.168.1.1" {
		t.Fatalf("unexpected IP: src=%v, dst=%v", ev.SrcIP, ev.DstIP)
	}
}
