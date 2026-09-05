package collectors

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type testMockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
	count        uint64
}

func (m *testMockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	m.observations = append(m.observations, obs)
	m.mu.Unlock()
	atomic.AddUint64(&m.count, 1)
	return nil
}

func TestRegistry_Lifecycle(t *testing.T) {
	sink := &testMockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	reg := NewRegistry(
		NewGCPAuditCollector(ModeFixture, sink),
		NewBaoAuditCollector(ModeFixture, sink),
		NewSPIREACollector(ModeFixture, sink),
		NewNetEBPFCollector(ModeFixture, sink),
		NewK8sAuditCollector(ModeFixture, sink),
		NewWorkspaceSaaSCollector(ModeFixture, sink),
		NewFixtureCollector(ModeOff, sink),
	)

	if len(reg.Collectors()) != 7 {
		t.Fatalf("expected 7 collectors, got %d", len(reg.Collectors()))
	}

	if err := reg.Start(ctx); err != nil {
		t.Fatalf("registry Start failed: %v", err)
	}

	if err := reg.Health(ctx); err != nil {
		t.Fatalf("registry Health expected nil, got %v", err)
	}

	if atomic.LoadUint64(&sink.count) == 0 {
		t.Fatal("expected fixture observations to be ingested on Start")
	}

	reg.Stop()
}

func TestRegistry_StartStopRace(t *testing.T) {
	sink := &testMockSink{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	reg := NewRegistry(
		NewGCPAuditCollector(ModeLive, sink),
		NewBaoAuditCollector(ModeLive, sink),
		NewSPIREACollector(ModeLive, sink),
		NewNetEBPFCollector(ModeLive, sink),
		NewK8sAuditCollector(ModeLive, sink),
		NewWorkspaceSaaSCollector(ModeOff, sink),
		NewFixtureCollector(ModeOff, sink),
	)

	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = reg.Health(ctx)
		}()
	}

	if err := reg.Start(ctx); err != nil {
		t.Fatalf("registry Start failed: %v", err)
	}

	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = reg.Health(ctx)
		}()
	}

	wg.Wait()
	reg.Stop()
}

func TestRegistry_OffModeReady(t *testing.T) {
	sink := &testMockSink{}
	ctx := context.Background()

	// Clear any collector env vars
	envVars := []string{
		"COLLECTOR_GCPAUDIT_MODE", "GCPAUDIT_MODE",
		"COLLECTOR_BAOAUDIT_MODE", "BAOAUDIT_MODE",
		"COLLECTOR_SPIREA_MODE", "SPIREA_MODE",
		"COLLECTOR_NETEBPF_MODE", "NETEBPF_MODE",
		"COLLECTOR_K8SAUDIT_MODE", "K8SAUDIT_MODE",
		"COLLECTOR_WORKSPACESAAS_MODE", "WORKSPACESAAS_MODE", "SIGNAL_COLLECTOR_WORKSPACESAAS",
		"COLLECTOR_FIXTURES_MODE", "FIXTURES_MODE",
	}
	for _, v := range envVars {
		os.Unsetenv(v)
	}

	reg := NewRegistryFromEnv(sink)
	for _, c := range reg.Collectors() {
		if c.Mode() != ModeOff {
			t.Errorf("expected collector %s to default to off, got %s", c.Name(), c.Mode())
		}
	}

	if err := reg.Start(ctx); err != nil {
		t.Fatalf("bare boot Start failed: %v", err)
	}

	if err := reg.Health(ctx); err != nil {
		t.Fatalf("bare boot Health expected ready, got %v", err)
	}

	if atomic.LoadUint64(&sink.count) != 0 {
		t.Errorf("bare boot with off mode should ingest 0 events, got %d", atomic.LoadUint64(&sink.count))
	}
}

func TestRegistry_HealthReflectsSourceFailure(t *testing.T) {
	sink := &testMockSink{}
	ctx := context.Background()

	gcpCol := NewGCPAuditCollector(ModeLive, sink)
	gcpCol.SetHealthFunc(func(ctx context.Context) error {
		return errors.New("gcp logging connection lost")
	})

	reg := NewRegistry(gcpCol)
	if err := reg.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	err := reg.Health(ctx)
	if err == nil {
		t.Fatal("expected Health error for unhealthy source, got nil")
	}
	if !strings.Contains(err.Error(), "gcp logging connection lost") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestRegistry_StartupFailureReflectedInHealth(t *testing.T) {
	sink := &testMockSink{}
	ctx := context.Background()

	badCol := NewBaoAuditCollector(ModeLive, sink)
	badCol.SetStartFunc(func(ctx context.Context) error {
		return errors.New("failed to bind unix socket: permission denied")
	})

	reg := NewRegistry(badCol)
	err := reg.Start(ctx)
	if err == nil {
		t.Fatal("expected Start to fail, got nil")
	}

	healthErr := reg.Health(ctx)
	if healthErr == nil {
		t.Fatal("expected Health to report start error, got nil")
	}
}

func TestRegistry_WorkspaceSaaS_ModeGating(t *testing.T) {
	ctx := context.Background()

	t.Run("ModeOff is quiet", func(t *testing.T) {
		sink := &testMockSink{}
		reg := NewRegistry(NewWorkspaceSaaSCollector(ModeOff, sink))
		if err := reg.Start(ctx); err != nil {
			t.Fatalf("ModeOff Start failed: %v", err)
		}
		if err := reg.Health(ctx); err != nil {
			t.Fatalf("ModeOff Health expected nil, got %v", err)
		}
		if sink.count != 0 {
			t.Errorf("expected 0 events in ModeOff, got %d", sink.count)
		}
	})

	t.Run("ModeFixture ingests workspace fixtures", func(t *testing.T) {
		sink := &testMockSink{}
		reg := NewRegistry(NewWorkspaceSaaSCollector(ModeFixture, sink))
		if err := reg.Start(ctx); err != nil {
			t.Fatalf("ModeFixture Start failed: %v", err)
		}
		if err := reg.Health(ctx); err != nil {
			t.Fatalf("ModeFixture Health expected nil, got %v", err)
		}
		if sink.count == 0 {
			t.Fatal("expected fixture observations to be ingested in ModeFixture")
		}
	})

	t.Run("ModeLive reports explicit deferred error", func(t *testing.T) {
		sink := &testMockSink{}
		reg := NewRegistry(NewWorkspaceSaaSCollector(ModeLive, sink))
		err := reg.Start(ctx)
		if err == nil {
			t.Fatal("ModeLive Start expected error, got nil (must not silently pass)")
		}
		if !strings.Contains(err.Error(), "deferred") {
			t.Fatalf("ModeLive Start expected deferred error, got: %v", err)
		}
	})
}

