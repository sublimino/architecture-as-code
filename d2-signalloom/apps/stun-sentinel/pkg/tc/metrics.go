// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

// metrics.go renders Prometheus exposition text for the TC severance
// subsystem.
//
// Hand-rendered rather than pulled from prometheus/client_golang for one
// reason that matters: the drop counter MUST be sourced from the BPF map at
// scrape time, not from a Go-side counter incremented when we think a drop
// happened. A Go-side counter reports our intentions; the map reports what the
// kernel actually destroyed. Those differ precisely in the cases anyone cares
// about — a filter that failed to attach, a map key that never matched, a
// program the verifier silently placed on the wrong hook.
//
// Keeping the registry dependency-free also keeps this module free of the
// dependency-set collision with the sibling daemon.

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Metric names. Two of these are named on the card and must not drift.
const (
	MetricPacketsDropped    = "stun_tc_packets_dropped_total"
	MetricBytesDropped      = "stun_tc_bytes_dropped_total"
	MetricIsolationDuration = "stun_tc_isolation_duration_seconds"
	MetricIsolationActive   = "stun_tc_isolation_active"
	MetricAttachedFilters   = "stun_tc_attached_filters"
	MetricConntrackDeleted  = "stun_tc_conntrack_entries_deleted_total"
)

// durationBuckets are tuned around the 100ms severance budget: four buckets
// below it so a regression toward the limit is visible before it breaches,
// and headroom above so a breach is quantified rather than merely clipped.
var durationBuckets = []float64{0.0001, 0.001, 0.005, 0.010, 0.025, 0.050, 0.100, 0.250, 1.0}

type histogram struct {
	counts []uint64
	sum    float64
	total  uint64
}

func (h *histogram) observe(v float64) {
	if h.counts == nil {
		h.counts = make([]uint64, len(durationBuckets))
	}
	for i, b := range durationBuckets {
		if v <= b {
			h.counts[i]++
		}
	}
	h.sum += v
	h.total++
}

// Registry collects TC severance metrics.
type Registry struct {
	mu               sync.Mutex
	packets          map[string]uint64
	bytes            map[string]uint64
	isolated         map[string]bool
	durations        map[string]*histogram
	conntrackDeleted uint64
	attached         int
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		packets:   make(map[string]uint64),
		bytes:     make(map[string]uint64),
		isolated:  make(map[string]bool),
		durations: make(map[string]*histogram),
	}
}

// ObserveDrops records counters read out of the BPF map. It SETS rather than
// adds, because the map value is itself a monotonic total; adding would
// double-count on every scrape.
func (r *Registry) ObserveDrops(iface string, packets, bytes uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.packets[iface] = packets
	r.bytes[iface] = bytes
}

// ObserveIsolationDuration records how long an Isolate call took.
func (r *Registry) ObserveIsolationDuration(iface string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h, ok := r.durations[iface]
	if !ok {
		h = &histogram{}
		r.durations[iface] = h
	}
	h.observe(d.Seconds())
}

// SetIsolated records the current isolation state of an interface.
func (r *Registry) SetIsolated(iface string, isolated bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.isolated[iface] = isolated
}

// AddConntrackDeleted records conntrack entries removed.
func (r *Registry) AddConntrackDeleted(n int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n > 0 {
		r.conntrackDeleted += uint64(n)
	}
}

// SetAttachedFilters records how many interfaces currently carry filters.
func (r *Registry) SetAttachedFilters(n int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attached = n
}

// Render produces Prometheus text exposition format.
func (r *Registry) Render() string {
	r.mu.Lock()
	defer r.mu.Unlock()

	var b strings.Builder

	writeCounter := func(name, help string, values map[string]uint64) {
		fmt.Fprintf(&b, "# HELP %s %s\n", name, help)
		fmt.Fprintf(&b, "# TYPE %s counter\n", name)
		for _, iface := range sortedKeys(values) {
			fmt.Fprintf(&b, "%s{interface=%q} %d\n", name, iface, values[iface])
		}
	}

	writeCounter(MetricPacketsDropped,
		"Total packets destroyed by the stun TC classifier, read from the BPF map.",
		r.packets)
	writeCounter(MetricBytesDropped,
		"Total bytes destroyed by the stun TC classifier, read from the BPF map.",
		r.bytes)

	fmt.Fprintf(&b, "# HELP %s Time taken to activate network isolation for an interface.\n", MetricIsolationDuration)
	fmt.Fprintf(&b, "# TYPE %s histogram\n", MetricIsolationDuration)
	for _, iface := range sortedHistKeys(r.durations) {
		h := r.durations[iface]
		cumulative := uint64(0)
		for i, bound := range durationBuckets {
			if h.counts != nil {
				cumulative = h.counts[i]
			}
			fmt.Fprintf(&b, "%s_bucket{interface=%q,le=\"%g\"} %d\n", MetricIsolationDuration, iface, bound, cumulative)
		}
		fmt.Fprintf(&b, "%s_bucket{interface=%q,le=\"+Inf\"} %d\n", MetricIsolationDuration, iface, h.total)
		fmt.Fprintf(&b, "%s_sum{interface=%q} %g\n", MetricIsolationDuration, iface, h.sum)
		fmt.Fprintf(&b, "%s_count{interface=%q} %d\n", MetricIsolationDuration, iface, h.total)
	}

	fmt.Fprintf(&b, "# HELP %s Whether an interface is currently network-isolated (1) or not (0).\n", MetricIsolationActive)
	fmt.Fprintf(&b, "# TYPE %s gauge\n", MetricIsolationActive)
	for _, iface := range sortedBoolKeys(r.isolated) {
		v := 0
		if r.isolated[iface] {
			v = 1
		}
		fmt.Fprintf(&b, "%s{interface=%q} %d\n", MetricIsolationActive, iface, v)
	}

	fmt.Fprintf(&b, "# HELP %s Number of interfaces with an attached stun TC drop filter.\n", MetricAttachedFilters)
	fmt.Fprintf(&b, "# TYPE %s gauge\n", MetricAttachedFilters)
	fmt.Fprintf(&b, "%s %d\n", MetricAttachedFilters, r.attached)

	fmt.Fprintf(&b, "# HELP %s Conntrack entries deleted to invalidate established flows.\n", MetricConntrackDeleted)
	fmt.Fprintf(&b, "# TYPE %s counter\n", MetricConntrackDeleted)
	fmt.Fprintf(&b, "%s %d\n", MetricConntrackDeleted, r.conntrackDeleted)

	return b.String()
}

func sortedKeys(m map[string]uint64) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedBoolKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedHistKeys(m map[string]*histogram) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
