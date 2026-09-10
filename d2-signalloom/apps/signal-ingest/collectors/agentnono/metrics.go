// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"fmt"
	"sort"
	"strings"
	"sync/atomic"
)

// Metric names exported by the agentnono collector.
const (
	// MetricSignalsIngested counts total agent-nono audit observations successfully ingested.
	MetricSignalsIngested = "agent_nono_signals_ingested_total"
	// MetricSignatureErrors counts detached signature failures, SVID verification rejections, and hash chain breaks.
	MetricSignatureErrors = "agent_nono_signature_errors_total"
	// MetricEventsReceived counts all incoming raw audit lines or events presented to the collector.
	MetricEventsReceived = "agent_nono_events_received_total"
	// MetricEventsDropped counts events dropped due to bounded ring-buffer saturation (backpressure/drop-tail).
	MetricEventsDropped = "agent_nono_events_dropped_total"
	// MetricTamperedSignals counts observations flagged as TAMPERED due to signature or hash chain divergence.
	MetricTamperedSignals = "agent_nono_tampered_signals_total"
	// MetricUnverifiedSignals counts observations admitted with UNVERIFIED status.
	MetricUnverifiedSignals = "agent_nono_unverified_signals_total"
)

var metricHelp = map[string]string{
	MetricSignalsIngested:   "Total agent-nono audit events ingested into observation store.",
	MetricSignatureErrors:   "Total agent-nono cryptographic signature and hash-chain verification errors.",
	MetricEventsReceived:    "Total raw audit events received by agent-nono collector.",
	MetricEventsDropped:     "Total audit events dropped due to bounded ring buffer capacity saturation.",
	MetricTamperedSignals:   "Total audit events detected with tampered payload or broken hash chains.",
	MetricUnverifiedSignals: "Total audit events ingested with unverified or unsigned status.",
}

// Metrics holds the atomic Prometheus counters for the agentnono collector.
type Metrics struct {
	signalsIngested   uint64
	signatureErrors   uint64
	eventsReceived    uint64
	eventsDropped     uint64
	tamperedSignals   uint64
	unverifiedSignals uint64
}

// NewMetrics instantiates a zeroed Prometheus metric counter set.
func NewMetrics() *Metrics {
	return &Metrics{}
}

// IncSignalsIngested increments agent_nono_signals_ingested_total.
func (m *Metrics) IncSignalsIngested() {
	if m != nil {
		atomic.AddUint64(&m.signalsIngested, 1)
	}
}

// IncSignatureErrors increments agent_nono_signature_errors_total.
func (m *Metrics) IncSignatureErrors() {
	if m != nil {
		atomic.AddUint64(&m.signatureErrors, 1)
	}
}

// IncEventsReceived increments agent_nono_events_received_total.
func (m *Metrics) IncEventsReceived() {
	if m != nil {
		atomic.AddUint64(&m.eventsReceived, 1)
	}
}

// AddEventsDropped increments agent_nono_events_dropped_total by n.
func (m *Metrics) AddEventsDropped(n uint64) {
	if m != nil && n > 0 {
		atomic.AddUint64(&m.eventsDropped, n)
	}
}

// IncTamperedSignals increments agent_nono_tampered_signals_total.
func (m *Metrics) IncTamperedSignals() {
	if m != nil {
		atomic.AddUint64(&m.tamperedSignals, 1)
	}
}

// IncUnverifiedSignals increments agent_nono_unverified_signals_total.
func (m *Metrics) IncUnverifiedSignals() {
	if m != nil {
		atomic.AddUint64(&m.unverifiedSignals, 1)
	}
}

// Snapshot returns the current metric values as a map.
func (m *Metrics) Snapshot() map[string]uint64 {
	if m == nil {
		return map[string]uint64{}
	}
	return map[string]uint64{
		MetricSignalsIngested:   atomic.LoadUint64(&m.signalsIngested),
		MetricSignatureErrors:   atomic.LoadUint64(&m.signatureErrors),
		MetricEventsReceived:    atomic.LoadUint64(&m.eventsReceived),
		MetricEventsDropped:     atomic.LoadUint64(&m.eventsDropped),
		MetricTamperedSignals:   atomic.LoadUint64(&m.tamperedSignals),
		MetricUnverifiedSignals: atomic.LoadUint64(&m.unverifiedSignals),
	}
}

// Render formats all metrics in standard Prometheus text exposition format (version 0.0.4).
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
