// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netebpf

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.observations = append(m.observations, obs)
	return nil
}

func (m *mockSink) getObservations() []*model.Observation {
	m.mu.Lock()
	defer m.mu.Unlock()
	copied := make([]*model.Observation, len(m.observations))
	copy(copied, m.observations)
	return copied
}

func TestCollectorFlowEventIngest(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewLiveNetworkEgressCollector(ctx, sink)
	defer col.Close()

	ev := &InboundFlowEvent{
		TimestampNs:    uint64(time.Now().UnixNano()),
		Time:           time.Now().UTC(),
		CgroupID:       12345,
		SockCookie:     9999,
		SeqNum:         1,
		SrcIP:          "10.244.0.12",
		DstIP:          "104.18.2.161",
		SrcPort:        40123,
		DstPort:        443,
		Family:         2,
		BytesSent:      1024,
		PodName:        "agent-cardvault-0",
		PodNamespace:   "fe-signalloom-agents",
		PodUID:         "uid-abc-123",
		ServiceAccount: "agent-cardvault-sa",
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		AgentRole:      "cardvault_operator",
		Provider:       "OpenAI",
		Classification: "approved_model_egress",
		Domain:         "api.openai.com",
		NodeName:       "kind-worker-1",
	}

	if err := col.ProcessFlowEvent(ctx, ev); err != nil {
		t.Fatalf("ProcessFlowEvent failed: %v", err)
	}

	obs := sink.getObservations()
	if len(obs) != 1 {
		t.Fatalf("Expected 1 observation, got %d", len(obs))
	}

	o := obs[0]
	if o.Layer != model.LayerNetworkEgress {
		t.Errorf("Expected LayerNetworkEgress, got %v", o.Layer)
	}
	if o.Fidelity != model.FidelityStrong {
		t.Errorf("Expected FidelityStrong, got %v", o.Fidelity)
	}
	if o.Confidence < 0.8 {
		t.Errorf("Expected confidence >= 0.8, got %f", o.Confidence)
	}
	if o.Labels["provider"] != "OpenAI" {
		t.Errorf("Expected provider OpenAI, got %s", o.Labels["provider"])
	}
	if o.Labels["domain"] != "api.openai.com" {
		t.Errorf("Expected domain api.openai.com, got %s", o.Labels["domain"])
	}
}

func TestCollectorSequenceGapDetection(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewLiveNetworkEgressCollector(ctx, sink)
	defer col.Close()

	// Send SeqNum 1
	_ = col.ProcessFlowEvent(ctx, &InboundFlowEvent{
		SeqNum:   1,
		NodeName: "node-1",
		PodName:  "agent-1",
		DstIP:    "1.1.1.1",
		DstPort:  443,
	})

	// Send SeqNum 5 (missing 2, 3, 4)
	_ = col.ProcessFlowEvent(ctx, &InboundFlowEvent{
		SeqNum:   5,
		NodeName: "node-1",
		PodName:  "agent-1",
		DstIP:    "1.1.1.1",
		DstPort:  443,
	})

	obs := sink.getObservations()
	// Should have: Event 1, TELEMETRY_GAP (missing 2-4), Event 5 -> 3 observations total
	if len(obs) != 3 {
		t.Fatalf("Expected 3 observations (1 event + 1 gap + 1 event), got %d", len(obs))
	}

	gapObs := obs[1]
	if gapObs.Labels["type"] != "telemetry_gap" {
		t.Errorf("Expected gap observation, got labels: %v", gapObs.Labels)
	}
	if gapObs.Labels["dropped_count"] != "3" {
		t.Errorf("Expected dropped_count 3, got %s", gapObs.Labels["dropped_count"])
	}
	if gapObs.Fidelity != model.FidelitySuggestive {
		t.Errorf("Expected suggestive fidelity on gap, got %v", gapObs.Fidelity)
	}
}

func TestCollectorDropAlert(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewLiveNetworkEgressCollector(ctx, sink)
	defer col.Close()

	alert := &InboundDropAlert{
		NodeName:     "worker-bpf-node",
		DroppedCount: 42,
		Reason:       "ringbuf_full_burst_drop",
	}

	if err := col.ProcessDropAlert(ctx, alert); err != nil {
		t.Fatalf("ProcessDropAlert failed: %v", err)
	}

	obs := sink.getObservations()
	if len(obs) != 1 {
		t.Fatalf("Expected 1 gap observation, got %d", len(obs))
	}

	if obs[0].Labels["dropped_count"] != "42" {
		t.Errorf("Expected dropped_count 42, got %s", obs[0].Labels["dropped_count"])
	}
}

func TestCollectorConcurrentMultiNode(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewLiveNetworkEgressCollector(ctx, sink)
	defer col.Close()

	var wg sync.WaitGroup
	nodes := 5
	eventsPerNode := 50

	for n := 0; n < nodes; n++ {
		wg.Add(1)
		go func(nodeID int) {
			defer wg.Done()
			for i := 1; i <= eventsPerNode; i++ {
				_ = col.ProcessFlowEvent(ctx, &InboundFlowEvent{
					SeqNum:   uint64(i),
					NodeName: string(rune('A' + nodeID)),
					PodName:  "agent-pod",
					DstIP:    "10.0.0.1",
					DstPort:  8080,
				})
			}
		}(n)
	}

	wg.Wait()

	received, gaps, ingested := col.Stats()
	if received != uint64(nodes*eventsPerNode) {
		t.Errorf("Received mismatch: %d vs %d", received, nodes*eventsPerNode)
	}
	if gaps != 0 {
		t.Errorf("Expected 0 gaps in sequential delivery, got %d", gaps)
	}
	if ingested != uint64(nodes*eventsPerNode) {
		t.Errorf("Ingested mismatch: %d vs %d", ingested, nodes*eventsPerNode)
	}
}
