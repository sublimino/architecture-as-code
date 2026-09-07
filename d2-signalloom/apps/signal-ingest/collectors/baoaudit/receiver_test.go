// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package baoaudit

import (
	"context"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
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

func (m *mockSink) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.observations)
}

func TestRingBuffer_PushAndPop(t *testing.T) {
	rb := NewAuditRingBuffer(10)
	defer rb.Close()

	ev := &OpenBaoAuditEvent{
		Type: "request",
		Time: "2026-09-02T08:00:00Z",
		Request: &AuditRequest{
			Operation: "read",
			Path:      "secret/data/cardvault/keys",
		},
	}

	if !rb.Push(ev) {
		t.Fatalf("expected Push to succeed")
	}

	if rb.Len() != 1 {
		t.Fatalf("expected Len 1, got %d", rb.Len())
	}

	popped, ok := rb.Pop()
	if !ok || popped == nil {
		t.Fatalf("expected Pop to return event")
	}

	if popped.Request.Path != "secret/data/cardvault/keys" {
		t.Fatalf("unexpected path: %s", popped.Request.Path)
	}

	if rb.Len() != 0 {
		t.Fatalf("expected Len 0 after pop, got %d", rb.Len())
	}
}

func TestRingBuffer_DropTailUnderSaturation(t *testing.T) {
	capacity := 5
	rb := NewAuditRingBuffer(capacity)
	defer rb.Close()

	// Push capacity items
	for i := 0; i < capacity; i++ {
		ev := &OpenBaoAuditEvent{Type: fmt.Sprintf("event-%d", i)}
		if !rb.Push(ev) {
			t.Fatalf("expected event %d to fit", i)
		}
	}

	// 6th item should be dropped
	overflow := &OpenBaoAuditEvent{Type: "overflow"}
	if rb.Push(overflow) {
		t.Fatalf("expected overflow event to be dropped")
	}

	if rb.DropsTotal() != 1 {
		t.Fatalf("expected 1 drop, got %d", rb.DropsTotal())
	}
}

func TestRingBuffer_ConcurrentRace(t *testing.T) {
	rb := NewAuditRingBuffer(1000)
	defer rb.Close()

	var wg sync.WaitGroup
	var pushedCount uint64
	var poppedCount uint64

	// 5 concurrent producers
	for p := 0; p < 5; p++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				ev := &OpenBaoAuditEvent{
					Type: "request",
					Request: &AuditRequest{
						Operation: "read",
						Path:      fmt.Sprintf("secret/path-%d-%d", id, i),
					},
				}
				if rb.Push(ev) {
					atomic.AddUint64(&pushedCount, 1)
				}
			}
		}(p)
	}

	// 3 concurrent consumers
	for c := 0; c < 3; c++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				ev, ok := rb.Pop()
				if !ok {
					return
				}
				if ev != nil {
					atomic.AddUint64(&poppedCount, 1)
				}
				if atomic.LoadUint64(&poppedCount) >= 1000 {
					return
				}
			}
		}()
	}

	// Let producers run
	time.Sleep(100 * time.Millisecond)
	rb.Close()
	wg.Wait()
}

func TestAuditReceiver_IngestRawBytes(t *testing.T) {
	sink := &mockSink{}
	receiver := NewAuditReceiver(100, sink)
	receiver.Start()
	defer receiver.Stop()

	rawJSON := []byte(`{
		"type": "response",
		"time": "2026-09-02T08:00:00Z",
		"auth": {
			"client_token": "hmac-token-xyz",
			"accessor": "acc-12345",
			"metadata": {
				"spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"role": "cardvault-agent"
			}
		},
		"request": {
			"operation": "read",
			"path": "secret/data/cardvault/master-keys",
			"client_token_accessor": "acc-12345"
		},
		"response": {
			"secret": {
				"lease_id": "secret/data/cardvault/master-keys/lease-99",
				"lease_duration": 3600
			}
		}
	}`)

	if err := receiver.IngestRawBytes(rawJSON); err != nil {
		t.Fatalf("IngestRawBytes failed: %v", err)
	}

	// Allow worker to drain
	time.Sleep(50 * time.Millisecond)

	if sink.Count() != 1 {
		t.Fatalf("expected 1 observation in sink, got %d", sink.Count())
	}

	obs := sink.observations[0]
	if obs.Layer != model.LayerIdentityAuth {
		t.Fatalf("expected LayerIdentityAuth, got %s", obs.Layer)
	}
	if obs.ActorHint != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Fatalf("unexpected actor hint: %s", obs.ActorHint)
	}
	if obs.Labels["operation"] != "read" || obs.Labels["path"] != "secret/data/cardvault/master-keys" {
		t.Fatalf("labels mismatch: %+v", obs.Labels)
	}
}

func TestAuditReceiver_UnixgramSocket(t *testing.T) {
	sockPath := fmt.Sprintf("/tmp/test-baoaudit-%d.sock", time.Now().UnixNano())
	defer os.Remove(sockPath)

	sink := &mockSink{}
	receiver := NewAuditReceiver(100, sink)
	receiver.Start()
	defer receiver.Stop()

	if err := receiver.ListenUnixgram(sockPath); err != nil {
		t.Fatalf("ListenUnixgram failed: %v", err)
	}

	time.Sleep(20 * time.Millisecond)

	// Send datagram payload
	addr, err := net.ResolveUnixAddr("unixgram", sockPath)
	if err != nil {
		t.Fatalf("resolve unixgram: %v", err)
	}
	conn, err := net.DialUnix("unixgram", nil, addr)
	if err != nil {
		t.Fatalf("dial unixgram: %v", err)
	}
	defer conn.Close()

	payload := []byte(`{"type":"request","time":"2026-09-02T08:00:00Z","request":{"operation":"create","path":"auth/token/create"}}`)
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write payload: %v", err)
	}

	time.Sleep(50 * time.Millisecond)

	if sink.Count() != 1 {
		t.Fatalf("expected 1 observation via unixgram, got %d", sink.Count())
	}
}

func TestAuditReceiver_DropSurfacingUnderSaturation(t *testing.T) {
	sink := &mockSink{}
	capacity := 5
	receiver := NewAuditReceiver(capacity, sink)
	// Do not start worker immediately so buffer saturates

	for i := 0; i < capacity+3; i++ {
		payload := []byte(fmt.Sprintf(`{"type":"request","time":"2026-09-02T08:00:00Z","request":{"operation":"read","path":"secret/data/%d"}}`, i))
		_ = receiver.IngestRawBytes(payload)
	}

	rec, ing, dropped, errs := receiver.Stats()
	if rec != uint64(capacity+3) {
		t.Fatalf("expected received=%d, got %d", capacity+3, rec)
	}
	if ing != 0 {
		t.Fatalf("expected ingested=0 before start, got %d", ing)
	}
	if dropped != 3 {
		t.Fatalf("expected dropped=3 under saturation, got %d", dropped)
	}
	if receiver.DropsTotal() != 3 {
		t.Fatalf("expected DropsTotal=3, got %d", receiver.DropsTotal())
	}
	if errs != 0 {
		t.Fatalf("expected 0 parse errors, got %d", errs)
	}

	// Drain remaining
	receiver.Start()
	time.Sleep(50 * time.Millisecond)
	receiver.Stop()

	_, ingFinal, _, _ := receiver.Stats()
	if ingFinal != uint64(capacity) {
		t.Fatalf("expected ingested=%d, got %d", capacity, ingFinal)
	}
}

func TestAuditReceiver_SASPIFFE_JoinConversion(t *testing.T) {
	sink := &mockSink{}
	receiver := NewAuditReceiver(100, sink)
	receiver.Start()
	defer receiver.Stop()

	rawJSON := []byte(`{
		"type": "response",
		"time": "2026-09-02T08:00:00Z",
		"auth": {
			"display_name": "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			"client_token": "hmac-token-xyz",
			"accessor": "acc-12345",
			"metadata": {
				"spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"role": "cardvault"
			}
		},
		"request": {
			"operation": "read",
			"path": "secret/data/cardvault/master-keys"
		}
	}`)

	if err := receiver.IngestRawBytes(rawJSON); err != nil {
		t.Fatalf("IngestRawBytes failed: %v", err)
	}

	time.Sleep(50 * time.Millisecond)

	if sink.Count() != 1 {
		t.Fatalf("expected 1 observation, got %d", sink.Count())
	}

	obs := sink.observations[0]
	if obs.ActorHint != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("actor hint = %s, want spiffe ID", obs.ActorHint)
	}
	if obs.PrincipalID != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("principal ID = %s, want SA principal", obs.PrincipalID)
	}
	if obs.Labels["sa_principal"] != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Errorf("label sa_principal = %s, want system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa", obs.Labels["sa_principal"])
	}
	if obs.Labels["spiffe_id"] != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("label spiffe_id = %s, want spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa", obs.Labels["spiffe_id"])
	}
	if obs.Labels["namespace"] != "fe-signalloom-agents" {
		t.Errorf("label namespace = %s, want fe-signalloom-agents", obs.Labels["namespace"])
	}
	if obs.Labels["service_account"] != "agent-cardvault-sa" {
		t.Errorf("label service_account = %s, want agent-cardvault-sa", obs.Labels["service_account"])
	}
}

func BenchmarkRingBuffer_PushPop(b *testing.B) {
	rb := NewAuditRingBuffer(16384)
	defer rb.Close()

	ev := &OpenBaoAuditEvent{
		Type: "request",
		Request: &AuditRequest{
			Operation: "read",
			Path:      "secret/data/cardvault/benchmark",
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rb.Push(ev)
		_, _ = rb.Pop()
	}
}

