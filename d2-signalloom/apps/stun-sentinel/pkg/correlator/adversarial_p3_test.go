// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	types "k8s.io/apimachinery/pkg/types"
)

// =============================================================================
// SLWD Phase 3 Adversarial Red-Team Test Suite
// =============================================================================
//
// This suite red-teams the Phase 3 presentation filter, anomaly bypass,
// and DNS cache eviction mechanisms:
//
// Attack 1: Hiding C2 inside a suppressed repeat name (Multi-Answer CDN/C2)
// Attack 2: Forcing an alert-volume denial of service via anomaly flood
// Attack 4: Starving the DNSCache LRU to induce false direct-IP CRITICALs
// =============================================================================

// =============================================================================
// Attack 1: Hiding C2 inside a suppressed repeat name
// =============================================================================

// TestAdversarialSuppressedConnect red-teams an evasion tactic where an adversary
// resolves a legitimate-looking domain once (returning multiple A records), allowing
// the Tier-2 presentation filter to suppress subsequent DNS queries for that domain,
// and then performs connections to different answer IPs to hide C2 traffic.
//
// Assertion: Tier-1 per-connect inline emission from reportConnect() must continue
// to emit one TelemetryObservation per connection to each distinct answer IP,
// proving Tier-1 per-connect emission survives Tier-2 per-name suppression.
func TestAdversarialSuppressedConnect(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "c2-evasion-pod",
			Namespace: "workload-agents",
			UID:       types.UID(pipelinePodUID),
			Labels: map[string]string{
				"tenant": "tenant-adversarial",
				"app":    "c2-simulation",
			},
		},
	}

	clk := newMockClock(time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
	)

	m, _ := pipeline(t, pod, nil)
	m.dnsCache = cache
	m.presentationFilter = filter
	m.clock = clk

	domain := "api.cdn-c2-adversary.net"
	ip1 := net.ParseIP("198.51.100.101")
	ip2 := net.ParseIP("198.51.100.102")
	ip3 := net.ParseIP("198.51.100.103")
	answers := []net.IP{ip1, ip2, ip3}
	ttls := []uint32{300, 300, 300} // 300s TTL

	podIdentifier := podKey(pod)

	// Step 1: First DNS resolution encounter for api.cdn-c2-adversary.net
	// Must emit (first encounter) and index all 3 IPs in DNSCache
	dnsObs1, emit1 := m.ProcessDNSResolution(pod, podIdentifier, answers, ttls, domain, "")
	if !emit1 {
		t.Fatalf("Step 1 FAIL: Initial DNS resolution for %s was suppressed, want emit=true", domain)
	}
	if dnsObs1.Domain != domain {
		t.Errorf("dnsObs1.Domain = %q, want %q", dnsObs1.Domain, domain)
	}

	// Step 2: Second and third DNS resolution queries for the same domain within TTL
	// Must be SUPPRESSED by Tier-2 filter ((pod, qname) deduplication)
	clk.Advance(10 * time.Second)
	_, emit2 := m.ProcessDNSResolution(pod, podIdentifier, answers, ttls, domain, "")
	if emit2 {
		t.Fatalf("Step 2 FAIL: In-TTL duplicate DNS query was emitted, want suppressed (emit=false)")
	}

	clk.Advance(15 * time.Second)
	_, emit3 := m.ProcessDNSResolution(pod, podIdentifier, answers, ttls, domain, "")
	if emit3 {
		t.Fatalf("Step 2 FAIL: In-TTL duplicate DNS query #2 was emitted, want suppressed (emit=false)")
	}

	filterStats := filter.Stats()
	if filterStats.Emitted != 1 || filterStats.Suppressed != 2 {
		t.Errorf("Filter stats after 3 DNS queries: %+v, want Emitted=1, Suppressed=2", filterStats)
	}

	// Step 3: Exploit execution - Adversary connects to answer IP 1
	// Tier-1 inline connect attribution must emit from reportConnect
	connectObs1, ok1 := m.handleRecord(rawConnect(1001, ip1, 443))
	if !ok1 {
		t.Fatalf("Step 3 FAIL: reportConnect for IP 1 (%s) returned ok=false", ip1)
	}
	if connectObs1.Domain != domain {
		t.Errorf("connectObs1.Domain = %q, want %q", connectObs1.Domain, domain)
	}
	if connectObs1.Syscall != SyscallNameConnect {
		t.Errorf("connectObs1.Syscall = %q, want %q", connectObs1.Syscall, SyscallNameConnect)
	}
	if connectObs1.Target != "198.51.100.101:443" {
		t.Errorf("connectObs1.Target = %q, want 198.51.100.101:443", connectObs1.Target)
	}

	// Step 4: Exploit execution - Adversary connects to answer IP 2 (different answer IP on suppressed domain)
	// Must NOT be suppressed by the fact that the domain name is currently suppressed in Tier 2 DNS deduplication
	clk.Advance(5 * time.Second)
	connectObs2, ok2 := m.handleRecord(rawConnect(1001, ip2, 443))
	if !ok2 {
		t.Fatalf("Step 4 FAIL: reportConnect for IP 2 (%s) returned ok=false", ip2)
	}
	if connectObs2.Domain != domain {
		t.Errorf("connectObs2.Domain = %q, want %q", connectObs2.Domain, domain)
	}
	if connectObs2.Target != "198.51.100.102:443" {
		t.Errorf("connectObs2.Target = %q, want 198.51.100.102:443", connectObs2.Target)
	}

	// Step 5: Exploit execution - Adversary connects to answer IP 3 (third answer IP on suppressed domain)
	clk.Advance(5 * time.Second)
	connectObs3, ok3 := m.handleRecord(rawConnect(1001, ip3, 8443))
	if !ok3 {
		t.Fatalf("Step 5 FAIL: reportConnect for IP 3 (%s) returned ok=false", ip3)
	}
	if connectObs3.Domain != domain {
		t.Errorf("connectObs3.Domain = %q, want %q", connectObs3.Domain, domain)
	}
	if connectObs3.Target != "198.51.100.103:8443" {
		t.Errorf("connectObs3.Target = %q, want 198.51.100.103:8443", connectObs3.Target)
	}

	// Step 6: Verify privacy layer downstream projection
	for i, obs := range []*TelemetryObservation{&connectObs1, &connectObs2, &connectObs3} {
		ingest := obs.toIngest()
		if ingest.Labels["domain_pseudonym"] == "" || !IsPseudonym(ingest.Labels["domain_pseudonym"]) {
			t.Errorf("Observation %d: missing or invalid domain_pseudonym: %q", i+1, ingest.Labels["domain_pseudonym"])
		}
		if _, exists := ingest.Labels["domain"]; exists {
			t.Errorf("Observation %d: leaked cleartext domain label: %v", i+1, ingest.Labels)
		}
	}

	// Final verification: 3 distinct connects emitted, 0 connects suppressed
	t.Logf("SUCCESS: All 3 multi-answer connects emitted under Tier 1 while Tier 2 DNS suppression was active (%d suppressed)", filterStats.Suppressed)
}

// =============================================================================
// Attack 2: Forcing an Alert-Volume Denial of Service via Anomaly Flood
// =============================================================================

// TestAdversarialAnomalyFlood_BoundedTransport red-teams the Tier-3 'always emit on anomaly'
// bypass path under high-rate adversarial flooding of anomaly-tagged queries and NXDOMAIN storms.
//
// Assertion: Bounded ringbuffer sizing, LRU table capacity limits, and drop accounting
// cap the resulting event streams and track drops rather than allowing unbounded memory growth
// or unmonitored downstream flooding.
func TestAdversarialAnomalyFlood_BoundedTransport(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk), WithDNSCacheCapacity(1024))
	filterCap := 512
	filter := NewPresentationFilter(
		WithPresentationFilterDNSCache(cache),
		WithPresentationFilterClock(clk),
		WithPresentationFilterCapacity(filterCap),
	)

	podID := "workload-flood/agent-attacker"

	// 1. Flood with 10,000 unique anomaly observations (direct-to-IP / mismatch)
	floodCount := 10000
	var emittedAnomalyCount uint64
	for i := 0; i < floodCount; i++ {
		anomalyObs := &TelemetryObservation{
			Timestamp: clk.Now().UTC().Format(time.RFC3339Nano),
			Syscall:   SyscallNameConnect,
			Target:    fmt.Sprintf("198.51.100.%d:443", (i%250)+1),
			Severity:  SeverityCritical,
			Labels: map[string]string{
				"anomaly": AnomalyDirectIPEgress,
				"dest_ip": fmt.Sprintf("198.51.100.%d", (i%250)+1),
			},
		}

		out, emit := filter.FilterObservation(podID, "", 0, anomalyObs)
		if emit && out != nil {
			emittedAnomalyCount++
		}
	}

	if emittedAnomalyCount != uint64(floodCount) {
		t.Fatalf("Anomaly bypass failed: emitted %d, want %d", emittedAnomalyCount, floodCount)
	}

	// 2. Assert PresentationFilter internal LRU capacity remains bounded
	filter.mu.RLock()
	tableSize := len(filter.entries)
	lruLen := filter.lruList.Len()
	filter.mu.RUnlock()

	if tableSize > filterCap || lruLen > filterCap {
		t.Errorf("PresentationFilter table grew unbounded: entries=%d, lruLen=%d, cap=%d", tableSize, lruLen, filterCap)
	}

	// 3. Test NXDOMAIN burst sliding window tracking
	resCache := NewResolverCache(WithResolverCacheClock(clk))
	engine := NewDNSHeuristicsEngine(
		WithHeuristicsDNSCache(cache),
		WithHeuristicsResolverCache(resCache),
		WithHeuristicsClock(clk),
	)

	fakePod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "burst-attacker-pod",
			Namespace: "workload-flood",
			UID:       types.UID("pod-burst-001"),
		},
	}

	// Burst 50 distinct NXDOMAIN lookups
	var alertCount int
	for i := 0; i < 50; i++ {
		qname := fmt.Sprintf("dga-nonexistent-%d.attacker.test", i)
		obs, alerted := engine.EvaluateNXDOMAIN(podKey(fakePod), qname, 3, fakePod, nil)
		if alerted && obs != nil {
			alertCount++
		}
	}

	// Burst tracker threshold is > 10 distinct names in 10s window:
	// Queries 1-10 do not alert, query 11 alerts.
	// Subsequent queries in the same burst alert as threshold remains exceeded.
	if alertCount == 0 {
		t.Fatalf("NXDOMAIN burst tracker failed to detect DGA storm")
	}

	// 4. Verify unparsed capture & ringbuffer drop accounting
	var dropCounter atomic.Uint64
	dropCounter.Add(1500) // 1,500 drops recorded during burst

	unparsedObs, unparsedAlert := engine.EvaluateUnparsedCapture(
		"dns",
		ebpf.DNS_PARSE_TRUNCATED,
		"ringbuf_full",
		dropCounter.Load(),
		fakePod,
		nil,
	)

	if !unparsedAlert || unparsedObs == nil {
		t.Fatalf("EvaluateUnparsedCapture failed on drop flood")
	}
	if unparsedObs.Severity != SeverityWarn {
		t.Errorf("unparsedObs.Severity = %q, want %q", unparsedObs.Severity, SeverityWarn)
	}
	if unparsedObs.Labels["drop_count"] != "1500" {
		t.Errorf("unparsedObs drop_count label = %q, want 1500", unparsedObs.Labels["drop_count"])
	}

	t.Logf("SUCCESS: Anomaly flood contained by bounded transport and drop counters (tableSize=%d <= %d, alerts=%d, drops=%s)",
		tableSize, filterCap, alertCount, unparsedObs.Labels["ringbuf_drops"])
}

// =============================================================================
// Attack 4: Starving the DNSCache LRU to Induce False CRITICALs
// =============================================================================

// TestCacheStarvationEviction red-teams DNSCache capacity exhaustion attacks.
// An adversary floods the cache with distinct domain resolutions to evict legitimate
// unexpired entries, then triggers connections to the evicted addresses.
//
// Assertion: Cache starvation produces a COUNTED eviction in stats (c.evicted and
// c.evictedUnexpired in DNSCacheStats), providing explicit telemetry evidence of
// cache starvation rather than leaving false CRITICAL direct-IP alerts uncounted.
// (Appendix C eviction false-positive exclusion row).
func TestCacheStarvationEviction(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC))
	// Configure small capacity to deterministically trigger LRU shard eviction
	// Total capacity = 32 entries across 16 shards = 2 entries per shard
	totalCapacity := 32
	cache := NewDNSCache(
		WithDNSCacheClock(clk),
		WithDNSCacheCapacity(totalCapacity),
	)

	podID := "workload-starve/agent-victim"
	legitDomain := "auth.enterprise-service.internal"
	legitIP := net.ParseIP("198.51.100.222")
	legitTTL := uint32(3600) // 1 hour TTL (unexpired)

	// Step 1: Insert legitimate long-lived domain resolution
	cache.Insert(podID, []net.IP{legitIP}, []uint32{legitTTL}, legitDomain, "")

	// Verify resolution is cached
	resolvedDomain, found := cache.Lookup(podID, legitIP.String())
	if !found || resolvedDomain != legitDomain {
		t.Fatalf("Step 1 FAIL: Initial lookup failed: found=%v, domain=%q", found, resolvedDomain)
	}

	initialStats := cache.Stats()
	if initialStats.Evicted != 0 || initialStats.EvictedUnexpired != 0 {
		t.Errorf("Initial cache stats dirty: %+v", initialStats)
	}

	// Step 2: Exploit - Adversary floods cache with 500 distinct synthetic resolutions
	// to completely evict the shard entries
	floodEntries := 500
	for i := 0; i < floodEntries; i++ {
		fakeDomain := fmt.Sprintf("flood-attacker-%d.evil.test", i)
		fakeIP := net.ParseIP(fmt.Sprintf("203.0.113.%d", (i%250)+1))
		cache.Insert(podID, []net.IP{fakeIP}, []uint32{300}, fakeDomain, "")
	}

	// Step 3: Verify LRU eviction occurred and was COUNTED
	postFloodStats := cache.Stats()
	if postFloodStats.Evicted == 0 {
		t.Fatalf("Step 3 FAIL: No evictions recorded after %d insertions into %d capacity cache", floodEntries, totalCapacity)
	}
	if postFloodStats.EvictedUnexpired == 0 {
		t.Fatalf("Step 3 FAIL: EvictedUnexpired counter is 0, want > 0 to account for evicted legitimate entry")
	}

	t.Logf("Cache stats after starvation flood: Inserted=%d, Evicted=%d, EvictedUnexpired=%d",
		postFloodStats.Inserted, postFloodStats.Evicted, postFloodStats.EvictedUnexpired)

	// Step 4: Workload connects to the evicted legitimate IP
	_, foundAfterFlood := cache.Lookup(podID, legitIP.String())
	if foundAfterFlood {
		t.Fatalf("Step 4 FAIL: Legit entry was not evicted (still found), adjust flood size")
	}

	// Step 5: Verify Appendix C exclusion accounting
	// In the heuristics engine, EvaluateDirectIPEgress flags unmapped IP,
	// but the unexpired eviction counter proves cache starvation occurred.
	resCache := NewResolverCache(WithResolverCacheClock(clk))
	engine := NewDNSHeuristicsEngine(
		WithHeuristicsDNSCache(cache),
		WithHeuristicsResolverCache(resCache),
		WithHeuristicsClock(clk),
	)

	fakePod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-victim",
			Namespace: "workload-starve",
		},
	}

	obs, alerted := engine.EvaluateDirectIPEgress(podID, legitIP, fakePod, nil)
	if !alerted || obs == nil {
		t.Fatalf("EvaluateDirectIPEgress did not flag unmapped IP after eviction")
	}

	// Confirm that the cache eviction telemetry confirms starvation took place
	if cache.Stats().EvictedUnexpired == 0 {
		t.Errorf("Eviction that could cause false direct-IP alert was UNCOUNTED in EvictedUnexpired")
	}

	t.Logf("SUCCESS: Cache starvation produced counted eviction (EvictedUnexpired=%d) matching Appendix C exclusion accounting",
		cache.Stats().EvictedUnexpired)
}
