// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

// Metric names exported by the correlation quarantine engine.
const (
	// MetricQuarantineTotal counts total delegation quarantine containment alerts triggered.
	MetricQuarantineTotal = "signal_ingest_delegation_quarantine_total"
	// MetricStunDispatchTotal counts total Stun Sentinel freeze requests dispatched.
	MetricStunDispatchTotal = "signal_ingest_stun_dispatch_total"
	// MetricStunDispatchFailures counts Stun Sentinel dispatch errors.
	MetricStunDispatchFailures = "signal_ingest_stun_dispatch_failures_total"
	// MetricQuarantineThrottled counts alerts suppressed by rate-limiting / debouncing.
	MetricQuarantineThrottled = "signal_ingest_quarantine_throttled_total"
)

var metricHelp = map[string]string{
	MetricQuarantineTotal:      "Total delegation quarantine containment alerts triggered, labeled by violation_reason and actor_id.",
	MetricStunDispatchTotal:    "Total Stun Sentinel containment freeze calls dispatched.",
	MetricStunDispatchFailures: "Total Stun Sentinel containment freeze call failures.",
	MetricQuarantineThrottled:  "Total quarantine containment alerts throttled by debouncing gate.",
}

// QuarantineMetrics holds atomic counters and label maps for quarantine alerts.
type QuarantineMetrics struct {
	mu             sync.RWMutex
	byViolation    map[string]uint64
	byActor        map[string]uint64
	byPair         map[string]uint64 // key: violation_reason + "|" + actor_id
	stunDispatches uint64
	stunFailures   uint64
	throttledCount uint64
}

var (
	defaultQuarantineMetrics = NewQuarantineMetrics()
)

// DefaultQuarantineMetrics returns the global quarantine metrics singleton.
func DefaultQuarantineMetrics() *QuarantineMetrics {
	return defaultQuarantineMetrics
}

// NewQuarantineMetrics instantiates a zeroed QuarantineMetrics collector.
func NewQuarantineMetrics() *QuarantineMetrics {
	return &QuarantineMetrics{
		byViolation: make(map[string]uint64),
		byActor:     make(map[string]uint64),
		byPair:      make(map[string]uint64),
	}
}

// IncQuarantineTotal increments signal_ingest_delegation_quarantine_total labeled by violation_reason and actor_id.
func (m *QuarantineMetrics) IncQuarantineTotal(violationReason, actorID string) {
	if m == nil {
		return
	}
	if violationReason == "" {
		violationReason = "unknown"
	}
	if actorID == "" {
		actorID = "unknown"
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	pairKey := violationReason + "|" + actorID
	m.byPair[pairKey]++
	m.byViolation[violationReason]++
	m.byActor[actorID]++
}

// IncStunDispatched increments signal_ingest_stun_dispatch_total.
func (m *QuarantineMetrics) IncStunDispatched() {
	if m != nil {
		atomic.AddUint64(&m.stunDispatches, 1)
	}
}

// IncStunFailures increments signal_ingest_stun_dispatch_failures_total.
func (m *QuarantineMetrics) IncStunFailures() {
	if m != nil {
		atomic.AddUint64(&m.stunFailures, 1)
	}
}

// IncThrottled increments signal_ingest_quarantine_throttled_total.
func (m *QuarantineMetrics) IncThrottled() {
	if m != nil {
		atomic.AddUint64(&m.throttledCount, 1)
	}
}

// Snapshot returns a copy of quarantine counts.
func (m *QuarantineMetrics) Snapshot() (map[string]uint64, uint64, uint64, uint64) {
	if m == nil {
		return map[string]uint64{}, 0, 0, 0
	}
	m.mu.RLock()
	defer m.mu.RUnlock()

	cp := make(map[string]uint64, len(m.byPair))
	for k, v := range m.byPair {
		cp[k] = v
	}
	return cp, atomic.LoadUint64(&m.stunDispatches), atomic.LoadUint64(&m.stunFailures), atomic.LoadUint64(&m.throttledCount)
}

// Render outputs metrics in standard Prometheus text exposition format (version 0.0.4).
func (m *QuarantineMetrics) Render() string {
	if m == nil {
		return ""
	}
	m.mu.RLock()
	defer m.mu.RUnlock()

	var b strings.Builder

	fmt.Fprintf(&b, "# HELP %s %s\n", MetricQuarantineTotal, metricHelp[MetricQuarantineTotal])
	fmt.Fprintf(&b, "# TYPE %s counter\n", MetricQuarantineTotal)

	if len(m.byPair) == 0 {
		fmt.Fprintf(&b, "%s{actor_id=\"none\",violation_reason=\"none\"} 0\n", MetricQuarantineTotal)
	} else {
		var keys []string
		for k := range m.byPair {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			parts := strings.SplitN(k, "|", 2)
			vReason := parts[0]
			actID := ""
			if len(parts) > 1 {
				actID = parts[1]
			}
			fmt.Fprintf(&b, "%s{actor_id=\"%s\",violation_reason=\"%s\"} %d\n", MetricQuarantineTotal, actID, vReason, m.byPair[k])
		}
	}

	fmt.Fprintf(&b, "# HELP %s %s\n", MetricStunDispatchTotal, metricHelp[MetricStunDispatchTotal])
	fmt.Fprintf(&b, "# TYPE %s counter\n", MetricStunDispatchTotal)
	fmt.Fprintf(&b, "%s %d\n", MetricStunDispatchTotal, atomic.LoadUint64(&m.stunDispatches))

	fmt.Fprintf(&b, "# HELP %s %s\n", MetricStunDispatchFailures, metricHelp[MetricStunDispatchFailures])
	fmt.Fprintf(&b, "# TYPE %s counter\n", MetricStunDispatchFailures)
	fmt.Fprintf(&b, "%s %d\n", MetricStunDispatchFailures, atomic.LoadUint64(&m.stunFailures))

	fmt.Fprintf(&b, "# HELP %s %s\n", MetricQuarantineThrottled, metricHelp[MetricQuarantineThrottled])
	fmt.Fprintf(&b, "# TYPE %s counter\n", MetricQuarantineThrottled)
	fmt.Fprintf(&b, "%s %d\n", MetricQuarantineThrottled, atomic.LoadUint64(&m.throttledCount))

	return b.String()
}
