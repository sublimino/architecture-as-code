// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	events []*model.Observation
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.events = append(m.events, obs)
	return nil
}

func TestDiskRingBuffer_PushPop(t *testing.T) {
	dir := t.TempDir()
	rb, err := NewDiskRingBuffer(dir, 10)
	if err != nil {
		t.Fatalf("NewDiskRingBuffer failed: %v", err)
	}
	defer rb.Close()

	rec := &LogRecord{
		SourceType: "aws:cloudtrail",
		TenantID:   "kusari",
		Payload:    []byte(`{"event":"test"}`),
	}

	if err := rb.Push(rec); err != nil {
		t.Fatalf("Push failed: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	popped, err := rb.Pop(ctx)
	if err != nil {
		t.Fatalf("Pop failed: %v", err)
	}

	if popped.SequenceID != 0 {
		t.Errorf("expected sequence 0, got %d", popped.SequenceID)
	}
}

func TestAWSLogCollector_Lifecycle(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ring")
	sink := &mockSink{}

	cfg := AWSCollectorConfig{
		TenantID:      "kusari",
		PollInterval:  50 * time.Millisecond,
		RingBufferDir: dir,
		RingCapacity:  100,
	}

	c, err := NewAWSLogCollector(cfg, sink)
	if err != nil {
		t.Fatalf("NewAWSLogCollector failed: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	if err := c.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	<-ctx.Done()

	if err := c.Stop(); err != nil {
		t.Fatalf("Stop failed: %v", err)
	}

	stats := c.Stats()
	if stats["processed_total"] == 0 {
		t.Errorf("expected processed_total > 0, got 0")
	}
}
