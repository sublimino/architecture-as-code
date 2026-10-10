// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestPresentationFilter_Tier1_InlineAttributionOnConnect asserts that reportConnect
// builds exactly one TelemetryObservation carrying the resolved domain inline per connect()
// syscall, pinning Tier 1's existing behaviour by construction.
func TestPresentationFilter_Tier1_InlineAttributionOnConnect(t *testing.T) {
	cache := NewDNSCache()
	pod := agentPod("tenant-agents")
	m, _ := pipeline(t, pod, nil)
	m.dnsCache = cache

	destIP := net.ParseIP("93.184.216.34")
	cache.Insert(podKey(pod), []net.IP{destIP}, []uint32{300}, "example.com", "")

	// 1. Assert handleRecord/reportConnect produces exactly one observation for the connect syscall
	obs, ok := m.handleRecord(rawConnect(1001, destIP, 443))
	if !ok {
		t.Fatalf("handleRecord/reportConnect returned ok=false, want true")
	}

	// 2. Assert domain is inline on connect
	if obs.Domain != "example.com" {
		t.Errorf("obs.Domain = %q, want %q", obs.Domain, "example.com")
	}
	if obs.Syscall != SyscallNameConnect {
		t.Errorf("obs.Syscall = %q, want %q", obs.Syscall, SyscallNameConnect)
	}
	if obs.Target != "93.184.216.34:443" {
		t.Errorf("obs.Target = %q, want %q", obs.Target, "93.184.216.34:443")
	}

	// 3. Assert passing through presentation filter does NOT suppress the connect observation
	filteredObs, emit := m.PresentationFilter().FilterObservation(podKey(pod), "", 0, &obs)
	if !emit || filteredObs == nil {
		t.Fatalf("PresentationFilter suppressed connect observation, want emit=true")
	}
	if filteredObs.Domain != "example.com" {
		t.Errorf("filteredObs.Domain = %q, want %q", filteredObs.Domain, "example.com")
	}
}

// TestPresentationFilter_SuppressionWithinTTL asserts that repeat emissions of the SAME
// resolved name for the same pod within its record's TTL are suppressed (Tier 2).
func TestPresentationFilter_SuppressionWithinTTL(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	podID := "default/agent-alpha"
	qname := "api.anthropic.com"
	ttl := uint32(60) // 60s TTL

	// First encounter: MUST emit
	if !filter.FilterResolution(podID, qname, ttl) {
		t.Fatalf("first encounter for %s was suppressed, want emit=true", qname)
	}

	stats := filter.Stats()
	if stats.Emitted != 1 || stats.Suppressed != 0 {
		t.Errorf("after first encounter: stats = %+v, want Emitted=1, Suppressed=0", stats)
	}

	// Repeat queries within TTL (t=10s, 20s, 30s, 50s): ALL MUST BE SUPPRESSED
	for _, offset := range []time.Duration{10 * time.Second, 20 * time.Second, 30 * time.Second, 50 * time.Second} {
		clk.Advance(offset - (clk.Now().Sub(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))))
		if filter.FilterResolution(podID, qname, ttl) {
			t.Fatalf("repeat query at offset %v was emitted, want suppressed", offset)
		}
	}

	stats = filter.Stats()
	if stats.Emitted != 1 || stats.Suppressed != 4 {
		t.Errorf("after in-TTL repeats: stats = %+v, want Emitted=1, Suppressed=4", stats)
	}
}

// TestPresentationFilter_ReEmissionAfterExpiry asserts that a resolved name is re-emitted
// once its record's TTL has elapsed, and subsequent repeat queries within the new TTL
// are suppressed again (Tier 2).
func TestPresentationFilter_ReEmissionAfterExpiry(t *testing.T) {
	startTime := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	clk := newMockClock(startTime)
	cache := NewDNSCache(WithDNSCacheClock(clk))
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	podID := "default/agent-beta"
	qname := "api.openai.com"
	ttl := uint32(30) // 30s TTL (matches MinDNSTTL floor)

	// t=0s: First encounter -> EMIT
	if !filter.FilterResolution(podID, qname, ttl) {
		t.Fatalf("t=0s: first encounter was suppressed, want emit=true")
	}

	// t=15s: In-TTL repeat -> SUPPRESS
	clk.Advance(15 * time.Second)
	if filter.FilterResolution(podID, qname, ttl) {
		t.Fatalf("t=15s: in-TTL repeat was emitted, want suppressed")
	}

	// t=35s: TTL expired (35s > 30s) -> RE-EMIT
	clk.Advance(20 * time.Second) // total t=35s
	if !filter.FilterResolution(podID, qname, ttl) {
		t.Fatalf("t=35s: post-expiry query was suppressed, want re-emitted")
	}

	// t=45s: Inside new TTL window (35s + 30s = 65s expiry) -> SUPPRESS
	clk.Advance(10 * time.Second) // total t=45s
	if filter.FilterResolution(podID, qname, ttl) {
		t.Fatalf("t=45s: repeat in new TTL window was emitted, want suppressed")
	}

	// t=70s: New TTL expired (70s > 65s) -> RE-EMIT
	clk.Advance(25 * time.Second) // total t=70s
	if !filter.FilterResolution(podID, qname, ttl) {
		t.Fatalf("t=70s: second post-expiry query was suppressed, want re-emitted")
	}

	stats := filter.Stats()
	if stats.Emitted != 3 || stats.Suppressed != 2 {
		t.Errorf("stats = %+v, want Emitted=3, Suppressed=2", stats)
	}
}

// TestPresentationFilter_NeverSuppressAnomaly asserts that any security anomaly
// (direct_ip_egress, dns_sni_mismatch, non_cluster_resolver, nxdomain_burst, unparsed_capture, CRITICAL)
// unconditionally bypasses presentation suppression (Tier 3).
func TestPresentationFilter_NeverSuppressAnomaly(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	podID := "default/compromised-agent"
	qname := "c2.attacker.com"

	// First, establish a suppressed routine state for this domain
	if !filter.FilterResolution(podID, qname, 600) {
		t.Fatalf("initial resolution should be emitted")
	}
	if filter.FilterResolution(podID, qname, 600) {
		t.Fatalf("subsequent routine resolution should be suppressed")
	}

	anomalyTestCases := []struct {
		name     string
		anomaly  string
		severity string
		syscall  string
		target   string
	}{
		{
			name:     "Direct IP Egress (CRITICAL)",
			anomaly:  AnomalyDirectIPEgress,
			severity: SeverityCritical,
			syscall:  SyscallNameConnect,
			target:   "198.51.100.23:443",
		},
		{
			name:     "DNS vs SNI Mismatch (CRITICAL)",
			anomaly:  AnomalyDNSSNIMismatch,
			severity: SeverityCritical,
			syscall:  SyscallNameConnect,
			target:   "198.51.100.24:443",
		},
		{
			name:     "Non-Cluster DNS Resolver (WARN)",
			anomaly:  AnomalyNonClusterResolver,
			severity: SeverityWarn,
			syscall:  SyscallNameDNSResolution,
			target:   "8.8.8.8:53",
		},
		{
			name:     "NXDOMAIN Burst / DGA (WARN)",
			anomaly:  AnomalyNXDOMAINBurst,
			severity: SeverityWarn,
			syscall:  SyscallNameDNSResolution,
			target:   "dga-probe.evil.com",
		},
		{
			name:     "Unparsed Capture (WARN)",
			anomaly:  AnomalyUnparsedCapture,
			severity: SeverityWarn,
			syscall:  SyscallNameDNSResolution,
			target:   "truncated-dns.com",
		},
		{
			name:     "Generic Critical Severity Alert",
			anomaly:  "",
			severity: SeverityCritical,
			syscall:  SyscallNameExecve,
			target:   "/bin/sh",
		},
	}

	for _, tc := range anomalyTestCases {
		t.Run(tc.name, func(t *testing.T) {
			// Injects 5 consecutive identical anomaly observations
			for i := 0; i < 5; i++ {
				obs := &TelemetryObservation{
					Timestamp: clk.Now().Format(time.RFC3339Nano),
					PodName:   "compromised-agent",
					Namespace: "default",
					Syscall:   tc.syscall,
					Target:    tc.target,
					Domain:    qname,
					Severity:  tc.severity,
					Labels:    map[string]string{},
				}
				if tc.anomaly != "" {
					obs.Labels["anomaly"] = tc.anomaly
				}

				filteredObs, emit := filter.FilterObservation(podID, qname, 600, obs)
				if !emit || filteredObs == nil {
					t.Fatalf("iteration %d: anomaly %s was suppressed, want unconditional emit", i, tc.name)
				}
			}
		})
	}
}

// TestPresentationFilter_CrossPodAttributionIsolation asserts that suppression is
// strictly keyed by (podOrCgroup, qname), ensuring Pod B's first encounter of a domain
// is NOT suppressed by Pod A's prior resolution.
func TestPresentationFilter_CrossPodAttributionIsolation(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	podA := "default/agent-alpha"
	podB := "tenant-prod/agent-beta"
	qname := "metrics.datadoghq.com"
	ttl := uint32(300)

	// 1. Pod A resolves domain -> EMIT
	if !filter.FilterResolution(podA, qname, ttl) {
		t.Fatalf("Pod A first resolution was suppressed, want emit=true")
	}

	// 2. Pod A resolves domain again within TTL -> SUPPRESS
	if filter.FilterResolution(podA, qname, ttl) {
		t.Fatalf("Pod A repeat resolution was emitted, want suppressed")
	}

	// 3. Pod B resolves the SAME domain for the first time -> MUST EMIT (not suppressed by Pod A)
	if !filter.FilterResolution(podB, qname, ttl) {
		t.Fatalf("Pod B first resolution was suppressed by Pod A's state! Cross-pod isolation violation!")
	}

	// 4. Pod B repeat resolution -> SUPPRESS
	if filter.FilterResolution(podB, qname, ttl) {
		t.Fatalf("Pod B repeat resolution was emitted, want suppressed")
	}

	stats := filter.Stats()
	if stats.Emitted != 2 || stats.Suppressed != 2 {
		t.Errorf("stats = %+v, want Emitted=2, Suppressed=2", stats)
	}
}

// TestPresentationFilter_HeuristicsRunStrictlyBeforeFilter asserts that calling the filter
// strictly after heuristic evaluation preserves anomaly tags and guarantees immediate emission.
func TestPresentationFilter_HeuristicsRunStrictlyBeforeFilter(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	heuristics := NewDNSHeuristicsEngine(
		WithHeuristicsDNSCache(cache),
		WithHeuristicsClock(clk),
	)
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-worker",
			Namespace: "default",
		},
	}
	podID := podKey(pod)
	destIP := net.ParseIP("203.0.113.88") // Uncached IP -> direct-to-IP egress anomaly

	// Step 1: Evaluate heuristics first
	anomalyObs, isAnomaly := heuristics.EvaluateDirectIPEgress(podID, destIP, pod, nil)
	if !isAnomaly || anomalyObs == nil {
		t.Fatalf("EvaluateDirectIPEgress failed to detect direct IP egress")
	}

	// Step 2: Pass heuristic-tagged observation through presentation filter
	emittedObs, emit := filter.FilterObservation(podID, "", 0, anomalyObs)
	if !emit || emittedObs == nil {
		t.Fatalf("PresentationFilter suppressed heuristic alert!")
	}
	if emittedObs.Labels["anomaly"] != AnomalyDirectIPEgress {
		t.Errorf("emittedObs anomaly label = %q, want %q", emittedObs.Labels["anomaly"], AnomalyDirectIPEgress)
	}
	if emittedObs.Severity != SeverityCritical {
		t.Errorf("emittedObs severity = %q, want %q", emittedObs.Severity, SeverityCritical)
	}
}

// TestPresentationFilter_PrometheusMetricsAndStats asserts that metrics and stats counters
// track emissions and suppressions accurately.
func TestPresentationFilter_PrometheusMetricsAndStats(t *testing.T) {
	filter := NewPresentationFilter()

	if MetricPresentationEventsSuppressed != "stun_presentation_events_suppressed_total" {
		t.Errorf("MetricPresentationEventsSuppressed = %q, want stun_presentation_events_suppressed_total", MetricPresentationEventsSuppressed)
	}
	if MetricPresentationEventsEmitted != "stun_presentation_events_emitted_total" {
		t.Errorf("MetricPresentationEventsEmitted = %q, want stun_presentation_events_emitted_total", MetricPresentationEventsEmitted)
	}

	filter.Metrics().Emitted.Add(42)
	filter.Metrics().Suppressed.Add(158)

	stats := filter.Stats()
	if stats.Emitted != 42 || stats.Suppressed != 158 {
		t.Errorf("Stats() = %+v, want Emitted=42, Suppressed=158", stats)
	}
}

// WorkloadEvent models one synthetic DNS event in the test fixture sequence.
type WorkloadEvent struct {
	ID                 int      `json:"id"`
	TimestampOffsetSec int      `json:"timestamp_offset_sec"`
	PodNamespace       string   `json:"pod_namespace"`
	PodName            string   `json:"pod_name"`
	QName              string   `json:"qname"`
	Answers            []string `json:"answers"`
	TTL                uint32   `json:"ttl"`
	IsAnomaly          bool     `json:"is_anomaly"`
	AnomalyType        string   `json:"anomaly_type,omitempty"`
}

// WorkloadReductionResult records the raw vs filtered reduction metrics.
type WorkloadReductionResult struct {
	FixtureDescription   string  `json:"fixture_description"`
	TotalWorkloadEvents  int     `json:"total_workload_events"`
	RawEmittedCount      int     `json:"raw_emitted_count"`
	FilteredEmittedCount int     `json:"filtered_emitted_count"`
	SuppressedCount      int     `json:"suppressed_count"`
	MeasuredReductionPct float64 `json:"measured_reduction_pct"`
}

// generateSyntheticWorkload creates a reproducible synthetic workload sequence.
func generateSyntheticWorkload() []WorkloadEvent {
	baseTime := 0
	events := make([]WorkloadEvent, 0, 1000)

	pods := []struct {
		ns   string
		name string
	}{
		{"default", "agent-runner-0"},
		{"default", "agent-runner-1"},
		{"tenant-a", "kusari-worker-0"},
		{"tenant-a", "kusari-worker-1"},
		{"tenant-b", "claude-code-0"},
		{"tenant-b", "claude-code-1"},
		{"tenant-c", "kagent-d5-0"},
		{"tenant-c", "kagent-d5-1"},
		{"system", "sentinel-aux-0"},
		{"system", "sentinel-aux-1"},
	}

	domains := []string{
		"api.anthropic.com", "api.openai.com", "github.com", "api.github.com",
		"raw.githubusercontent.com", "registry.npmjs.org", "pypi.org", "files.pythonhosted.org",
		"cdn.cloudflare.net", "cloudflare-dns.com", "pkg.go.dev", "golang.org",
		"aws.amazon.com", "s3.us-east-1.amazonaws.com", "sts.amazonaws.com", "sqs.us-east-1.amazonaws.com",
		"googleapis.com", "storage.googleapis.com", "oauth2.googleapis.com", "logging.googleapis.com",
		"datadoghq.com", "api.datadoghq.com", "events.datadoghq.com", "agent.datadoghq.com",
		"sentry.io", "o12345.ingest.sentry.io", "api.segment.io", "telemetry.controlplane.io",
		"control-plane.io", "docs.control-plane.io", "signalloom.ai", "api.signalloom.ai",
		"vault.corp.internal", "spire.corp.internal", "db.corp.internal", "redis.corp.internal",
		"auth.corp.internal", "identity.corp.internal", "monitoring.corp.internal", "metrics.corp.internal",
		"k8s.io", "kubernetes.default.svc.cluster.local", "kube-dns.kube-system.svc.cluster.local",
		"cgroup.internal", "node-local-dns.kube-system.svc.cluster.local", "zot.registry.svc.cluster.local",
		"envoy.ingress.svc.cluster.local", "openbao.inf-bao.svc.cluster.local", "frostdb.signal-ingest.svc.cluster.local",
		"api.signal-ingest.svc.cluster.local",
	}

	eventID := 1

	// 1. Initial burst: 100 first-seen unique resolutions (10 pods x 10 domains)
	for i, pod := range pods {
		for j := 0; j < 10; j++ {
			domainIdx := (i + j) % len(domains)
			events = append(events, WorkloadEvent{
				ID:                 eventID,
				TimestampOffsetSec: baseTime,
				PodNamespace:       pod.ns,
				PodName:            pod.name,
				QName:              domains[domainIdx],
				Answers:            []string{fmt.Sprintf("192.0.2.%d", (eventID%250)+1)},
				TTL:                60, // 60s TTL
				IsAnomaly:          false,
			})
			eventID++
		}
	}

	// 2. High-frequency routine repeated lookups within TTL (t=5s to 25s): 820 events
	for sec := 5; sec <= 25; sec += 5 {
		for _, pod := range pods {
			for k := 0; k < 20; k++ {
				if eventID > 920 {
					break
				}
				domainIdx := (k * 2) % len(domains)
				events = append(events, WorkloadEvent{
					ID:                 eventID,
					TimestampOffsetSec: sec,
					PodNamespace:       pod.ns,
					PodName:            pod.name,
					QName:              domains[domainIdx],
					Answers:            []string{fmt.Sprintf("192.0.2.%d", (domainIdx%250)+1)},
					TTL:                60,
					IsAnomaly:          false,
				})
				eventID++
			}
		}
	}

	// Fill remaining up to 920
	for eventID <= 920 {
		events = append(events, WorkloadEvent{
			ID:                 eventID,
			TimestampOffsetSec: 25,
			PodNamespace:       "default",
			PodName:            "agent-runner-0",
			QName:              "api.anthropic.com",
			Answers:            []string{"192.0.2.1"},
			TTL:                60,
			IsAnomaly:          false,
		})
		eventID++
	}

	// 3. Post-expiry lookups (t=120s, after 60s TTL elapsed): 50 events
	for i := 0; i < 50; i++ {
		pod := pods[i%len(pods)]
		domainIdx := i % len(domains)
		events = append(events, WorkloadEvent{
			ID:                 eventID,
			TimestampOffsetSec: 120, // Expired relative to t=0..25s
			PodNamespace:       pod.ns,
			PodName:            pod.name,
			QName:              domains[domainIdx],
			Answers:            []string{fmt.Sprintf("198.51.100.%d", (i%250)+1)},
			TTL:                60,
			IsAnomaly:          false,
		})
		eventID++
	}

	// 4. Anomaly-tagged security alerts: 30 events
	anomalyTypes := []string{
		AnomalyDirectIPEgress,
		AnomalyDNSSNIMismatch,
		AnomalyNonClusterResolver,
		AnomalyNXDOMAINBurst,
		AnomalyUnparsedCapture,
	}
	for i := 0; i < 30; i++ {
		pod := pods[i%len(pods)]
		events = append(events, WorkloadEvent{
			ID:                 eventID,
			TimestampOffsetSec: 130 + i,
			PodNamespace:       pod.ns,
			PodName:            pod.name,
			QName:              fmt.Sprintf("c2-beacon-%d.attacker.com", i),
			Answers:            []string{"203.0.113.100"},
			TTL:                60,
			IsAnomaly:          true,
			AnomalyType:        anomalyTypes[i%len(anomalyTypes)],
		})
		eventID++
	}

	return events
}

// replayWorkload executes the synthetic workload through the correlator and records emissions.
func replayWorkload(events []WorkloadEvent, enableFilter bool) (int, *PresentationFilter) {
	startTime := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	clk := newMockClock(startTime)
	cache := NewDNSCache(WithDNSCacheClock(clk))
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	emittedCount := 0

	for _, ev := range events {
		eventTime := startTime.Add(time.Duration(ev.TimestampOffsetSec) * time.Second)
		if clk.Now().Before(eventTime) {
			clk.Advance(eventTime.Sub(clk.Now()))
		}

		podKey := ev.PodNamespace + "/" + ev.PodName
		answers := make([]net.IP, 0, len(ev.Answers))
		for _, a := range ev.Answers {
			if ip := net.ParseIP(a); ip != nil {
				answers = append(answers, ip)
			}
		}

		// Insert into DNSCache
		cache.Insert(podKey, answers, []uint32{ev.TTL}, ev.QName, "")

		// Build observation
		pod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      ev.PodName,
				Namespace: ev.PodNamespace,
			},
		}
		obs := BuildDNSResolutionObservation(pod, ev.QName, answers, clk)
		if ev.IsAnomaly {
			obs.Labels["anomaly"] = ev.AnomalyType
			if ev.AnomalyType == AnomalyDirectIPEgress || ev.AnomalyType == AnomalyDNSSNIMismatch {
				obs.Severity = SeverityCritical
			}
		}

		if !enableFilter {
			// Filter DISABLED -> RAW count: every event emits
			emittedCount++
		} else {
			// Filter ENABLED -> 3-tier presentation filter evaluation
			filteredObs, emit := filter.FilterObservation(podKey, ev.QName, ev.TTL, obs)
			if emit && filteredObs != nil {
				emittedCount++
			}
		}
	}

	return emittedCount, filter
}

// TestPresentationFilter_WorkloadFixture_MeasuredReduction executes the fixture workload
// harness modeled on collectors/awslogs/collector.go:411 replayFixtures, compares raw vs
// filtered emission counts, and validates the reduction against golden test fixture.
func TestPresentationFilter_WorkloadFixture_MeasuredReduction(t *testing.T) {
	fixturePath := filepath.Join("testdata", "dns-resolution-workload-fixture.json")
	goldenPath := filepath.Join("testdata", "presentation-filter-reduction.golden.json")

	var events []WorkloadEvent

	// Load fixture or generate if absent
	data, err := os.ReadFile(fixturePath)
	if err == nil {
		if err := json.Unmarshal(data, &events); err != nil {
			t.Fatalf("failed to unmarshal fixture %s: %v", fixturePath, err)
		}
	} else {
		events = generateSyntheticWorkload()
		out, _ := json.MarshalIndent(events, "", "  ")
		_ = os.MkdirAll("testdata", 0755)
		_ = os.WriteFile(fixturePath, out, 0644)
	}

	totalEvents := len(events)
	if totalEvents != 1000 {
		t.Fatalf("expected 1000 workload events, got %d", totalEvents)
	}

	// 1. Run fixture with filter DISABLED -> RAW count
	rawCount, _ := replayWorkload(events, false)

	// 2. Run fixture with filter ENABLED -> FILTERED count
	filteredCount, filter := replayWorkload(events, true)

	suppressedCount := rawCount - filteredCount
	reductionPct := (float64(suppressedCount) / float64(rawCount)) * 100.0

	result := WorkloadReductionResult{
		FixtureDescription:   "1000-event synthetic DNS workload: 100 first-seen resolutions, 820 in-TTL repeats, 50 post-expiry lookups, 30 anomaly queries across 10 pods and 50 domains",
		TotalWorkloadEvents:  totalEvents,
		RawEmittedCount:      rawCount,
		FilteredEmittedCount: filteredCount,
		SuppressedCount:      suppressedCount,
		MeasuredReductionPct: reductionPct,
	}

	t.Logf("Presentation Filter Measured Reduction Results:")
	t.Logf("  Raw Baseline (Filter Disabled):    %d events", rawCount)
	t.Logf("  Filtered Stream (Filter Enabled):  %d events", filteredCount)
	t.Logf("  Suppressed Duplicate Events:       %d events", suppressedCount)
	t.Logf("  Measured Volume Reduction:         %.2f%%", reductionPct)

	// Verify metrics match
	stats := filter.Stats()
	if int(stats.Emitted) != filteredCount {
		t.Errorf("filter.Stats().Emitted = %d, want %d", stats.Emitted, filteredCount)
	}
	if int(stats.Suppressed) != suppressedCount {
		t.Errorf("filter.Stats().Suppressed = %d, want %d", stats.Suppressed, suppressedCount)
	}

	// Verify / save golden fixture
	goldenBytes, err := os.ReadFile(goldenPath)
	if err == nil {
		var goldenResult WorkloadReductionResult
		if err := json.Unmarshal(goldenBytes, &goldenResult); err == nil {
			if goldenResult.RawEmittedCount != rawCount || goldenResult.FilteredEmittedCount != filteredCount {
				t.Errorf("fixture result does not match golden file!\nGot: %+v\nGolden: %+v", result, goldenResult)
			}
		}
	} else {
		out, _ := json.MarshalIndent(result, "", "  ")
		_ = os.WriteFile(goldenPath, out, 0644)
	}
}

// BenchmarkPresentationFilter_Filter measures lookup performance of the presentation filter.
func BenchmarkPresentationFilter_Filter(b *testing.B) {
	cache := NewDNSCache()
	filter := NewPresentationFilter(WithPresentationFilterDNSCache(cache))

	podID := "default/bench-pod"
	qname := "api.example.com"
	ttl := uint32(300)

	// Pre-populate
	filter.FilterResolution(podID, qname, ttl)

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		_ = filter.FilterResolution(podID, qname, ttl)
	}
}

// BenchmarkPresentationFilter_Parallel measures concurrent filter lookups across goroutines.
func BenchmarkPresentationFilter_Parallel(b *testing.B) {
	cache := NewDNSCache()
	filter := NewPresentationFilter(WithPresentationFilterDNSCache(cache))

	for i := 0; i < 100; i++ {
		podID := fmt.Sprintf("default/pod-%d", i)
		filter.FilterResolution(podID, "api.example.com", 300)
	}

	b.ResetTimer()
	b.ReportAllocs()

	b.RunParallel(func(pb *testing.PB) {
		i := 0
		for pb.Next() {
			podID := fmt.Sprintf("default/pod-%d", i%100)
			_ = filter.FilterResolution(podID, "api.example.com", 300)
			i++
		}
	})
}
