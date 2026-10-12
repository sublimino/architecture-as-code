// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
}

func (m *mockSink) IngestObservation(_ context.Context, obs *model.Observation) error {
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

// sliceEndpointEventStream is a deterministic, slice-backed EndpointEventStream.
// It yields each embedded event once, then io.EOF (closing done the first time,
// if set, so a Start-driven test can wait for the consume goroutine to drain).
// Each test uses its own instance driven from a single goroutine, so it needs no
// locking.
type sliceEndpointEventStream struct {
	events     []*netebpf.InboundFlowEvent
	index      int
	done       chan struct{}
	doneClosed bool
}

func (s *sliceEndpointEventStream) Recv(_ context.Context) (*netebpf.InboundFlowEvent, error) {
	if s.index < len(s.events) {
		ev := s.events[s.index]
		s.index++
		return ev, nil
	}

	if s.done != nil && !s.doneClosed {
		close(s.done)
		s.doneClosed = true
	}
	return nil, io.EOF
}

// TestLiveConsumeProjectsSyscallEvents drives the real consume loop over a mixed
// stream and asserts the projected endpoint_host observations land in the sink,
// that a network_connect event is skipped (it is egress, not endpoint), and that
// the counters reflect received/projected/skipped. This is the live-consume path
// the production ModeLive goroutine runs; breaking ProjectEndpoint turns it RED.
func TestLiveConsumeProjectsSyscallEvents(t *testing.T) {
	sink := &mockSink{}
	stream := &sliceEndpointEventStream{
		events: []*netebpf.InboundFlowEvent{
			{
				Classification: ClassFileAccess,
				Domain:         "/etc/shadow",
				ServiceAccount: "security-scanner",
				SeqNum:         1,
			},
			{
				Classification: ClassProcessExec,
				ServiceAccount: "build-agent",
				SeqNum:         2,
			},
			{
				Classification: ClassNetworkConnect,
				ServiceAccount: "network-agent",
				SeqNum:         3,
			},
		},
	}

	collector := NewCollector(collectors.ModeLive, sink)
	collector.SetStream(stream)

	if err := collector.consume(context.Background(), stream); err != nil {
		t.Fatalf("consume returned an error: %v", err)
	}

	observations := sink.getObservations()
	if len(observations) != 2 {
		t.Fatalf("observation count = %d, want 2", len(observations))
	}

	for i, obs := range observations {
		if obs.Source != EndpointObservationSource {
			t.Errorf("observation %d source = %q, want %q", i, obs.Source, EndpointObservationSource)
		}
		if obs.Layer != model.LayerEndpointHost {
			t.Errorf("observation %d layer = %q, want %q", i, obs.Layer, model.LayerEndpointHost)
		}
		if obs.RawEvidenceRef == "" {
			t.Errorf("observation %d has an empty raw evidence reference", i)
		}
	}

	fileAccess := observations[0]
	if got := fileAccess.Labels["target"]; got != "/etc/shadow" {
		t.Errorf("file-access target = %q, want %q", got, "/etc/shadow")
	}
	if got := fileAccess.Labels["syscall"]; got != "openat" {
		t.Errorf("file-access syscall = %q, want %q", got, "openat")
	}

	received, projected, skipped := collector.Stats()
	if received != 3 || projected != 2 || skipped != 1 {
		t.Fatalf(
			"Stats() = (%d, %d, %d), want (3, 2, 1)",
			received,
			projected,
			skipped,
		)
	}
}

// TestLiveModeRefusesWithoutStream guards the mode gate: a live collector with no
// stream wired must fail loudly (Start and Health), never report ready.
func TestLiveModeRefusesWithoutStream(t *testing.T) {
	collector := NewCollector(collectors.ModeLive, &mockSink{})

	err := collector.Start(context.Background())
	if !errors.Is(err, ErrLiveSourceNotWired) {
		t.Fatalf("Start() error = %v, want ErrLiveSourceNotWired", err)
	}

	err = collector.Health(context.Background())
	if !errors.Is(err, ErrLiveSourceNotWired) {
		t.Fatalf("Health() error = %v, want ErrLiveSourceNotWired", err)
	}
}

// TestLiveModeStartSpawnsConsumeGoroutine proves Start actually wires the
// background consume loop: it returns promptly (non-blocking), the goroutine
// drains the injected stream, and the projected observation reaches the sink.
func TestLiveModeStartSpawnsConsumeGoroutine(t *testing.T) {
	sink := &mockSink{}
	done := make(chan struct{})
	stream := &sliceEndpointEventStream{
		events: []*netebpf.InboundFlowEvent{
			{
				Classification: ClassProcessExec,
				ServiceAccount: "runtime-agent",
				SeqNum:         1,
			},
		},
		done: done,
	}

	collector := NewCollector(collectors.ModeLive, sink)
	collector.SetStream(stream)
	defer collector.Stop()

	if err := collector.Start(context.Background()); err != nil {
		t.Fatalf("Start() returned an error: %v", err)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the live consume goroutine")
	}

	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		_, projected, _ := collector.Stats()
		if projected >= 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("projected count = %d, want at least 1", projected)
		}
		time.Sleep(time.Millisecond)
	}

	observations := sink.getObservations()
	if len(observations) != 1 {
		t.Fatalf("observation count = %d, want 1", len(observations))
	}
}
