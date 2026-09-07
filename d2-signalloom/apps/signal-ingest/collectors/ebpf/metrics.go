// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"fmt"
	"sort"
	"strings"
	"sync/atomic"
)

// Metric names exported by this collector. They are declared as constants
// rather than string literals at the call site so that the BATS suite and the
// polling loop in scripts/test-tetragon-stream.sh can assert against the same
// source of truth the code renders from.
const (
	// MetricEventsReceived counts every event read off the Tetragon stream,
	// before filtering, normalisation, or buffering.
	MetricEventsReceived = "tetragon_events_received_total"
	// MetricFlowEventsIngested counts events successfully normalised into an
	// InboundFlowEvent and accepted by the downstream flow processor.
	MetricFlowEventsIngested = "tetragon_flow_events_ingested_total"
	// MetricEventsDropped counts events discarded by the ring buffer drop
	// policy. A non-zero value means the consumer could not keep up; it is
	// deliberately a separate series from stream errors because the remedy is
	// different (tune capacity, versus fix the connection).
	MetricEventsDropped = "tetragon_events_dropped_total"
	// MetricStreamErrors counts gRPC stream failures, reconnects, and
	// undecodable JSON lines.
	MetricStreamErrors = "tetragon_stream_errors_total"
	// MetricEventsSkipped counts events that were read and understood but
	// carried no normalisable payload (ProcessExit, ProcessLoader, RateLimitInfo).
	// Without this series a quiet stream is indistinguishable from a broken
	// normaliser, because received would climb while ingested stayed flat.
	MetricEventsSkipped = "tetragon_events_skipped_total"
	// MetricEventsIdentityless counts ingested events that carry no real
	// Kubernetes identity (no service account, no label-sourced pod UID).
	//
	// This series exists because NOTHING IN THIS REPOSITORY SETS THE
	// signalloom.io/* POD LABELS the normaliser reads identity from. Without a
	// counter, a cluster in that state produces a full-looking event stream in
	// which every identity field is empty and nothing surfaces the fact. If this
	// tracks tetragon_flow_events_ingested_total 1:1, identity enrichment is not
	// deployed and no Tetragon-sourced event is attributable.
	MetricEventsIdentityless = "tetragon_events_identityless_total"
)

// metricHelp maps each metric to its HELP text. Rendering iterates this map, so
// a metric absent here is absent from /metrics — which is why the test asserts
// against this map rather than against a hand-written list.
var metricHelp = map[string]string{
	MetricEventsReceived:     "Total Tetragon events read from the event stream.",
	MetricFlowEventsIngested: "Total Tetragon events normalised into InboundFlowEvent and ingested.",
	MetricEventsDropped:      "Total Tetragon events discarded by the bounded ring buffer drop policy.",
	MetricStreamErrors:       "Total Tetragon stream errors, reconnects, and decode failures.",
	MetricEventsSkipped:      "Total Tetragon events with no normalisable payload.",
	MetricEventsIdentityless: "Total ingested Tetragon events carrying no attributable Kubernetes identity.",
}

// Metrics holds the collector's counters. All access is atomic; a Metrics value
// is safe to share between the stream reader goroutine and an HTTP handler.
type Metrics struct {
	received     uint64
	ingested     uint64
	dropped      uint64
	errors       uint64
	skipped      uint64
	identityless uint64
}

// NewMetrics returns a zeroed counter set.
func NewMetrics() *Metrics { return &Metrics{} }

func (m *Metrics) incReceived() { atomic.AddUint64(&m.received, 1) }
func (m *Metrics) incIngested() { atomic.AddUint64(&m.ingested, 1) }
func (m *Metrics) incErrors()   { atomic.AddUint64(&m.errors, 1) }
func (m *Metrics) incSkipped()  { atomic.AddUint64(&m.skipped, 1) }

func (m *Metrics) incIdentityless() { atomic.AddUint64(&m.identityless, 1) }

func (m *Metrics) addDropped(n uint64) {
	if n > 0 {
		atomic.AddUint64(&m.dropped, n)
	}
}

// Snapshot returns the current counter values keyed by metric name.
func (m *Metrics) Snapshot() map[string]uint64 {
	if m == nil {
		return map[string]uint64{}
	}
	return map[string]uint64{
		MetricEventsReceived:     atomic.LoadUint64(&m.received),
		MetricFlowEventsIngested: atomic.LoadUint64(&m.ingested),
		MetricEventsDropped:      atomic.LoadUint64(&m.dropped),
		MetricStreamErrors:       atomic.LoadUint64(&m.errors),
		MetricEventsSkipped:      atomic.LoadUint64(&m.skipped),
		MetricEventsIdentityless: atomic.LoadUint64(&m.identityless),
	}
}

// Render produces Prometheus text exposition format (version 0.0.4).
//
// Output is sorted by metric name so the rendering is byte-stable across calls.
// An unsorted map range would make the output non-deterministic and any test
// asserting on the full body would flake.
func (m *Metrics) Render() string {
	snap := m.Snapshot()

	names := make([]string, 0, len(snap))
	for name := range snap {
		names = append(names, name)
	}
	sort.Strings(names)

	var b strings.Builder
	for _, name := range names {
		help, ok := metricHelp[name]
		if !ok {
			help = name
		}
		fmt.Fprintf(&b, "# HELP %s %s\n", name, help)
		fmt.Fprintf(&b, "# TYPE %s counter\n", name)
		fmt.Fprintf(&b, "%s %d\n", name, snap[name])
	}
	return b.String()
}
