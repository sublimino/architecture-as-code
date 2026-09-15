// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"net"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

func TestPodAttributorRegisterEnrichAndTombstone(t *testing.T) {
	attributor := NewPodAttributor(100 * time.Millisecond)

	meta := &PodMetadata{
		PodName:        "agent-smith",
		PodNamespace:   "fe-signalloom-agents",
		PodUID:         "uid-999",
		ServiceAccount: "smith-sa",
		AgentRole:      "coder",
	}

	attributor.RegisterPod(12345, meta)

	gotMeta, ok := attributor.GetPod(12345)
	if !ok || gotMeta.PodName != "agent-smith" {
		t.Fatalf("GetPod failed: %+v, ok=%v", gotMeta, ok)
	}
	if gotMeta.SPIFFEID != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/smith-sa" {
		t.Fatalf("SPIFFE ID auto-derivation failed: %q", gotMeta.SPIFFEID)
	}

	ev := ebpf.FlowEvent{
		CgroupID: 12345,
		DstIP:    net.ParseIP("104.18.2.1"),
		DstPort:  443,
	}

	enriched := attributor.Enrich(ev, "api.openai.com")
	if enriched.PodName != "agent-smith" || enriched.Provider != ProviderOpenAI || enriched.Classification != ClassApprovedModelEgress {
		t.Fatalf("Enrich failed: %+v", enriched)
	}

	// Test unregister -> tombstone
	attributor.UnregisterPod(12345)
	tombstonedMeta, ok := attributor.GetPod(12345)
	if !ok || tombstonedMeta.PodName != "agent-smith" {
		t.Fatalf("Tombstone lookup failed immediately after unregister: %+v, ok=%v", tombstonedMeta, ok)
	}

	time.Sleep(150 * time.Millisecond)
	if _, ok := attributor.GetPod(12345); ok {
		t.Fatal("expected tombstone entry to be expired")
	}
}

func TestValidateAuditEvent(t *testing.T) {
	raw := []byte(`{"timestamp":"2026-09-15T05:00:00Z","event":"StunExecutionHalted","pod":"agent-1","frozen":true}`)
	ev, err := ValidateAuditEvent(raw)
	if err != nil {
		t.Fatalf("ValidateAuditEvent failed on valid event: %v", err)
	}
	if ev.Event != "StunExecutionHalted" || ev.PodName != "agent-1" || !ev.Frozen {
		t.Fatalf("unexpected parsed event: %+v", ev)
	}

	// Missing timestamp
	_, err = ValidateAuditEvent([]byte(`{"event":"StunExecutionHalted"}`))
	if err == nil {
		t.Fatal("expected error on missing timestamp")
	}

	// Missing event
	_, err = ValidateAuditEvent([]byte(`{"timestamp":"2026-09-15T05:00:00Z"}`))
	if err == nil {
		t.Fatal("expected error on missing event")
	}
}
