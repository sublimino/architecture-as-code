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

	// Review-C4 renames: src_ip -> source_ip, bytes_sent -> bytes.
	if o.Labels["source_ip"] != "10.244.0.12" {
		t.Errorf("expected source_ip 10.244.0.12, got %q", o.Labels["source_ip"])
	}
	if _, ok := o.Labels["src_ip"]; ok {
		t.Errorf("src_ip must be renamed to source_ip; it is still present")
	}
	if o.Labels["bytes"] != "1024" {
		t.Errorf("expected bytes 1024, got %q", o.Labels["bytes"])
	}
	if _, ok := o.Labels["bytes_sent"]; ok {
		t.Errorf("bytes_sent must be renamed to bytes; it is still present")
	}

	// The cleartext domain must NOT be projected; only its entropy bucket is.
	if _, ok := o.Labels["domain"]; ok {
		t.Errorf("cleartext domain must not be projected into a segment label")
	}
	if got := o.Labels["qname_entropy_bucket"]; got != "low" {
		t.Errorf("expected qname_entropy_bucket low for api.openai.com, got %q", got)
	}

	// Non-allow-listed operational keys must be gone.
	for _, k := range []string{"destination", "seq_num", "cgroup_id"} {
		if _, ok := o.Labels[k]; ok {
			t.Errorf("non-allow-listed key %q must not be projected", k)
		}
	}

	// The flow projection emits exactly this allow-listed key set (plus the one
	// intentionally-pending qname_entropy_bucket).
	wantFlowKeys := map[string]bool{
		"pod_name": true, "namespace": true, "pod_uid": true, "service_account": true,
		"spiffe_id": true, "agent_role": true, "provider": true, "classification": true,
		"source_ip": true, "dst_ip": true, "src_port": true, "dst_port": true,
		"bytes": true, "qname_entropy_bucket": true,
	}
	for k := range o.Labels {
		if !wantFlowKeys[k] {
			t.Errorf("flow projection emitted unexpected key %q", k)
		}
	}
	for k := range wantFlowKeys {
		if _, ok := o.Labels[k]; !ok {
			t.Errorf("flow projection is missing expected key %q", k)
		}
	}
}

func TestQnameEntropyBucket(t *testing.T) {
	cases := []struct {
		domain string
		want   string
	}{
		{"", "none"},
		{".example.com", "none"},
		{"api.openai.com", "low"},
		{"api.internal.svc", "low"},
		{"example.com", "low"},
		{"zqxjvkwmbpfhtdlrncsy.tunnel.example.com", "high"},
		{"qpwoeirutyalskdjfhgz.exfil.example.net", "high"},
	}
	for _, c := range cases {
		if got := QnameEntropyBucket(c.domain); got != c.want {
			t.Errorf("QnameEntropyBucket(%q) = %q, want %q", c.domain, got, c.want)
		}
	}
}

func TestFixtureObservationsAreAllowListClean(t *testing.T) {
	obs, err := FixtureObservations()
	if err != nil {
		t.Fatalf("FixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("fixture corpus is empty; every downstream assertion would be vacuous")
	}

	// Every label key a fixture observation carries must be in the segment label
	// allow-list (store/label_allowlist.go) EXCEPT qname_entropy_bucket, which is
	// the single new key flagged for allow-listing by this card.
	allowed := map[string]bool{
		"pod_name": true, "namespace": true, "pod_uid": true, "service_account": true,
		"spiffe_id": true, "agent_role": true, "provider": true, "classification": true,
		"source_ip": true, "dst_ip": true, "src_port": true, "dst_port": true, "bytes": true,
		"qname_entropy_bucket": true, // intentionally pending allow-listing
	}
	ids := map[string]bool{}
	for i := range obs {
		o := obs[i]
		if o.RawEvidenceRef == "" {
			t.Errorf("observation %s has no RawEvidenceRef; negative-discipline attribution would fail", o.ID)
		}
		if ids[o.ID] {
			t.Errorf("duplicate observation ID %q; the e2e deduper would drop one and skew counts", o.ID)
		}
		ids[o.ID] = true
		for k := range o.Labels {
			if !allowed[k] {
				t.Errorf("observation %s carries non-allow-listed label key %q", o.ID, k)
			}
		}
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
