// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"net"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/ebpf"
)

func TestPodAttributionAndEnrichment(t *testing.T) {
	attributor := NewPodAttributor(60 * time.Second)

	meta := &PodMetadata{
		PodName:        "kagent-analyst-7f6d9",
		PodNamespace:   "fe-signalloom-agents",
		PodUID:         "uid-9999",
		ServiceAccount: "kagent-sa",
		AgentRole:      "threat_analyst",
	}

	cgroupID := uint64(54321)
	attributor.RegisterPod(cgroupID, meta)

	// Enrich an OpenAI outbound flow
	rawFlow := ebpf.FlowEvent{
		TimestampNs: uint64(time.Now().UnixNano()),
		CgroupID:    cgroupID,
		SockCookie:  123456,
		SeqNum:      1,
		SrcIP:       net.ParseIP("10.244.0.22"),
		DstIP:       net.ParseIP("104.18.2.161"),
		SrcPort:     49152,
		DstPort:     443,
		Family:      ebpf.AF_INET,
		OldState:    ebpf.TCPSynSent,
		NewState:    ebpf.TCPEstablished,
		BytesSent:   512,
	}

	enriched := attributor.Enrich(rawFlow, "api.openai.com")

	if enriched.PodName != "kagent-analyst-7f6d9" {
		t.Errorf("Expected PodName kagent-analyst-7f6d9, got %s", enriched.PodName)
	}
	if enriched.Provider != ProviderOpenAI {
		t.Errorf("Expected Provider OpenAI, got %s", enriched.Provider)
	}
	if enriched.Classification != ClassApprovedModelEgress {
		t.Errorf("Expected ClassApprovedModelEgress, got %s", enriched.Classification)
	}
	if enriched.SPIFFEID != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/kagent-sa" {
		t.Errorf("SPIFFE ID mismatch: %s", enriched.SPIFFEID)
	}
}

func TestTombstoneCacheRetention(t *testing.T) {
	// 100ms TTL for testing
	ttl := 100 * time.Millisecond
	attributor := NewPodAttributor(ttl)

	meta := &PodMetadata{
		PodName:        "ephemeral-agent",
		PodNamespace:   "default",
		PodUID:         "ephemeral-uid",
		ServiceAccount: "default",
	}

	cgroupID := uint64(7777)
	attributor.RegisterPod(cgroupID, meta)

	// Unregister pod (simulates container deletion)
	attributor.UnregisterPod(cgroupID)

	// Should still be resolved via tombstone cache immediately
	pod, ok := attributor.GetPod(cgroupID)
	if !ok || pod == nil {
		t.Fatalf("Expected pod to be resolved via tombstone cache, got nil")
	}
	if pod.PodName != "ephemeral-agent" {
		t.Errorf("Expected ephemeral-agent, got %s", pod.PodName)
	}

	// Wait for TTL to expire
	time.Sleep(150 * time.Millisecond)

	// Should no longer be resolved
	_, okAfter := attributor.GetPod(cgroupID)
	if okAfter {
		t.Errorf("Expected tombstone to be expired after TTL")
	}
}

func TestAttributionConcurrentAccess(t *testing.T) {
	attributor := NewPodAttributor(10 * time.Second)

	var wg sync.WaitGroup
	workers := 20
	opsPerWorker := 200

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			cgroup := uint64(workerID * 100)
			for i := 0; i < opsPerWorker; i++ {
				attributor.RegisterPod(cgroup, &PodMetadata{
					PodName:        "agent-worker",
					PodNamespace:   "test-ns",
					ServiceAccount: "test-sa",
				})

				_ = attributor.Enrich(ebpf.FlowEvent{
					CgroupID: cgroup,
					DstPort:  443,
				}, "api.anthropic.com")

				if i%50 == 0 {
					attributor.UnregisterPod(cgroup)
				}
			}
		}(w)
	}

	wg.Wait()
}

func BenchmarkAttributionEnrich(b *testing.B) {
	attributor := NewPodAttributor(60 * time.Second)
	cgroupID := uint64(99999)
	attributor.RegisterPod(cgroupID, &PodMetadata{
		PodName:        "bench-agent",
		PodNamespace:   "bench-ns",
		ServiceAccount: "bench-sa",
		AgentRole:      "evaluator",
	})

	flow := ebpf.FlowEvent{
		CgroupID: cgroupID,
		DstPort:  443,
		DstIP:    net.ParseIP("104.18.2.161"),
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = attributor.Enrich(flow, "api.openai.com")
	}
}
