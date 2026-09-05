package collectors

import (
	"context"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/gcpaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea"
)

// GCPAuditCollector adapts the gcpaudit package to the Collector interface.
type GCPAuditCollector struct {
	mode     Mode
	sink     IngestionSink
	col      *gcpaudit.Collector
	healthFn func(ctx context.Context) error
	startFn  func(ctx context.Context) error
}

// NewGCPAuditCollector creates a GCPAuditCollector.
func NewGCPAuditCollector(mode Mode, sink IngestionSink) *GCPAuditCollector {
	return &GCPAuditCollector{mode: mode, sink: sink}
}

func (c *GCPAuditCollector) Name() string { return "gcpaudit" }
func (c *GCPAuditCollector) Mode() Mode   { return c.mode }

func (c *GCPAuditCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }
func (c *GCPAuditCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *GCPAuditCollector) RawCollector() *gcpaudit.Collector                { return c.col }

func (c *GCPAuditCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	if c.col == nil {
		c.col = gcpaudit.New(ctx, c.sink, 0, gcpaudit.WithMode(string(c.mode)))
	}
	return c.col.Start(ctx)
}

func (c *GCPAuditCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	if c.col != nil {
		return c.col.Health(ctx)
	}
	return nil
}

func (c *GCPAuditCollector) Stop() {
	if c.col != nil {
		c.col.Close()
	}
}

// BaoAuditCollector adapts the baoaudit package to the Collector interface.
type BaoAuditCollector struct {
	mode     Mode
	sink     IngestionSink
	rcv      *baoaudit.AuditReceiver
	healthFn func(ctx context.Context) error
	startFn  func(ctx context.Context) error
}

// NewBaoAuditCollector creates a BaoAuditCollector.
func NewBaoAuditCollector(mode Mode, sink IngestionSink) *BaoAuditCollector {
	return &BaoAuditCollector{mode: mode, sink: sink}
}

func (c *BaoAuditCollector) Name() string { return "baoaudit" }
func (c *BaoAuditCollector) Mode() Mode   { return c.mode }

func (c *BaoAuditCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }
func (c *BaoAuditCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *BaoAuditCollector) RawReceiver() *baoaudit.AuditReceiver             { return c.rcv }

func (c *BaoAuditCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	switch c.mode {
	case ModeOff:
		return nil
	case ModeFixture:
		if c.sink != nil {
			for _, obs := range IdentityAuthFixtures(time.Now().UTC()) {
				o := obs
				if err := c.sink.IngestObservation(ctx, &o); err != nil {
					return fmt.Errorf("bao fixture ingestion failed: %w", err)
				}
			}
		}
		return nil
	case ModeLive:
		if c.rcv == nil {
			c.rcv = baoaudit.NewAuditReceiver(1000, c.sink)
		}
		c.rcv.Start()
		return nil
	}
	return nil
}

func (c *BaoAuditCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	return nil
}

func (c *BaoAuditCollector) Stop() {
	if c.rcv != nil {
		c.rcv.Stop()
	}
}

// SPIREACollector adapts the spirea package to the Collector interface.
type SPIREACollector struct {
	mode     Mode
	sink     IngestionSink
	col      *spirea.SPIREIssuanceCollector
	healthFn func(ctx context.Context) error
	startFn  func(ctx context.Context) error
}

// NewSPIREACollector creates a SPIREACollector.
func NewSPIREACollector(mode Mode, sink IngestionSink) *SPIREACollector {
	return &SPIREACollector{mode: mode, sink: sink}
}

func (c *SPIREACollector) Name() string { return "spirea" }
func (c *SPIREACollector) Mode() Mode   { return c.mode }

func (c *SPIREACollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }
func (c *SPIREACollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *SPIREACollector) RawCollector() *spirea.SPIREIssuanceCollector       { return c.col }

func (c *SPIREACollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	switch c.mode {
	case ModeOff:
		return nil
	case ModeFixture:
		if c.sink != nil {
			for _, obs := range IdentityAuthFixtures(time.Now().UTC()) {
				o := obs
				if err := c.sink.IngestObservation(ctx, &o); err != nil {
					return fmt.Errorf("spire fixture ingestion failed: %w", err)
				}
			}
		}
		return nil
	case ModeLive:
		if c.col == nil {
			c.col = spirea.NewSPIREIssuanceCollector(c.sink)
		}
		c.col.Start()
		return nil
	}
	return nil
}

func (c *SPIREACollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	return nil
}

func (c *SPIREACollector) Stop() {
	if c.col != nil {
		c.col.Stop()
	}
}

// NetEBPFCollector adapts the netebpf package to the Collector interface.
type NetEBPFCollector struct {
	mode     Mode
	sink     IngestionSink
	col      *netebpf.LiveNetworkEgressCollector
	healthFn func(ctx context.Context) error
	startFn  func(ctx context.Context) error
}

// NewNetEBPFCollector creates a NetEBPFCollector.
func NewNetEBPFCollector(mode Mode, sink IngestionSink) *NetEBPFCollector {
	return &NetEBPFCollector{mode: mode, sink: sink}
}

func (c *NetEBPFCollector) Name() string { return "netebpf" }
func (c *NetEBPFCollector) Mode() Mode   { return c.mode }

func (c *NetEBPFCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }
func (c *NetEBPFCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *NetEBPFCollector) RawCollector() *netebpf.LiveNetworkEgressCollector { return c.col }

func (c *NetEBPFCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	switch c.mode {
	case ModeOff:
		return nil
	case ModeFixture:
		if c.sink != nil {
			for _, obs := range NetworkEgressFixtures(time.Now().UTC()) {
				o := obs
				if err := c.sink.IngestObservation(ctx, &o); err != nil {
					return fmt.Errorf("netebpf fixture ingestion failed: %w", err)
				}
			}
		}
		return nil
	case ModeLive:
		if c.col == nil {
			c.col = netebpf.NewLiveNetworkEgressCollector(ctx, c.sink)
		}
		return nil
	}
	return nil
}

func (c *NetEBPFCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	return nil
}

func (c *NetEBPFCollector) Stop() {
	if c.col != nil {
		c.col.Close()
	}
}

// K8sAuditCollector adapts the Kubernetes APIServer audit WebhookReceiver to the Collector interface.
type K8sAuditCollector struct {
	mode     Mode
	sink     IngestionSink
	rcv      *audit.WebhookReceiver
	healthFn func(ctx context.Context) error
	startFn  func(ctx context.Context) error
}

// NewK8sAuditCollector creates a K8sAuditCollector.
func NewK8sAuditCollector(mode Mode, sink IngestionSink) *K8sAuditCollector {
	return &K8sAuditCollector{mode: mode, sink: sink}
}

func (c *K8sAuditCollector) Name() string { return "k8saudit" }
func (c *K8sAuditCollector) Mode() Mode   { return c.mode }

func (c *K8sAuditCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }
func (c *K8sAuditCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *K8sAuditCollector) RawReceiver() *audit.WebhookReceiver              { return c.rcv }

func (c *K8sAuditCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	switch c.mode {
	case ModeOff:
		return nil
	case ModeFixture:
		if c.sink != nil {
			for _, obs := range CloudControlPlaneFixtures(time.Now().UTC()) {
				o := obs
				if err := c.sink.IngestObservation(ctx, &o); err != nil {
					return fmt.Errorf("k8s audit fixture ingestion failed: %w", err)
				}
			}
		}
		return nil
	case ModeLive:
		if c.rcv == nil {
			c.rcv = audit.NewWebhookReceiver(ctx, 1000, 2, c.sink)
		}
		return nil
	}
	return nil
}

func (c *K8sAuditCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	return nil
}

func (c *K8sAuditCollector) Stop() {
	if c.rcv != nil {
		c.rcv.Close()
	}
}

// FixtureCollector seeds all deterministic fixtures when started.
type FixtureCollector struct {
	mode     Mode
	sink     IngestionSink
	startFn  func(ctx context.Context) error
	healthFn func(ctx context.Context) error
}

// NewFixtureCollector creates a FixtureCollector.
func NewFixtureCollector(mode Mode, sink IngestionSink) *FixtureCollector {
	return &FixtureCollector{mode: mode, sink: sink}
}

func (c *FixtureCollector) Name() string { return "fixtures" }
func (c *FixtureCollector) Mode() Mode   { return c.mode }

func (c *FixtureCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *FixtureCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }

func (c *FixtureCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	if c.mode == ModeOff {
		return nil
	}
	if c.sink != nil {
		for _, obs := range SeedAll(time.Now().UTC()) {
			o := obs
			if err := c.sink.IngestObservation(ctx, &o); err != nil {
				return fmt.Errorf("seed fixture ingestion failed: %w", err)
			}
		}
	}
	return nil
}

func (c *FixtureCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	return nil
}
