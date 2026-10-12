// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
)

// CollectorName is the registry name for the sentinel eBPF endpoint collector.
//
// Deliberately NOT "netebpf". The netebpf collector consumes the stun-sentinel's
// socket traces onto the network_egress layer and is owned by a different card;
// giving the endpoint syscall stream its own name keeps the two sources
// independently mode-gateable and independently diagnosable in
// `collector started` log lines.
const CollectorName = "ebpf-endpoint"

// Environment variables consumed by NewCollectorFromEnv. The retired
// COLLECTOR_TETRAGON_* variables are gone (P1-8); this stream is the
// stun-sentinel's own eBPF syscall trace, not Tetragon.
const (
	EnvMode    = "COLLECTOR_EBPF_ENDPOINT_MODE"
	EnvModeAlt = "SIGNAL_COLLECTOR_EBPF_ENDPOINT"
)

// LiveOriginRef is the RawEvidenceRef prefix every live-ingested observation
// carries. Sentinel syscall events reach signal-ingest over
// POST /api/v1/observations; combining this prefix with the event's SeqNum keeps
// every projected observation's RawEvidenceRef non-empty and distinguishable, so
// the e2e negative-discipline check can attribute an observation to its source.
const LiveOriginRef = "api/v1/observations"

// ErrLiveSourceNotWired is returned when live mode is started without a sentinel
// eBPF syscall stream injected via SetStream. Live mode fails loudly rather than
// reporting a healthy collector that consumes nothing — the same
// never-silently-pass discipline the deferred seam used to enforce, now that the
// consume-and-project loop itself is real.
var ErrLiveSourceNotWired = errors.New(
	"ebpf-endpoint: live mode has no sentinel eBPF syscall stream wired (SetStream was not called); " +
		"refusing to report a live collector that consumes nothing")

// EndpointEventStream is the injectable live source of sentinel eBPF syscall
// events. In production it is fed by the stun-sentinel posting normalised
// netebpf.InboundFlowEvent values to signal-ingest over POST
// /api/v1/observations; that subscriber is not reachable from a unit test or an
// offline sandbox, so the source is injected. Recv returns the next event,
// io.EOF when the stream is cleanly exhausted, or a non-nil error (including
// ctx.Err()) on cancellation or transport failure.
type EndpointEventStream interface {
	Recv(ctx context.Context) (*netebpf.InboundFlowEvent, error)
}

// Collector adapts the sentinel eBPF endpoint projection to the signal-ingest
// collector lifecycle interface (Name / Mode / Start, plus Health and Stop).
//
//   - ModeFixture replays the embedded endpoint corpus through ProjectEndpoint.
//   - ModeLive consumes the injected EndpointEventStream, projecting each event
//     through the SAME ProjectEndpoint and ingesting the endpoint_host results.
type Collector struct {
	mode   collectors.Mode
	sink   collectors.IngestionSink
	stream EndpointEventStream
	cancel context.CancelFunc

	receivedCount  uint64
	projectedCount uint64
	skippedCount   uint64

	mu     sync.Mutex
	runErr error
}

// NewCollector constructs an endpoint collector writing into sink.
func NewCollector(mode collectors.Mode, sink collectors.IngestionSink) *Collector {
	return &Collector{mode: mode, sink: sink}
}

// NewCollectorFromEnv constructs an endpoint collector configured from the
// environment, defaulting to ModeOff when unset. Off-by-default matches every
// sibling collector: a collector that started ingesting merely because the
// binary was upgraded would be a surprise in production.
func NewCollectorFromEnv(sink collectors.IngestionSink) *Collector {
	mode := collectors.ParseMode(firstNonEmptyEnv(EnvMode, EnvModeAlt))
	return NewCollector(mode, sink)
}

// Name satisfies collectors.Collector.
func (c *Collector) Name() string { return CollectorName }

// Mode satisfies collectors.Collector.
func (c *Collector) Mode() collectors.Mode { return c.mode }

// SetStream injects the sentinel eBPF syscall event stream consumed in live
// mode. It must be called before Start when the collector runs in ModeLive;
// otherwise Start fails with ErrLiveSourceNotWired.
func (c *Collector) SetStream(s EndpointEventStream) { c.stream = s }

// Start satisfies collectors.Collector.
//
//   - ModeOff:     no-op.
//   - ModeFixture: replays the embedded endpoint corpus through ProjectEndpoint —
//     the SAME projection production uses — so an offline demo shows the endpoint
//     lane populated rather than blank.
//   - ModeLive:    consumes the injected EndpointEventStream in a background
//     goroutine, projecting each event through ProjectEndpoint. With no stream
//     wired it returns ErrLiveSourceNotWired rather than reporting a silent
//     success. Start never blocks: the registry starts collectors synchronously
//     in a loop (collectors/registry.go), so the consume loop runs in its own
//     goroutine, cancelled by Stop.
func (c *Collector) Start(ctx context.Context) error {
	switch c.mode {
	case collectors.ModeOff:
		return nil

	case collectors.ModeFixture:
		return c.startFixture(ctx)

	case collectors.ModeLive:
		if c.stream == nil {
			return ErrLiveSourceNotWired
		}
		cctx, cancel := context.WithCancel(ctx)
		c.cancel = cancel
		go func() {
			if err := c.consume(cctx, c.stream); err != nil {
				c.mu.Lock()
				c.runErr = err
				c.mu.Unlock()
				slog.Error("ebpf-endpoint live consume loop terminated", "error", err)
			}
		}()
		return nil
	}
	return nil
}

// startFixture replays the embedded endpoint_testdata corpus through the
// production projection so fixture mode asserts the real contract.
func (c *Collector) startFixture(ctx context.Context) error {
	if c.sink == nil {
		return nil
	}
	obs, err := FixtureEndpointObservations()
	if err != nil {
		return fmt.Errorf("ebpf-endpoint fixture projection failed: %w", err)
	}
	for i := range obs {
		o := obs[i]
		if err := c.sink.IngestObservation(ctx, &o); err != nil {
			return fmt.Errorf("ebpf-endpoint fixture ingestion failed: %w", err)
		}
	}
	return nil
}

// ProcessSyscallEvent projects one live sentinel eBPF syscall event through
// ProjectEndpoint and ingests the result. It mirrors netebpf's ProcessFlowEvent:
// a nil event is an error, an event whose class is not a host-endpoint syscall
// (network_connect / unattributed / "") is correctly skipped rather than failed,
// and a sink ingestion failure is wrapped and propagated so the consume loop
// fails loudly instead of dropping evidence on the floor.
func (c *Collector) ProcessSyscallEvent(ctx context.Context, ev *netebpf.InboundFlowEvent) error {
	if ev == nil {
		return fmt.Errorf("ebpf-endpoint: nil syscall event")
	}

	atomic.AddUint64(&c.receivedCount, 1)

	obs, ok := ProjectEndpoint(ev, fmt.Sprintf("%s#%d", LiveOriginRef, ev.SeqNum))
	if !ok {
		atomic.AddUint64(&c.skippedCount, 1)
		return nil
	}

	if c.sink == nil {
		return nil
	}
	if err := c.sink.IngestObservation(ctx, &obs); err != nil {
		return fmt.Errorf("ebpf-endpoint live ingestion failed: %w", err)
	}

	atomic.AddUint64(&c.projectedCount, 1)
	return nil
}

// consume drains the stream, projecting and ingesting each event, until the
// stream is cleanly exhausted (io.EOF) or the context is cancelled — both of
// which are normal shutdown, not failures. Any other Recv error, or a sink
// ingestion failure surfaced by ProcessSyscallEvent, terminates the loop and is
// returned so the caller can record it on Health.
func (c *Collector) consume(ctx context.Context, stream EndpointEventStream) error {
	for {
		ev, err := stream.Recv(ctx)
		switch {
		case errors.Is(err, io.EOF):
			return nil
		case errors.Is(err, context.Canceled):
			return nil
		case errors.Is(err, context.DeadlineExceeded):
			return nil
		case err != nil:
			return fmt.Errorf("ebpf-endpoint live stream recv failed: %w", err)
		}

		if err := c.ProcessSyscallEvent(ctx, ev); err != nil {
			return err
		}
	}
}

// Health satisfies collectors.HealthChecker. In live mode it reports
// ErrLiveSourceNotWired when no stream is wired, and otherwise reports the
// terminal error of the consume loop (nil until the loop fails), so an
// unconfigured or failed live collector is never reported ready. Every other
// mode is healthy.
func (c *Collector) Health(_ context.Context) error {
	if c.mode != collectors.ModeLive {
		return nil
	}
	if c.stream == nil {
		return ErrLiveSourceNotWired
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.runErr
}

// Stats returns live events received, projected (ingested as endpoint_host
// observations), and skipped (non-endpoint classes).
func (c *Collector) Stats() (received, projected, skipped uint64) {
	return atomic.LoadUint64(&c.receivedCount),
		atomic.LoadUint64(&c.projectedCount),
		atomic.LoadUint64(&c.skippedCount)
}

// Stop satisfies collectors.Stopper. It cancels the live consume goroutine.
func (c *Collector) Stop() {
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
}

func firstNonEmptyEnv(keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return v
		}
	}
	return ""
}
