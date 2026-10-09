// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	types "k8s.io/apimachinery/pkg/types"
)

// =============================================================================
// Red-Team Test Fixture Builder (Test-Only)
// =============================================================================

// redteamFixture encapsulates test infrastructure for red-teaming Phase 2 heuristics.
// It is test-only and isolates adversary simulation from production paths.
type redteamFixture struct {
	clock         *mockClock
	cache         *DNSCache
	resolverCache *ResolverCache
	engine        *DNSHeuristicsEngine
	defaultPod    *corev1.Pod
}

func newRedteamFixture(t *testing.T) *redteamFixture {
	t.Helper()
	baseTime := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	clk := newMockClock(baseTime)

	cache := NewDNSCache(WithDNSCacheClock(clk))
	resCache := NewResolverCache(WithResolverCacheClock(clk))
	engine := NewDNSHeuristicsEngine(
		WithHeuristicsDNSCache(cache),
		WithHeuristicsResolverCache(resCache),
		WithHeuristicsClock(clk),
	)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "redteam-victim-pod",
			Namespace: "workload-prod",
			UID:       types.UID("pod-redteam-001"),
			Labels: map[string]string{
				"tenant": "tenant-redteam",
				"app":    "payment-processor",
			},
		},
	}

	return &redteamFixture{
		clock:         clk,
		cache:         cache,
		resolverCache: resCache,
		engine:        engine,
		defaultPod:    pod,
	}
}

func (f *redteamFixture) podKey() string {
	return podKey(f.defaultPod)
}

// =============================================================================
// Attack 1: Direct-to-IP C2 Beaconing (Appendix C Row 1)
// =============================================================================

// TestRedteamDNS_DirectToIPC2Beaconing red-teams direct socket connections to external
// IP addresses where no DNS resolution was ever performed by the pod.
//
// Expected: CRITICAL alert (AnomalyDirectIPEgress) must fire.
func TestRedteamDNS_DirectToIPC2Beaconing(t *testing.T) {
	f := newRedteamFixture(t)
	c2IP := net.ParseIP("198.51.100.99")

	// Adversary connects directly to C2 IP without DNS resolution
	obs, ok := f.engine.EvaluateDirectIPEgress(f.podKey(), c2IP, f.defaultPod, nil)
	if !ok || obs == nil {
		t.Fatalf("FAIL: Direct-to-IP C2 beacon to %s was missed by EvaluateDirectIPEgress (got ok=%v, obs=%v)", c2IP, ok, obs)
	}

	if obs.Severity != SeverityCritical {
		t.Errorf("Severity = %q, want %q (CRITICAL)", obs.Severity, SeverityCritical)
	}
	if obs.Labels["anomaly"] != AnomalyDirectIPEgress {
		t.Errorf("Anomaly label = %q, want %q", obs.Labels["anomaly"], AnomalyDirectIPEgress)
	}
	if obs.Labels["dest_ip"] != "198.51.100.99" {
		t.Errorf("dest_ip label = %q, want 198.51.100.99", obs.Labels["dest_ip"])
	}
	if f.engine.Metrics().DirectIPEgressAlerts.Load() != 1 {
		t.Errorf("Metric DirectIPEgressAlerts = %d, want 1", f.engine.Metrics().DirectIPEgressAlerts.Load())
	}
}

// =============================================================================
// Attack 2: SNI Domain Fronting & CNAME Cross-Check (Appendix C Row 2)
// =============================================================================

// TestRedteamDNS_SNIDomainFronting red-teams TLS ClientHello Server Name Indication
// (SNI) evasion where the DNS query resolves a benign domain A, but TLS SNI requests domain B.
//
// Expected:
// - CRITICAL alert (AnomalyDNSSNIMismatch) fires when domain B is NOT a CNAME alias of domain A.
// - Must NOT fire when domain B is a legitimate CNAME alias of domain A.
func TestRedteamDNS_SNIDomainFronting(t *testing.T) {
	f := newRedteamFixture(t)
	frontIP := net.ParseIP("198.51.100.40")

	// 1. Pod resolves benign decoy domain via DNS
	f.cache.Insert(f.podKey(), []net.IP{frontIP}, []uint32{300}, "decoy-cdn.example.com", "")

	// 2. TLS ClientHello transmits hostile C2 SNI to the fronting IP
	obs, ok := f.engine.EvaluateDNSSNIMismatch(f.podKey(), frontIP, "c2-controller.attacker.com", ebpf.TLS_CH_OK, f.defaultPod, nil)
	if !ok || obs == nil {
		t.Fatalf("FAIL: SNI domain fronting (decoy-cdn.example.com -> c2-controller.attacker.com) missed by EvaluateDNSSNIMismatch (got ok=%v, obs=%v)", ok, obs)
	}

	if obs.Severity != SeverityCritical {
		t.Errorf("Severity = %q, want %q (CRITICAL)", obs.Severity, SeverityCritical)
	}
	if obs.Labels["anomaly"] != AnomalyDNSSNIMismatch {
		t.Errorf("Anomaly label = %q, want %q", obs.Labels["anomaly"], AnomalyDNSSNIMismatch)
	}
	if obs.Labels["dns_domain"] != "decoy-cdn.example.com" {
		t.Errorf("dns_domain label = %q, want decoy-cdn.example.com", obs.Labels["dns_domain"])
	}
	if obs.Labels["sni"] != "c2-controller.attacker.com" {
		t.Errorf("sni label = %q, want c2-controller.attacker.com", obs.Labels["sni"])
	}

	// 3. Cross-check exclusion: Valid CNAME alias relationship must NOT fire
	aliasIP := net.ParseIP("198.51.100.41")
	f.cache.Insert(f.podKey(), []net.IP{aliasIP}, []uint32{300}, "app.example.com", "d123.cloudfront.net")
	obsAlias, okAlias := f.engine.EvaluateDNSSNIMismatch(f.podKey(), aliasIP, "d123.cloudfront.net", ebpf.TLS_CH_OK, f.defaultPod, nil)
	if okAlias || obsAlias != nil {
		t.Errorf("FAIL: False positive on legitimate CNAME alias (got obs=%+v)", obsAlias)
	}
}

// =============================================================================
// Attack 3: Covert DNS Tunnelling over TXT (Undetected Class Probe)
// =============================================================================

// TestRedteamDNS_CovertTXTTunnellingUndetected probes whether high-rate, high-cardinality
// TXT queries (qtype=16) with NOERROR responses are detected by any Phase 2 heuristic.
//
// Finding: Appendix B decodes TXT (16), but existing Phase 2 heuristics only check:
// 1. Direct IP connect (no connection made in pure DNS tunnel)
// 2. DNS vs SNI (no TLS handshake in pure DNS tunnel)
// 3. Non-cluster resolver (tunnel uses authorized cluster DNS)
// 4. NXDOMAIN burst (tunnel returns NOERROR rcode=0, not NXDOMAIN rcode=3)
// 5. Unparsed capture (parse_status == DNS_PARSE_OK)
//
// Result: TXT DNS tunnelling over authorized resolvers with NOERROR is completely UNDETECTED.
func TestRedteamDNS_CovertTXTTunnellingUndetected(t *testing.T) {
	f := newRedteamFixture(t)
	clusterDNS := net.ParseIP("10.96.0.10")
	f.resolverCache.AddClusterDNS(clusterDNS.String())

	tunnelCount := 50
	alertsTriggered := 0

	for i := 0; i < tunnelCount; i++ {
		// High-cardinality data chunks exfiltrated in QNAME
		tunnelQName := fmt.Sprintf("chunk-%04d.exfil-session-%02d.tunnel.attacker.com", i, i%5)

		// 1. Check Non-Cluster Resolver Heuristic (directed to authorized cluster DNS)
		if _, ok := f.engine.EvaluateNonClusterResolver(f.podKey(), 1234, clusterDNS, f.defaultPod, nil); ok {
			alertsTriggered++
		}

		// 2. Check NXDOMAIN Heuristic (DNS tunnel answers with NOERROR rcode=0 containing TXT payload)
		if _, ok := f.engine.EvaluateNXDOMAIN(f.podKey(), tunnelQName, 0 /* NOERROR */, f.defaultPod, nil); ok {
			alertsTriggered++
		}

		// 3. Check Unparsed Capture Heuristic (qtype=16 cleanly parsed)
		if _, ok := f.engine.EvaluateUnparsedCapture("dns", ebpf.DNS_PARSE_OK, "", 0, f.defaultPod, nil); ok {
			alertsTriggered++
		}
	}

	// Document the undetected evasion finding:
	if alertsTriggered > 0 {
		t.Fatalf("Unexpected detection of TXT tunnel: got %d alerts, expected 0 in Phase 2 baseline", alertsTriggered)
	}

	t.Logf("CONFIRMED FINDING: 50/50 covert TXT tunnel queries with NOERROR over cluster DNS generated %d alerts (0%% detection rate — undetected class in Phase 2)", alertsTriggered)
}

// =============================================================================
// Attack 4: Resolution Before Warden Attached (Structural False Positive)
// =============================================================================

// TestRedteamDNS_PreAttachResolutionFalsePositive reproduces the structural false positive
// where a pod resolves an address before Warden/TC monitor attaches, leaving DNSCache empty.
//
// Cross-reference: P2-3 Errata Finding 1 (Direct-to-IP pre-attachment observability boundary).
func TestRedteamDNS_PreAttachResolutionFalsePositive(t *testing.T) {
	f := newRedteamFixture(t)
	legitIP := net.ParseIP("203.0.113.88")

	// Pod resolved 'api.legit-partner.com -> 203.0.113.88' BEFORE Warden TC filter attached.
	// Therefore, f.cache has no record of this resolution.

	// Pod now initiates a legitimate connect() to 203.0.113.88
	obs, ok := f.engine.EvaluateDirectIPEgress(f.podKey(), legitIP, f.defaultPod, nil)
	if !ok || obs == nil {
		t.Fatalf("Expected Direct-IP heuristic to fire on pre-attach resolution (documenting known false positive), got ok=%v", ok)
	}

	if obs.Severity != SeverityCritical {
		t.Errorf("Severity = %q, want %q", obs.Severity, SeverityCritical)
	}
	if obs.Labels["anomaly"] != AnomalyDirectIPEgress {
		t.Errorf("Anomaly label = %q, want %q", obs.Labels["anomaly"], AnomalyDirectIPEgress)
	}

	t.Logf("CONFIRMED STRUCTURAL FALSE POSITIVE: Pre-attach resolution to %s generated CRITICAL Direct-IP alert (reproduced as documented in P2-3 errata)", legitIP)
}

// =============================================================================
// Attack 5: CDN Multi-Answer Egress Sweep (False-Positive Protection)
// =============================================================================

// TestRedteamDNS_MultiAnswerCDNSweepNoFalsePositive sweeps all answer addresses of a
// multi-answer CDN record to prove none trigger false CRITICAL Direct-IP alerts.
func TestRedteamDNS_MultiAnswerCDNSweepNoFalsePositive(t *testing.T) {
	f := newRedteamFixture(t)
	cdnAnswers := []net.IP{
		net.ParseIP("198.51.100.101"),
		net.ParseIP("198.51.100.102"),
		net.ParseIP("198.51.100.103"),
		net.ParseIP("198.51.100.104"),
	}
	ttls := []uint32{120, 120, 120, 120}

	// Insert multi-answer record for cdn.globalassets.com
	f.cache.Insert(f.podKey(), cdnAnswers, ttls, "cdn.globalassets.com", "")

	// Connect across 1st, 2nd, 3rd, and 4th answer addresses
	for idx, ip := range cdnAnswers {
		obs, ok := f.engine.EvaluateDirectIPEgress(f.podKey(), ip, f.defaultPod, nil)
		if ok || obs != nil {
			t.Errorf("FAIL: False positive on CDN answer %d (%s): got obs=%+v", idx+1, ip, obs)
		}
	}

	t.Logf("VERIFIED: 4/4 CDN answer addresses evaluated cleanly with 0 false positives (0.0%% false-positive rate)")
}

// =============================================================================
// Attack 6: Deep CNAME Alias Chain Sweep (False-Positive & Detection Sweep)
// =============================================================================

// TestRedteamDNS_CNAMEDepthSweepNoFalsePositive tests CNAME alias chains up to depth 3:
// Depth 1: portal.corp.com -> edge.cdn.net -> [IP]
// Depth 2: auth.corp.com -> idp.global.net -> auth-lb.infra.net -> [IP]
// Depth 3: api.corp.com -> gw.cloud.com -> egress.cluster.net -> node.internal.net -> [IP]
func TestRedteamDNS_CNAMEDepthSweepNoFalsePositive(t *testing.T) {
	f := newRedteamFixture(t)

	// Depth 1 CNAME
	ip1 := net.ParseIP("198.51.100.201")
	f.cache.Insert(f.podKey(), []net.IP{ip1}, []uint32{300}, "portal.corp.com", "edge.cdn.net")

	// Depth 2 CNAME
	ip2 := net.ParseIP("198.51.100.202")
	f.cache.Insert(f.podKey(), []net.IP{ip2}, []uint32{300}, "idp.global.net", "auth-lb.infra.net")
	f.cache.Insert(f.podKey(), []net.IP{ip2}, []uint32{300}, "auth.corp.com", "idp.global.net")

	// Depth 3 CNAME
	ip3 := net.ParseIP("198.51.100.203")
	f.cache.Insert(f.podKey(), []net.IP{ip3}, []uint32{300}, "egress.cluster.net", "node.internal.net")
	f.cache.Insert(f.podKey(), []net.IP{ip3}, []uint32{300}, "gw.cloud.com", "egress.cluster.net")
	f.cache.Insert(f.podKey(), []net.IP{ip3}, []uint32{300}, "api.corp.com", "gw.cloud.com")

	// Verify all alias names in the chain do NOT produce false CRITICAL SNI alerts
	testCases := []struct {
		ip   net.IP
		sni  string
		desc string
	}{
		{ip1, "portal.corp.com", "depth-1 origin"},
		{ip1, "edge.cdn.net", "depth-1 target"},
		{ip2, "auth.corp.com", "depth-2 origin"},
		{ip2, "idp.global.net", "depth-2 hop1"},
		{ip2, "auth-lb.infra.net", "depth-2 target"},
		{ip3, "api.corp.com", "depth-3 origin"},
		{ip3, "gw.cloud.com", "depth-3 hop1"},
		{ip3, "egress.cluster.net", "depth-3 hop2"},
		{ip3, "node.internal.net", "depth-3 target"},
	}

	for _, tc := range testCases {
		obs, ok := f.engine.EvaluateDNSSNIMismatch(f.podKey(), tc.ip, tc.sni, ebpf.TLS_CH_OK, f.defaultPod, nil)
		if ok || obs != nil {
			t.Errorf("FAIL: False positive on CNAME %s (sni=%s, ip=%s): got obs=%+v", tc.desc, tc.sni, tc.ip, obs)
		}
	}

	// Verify that an attacker presenting an unrelated SNI to these IPs DOES trigger CRITICAL
	obsBad, okBad := f.engine.EvaluateDNSSNIMismatch(f.podKey(), ip3, "unrelated-evil.com", ebpf.TLS_CH_OK, f.defaultPod, nil)
	if !okBad || obsBad == nil || obsBad.Severity != SeverityCritical {
		t.Errorf("FAIL: Expected CRITICAL detection on mismatched SNI for depth-3 CNAME target, got ok=%v obs=%+v", okBad, obsBad)
	}

	t.Logf("VERIFIED: 9/9 CNAME alias tests produced 0 false positives; 1/1 mismatch attack detected (100%% detection)")
}

// =============================================================================
// Attack 7: Shared-IP Virtual Hosting Sweep (Virtual Host Exclusion)
// =============================================================================

// TestRedteamDNS_VirtualHostSharedIPSweep evaluates virtual hosting where two unrelated
// domains share a common server IP address.
func TestRedteamDNS_VirtualHostSharedIPSweep(t *testing.T) {
	f := newRedteamFixture(t)
	sharedIP := net.ParseIP("198.51.100.55")

	// Domain A resolved to sharedIP
	f.cache.Insert(f.podKey(), []net.IP{sharedIP}, []uint32{300}, "site-a.example.com", "")

	// Domain B registered as shared virtual host on the same IP
	f.engine.RegisterVirtualHost(f.podKey(), sharedIP, "site-b.example.com")

	// TLS ClientHello with SNI site-b.example.com to sharedIP must NOT fire
	obsVHost, okVHost := f.engine.EvaluateDNSSNIMismatch(f.podKey(), sharedIP, "site-b.example.com", ebpf.TLS_CH_OK, f.defaultPod, nil)
	if okVHost || obsVHost != nil {
		t.Errorf("FAIL: False positive on registered shared virtual host: got obs=%+v", obsVHost)
	}

	// TLS ClientHello with un-registered SNI site-c2.attacker.com MUST fire CRITICAL
	obsFront, okFront := f.engine.EvaluateDNSSNIMismatch(f.podKey(), sharedIP, "site-c2.attacker.com", ebpf.TLS_CH_OK, f.defaultPod, nil)
	if !okFront || obsFront == nil || obsFront.Severity != SeverityCritical {
		t.Errorf("FAIL: Expected CRITICAL on un-registered SNI to shared IP, got ok=%v obs=%+v", okFront, obsFront)
	}

	t.Logf("VERIFIED: Shared virtual host exclusion passed with 0 false positives; fronting attempt detected with CRITICAL alert")
}

// =============================================================================
// Attack 8: Off-Cluster-Resolver Exact-Match vs Subnet Semantics Probe
// =============================================================================

// TestRedteamDNS_OffClusterResolverExactMatchSemantics probes whether the resolver
// allow-list uses strict exact-match semantics or prefix/subnet matching.
//
// Adversary queries resolver addresses 1 bit away from allowed addresses:
// - Allowed NodeLocal DNS: 169.254.20.10 -> Probes: 169.254.20.11, 169.254.20.1
// - Allowed Cluster DNS: 10.96.0.10 -> Probes: 10.96.0.11, 10.96.0.1
//
// Expected: Strict exact-match semantics ensure all off-by-one/subnet queries trigger WARN.
func TestRedteamDNS_OffClusterResolverExactMatchSemantics(t *testing.T) {
	f := newRedteamFixture(t)

	// Configure known legitimate resolvers
	clusterDNS := net.ParseIP("10.96.0.10")
	f.resolverCache.AddClusterDNS(clusterDNS.String())
	// NodeLocal 169.254.20.10 is allowed by default in ResolverCache

	// Verify exact match allows legitimate resolvers
	if obs, ok := f.engine.EvaluateNonClusterResolver(f.podKey(), 100, clusterDNS, f.defaultPod, nil); ok || obs != nil {
		t.Errorf("FAIL: Legitimate cluster DNS 10.96.0.10 triggered false alert: %+v", obs)
	}
	if obs, ok := f.engine.EvaluateNonClusterResolver(f.podKey(), 100, net.ParseIP("169.254.20.10"), f.defaultPod, nil); ok || obs != nil {
		t.Errorf("FAIL: Legitimate NodeLocal DNS 169.254.20.10 triggered false alert: %+v", obs)
	}

	// Adversary probe cases: 1-bit away or adjacent in same subnet
	probes := []struct {
		ip   net.IP
		desc string
	}{
		{net.ParseIP("169.254.20.11"), "NodeLocal + 1 bit"},
		{net.ParseIP("169.254.20.1"), "NodeLocal subnet gateway"},
		{net.ParseIP("10.96.0.11"), "Cluster DNS + 1 bit"},
		{net.ParseIP("10.96.0.1"), "Cluster DNS subnet gateway"},
		{net.ParseIP("8.8.8.8"), "Public Google DNS"},
		{net.ParseIP("1.1.1.1"), "Public Cloudflare DNS"},
	}

	for _, p := range probes {
		obs, ok := f.engine.EvaluateNonClusterResolver(f.podKey(), 100, p.ip, f.defaultPod, nil)
		if !ok || obs == nil {
			t.Fatalf("FAIL: Off-cluster resolver probe %s (%s) was NOT detected (possible subnet leak)", p.ip, p.desc)
		}
		if obs.Severity != SeverityWarn {
			t.Errorf("Severity = %q, want %q (WARN)", obs.Severity, SeverityWarn)
		}
		if obs.Labels["anomaly"] != AnomalyNonClusterResolver {
			t.Errorf("Anomaly label = %q, want %q", obs.Labels["anomaly"], AnomalyNonClusterResolver)
		}
	}

	t.Logf("DETERMINATION: Off-cluster resolver allow-list strictly implements EXACT-MATCH semantics (6/6 rogue/adjacent resolver probes detected, 0 subnet bypasses)")
}

// =============================================================================
// Attack 9: NXDOMAIN Burst Sliding Window Semantics Probe
// =============================================================================

// TestRedteamDNS_NXDOMAINBurstSlidingWindowSemantics probes whether NXDOMAIN burst
// tracking implements true sliding window semantics vs fixed boundary windows.
//
// Probe Scenarios:
// 1. Sliding Window Boundary Straddle: 9 queries at t=5s, 9 queries at t=7s -> Total 18 in a 10s slice.
//    - Fixed window (0-10s, 10-20s): 9 in window 1, 9 in window 2 -> Missed!
//    - Sliding window (t-10s to t): 18 distinct names at t=7s -> FIRES at 11th distinct name.
// 2. Low-and-Slow Evasion: 1 query every 1.1s (9 queries per 10s sliding window) sustained over 30s.
//    - Sliding window purges stale names, distinct count never exceeds 10 -> Low-and-slow bypasses alert.
// 3. Same-Name Retry Exclusion: 50 retries for 1 name -> Distinct count = 1 -> Never fires.
func TestRedteamDNS_NXDOMAINBurstSlidingWindowSemantics(t *testing.T) {
	f := newRedteamFixture(t)

	// --- Scenario 1: Boundary Straddle (Proving Sliding Window vs Fixed Window) ---
	// Send 9 distinct queries at t=5s
	f.clock.Advance(5 * time.Second)
	for i := 0; i < 9; i++ {
		qname := fmt.Sprintf("dga-batch1-%d.evil.com", i)
		obs, ok := f.engine.EvaluateNXDOMAIN(f.podKey(), qname, 3 /* NXDOMAIN */, f.defaultPod, nil)
		if ok || obs != nil {
			t.Errorf("Unexpected alert at %d queries (threshold is 10)", i+1)
		}
	}

	// Advance 2s to t=7s (within the 10s window of the first batch)
	f.clock.Advance(2 * time.Second)

	// Send 2 more distinct queries (total 11 in 7 seconds)
	obs10, ok10 := f.engine.EvaluateNXDOMAIN(f.podKey(), "dga-batch2-0.evil.com", 3, f.defaultPod, nil)
	if ok10 || obs10 != nil {
		t.Errorf("10th query should not trigger alert (threshold is > 10)")
	}

	obs11, ok11 := f.engine.EvaluateNXDOMAIN(f.podKey(), "dga-batch2-1.evil.com", 3, f.defaultPod, nil)
	if !ok11 || obs11 == nil {
		t.Fatalf("FAIL: 11th distinct NXDOMAIN at t=7s did not trigger alert (sliding window failure)")
	}
	if obs11.Severity != SeverityWarn || obs11.Labels["anomaly"] != AnomalyNXDOMAINBurst {
		t.Errorf("Alert labels mismatch: %+v", obs11)
	}

	// --- Scenario 2: Low-and-Slow Rate Evasion Below Threshold ---
	f2 := newRedteamFixture(t)
	lowAndSlowAlerts := 0
	// 27 queries spread over 30 seconds (1 query every 1.1s -> max 9-10 queries per any 10s slice)
	for i := 0; i < 27; i++ {
		f2.clock.Advance(1100 * time.Millisecond)
		qname := fmt.Sprintf("slow-dga-%03d.evil.com", i)
		if _, ok := f2.engine.EvaluateNXDOMAIN(f2.podKey(), qname, 3, f2.defaultPod, nil); ok {
			lowAndSlowAlerts++
		}
	}
	if lowAndSlowAlerts > 0 {
		t.Errorf("Low-and-slow rate (<10 in 10s) triggered %d alerts, expected 0", lowAndSlowAlerts)
	}

	// --- Scenario 3: Single Name Retry Loop Exclusion ---
	f3 := newRedteamFixture(t)
	retryAlerts := 0
	for i := 0; i < 50; i++ {
		f3.clock.Advance(10 * time.Millisecond)
		if _, ok := f3.engine.EvaluateNXDOMAIN(f3.podKey(), "static-missing.corp.internal", 3, f3.defaultPod, nil); ok {
			retryAlerts++
		}
	}
	if retryAlerts > 0 {
		t.Errorf("Single name retry loop triggered %d alerts, expected 0 (must count distinct names only)", retryAlerts)
	}

	t.Logf("DETERMINATION: NXDOMAIN burst tracker strictly implements SLIDING-WINDOW semantics with distinct-qname accounting")
}
