// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"

	// Linking the live package in is what gives the awslogs collector a live mode: it
	// registers the aws-sdk-go-v2 implementation of the SQS, S3 and STS seams through
	// awslogs.SetLiveClientFactory from its init (SLAWS P3-1).
	//
	// It has to be a blank import here rather than a direct call from
	// Collector.Start, because the live package imports awslogs for Message,
	// ObjectRef and Credentials, so the dependency can only run one way. Keeping the
	// SDK out of the core package is the point — fixture mode and the §2.3 contract
	// tests build without it.
	//
	// The import is in the awslogs adapter rather than in main so that anything
	// constructing a registry gets live mode, including the mode-matrix tests that
	// assert the gate. Dropping it does not break the build; it silently turns live
	// mode into ErrLiveClientsNotWired, which is what
	// TestAWSLogsLiveModeIsWired guards against.
	_ "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/live"
)

// AWSLogsCollector adapts the awslogs package to the Collector interface.
//
// It lives in its own file rather than in adapters.go so the awslogs card touches no
// shared adapter code. The adapter is also the layer that applies the tenant binder:
// awslogs declares its own narrow Sink interface and does not import this package
// (which is what lets this package register it without an import cycle), so
// BindTenant is applied here, where both sides are in scope.
type AWSLogsCollector struct {
	name     string
	mode     Mode
	sink     IngestionSink
	cfg      awslogs.AWSCollectorConfig
	col      *awslogs.Collector
	opts     []awslogs.Option
	healthFn func(ctx context.Context) error
	startFn  func(ctx context.Context) error
}

// NewAWSLogsCollector creates an AWSLogsCollector for one customer account, reading
// that account's configuration from the environment.
func NewAWSLogsCollector(mode Mode, sink IngestionSink) *AWSLogsCollector {
	return NewAWSLogsCollectorWithConfig(mode, sink, awslogs.ConfigFromEnv())
}

// NewAWSLogsCollectorsFromEnv creates AWSLogsCollector instances from the environment.
// If COLLECTOR_AWSLOGS_ACCOUNTS is populated, it returns one collector per declared account,
// where the first retains Name() "awslogs" and subsequent instances report "awslogs/<account_id>".
// If COLLECTOR_AWSLOGS_ACCOUNTS is empty or unset, it returns a single collector configured from
// the individual AWSLOGS_* environment variables.
func NewAWSLogsCollectorsFromEnv(mode Mode, sink IngestionSink) ([]Collector, error) {
	cfgs, err := awslogs.AccountsFromEnv()
	if err != nil {
		return nil, err
	}
	if len(cfgs) == 0 {
		return []Collector{NewAWSLogsCollector(mode, sink)}, nil
	}

	cols := make([]Collector, len(cfgs))
	for i, cfg := range cfgs {
		name := "awslogs"
		if i > 0 {
			if cfg.AccountID != "" {
				name = fmt.Sprintf("awslogs/%s", cfg.AccountID)
			} else {
				name = fmt.Sprintf("awslogs/%d", i)
			}
		}
		c := NewAWSLogsCollectorWithConfig(mode, sink, cfg)
		c.name = name
		cols[i] = c
	}
	return cols, nil
}

// NewAWSLogsCollectorWithConfig creates an AWSLogsCollector for an explicitly supplied
// account configuration.
//
// There is one instance per account (SLAWS D7). A deployment serving several accounts
// registers several of these, each with its own config and therefore its own tenant;
// nothing about an account's tenancy is ever taken from a record.
func NewAWSLogsCollectorWithConfig(mode Mode, sink IngestionSink, cfg awslogs.AWSCollectorConfig, opts ...awslogs.Option) *AWSLogsCollector {
	return &AWSLogsCollector{mode: mode, sink: sink, cfg: cfg, opts: opts}
}

func (c *AWSLogsCollector) Name() string {
	if c.name != "" {
		return c.name
	}
	return "awslogs"
}

// Mode returns the configured mode. The v1 stub hard-coded live (§8).
func (c *AWSLogsCollector) Mode() Mode { return c.mode }

func (c *AWSLogsCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }
func (c *AWSLogsCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }

// RawCollector exposes the underlying collector, nil until Start has built it.
func (c *AWSLogsCollector) RawCollector() *awslogs.Collector { return c.col }

// Config returns the account configuration this instance was built with.
func (c *AWSLogsCollector) Config() awslogs.AWSCollectorConfig { return c.cfg }

// boundSink wraps the registry's sink with the tenant binder, so every observation
// this collector produces is bound to the tenant from its CONFIGURATION.
//
// This is the in-process half of SLAWS D7: the HTTP path binds tenancy at the API
// boundary, and §8 records that the in-process StoreSink path had no binder at all.
// A collector whose tenancy came from the record it just parsed would let a crafted
// CloudTrail payload write into another customer's data.
func (c *AWSLogsCollector) boundSink() awslogs.Sink {
	if c.sink == nil {
		return nil
	}
	return BindTenant(c.sink, c.cfg.TenantID)
}

func (c *AWSLogsCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	if c.mode == ModeOff {
		return nil
	}

	if c.col == nil {
		opts := append([]awslogs.Option{awslogs.WithMode(string(c.mode))}, c.opts...)
		col, err := awslogs.New(c.cfg, c.boundSink(), opts...)
		if err != nil {
			return fmt.Errorf("awslogs collector configuration rejected: %w", err)
		}
		c.col = col
	}
	return c.col.Start(ctx)
}

func (c *AWSLogsCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	if c.col != nil {
		return c.col.Health(ctx)
	}
	return nil
}

// Stop satisfies Stopper. The v1 `Stop() error` did not, so the registry's teardown
// silently skipped this collector (§8).
func (c *AWSLogsCollector) Stop() {
	if c.col != nil {
		c.col.Stop()
	}
}

// AWSLogsFixtures returns the observations fixture mode replays, which is where the
// mode matrix gets its expected count. Deriving it rather than hard-coding a number
// means a fixture added to testdata/ needs no test edit.
func AWSLogsFixtures(_ time.Time) []model.Observation {
	cfg := awslogs.ConfigFromEnv()
	obs, err := awslogs.FixtureObservations(cfg.TenantID, cfg.Region)
	if err != nil {
		// Unreachable unless the embedded fixtures are malformed, which the awslogs
		// contract tests would have caught first.
		return nil
	}
	return obs
}

// AWSLogsAcceptTwinObservation is a valid cloud-control-plane observation for the
// registry coverage guard's accept twin.
func AWSLogsAcceptTwinObservation(_ time.Time) model.Observation {
	obs := AWSLogsFixtures(time.Time{})
	if len(obs) == 0 {
		return model.Observation{}
	}
	return obs[0]
}

// AWSLogsRejectTwinObservation is deliberately invalid: no ID, no timestamp and an
// unknown layer, so the guard's reject twin fails Validate as it must.
func AWSLogsRejectTwinObservation() model.Observation {
	return model.Observation{
		Layer:      model.Layer("not_a_layer"),
		Source:     "",
		Confidence: 7.5,
	}
}
