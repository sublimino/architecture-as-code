// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"container/list"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
)

const (
	// MetricPresentationEventsSuppressed is the Prometheus counter metric for suppressed routine duplicate events.
	MetricPresentationEventsSuppressed = "stun_presentation_events_suppressed_total"
	// MetricPresentationEventsEmitted is the Prometheus counter metric for emitted events (first encounter, post-expiry, or anomaly).
	MetricPresentationEventsEmitted = "stun_presentation_events_emitted_total"

	// DefaultPresentationFilterCapacity is the default LRU capacity for the suppression state map.
	DefaultPresentationFilterCapacity = 65536

	// SyscallNameDNSResolution is the telemetry observation syscall identifier for DNS resolution events.
	SyscallNameDNSResolution = "dns_resolution"
)

// PresentationFilterStats holds a point-in-time snapshot of the presentation filter counters.
type PresentationFilterStats struct {
	Suppressed uint64 `json:"suppressed"`
	Emitted    uint64 `json:"emitted"`
}

// PresentationFilterMetrics holds atomic counters for runtime observability of presentation volume reduction.
type PresentationFilterMetrics struct {
	Suppressed atomic.Uint64
	Emitted    atomic.Uint64
}

// suppressionKey is the composite key (podOrCgroup, qname) for suppression tracking.
// Interface is the attribution key: attribution is resolved in userspace, never from kernel pid/tgid.
type suppressionKey struct {
	podOrCgroup string
	qname       string
}

// suppressionEntry stores the expiration deadline and LRU entry for a suppressed domain.
type suppressionEntry struct {
	podOrCgroup string
	qname       string
	expiresAt   time.Time
}

// PresentationFilter implements the 3-tier presentation volume defense in Warden's correlator:
// - Tier 1: Inline attribution on connect (via reportConnect, 1 observation per connect).
// - Tier 2: Emit once per unique name within its record TTL, suppress routine repeats.
// - Tier 3: Always emit on anomaly (direct_ip_egress, dns_sni_mismatch, non_cluster_resolver, nxdomain_burst, unparsed_capture).
type PresentationFilter struct {
	mu       sync.RWMutex
	capacity int
	entries  map[suppressionKey]*list.Element
	lruList  *list.List
	dnsCache *DNSCache
	clock    Clock
	metrics  PresentationFilterMetrics
}

// PresentationFilterOption configures a PresentationFilter instance.
type PresentationFilterOption func(*PresentationFilter)

// WithPresentationFilterDNSCache binds the DNSCache instance for TTL access and canonical domain resolution.
func WithPresentationFilterDNSCache(cache *DNSCache) PresentationFilterOption {
	return func(f *PresentationFilter) {
		f.dnsCache = cache
	}
}

// WithPresentationFilterClock overrides the time provider (used for testing with mockClock).
func WithPresentationFilterClock(clk Clock) PresentationFilterOption {
	return func(f *PresentationFilter) {
		f.clock = clk
	}
}

// WithPresentationFilterCapacity configures the maximum LRU capacity of the suppression table.
func WithPresentationFilterCapacity(capacity int) PresentationFilterOption {
	return func(f *PresentationFilter) {
		if capacity > 0 {
			f.capacity = capacity
		}
	}
}

// NewPresentationFilter constructs a new PresentationFilter instance.
func NewPresentationFilter(opts ...PresentationFilterOption) *PresentationFilter {
	f := &PresentationFilter{
		capacity: DefaultPresentationFilterCapacity,
		entries:  make(map[suppressionKey]*list.Element),
		lruList:  list.New(),
		clock:    realClock{},
	}
	for _, opt := range opts {
		opt(f)
	}
	return f
}

// Metrics returns the filter's Prometheus metric counters.
func (f *PresentationFilter) Metrics() *PresentationFilterMetrics {
	return &f.metrics
}

// Stats returns a point-in-time snapshot of the filter counters.
func (f *PresentationFilter) Stats() PresentationFilterStats {
	return PresentationFilterStats{
		Suppressed: f.metrics.Suppressed.Load(),
		Emitted:    f.metrics.Emitted.Load(),
	}
}

// Reset clears the filter's suppression state and resets counters (used in testing).
func (f *PresentationFilter) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.entries = make(map[suppressionKey]*list.Element)
	f.lruList.Init()
	f.metrics.Suppressed.Store(0)
	f.metrics.Emitted.Store(0)
}

// IsAnomalyObservation reports whether an observation carries a security anomaly tag
// or critical severity that must unconditionally bypass presentation suppression.
func IsAnomalyObservation(obs *TelemetryObservation) bool {
	if obs == nil {
		return false
	}
	if obs.Severity == SeverityCritical {
		return true
	}
	if obs.Labels != nil {
		if anomaly := obs.Labels["anomaly"]; anomaly != "" {
			return true
		}
	}
	return false
}

// FilterResolution evaluates a raw DNS resolution for (podOrCgroup, qname).
//
// Returns true if the resolution is a first encounter or has expired and should be emitted.
// Returns false if the resolution is a routine repeat within TTL and is suppressed.
func (f *PresentationFilter) FilterResolution(podOrCgroup, qname string, rawTTL uint32) bool {
	normQName := normalizeDomain(qname)
	if normQName == "" {
		f.metrics.Emitted.Add(1)
		return true
	}

	key := suppressionKey{
		podOrCgroup: podOrCgroup,
		qname:       normQName,
	}

	now := f.clock.Now()
	f.mu.Lock()
	defer f.mu.Unlock()

	// Check existing suppression state
	if elem, exists := f.entries[key]; exists {
		entry := elem.Value.(*suppressionEntry)
		if now.Before(entry.expiresAt) {
			// Routine repeat within TTL -> SUPPRESS
			f.lruList.MoveToFront(elem)
			f.metrics.Suppressed.Add(1)
			return false
		}

		// TTL expired -> re-emission allowed
		effectiveTTL := f.dnsCache.EffectiveTTL(rawTTL)
		entry.expiresAt = now.Add(effectiveTTL)
		f.lruList.MoveToFront(elem)
		f.metrics.Emitted.Add(1)
		return true
	}

	// First encounter for this (podOrCgroup, qname) -> EMIT
	// Evict oldest if at capacity
	if f.lruList.Len() >= f.capacity {
		oldestElem := f.lruList.Back()
		if oldestElem != nil {
			oldestEntry := oldestElem.Value.(*suppressionEntry)
			delete(f.entries, suppressionKey{
				podOrCgroup: oldestEntry.podOrCgroup,
				qname:       oldestEntry.qname,
			})
			f.lruList.Remove(oldestElem)
		}
	}

	effectiveTTL := f.dnsCache.EffectiveTTL(rawTTL)
	newEntry := &suppressionEntry{
		podOrCgroup: podOrCgroup,
		qname:       normQName,
		expiresAt:   now.Add(effectiveTTL),
	}
	elem := f.lruList.PushFront(newEntry)
	f.entries[key] = elem

	f.metrics.Emitted.Add(1)
	return true
}

// ShouldEmit is an alias for FilterResolution.
func (f *PresentationFilter) ShouldEmit(podOrCgroup, qname string, rawTTL uint32) bool {
	return f.FilterResolution(podOrCgroup, qname, rawTTL)
}

// FilterObservation passes a TelemetryObservation through the 3-tier presentation filter:
//
// Tier 1 (Inline attribution on connect): normal connect observations pass through.
// Tier 2 (DNS resolution deduplication): routine repeated DNS names within TTL are suppressed.
// Tier 3 (Anomaly bypass): any observation tagged with an anomaly or critical severity bypasses suppression unconditionally.
func (f *PresentationFilter) FilterObservation(
	podOrCgroup string,
	qname string,
	rawTTL uint32,
	obs *TelemetryObservation,
) (*TelemetryObservation, bool) {
	if obs == nil {
		return nil, false
	}

	// -------------------------------------------------------------------------
	// Tier 3: Always emit on anomaly (Structural Bypass)
	// -------------------------------------------------------------------------
	if IsAnomalyObservation(obs) {
		f.metrics.Emitted.Add(1)
		return obs, true
	}

	// Extract domain name from observation if not provided explicitly
	if qname == "" {
		if obs.Domain != "" {
			qname = obs.Domain
		} else if obs.Syscall == SyscallNameDNSResolution {
			qname = obs.Target
		}
	}

	// Non-DNS routine syscall observations (e.g. openat, execve) pass through directly
	if qname == "" && obs.Syscall != SyscallNameDNSResolution {
		f.metrics.Emitted.Add(1)
		return obs, true
	}

	// Derive podOrCgroup from observation metadata if not provided
	if podOrCgroup == "" {
		if obs.Namespace != "" && obs.PodName != "" {
			podOrCgroup = obs.Namespace + "/" + obs.PodName
		} else if obs.CgroupPath != "" {
			podOrCgroup = obs.CgroupPath
		}
	}

	// -------------------------------------------------------------------------
	// Tier 2: Emit once per unique name within TTL, suppress routine repeats
	// -------------------------------------------------------------------------
	shouldEmit := f.FilterResolution(podOrCgroup, qname, rawTTL)
	if !shouldEmit {
		return nil, false
	}

	return obs, true
}

// BuildDNSResolutionObservation creates a TelemetryObservation for a DNS resolution event.
func BuildDNSResolutionObservation(
	pod *corev1.Pod,
	qname string,
	answers []net.IP,
	clk Clock,
) *TelemetryObservation {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if clk != nil {
		now = clk.Now().UTC().Format(time.RFC3339Nano)
	}

	answerStrs := make([]string, 0, len(answers))
	for _, ip := range answers {
		if s := ipToString(ip); s != "" {
			answerStrs = append(answerStrs, s)
		}
	}

	obs := &TelemetryObservation{
		Timestamp:      now,
		Syscall:        SyscallNameDNSResolution,
		Target:         normalizeDomain(qname),
		Domain:         normalizeDomain(qname),
		Severity:       SeverityWarn,
		DirectReaction: ReactionNone,
		Labels: map[string]string{
			"qname":   normalizeDomain(qname),
			"answers": strings.Join(answerStrs, ","),
		},
	}

	if pod != nil {
		obs.PodName = pod.Name
		obs.Namespace = pod.Namespace
		obs.ActorID = pod.Spec.ServiceAccountName
		if obs.ActorID == "" {
			obs.ActorID = "default"
		}
		if pod.Labels != nil && pod.Labels["tenant"] != "" {
			obs.TenantID = pod.Labels["tenant"]
		} else {
			obs.TenantID = UnattributedTenantID
		}
	}

	return obs
}
