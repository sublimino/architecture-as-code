// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package kagent

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// IngestionSink is the consumer interface that receives drained or converted observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// Collector manages Kagent telemetry ingestion, resolution, and lifecycle.
type Collector struct {
	sink        IngestionSink
	resolver    *Resolver
	inboundCh   chan TelemetrySpan
	ctx         context.Context
	cancel      context.CancelFunc
	wg          sync.WaitGroup
	running     atomic.Bool
	healthy     atomic.Bool
	eventsCount atomic.Uint64
	errCount    atomic.Uint64
}

// NewCollector creates a new Kagent telemetry collector.
func NewCollector(sink IngestionSink, cfg ResolverConfig) *Collector {
	ctx, cancel := context.WithCancel(context.Background())
	return &Collector{
		sink:      sink,
		resolver:  NewResolver(cfg),
		inboundCh: make(chan TelemetrySpan, 1024),
		ctx:       ctx,
		cancel:    cancel,
	}
}

// Name returns the collector identifier.
func (c *Collector) Name() string {
	return "kagent"
}

// Resolver returns the underlying Resolver.
func (c *Collector) Resolver() *Resolver {
	return c.resolver
}

// Start launches the collector lifecycle routines non-blockingly.
func (c *Collector) Start(ctx context.Context) error {
	if c.running.CompareAndSwap(false, true) {
		c.healthy.Store(true)
		c.wg.Add(1)
		go c.consumeLoop()
	}
	return nil
}

// Stop terminates all collector worker routines cleanly.
func (c *Collector) Stop() {
	if c.running.CompareAndSwap(true, false) {
		if c.cancel != nil {
			c.cancel()
		}
		c.wg.Wait()
		c.healthy.Store(false)
	}
}

// Health reports the operational readiness of the collector.
func (c *Collector) Health(ctx context.Context) error {
	if !c.healthy.Load() {
		return fmt.Errorf("kagent collector is not healthy")
	}
	return nil
}

// IngestSpan processes and drains a TelemetrySpan immediately into the sink.
func (c *Collector) IngestSpan(ctx context.Context, span TelemetrySpan) (*ResolutionResult, error) {
	res, err := c.resolver.Resolve(span)
	if err != nil {
		c.errCount.Add(1)
		return nil, err
	}

	if c.sink != nil && res.Observation != nil {
		if err := c.sink.IngestObservation(ctx, res.Observation); err != nil {
			c.errCount.Add(1)
			return nil, fmt.Errorf("failed to ingest observation: %w", err)
		}
		c.eventsCount.Add(1)
	}

	return res, nil
}

// FeedSpan enqueues a TelemetrySpan for asynchronous consumption in Live mode.
func (c *Collector) FeedSpan(span TelemetrySpan) bool {
	if !c.running.Load() {
		return false
	}
	select {
	case c.inboundCh <- span:
		return true
	default:
		slog.Warn("kagent inbound channel full, dropping span", "span_id", span.SpanID)
		return false
	}
}

func (c *Collector) consumeLoop() {
	defer c.wg.Done()

	for {
		select {
		case <-c.ctx.Done():
			return
		case span, ok := <-c.inboundCh:
			if !ok {
				return
			}
			if _, err := c.IngestSpan(c.ctx, span); err != nil {
				slog.Error("kagent span resolution error in consumer loop", "error", err, "span_id", span.SpanID)
			}
		}
	}
}

// CalibratedP0Fixtures returns deterministic observations derived directly from the P0 live trace.
func CalibratedP0Fixtures(baseTime time.Time) []model.Observation {
	resolver := NewResolver(ResolverConfig{
		TrustDomain: DefaultTrustDomain,
	})

	// Exact span captured during P0 calibration:
	span := TelemetrySpan{
		SpanID:         "p0-calibrated-span-001",
		TraceID:        "p0-calibrated-trace-001",
		Name:           SpanNameToolExecution,
		Timestamp:      baseTime,
		RuntimeVersion: RuntimeVersion0_9_9,
		Attributes: map[string]string{
			AttrAgentNamespace: "fe-signalloom-agents",
			AttrAgentName:      "kagent-k8s-reader",
			AttrAppName:        "fe_signalloom_agents__NS__kagent_k8s_reader",
			AttrToolName:       "k8s_get_resources",
			AttrFunctionCallID: "toolu_01HSGfBFovPGeMjBaUPhGfUj",
			AttrContextID:      "01a0722f-a1c4-7963-890c-37184946daca",
			AttrTaskID:         "01a0722f-a1c4-7874-a9c0-d55a1638c1e5",
			AttrUserID:         "admin@kagent.dev",
			AttrAuthType:       "unverified_session",
		},
	}

	res, err := resolver.Resolve(span)
	if err != nil {
		panic(fmt.Sprintf("calibrated fixture generation failed: %v", err))
	}

	return []model.Observation{*res.Observation}
}
