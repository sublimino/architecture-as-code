// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
	count        uint64
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	m.observations = append(m.observations, obs)
	m.mu.Unlock()
	atomic.AddUint64(&m.count, 1)
	return nil
}

func TestCollector_FixtureMode(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("fixture", sink, CollectorConfig{})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start failed: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	if atomic.LoadUint64(&sink.count) == 0 {
		t.Fatal("expected fixture observations to be ingested into sink")
	}

	col.Stop()
}

func TestCollector_LiveModeIngestRawLine(t *testing.T) {
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
	kp, err := GenerateTestKeypair(spiffeID)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}

	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("live", sink, CollectorConfig{
		TrustDomain:    DefaultTrustDomain,
		TrustBundlePEM: []byte(kp.CACertPEM),
	})

	if err := col.Start(ctx); err != nil {
		t.Fatalf("collector Start failed: %v", err)
	}

	events, err := GenerateSignedSession(kp, "audit-sess-live-001", 3, time.Now().UTC())
	if err != nil {
		t.Fatalf("generate signed session: %v", err)
	}

	for _, ev := range events {
		data, err := json.Marshal(ev)
		if err != nil {
			t.Fatalf("marshal event: %v", err)
		}
		if err := col.IngestRawLine(ctx, data); err != nil {
			t.Fatalf("IngestRawLine failed: %v", err)
		}
	}

	time.Sleep(200 * time.Millisecond)

	if atomic.LoadUint64(&sink.count) != 3 {
		t.Fatalf("expected 3 observations ingested, got %d", atomic.LoadUint64(&sink.count))
	}

	sink.mu.Lock()
	for _, obs := range sink.observations {
		if obs.Labels["verification_status"] != string(StatusVerified) {
			t.Errorf("observation %s: expected %s, got %s", obs.ID, StatusVerified, obs.Labels["verification_status"])
		}
		if obs.ActorHint != spiffeID {
			t.Errorf("observation %s: expected actor_hint %s, got %s", obs.ID, spiffeID, obs.ActorHint)
		}
	}
	sink.mu.Unlock()

	// Verify Prometheus metrics rendering
	rendered := col.Metrics().Render()
	if !strings.Contains(rendered, "agent_nono_signals_ingested_total 3") {
		t.Errorf("expected metric in output, got:\n%s", rendered)
	}

	col.Stop()
}

func TestCollector_ConcurrentIngestRace(t *testing.T) {
	sink := &mockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	col := NewCollector("live", sink, CollectorConfig{Capacity: 500})
	if err := col.Start(ctx); err != nil {
		t.Fatalf("start failed: %v", err)
	}

	var wg sync.WaitGroup
	for g := 0; g < 10; g++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				ev := &NonoAuditEvent{
					Timestamp:      time.Now().UTC(),
					AgentID:        "agent-nono-evidenced",
					AuditSessionID: "audit-sess-race",
					Seq:            int64(id*100 + i),
					EventType:      "heartbeat",
				}
				_ = col.IngestEvent(ctx, ev)
			}
		}(g)
	}

	wg.Wait()
	time.Sleep(100 * time.Millisecond)
	col.Stop()
}
