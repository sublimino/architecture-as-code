// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"encoding/binary"
	"net"
	"sync"
	"testing"
	"time"
)

func TestProbeLifecycle(t *testing.T) {
	pm := NewProbeManager(100)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := pm.Start(ctx); err != nil {
		t.Fatalf("Failed to start probe manager: %v", err)
	}

	// Double start should fail
	if err := pm.Start(ctx); err == nil {
		t.Fatalf("Expected error starting already running probe manager, got nil")
	}

	if err := pm.Stop(); err != nil {
		t.Fatalf("Failed to stop probe manager: %v", err)
	}

	// Stop again should be idempotent
	if err := pm.Stop(); err != nil {
		t.Fatalf("Idempotent stop failed: %v", err)
	}
}

func TestProbeEventStreamingAndSeqNum(t *testing.T) {
	pm := NewProbeManager(100)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := pm.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	defer pm.Stop()

	// Emit 10 simulated events
	for i := 0; i < 10; i++ {
		pm.SimulateEvent(FlowEvent{
			CgroupID:   12345,
			SockCookie: uint64(1000 + i),
			SrcIP:      net.ParseIP("10.244.0.15"),
			DstIP:      net.ParseIP("104.18.2.161"),
			SrcPort:    uint16(40000 + i),
			DstPort:    443,
			Family:     AF_INET,
			OldState:   TCPSynSent,
			NewState:   TCPEstablished,
		})
	}

	// Receive and verify monotonic seq_num
	var lastSeq uint64
	for i := 0; i < 10; i++ {
		select {
		case ev := <-pm.Events():
			if ev.SeqNum <= lastSeq {
				t.Errorf("Expected strictly increasing seq_num, got %d <= %d", ev.SeqNum, lastSeq)
			}
			lastSeq = ev.SeqNum
			if ev.CgroupID != 12345 {
				t.Errorf("Expected CgroupID 12345, got %d", ev.CgroupID)
			}
			if ev.DstPort != 443 {
				t.Errorf("Expected DstPort 443, got %d", ev.DstPort)
			}
		case <-time.After(1 * time.Second):
			t.Fatalf("Timed out waiting for event %d", i)
		}
	}

	stats, err := pm.GetDropStats()
	if err != nil {
		t.Fatalf("GetDropStats failed: %v", err)
	}
	if stats.TotalEvents != 10 {
		t.Errorf("Expected total events 10, got %d", stats.TotalEvents)
	}
	if stats.RingbufDrops != 0 {
		t.Errorf("Expected 0 drops, got %d", stats.RingbufDrops)
	}
}

func TestProbeDropSimulation(t *testing.T) {
	// Tiny buffer of 2 items
	pm := NewProbeManager(2)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	_ = pm.Start(ctx)
	defer pm.Stop()

	// Emit 5 events without draining
	for i := 0; i < 5; i++ {
		pm.SimulateEvent(FlowEvent{
			CgroupID: 9999,
			DstPort:  80,
		})
	}

	stats, _ := pm.GetDropStats()
	if stats.RingbufDrops == 0 {
		t.Errorf("Expected drop count > 0 when buffer full, got 0")
	}

	pm.SimulateDrop(100)
	statsAfter, _ := pm.GetDropStats()
	if statsAfter.RingbufDrops < 100 {
		t.Errorf("Expected >= 100 drops after simulated drop, got %d", statsAfter.RingbufDrops)
	}
}

func TestDecodeRawEvent(t *testing.T) {
	buf := make([]byte, 56)
	binary.LittleEndian.PutUint64(buf[0:8], 1700000000000) // timestamp_ns
	binary.LittleEndian.PutUint64(buf[8:16], 8888)          // cgroup_id
	binary.LittleEndian.PutUint64(buf[16:24], 99999)       // sock_cookie
	binary.LittleEndian.PutUint64(buf[24:32], 42)          // seq_num

	// IPv4 10.244.1.2 -> 192.168.1.1
	copy(buf[32:36], net.IPv4(10, 244, 1, 2).To4())
	copy(buf[36:40], net.IPv4(192, 168, 1, 1).To4())

	binary.LittleEndian.PutUint16(buf[40:42], 54321) // src_port
	binary.LittleEndian.PutUint16(buf[42:44], 443)   // dst_port
	binary.LittleEndian.PutUint16(buf[44:46], AF_INET)
	buf[46] = TCPSynSent
	buf[47] = TCPEstablished
	binary.LittleEndian.PutUint64(buf[48:56], 1024)  // bytes_sent

	ev, err := DecodeRawEvent(buf)
	if err != nil {
		t.Fatalf("DecodeRawEvent failed: %v", err)
	}

	if ev.CgroupID != 8888 {
		t.Errorf("Expected cgroup 8888, got %d", ev.CgroupID)
	}
	if ev.SeqNum != 42 {
		t.Errorf("Expected seq 42, got %d", ev.SeqNum)
	}
	if ev.SrcPort != 54321 || ev.DstPort != 443 {
		t.Errorf("Port mismatch: %d -> %d", ev.SrcPort, ev.DstPort)
	}
	if ev.OldState != TCPSynSent || ev.NewState != TCPEstablished {
		t.Errorf("State mismatch: %d -> %d", ev.OldState, ev.NewState)
	}
	if ev.BytesSent != 1024 {
		t.Errorf("Expected bytes_sent 1024, got %d", ev.BytesSent)
	}
}

func TestProbeConcurrentSafety(t *testing.T) {
	pm := NewProbeManager(1000)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	_ = pm.Start(ctx)
	defer pm.Stop()

	var wg sync.WaitGroup
	workers := 10
	eventsPerWorker := 100

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for i := 0; i < eventsPerWorker; i++ {
				pm.SimulateEvent(FlowEvent{
					CgroupID: uint64(workerID),
					DstPort:  uint16(8000 + i),
				})
			}
		}(w)
	}

	// Concurrent consumer
	receivedCount := 0
	doneCh := make(chan struct{})
	go func() {
		for {
			select {
			case <-pm.Events():
				receivedCount++
			case <-doneCh:
				return
			}
		}
	}()

	wg.Wait()
	time.Sleep(50 * time.Millisecond)
	close(doneCh)

	stats, _ := pm.GetDropStats()
	if stats.TotalEvents != uint64(workers*eventsPerWorker) {
		t.Errorf("Expected total %d events, got %d", workers*eventsPerWorker, stats.TotalEvents)
	}
}
