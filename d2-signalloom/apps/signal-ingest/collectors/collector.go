// Package collectors provides the collector wiring harness, mode gating, and fixture generators.
package collectors

import (
	"context"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Mode defines the operational mode of a collector: live, fixture, or off.
type Mode string

const (
	// ModeLive indicates the collector connects to real infrastructure/sources.
	ModeLive Mode = "live"
	// ModeFixture indicates the collector generates deterministic fixture observations.
	ModeFixture Mode = "fixture"
	// ModeOff indicates the collector is inactive.
	ModeOff Mode = "off"
)

// ParseMode converts a string to a Mode, defaulting to ModeOff for unrecognized or empty values.
func ParseMode(s string) Mode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "live":
		return ModeLive
	case "fixture":
		return ModeFixture
	case "off", "":
		return ModeOff
	default:
		return ModeOff
	}
}

// Collector is the common lifecycle interface for all signal collectors.
type Collector interface {
	Name() string
	Mode() Mode
	Start(ctx context.Context) error
}

// HealthChecker is an optional interface for collectors supporting active source health verification.
type HealthChecker interface {
	Health(ctx context.Context) error
}

// Stopper is an optional interface for collectors requiring explicit teardown.
type Stopper interface {
	Stop()
}

// IngestionSink is the consumer interface that receives drained or converted observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}
