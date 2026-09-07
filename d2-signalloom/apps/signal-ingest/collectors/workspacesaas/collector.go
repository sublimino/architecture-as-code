package workspacesaas

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Mode defines the operational mode of the workspacesaas collector.
type Mode string

const (
	ModeLive    Mode = "live"
	ModeFixture Mode = "fixture"
	ModeOff     Mode = "off"
)

// ErrLiveDeferred is the explicit deferred / not-implemented error returned when
// live mode is started. Live provider integration for Google Workspace and Microsoft 365
// is deliberately deferred by design under SFDP-P2-6 to stabilize the adapter contract first.
var ErrLiveDeferred = errors.New("live mode deferred: Google Workspace and Microsoft 365 SaaS live API adapters are deferred (see SFDP-P2-6)")

// IngestionSink receives converted model observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// Option configures the Collector.
type Option func(*Collector)

// WithFixtureObservations sets custom fixture observations to emit in fixture mode.
func WithFixtureObservations(fixtures []model.Observation) Option {
	return func(c *Collector) {
		c.fixtures = fixtures
	}
}

// WithAdapter configures a custom SaaSAdapter implementation.
func WithAdapter(adapter SaaSAdapter) Option {
	return func(c *Collector) {
		c.adapter = adapter
	}
}

// Collector implements the workspace/M365 SaaS collector.
type Collector struct {
	mu       sync.RWMutex
	mode     Mode
	sink     IngestionSink
	adapter  SaaSAdapter
	fixtures []model.Observation
	cancel   context.CancelFunc
}

// NewCollector creates a new workspacesaas collector.
func NewCollector(mode Mode, sink IngestionSink, opts ...Option) *Collector {
	c := &Collector{
		mode: mode,
		sink: sink,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// Name returns the standard collector identifier.
func (c *Collector) Name() string {
	return "workspacesaas"
}

// Mode returns the configured operational mode.
func (c *Collector) Mode() Mode {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.mode
}

// Start activates the collector based on its configured mode.
// In ModeOff: returns nil (no-op).
// In ModeFixture: emits SaaS fixture observations to the sink.
// In ModeLive: returns ErrLiveDeferred (explicit deferred signal, never a silent pass).
func (c *Collector) Start(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	switch c.mode {
	case ModeOff:
		return nil

	case ModeFixture:
		if c.sink == nil {
			return nil
		}
		// Emit configured fixtures or default sample fixtures
		fixtures := c.fixtures
		if len(fixtures) == 0 {
			fixtures = DefaultWorkspaceFixtures(time.Now().UTC())
		}
		for _, obs := range fixtures {
			o := obs
			if err := c.sink.IngestObservation(ctx, &o); err != nil {
				return fmt.Errorf("workspacesaas fixture ingestion failed: %w", err)
			}
		}
		return nil

	case ModeLive:
		// Explicit not-implemented / deferred signal for live mode
		return fmt.Errorf("workspacesaas: %w", ErrLiveDeferred)

	default:
		return nil
	}
}

// Health verifies the readiness of the collector source.
// In ModeLive, reports ErrLiveDeferred to ensure unconfigured/deferred live mode is not reported ready.
func (c *Collector) Health(ctx context.Context) error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.mode == ModeLive {
		return fmt.Errorf("workspacesaas health: %w", ErrLiveDeferred)
	}
	return nil
}

// Stop cleanly terminates any running background loops.
func (c *Collector) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
}

// Close is an alias for Stop.
func (c *Collector) Close() {
	c.Stop()
}
