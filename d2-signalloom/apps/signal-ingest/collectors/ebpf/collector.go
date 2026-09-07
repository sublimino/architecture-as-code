// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
)

// CollectorName is the registry name for the Tetragon collector.
//
// Deliberately NOT "netebpf". The netebpf collector consumes stun-sentinel's
// socket traces and is owned by a different card; giving Tetragon its own name
// keeps the two sources independently mode-gateable and independently
// diagnosable in `collector started` log lines.
const CollectorName = "tetragon"

// Environment variables consumed by NewCollectorFromEnv.
const (
	EnvMode              = "COLLECTOR_TETRAGON_MODE"
	EnvModeAlt           = "SIGNAL_COLLECTOR_TETRAGON"
	EnvModeLegacy        = "TETRAGON_MODE"
	EnvSocketPath        = "TETRAGON_SOCKET_PATH"
	EnvRingCapacity      = "TETRAGON_RING_CAPACITY"
	EnvAllowedNamespaces = "TETRAGON_NAMESPACES"
)

// Collector adapts the Tetragon StreamClient to the signal-ingest collector
// lifecycle interface (Name / Mode / Start, plus optional Health and Stop).
type Collector struct {
	mode   collectors.Mode
	sink   collectors.IngestionSink
	cfg    StreamConfig
	client *StreamClient
	flow   *netebpf.LiveNetworkEgressCollector
	cancel context.CancelFunc
}

// NewCollector constructs a Tetragon collector writing into sink.
func NewCollector(mode collectors.Mode, sink collectors.IngestionSink, cfg StreamConfig) *Collector {
	return &Collector{mode: mode, sink: sink, cfg: cfg.withDefaults()}
}

// NewCollectorFromEnv constructs a Tetragon collector configured from the
// environment, defaulting to ModeOff when unset. Off-by-default matches every
// sibling collector: a collector that started dialling a socket merely because
// the binary was upgraded would be a surprise in production.
func NewCollectorFromEnv(sink collectors.IngestionSink) *Collector {
	mode := collectors.ParseMode(firstNonEmptyEnv(EnvMode, EnvModeAlt, EnvModeLegacy))

	cfg := StreamConfig{
		SocketPath: os.Getenv(EnvSocketPath),
		Logger:     slog.Default(),
	}
	if raw := os.Getenv(EnvRingCapacity); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			cfg.RingCapacity = n
		}
	}
	if raw := os.Getenv(EnvAllowedNamespaces); raw != "" {
		for _, ns := range strings.Split(raw, ",") {
			if ns = strings.TrimSpace(ns); ns != "" {
				cfg.AllowedNamespaces = append(cfg.AllowedNamespaces, ns)
			}
		}
	}

	return NewCollector(mode, sink, cfg)
}

// Name satisfies collectors.Collector.
func (c *Collector) Name() string { return CollectorName }

// Mode satisfies collectors.Collector.
func (c *Collector) Mode() collectors.Mode { return c.mode }

// Client exposes the underlying stream client for metrics scraping and tests.
// It is nil until Start has run in live mode.
func (c *Collector) Client() *StreamClient { return c.client }

// Metrics returns the collector's counters, or a zeroed set before Start.
// Returning a zeroed set rather than nil means a /metrics scrape before startup
// renders "0" instead of panicking or returning an empty body that reads as
// "this collector does not exist".
func (c *Collector) Metrics() *Metrics {
	if c.client == nil {
		return NewMetrics()
	}
	return c.client.Metrics()
}

// Start satisfies collectors.Collector.
//
// In ModeLive it dials Tetragon and spawns the reader and drain goroutines. It
// does NOT block on a successful connection: Tetragon may legitimately start
// after signal-ingest, and refusing to boot until the socket exists would make
// pod start ordering load-bearing. The reconnect loop covers the gap.
func (c *Collector) Start(ctx context.Context) error {
	switch c.mode {
	case collectors.ModeOff:
		return nil

	case collectors.ModeFixture:
		return c.startFixture(ctx)

	case collectors.ModeLive:
		runCtx, cancel := context.WithCancel(ctx)
		c.cancel = cancel

		c.flow = netebpf.NewLiveNetworkEgressCollector(runCtx, c.sink)
		c.client = NewStreamClient(c.cfg, c.flow)

		go func() {
			if err := c.client.Run(runCtx); err != nil && runCtx.Err() == nil {
				c.cfg.Logger.Error("tetragon stream client stopped", "error", err)
			}
		}()
		go func() {
			if err := c.client.Drain(runCtx); err != nil && runCtx.Err() == nil {
				c.cfg.Logger.Error("tetragon drain loop stopped", "error", err)
			}
		}()
		return nil
	}
	return nil
}

// startFixture ingests one deterministic event of each modelled class so that
// an offline demo shows the Tetragon lane populated rather than blank.
func (c *Collector) startFixture(ctx context.Context) error {
	if c.sink == nil {
		return nil
	}
	c.flow = netebpf.NewLiveNetworkEgressCollector(ctx, c.sink)
	for _, ev := range FixtureFlowEvents() {
		e := ev
		if err := c.flow.ProcessFlowEvent(ctx, e); err != nil {
			return err
		}
	}
	return nil
}

// Health satisfies collectors.HealthChecker. In live mode it reports unhealthy
// when the socket is absent, which is the single most common misconfiguration
// (Tetragon not installed, or installed with grpc.enabled=false).
func (c *Collector) Health(ctx context.Context) error {
	if c.mode != collectors.ModeLive {
		return nil
	}
	if _, err := os.Stat(c.cfg.SocketPath); err != nil {
		return err
	}
	return nil
}

// Stop satisfies collectors.Stopper.
func (c *Collector) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
	if c.client != nil {
		c.client.Close()
	}
	if c.flow != nil {
		c.flow.Close()
	}
}

func firstNonEmptyEnv(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return ""
}
