// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

import (
	"context"
	"fmt"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Mode is the collector's operational mode, mirroring gcpaudit/awslogs: off,
// fixture or live.
type Mode string

const (
	ModeOff     Mode = "off"
	ModeFixture Mode = "fixture"
	ModeLive    Mode = "live"
)

// ParseMode maps a string to a Mode, defaulting to off for anything unknown —
// an unrecognised mode is a disabled collector, never a live one by accident.
func ParseMode(s string) Mode {
	switch s {
	case string(ModeLive):
		return ModeLive
	case string(ModeFixture):
		return ModeFixture
	default:
		return ModeOff
	}
}

// Sink is the narrow consumer this collector writes to. It is declared here, not
// imported from package collectors, so collectors can register this package
// through an adapter without an import cycle — the awslogs pattern.
type Sink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// Config selects the live source and its input. Fixture and off modes ignore
// every field. Tenancy is deliberately absent: it is stamped by the binder in
// the adapter (SLAWS D7), never read from an audit record.
type Config struct {
	// SourceName selects the live source: "warden-local" (default), "eks",
	// "gke" or "aks".
	SourceName string
	// AuditLogPath is the file the warden-local source reads.
	AuditLogPath string
	// Cloud is the configuration a deferred live cloud source would use.
	Cloud CloudConfig
}

// Environment variable names. The adapter resolves the mode; these configure the
// source once live.
const (
	EnvSource       = "K8SAUDIT_SOURCE"
	EnvAuditLogPath = "K8SAUDIT_AUDIT_LOG_PATH"
	EnvAuditLogAlt  = "COLLECTOR_K8SAUDIT_KUBE_AUDIT_LOG"
	EnvCloudLoc     = "K8SAUDIT_CLOUD_LOCATION"
)

// ConfigFromEnv reads the live-source configuration. It never reads the mode:
// that is the registry's job, through the same COLLECTOR_/SIGNAL_ aliases every
// other collector uses.
func ConfigFromEnv() Config {
	path := os.Getenv(EnvAuditLogPath)
	if path == "" {
		path = os.Getenv(EnvAuditLogAlt)
	}
	source := os.Getenv(EnvSource)
	if source == "" {
		source = "warden-local"
	}
	return Config{
		SourceName:   source,
		AuditLogPath: path,
		Cloud: CloudConfig{
			Provider: CloudProvider(source),
			Location: os.Getenv(EnvCloudLoc),
		},
	}
}

// Collector is the k8saudit-kube reference vertical: one Projector over a
// mode-selected Source, writing LayerKubernetes observations to a Sink.
type Collector struct {
	mode   Mode
	cfg    Config
	sink   Sink
	source Source
}

// New builds a collector. It does not touch the source until Start, so
// constructing a live collector with a missing audit path is not an error until
// the collector is actually started (matching the other collectors' lifecycle).
func New(mode Mode, cfg Config, sink Sink) *Collector {
	return &Collector{mode: mode, cfg: cfg, sink: sink}
}

// Name is the stable collector name.
func (c *Collector) Name() string { return "k8saudit-kube" }

// Mode returns the configured mode.
func (c *Collector) Mode() Mode { return c.mode }

// Start selects the source for the mode and drains it once into the sink.
//
// Draining once (rather than looping) matches fixture/gcpaudit: the demo and the
// offline tests ingest a bounded corpus. A streaming deployment wraps Drain in
// its own poll loop; the Source contract (Drain acknowledges by not re-yielding)
// is written so that loop is correct without change here.
func (c *Collector) Start(ctx context.Context) error {
	if c.mode == ModeOff {
		return nil
	}

	src, err := c.resolveSource()
	if err != nil {
		return err
	}
	c.source = src

	events, err := src.Drain(ctx)
	if err != nil {
		return fmt.Errorf("k8saudit: draining source %q: %w", src.Name(), err)
	}
	return c.project(ctx, events)
}

func (c *Collector) resolveSource() (Source, error) {
	switch c.mode {
	case ModeFixture:
		events, err := FixtureEvents()
		if err != nil {
			return nil, fmt.Errorf("k8saudit: loading embedded fixtures: %w", err)
		}
		return newFixtureSource(events), nil
	case ModeLive:
		return c.resolveLiveSource()
	default:
		return nil, fmt.Errorf("k8saudit: unknown mode %q", c.mode)
	}
}

func (c *Collector) resolveLiveSource() (Source, error) {
	switch c.cfg.SourceName {
	case "", "warden-local":
		if c.cfg.AuditLogPath == "" {
			return nil, ErrNoAuditLogPath
		}
		return newWardenLocalFileSource(c.cfg.AuditLogPath), nil
	case string(ProviderEKS), string(ProviderGKE), string(ProviderAKS):
		provider := CloudProvider(c.cfg.SourceName)
		client, err := liveCloudClient(provider, c.cfg.Cloud)
		if err != nil {
			return nil, err // ErrCloudLiveDeferred until a live factory is registered
		}
		return newCloudSource(provider, client), nil
	default:
		return nil, fmt.Errorf("k8saudit: unknown source %q (want warden-local|eks|gke|aks)", c.cfg.SourceName)
	}
}

// project maps every event and ingests the ones that yield an observation. A
// projection that attributes nothing is skipped, not failed: apiserver noise is
// expected in a real stream.
func (c *Collector) project(ctx context.Context, events []AuditEvent) error {
	if c.sink == nil {
		return nil
	}
	var p Projector
	for i := range events {
		obs, ok := p.Project(events[i], "")
		if !ok {
			continue
		}
		o := obs
		if err := c.sink.IngestObservation(ctx, &o); err != nil {
			return fmt.Errorf("k8saudit: ingesting %s: %w", o.ID, err)
		}
	}
	return nil
}

// Health reports the collector healthy. Fixture and warden-local drain
// synchronously at Start, so a started collector is by construction healthy;
// there is no background connection to probe. Live cloud health would live in
// the deferred client.
func (c *Collector) Health(_ context.Context) error { return nil }

// Stop is a no-op: Start drains synchronously and holds no goroutine, file
// handle or connection open past its return.
func (c *Collector) Stop() {}
