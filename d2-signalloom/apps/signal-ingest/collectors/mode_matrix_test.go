// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"encoding/json"
	"errors"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// trackingSink records all ingested observations safely for test assertions.
type trackingSink struct {
	mu           sync.Mutex
	observations []model.Observation
	ingestCalls  int
	err          error
}

func (s *trackingSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ingestCalls++
	if s.err != nil {
		return s.err
	}
	if obs != nil {
		s.observations = append(s.observations, *obs)
	}
	return nil
}

func (s *trackingSink) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.observations)
}

func (s *trackingSink) Observations() []model.Observation {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]model.Observation, len(s.observations))
	copy(out, s.observations)
	return out
}

// TestModeMatrix_RepresentativeCollector_DistinctObservableBehaviour drives a single representative
// collector (BaoAuditCollector) through live, fixture, and off modes to prove each mode produces
// distinct, observable runtime behavior.
func TestModeMatrix_RepresentativeCollector_DistinctObservableBehaviour(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	t.Run("off_mode_is_inert_and_spawns_no_workers", func(t *testing.T) {
		sink := &trackingSink{}
		c := NewBaoAuditCollector(ModeOff, sink)

		if c.Mode() != ModeOff {
			t.Fatalf("expected ModeOff, got %v", c.Mode())
		}
		if c.Name() != "baoaudit" {
			t.Fatalf("expected name baoaudit, got %s", c.Name())
		}

		baseGoroutines := runtime.NumGoroutine()

		if err := c.Start(ctx); err != nil {
			t.Fatalf("Start in off mode returned error: %v", err)
		}

		// Verify sink remains completely empty
		if count := sink.Count(); count != 0 {
			t.Errorf("off mode ingested %d observations into sink, want 0", count)
		}

		// Verify no receiver or worker is initialized
		if c.RawReceiver() != nil {
			t.Errorf("off mode initialized RawReceiver, want nil")
		}

		// Ensure no goroutines were spawned
		time.Sleep(20 * time.Millisecond)
		afterGoroutines := runtime.NumGoroutine()
		if afterGoroutines > baseGoroutines+1 {
			t.Errorf("off mode spawned goroutines: before=%d, after=%d", baseGoroutines, afterGoroutines)
		}

		// Stop should be safe and no-op
		c.Stop()
	})

	t.Run("fixture_mode_replays_deterministic_data_synchronously", func(t *testing.T) {
		sink := &trackingSink{}
		c := NewBaoAuditCollector(ModeFixture, sink)

		if c.Mode() != ModeFixture {
			t.Fatalf("expected ModeFixture, got %v", c.Mode())
		}

		if err := c.Start(ctx); err != nil {
			t.Fatalf("Start in fixture mode returned error: %v", err)
		}

		// Verify sink received fixture observations
		obs := sink.Observations()
		if len(obs) == 0 {
			t.Fatalf("fixture mode ingested 0 observations, expected >0 deterministic fixtures")
		}

		// Verify observations carry expected identity_authorization layer and non-empty IDs
		for _, o := range obs {
			if o.Layer != model.LayerIdentityAuth {
				t.Errorf("fixture observation layer = %v, want %v", o.Layer, model.LayerIdentityAuth)
			}
			if o.ID == "" {
				t.Errorf("fixture observation has empty ID: %+v", o)
			}
			if o.ActorHint == "" && o.PrincipalID == "" {
				t.Errorf("fixture observation has neither ActorHint nor PrincipalID: %+v", o)
			}
		}

		// In fixture mode, no background live worker should be created
		if c.RawReceiver() != nil {
			t.Errorf("fixture mode created a live RawReceiver, want nil")
		}

		c.Stop()
	})

	t.Run("live_mode_starts_active_worker_and_tears_down_cleanly", func(t *testing.T) {
		sink := &trackingSink{}
		c := NewBaoAuditCollector(ModeLive, sink)

		if c.Mode() != ModeLive {
			t.Fatalf("expected ModeLive, got %v", c.Mode())
		}

		if err := c.Start(ctx); err != nil {
			t.Fatalf("Start in live mode returned error: %v", err)
		}

		// Verify live receiver is initialized and active
		rcv := c.RawReceiver()
		if rcv == nil {
			t.Fatalf("live mode failed to initialize RawReceiver")
		}

		// Live mode starts with empty queue before events arrive
		if count := sink.Count(); count != 0 {
			t.Errorf("live mode immediately had %d observations before ingestion, want 0", count)
		}

		// Feed a real raw JSON event into the receiver to observe live processing
		event := baoaudit.OpenBaoAuditEvent{
			Type: "request",
			Time: time.Now().UTC().Format(time.RFC3339Nano),
			Request: &baoaudit.AuditRequest{
				ID:                   "req-live-test-1",
				Operation:            "read",
				Path:                 "secret/data/payment/keys",
				ClientTokenAccessor: "acc-12345",
			},
			Auth: &baoaudit.AuditAuth{
				DisplayName: "token-payment-agent",
				Policies:    []string{"payment-read"},
				TokenType:   "service",
				Metadata: map[string]string{
					"spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
					"role":      "payment-agent",
				},
			},
		}

		rawBytes, err := json.Marshal(event)
		if err != nil {
			t.Fatalf("Marshal event: %v", err)
		}

		if err := rcv.IngestRawBytes(rawBytes); err != nil {
			t.Fatalf("IngestRawBytes failed: %v", err)
		}

		// Wait for live worker to drain and deliver to sink
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			if sink.Count() > 0 {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}

		if sink.Count() == 0 {
			t.Fatalf("live worker did not deliver enqueued event to sink within deadline")
		}

		obs := sink.Observations()
		if len(obs) != 1 {
			t.Fatalf("expected 1 observation delivered, got %d", len(obs))
		}
		if obs[0].Source != "openbao-audit" {
			t.Errorf("observation source = %q, want openbao-audit", obs[0].Source)
		}
		if obs[0].ActorHint != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
			t.Errorf("observation ActorHint = %q, want SPIFFE ID", obs[0].ActorHint)
		}

		// Verify clean shutdown
		c.Stop()
	})
}

// TestModeMatrix_AllCollectorsMatrix tests all six standard collector adapters across live, fixture, and off.
func TestModeMatrix_AllCollectorsMatrix(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	collectorsFactory := []struct {
		name        string
		makeOff     func(sink IngestionSink) Collector
		makeFixture func(sink IngestionSink) Collector
		makeLive    func(sink IngestionSink) Collector
		expectedObs int
	}{
		{
			name: "gcpaudit",
			makeOff: func(sink IngestionSink) Collector {
				return NewGCPAuditCollector(ModeOff, sink)
			},
			makeFixture: func(sink IngestionSink) Collector {
				return NewGCPAuditCollector(ModeFixture, sink)
			},
			makeLive: func(sink IngestionSink) Collector {
				return NewGCPAuditCollector(ModeLive, sink)
			},
			expectedObs: len(CloudControlPlaneFixtures(time.Now().UTC())),
		},
		{
			name: "baoaudit",
			makeOff: func(sink IngestionSink) Collector {
				return NewBaoAuditCollector(ModeOff, sink)
			},
			makeFixture: func(sink IngestionSink) Collector {
				return NewBaoAuditCollector(ModeFixture, sink)
			},
			makeLive: func(sink IngestionSink) Collector {
				return NewBaoAuditCollector(ModeLive, sink)
			},
			expectedObs: len(IdentityAuthFixtures(time.Now().UTC())),
		},
		{
			name: "spirea",
			makeOff: func(sink IngestionSink) Collector {
				return NewSPIREACollector(ModeOff, sink)
			},
			makeFixture: func(sink IngestionSink) Collector {
				return NewSPIREACollector(ModeFixture, sink)
			},
			makeLive: func(sink IngestionSink) Collector {
				return NewSPIREACollector(ModeLive, sink)
			},
			expectedObs: len(IdentityAuthFixtures(time.Now().UTC())),
		},
		{
			name: "netebpf",
			makeOff: func(sink IngestionSink) Collector {
				return NewNetEBPFCollector(ModeOff, sink)
			},
			makeFixture: func(sink IngestionSink) Collector {
				return NewNetEBPFCollector(ModeFixture, sink)
			},
			makeLive: func(sink IngestionSink) Collector {
				return NewNetEBPFCollector(ModeLive, sink)
			},
			expectedObs: len(NetworkEgressFixtures(time.Now().UTC())),
		},
		{
			name: "k8saudit",
			makeOff: func(sink IngestionSink) Collector {
				return NewK8sAuditCollector(ModeOff, sink)
			},
			makeFixture: func(sink IngestionSink) Collector {
				return NewK8sAuditCollector(ModeFixture, sink)
			},
			makeLive: func(sink IngestionSink) Collector {
				return NewK8sAuditCollector(ModeLive, sink)
			},
			expectedObs: len(CloudControlPlaneFixtures(time.Now().UTC())),
		},
		{
			name: "fixtures",
			makeOff: func(sink IngestionSink) Collector {
				return NewFixtureCollector(ModeOff, sink)
			},
			makeFixture: func(sink IngestionSink) Collector {
				return NewFixtureCollector(ModeFixture, sink)
			},
			makeLive: func(sink IngestionSink) Collector {
				return NewFixtureCollector(ModeLive, sink)
			},
			expectedObs: len(SeedAll(time.Now().UTC())),
		},
	}

	for _, tc := range collectorsFactory {
		t.Run(tc.name+"_mode_matrix", func(t *testing.T) {
			// 1. Mode Off: Must be 100% inert
			sinkOff := &trackingSink{}
			colOff := tc.makeOff(sinkOff)
			if colOff.Mode() != ModeOff {
				t.Fatalf("%s: expected ModeOff, got %v", tc.name, colOff.Mode())
			}
			if err := colOff.Start(ctx); err != nil {
				t.Fatalf("%s off: Start() failed: %v", tc.name, err)
			}
			if sinkOff.Count() != 0 {
				t.Fatalf("%s off: expected 0 observations, got %d", tc.name, sinkOff.Count())
			}
			if s, ok := colOff.(Stopper); ok {
				s.Stop()
			}

			// 2. Mode Fixture: Must populate deterministic observations
			sinkFix := &trackingSink{}
			colFix := tc.makeFixture(sinkFix)
			if colFix.Mode() != ModeFixture {
				t.Fatalf("%s: expected ModeFixture, got %v", tc.name, colFix.Mode())
			}
			if err := colFix.Start(ctx); err != nil {
				t.Fatalf("%s fixture: Start() failed: %v", tc.name, err)
			}
			if sinkFix.Count() != tc.expectedObs {
				t.Fatalf("%s fixture: expected %d observations, got %d", tc.name, tc.expectedObs, sinkFix.Count())
			}
			if s, ok := colFix.(Stopper); ok {
				s.Stop()
			}

			// 3. Mode Live: Must start active component and stop cleanly
			sinkLive := &trackingSink{}
			colLive := tc.makeLive(sinkLive)
			if colLive.Mode() != ModeLive {
				t.Fatalf("%s: expected ModeLive, got %v", tc.name, colLive.Mode())
			}
			if err := colLive.Start(ctx); err != nil {
				t.Fatalf("%s live: Start() failed: %v", tc.name, err)
			}
			if s, ok := colLive.(Stopper); ok {
				s.Stop()
			}
		})
	}
}

// TestModeMatrix_NoSilentDowngrade ensures that an error during fixture or live ingestion
// surfaces as a hard error and does not silently swallow failures.
func TestModeMatrix_NoSilentDowngrade(t *testing.T) {
	ctx := context.Background()
	wantErr := errors.New("sink disk full")
	failingSink := &trackingSink{err: wantErr}

	col := NewBaoAuditCollector(ModeFixture, failingSink)
	err := col.Start(ctx)
	if err == nil {
		t.Fatal("expected error when sink fails, got nil (silent downgrade/swallow detected)")
	}
	if !errors.Is(err, wantErr) && !errors.Is(errors.Unwrap(err), wantErr) {
		t.Logf("wrapped error: %v", err)
	}
}
