package workspacesaas

import (
	"context"
	"errors"
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

func (m *mockSink) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.observations)
}

func TestCollector_ModeOff(t *testing.T) {
	sink := &mockSink{}
	col := NewCollector(ModeOff, sink)

	if col.Name() != "workspacesaas" {
		t.Errorf("expected collector name workspacesaas, got %s", col.Name())
	}
	if col.Mode() != ModeOff {
		t.Errorf("expected mode off, got %s", col.Mode())
	}

	ctx := context.Background()
	if err := col.Start(ctx); err != nil {
		t.Fatalf("ModeOff Start() failed: %v", err)
	}

	if err := col.Health(ctx); err != nil {
		t.Fatalf("ModeOff Health() failed: %v", err)
	}

	if sink.count() != 0 {
		t.Errorf("expected 0 observations ingested in ModeOff, got %d", sink.count())
	}
}

func TestCollector_ModeFixture(t *testing.T) {
	sink := &mockSink{}
	now := time.Now().UTC()
	fixtures := DefaultWorkspaceFixtures(now)

	col := NewCollector(ModeFixture, sink, WithFixtureObservations(fixtures))

	if col.Mode() != ModeFixture {
		t.Errorf("expected mode fixture, got %s", col.Mode())
	}

	ctx := context.Background()
	if err := col.Start(ctx); err != nil {
		t.Fatalf("ModeFixture Start() failed: %v", err)
	}

	if err := col.Health(ctx); err != nil {
		t.Fatalf("ModeFixture Health() failed: %v", err)
	}

	if sink.count() != len(fixtures) {
		t.Errorf("expected %d observations ingested, got %d", len(fixtures), sink.count())
	}

	col.Stop()
}

func TestCollector_ModeLive_ReturnsExplicitDeferredError(t *testing.T) {
	sink := &mockSink{}
	col := NewCollector(ModeLive, sink)

	if col.Mode() != ModeLive {
		t.Errorf("expected mode live, got %s", col.Mode())
	}

	ctx := context.Background()

	// 1. Start() MUST fail with explicit ErrLiveDeferred (never silent success)
	err := col.Start(ctx)
	if err == nil {
		t.Fatal("ModeLive Start() expected error, got nil (must not silently pass)")
	}
	if !errors.Is(err, ErrLiveDeferred) {
		t.Fatalf("ModeLive Start() expected error wrapping ErrLiveDeferred, got: %v", err)
	}

	// 2. Health() MUST report unhealthy/deferred state
	hErr := col.Health(ctx)
	if hErr == nil {
		t.Fatal("ModeLive Health() expected error, got nil (must not report healthy)")
	}
	if !errors.Is(hErr, ErrLiveDeferred) {
		t.Fatalf("ModeLive Health() expected error wrapping ErrLiveDeferred, got: %v", hErr)
	}

	// 3. No fake events ingested
	if sink.count() != 0 {
		t.Errorf("expected 0 observations in deferred live mode, got %d", sink.count())
	}

	col.Close()
}
