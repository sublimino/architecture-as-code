// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
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

// ErrLiveDeferred is the explicit deferred / not-implemented error returned when
// live mode is started. The sentinel eBPF endpoint stream reaches signal-ingest
// over /api/v1/observations; the in-collector live wiring that subscribes to it
// is deliberately deferred so the projection contract (ProjectEndpoint) and the
// endpoint-runtime bundle stabilise first. This mirrors the deferred-live seam of
// the awslogs and k8saudit cloud sources — live mode never silently passes.
var ErrLiveDeferred = errors.New(
	"ebpf-endpoint: live mode deferred — sentinel eBPF syscall observations arrive over /api/v1/observations; " +
		"the in-collector subscriber is not yet wired (fixture mode replays the embedded corpus)")

// Collector adapts the sentinel eBPF endpoint projection to the signal-ingest
// collector lifecycle interface (Name / Mode / Start, plus Health and Stop).
type Collector struct {
	mode   collectors.Mode
	sink   collectors.IngestionSink
	cancel context.CancelFunc
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

// Start satisfies collectors.Collector.
//
//   - ModeOff:     no-op.
//   - ModeFixture: replays the embedded endpoint corpus through ProjectEndpoint —
//     the SAME projection production uses — so an offline demo shows the endpoint
//     lane populated rather than blank.
//   - ModeLive:    returns ErrLiveDeferred. The live subscriber to the sentinel
//     eBPF syscall stream is a follow-up; until it lands, live mode fails loudly
//     rather than reporting a silent success it has not earned.
func (c *Collector) Start(ctx context.Context) error {
	switch c.mode {
	case collectors.ModeOff:
		return nil

	case collectors.ModeFixture:
		return c.startFixture(ctx)

	case collectors.ModeLive:
		return ErrLiveDeferred
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

// Health satisfies collectors.HealthChecker. In live mode it reports
// ErrLiveDeferred so an unconfigured/deferred live mode is never reported ready;
// every other mode is healthy.
func (c *Collector) Health(_ context.Context) error {
	if c.mode == collectors.ModeLive {
		return ErrLiveDeferred
	}
	return nil
}

// Stop satisfies collectors.Stopper.
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
