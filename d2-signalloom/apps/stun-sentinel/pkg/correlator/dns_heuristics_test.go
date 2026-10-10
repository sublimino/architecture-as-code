// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"context"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	types "k8s.io/apimachinery/pkg/types"
)

func samplePod(name, ns, uid string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			UID:       types.UID(uid),
			Labels: map[string]string{
				"tenant": "tenant-kusari",
			},
		},
	}
}

// -----------------------------------------------------------------------------
// 1. Direct IP Outbound Egress Tests (Appendix C Row 1)
// -----------------------------------------------------------------------------

func TestDirectIP_AlertOnDirectEgress(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	destIP := net.ParseIP("203.0.113.50")

	obs, ok := engine.EvaluateDirectIPEgress(podKey(pod), destIP, pod, nil)
	if !ok || obs == nil {
		t.Fatalf("expected direct IP egress alert, got ok=%v obs=%v", ok, obs)
	}

	if obs.Severity != SeverityCritical {
		t.Errorf("severity = %q, want %q", obs.Severity, SeverityCritical)
	}
	if obs.Labels["anomaly"] != AnomalyDirectIPEgress {
		t.Errorf("anomaly label = %q, want %q", obs.Labels["anomaly"], AnomalyDirectIPEgress)
	}
	if obs.Labels["dest_ip"] != "203.0.113.50" {
		t.Errorf("dest_ip label = %q, want 203.0.113.50", obs.Labels["dest_ip"])
	}
	if engine.Metrics().DirectIPEgressAlerts.Load() != 1 {
		t.Errorf("metric count = %d, want 1", engine.Metrics().DirectIPEgressAlerts.Load())
	}
}

func TestDirectIP_MustNotFireOnMultiAnswerCDN(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	// Multi-answer CDN response with 3 IP addresses
	answers := []net.IP{
		net.ParseIP("198.51.100.1"),
		net.ParseIP("198.51.100.2"),
		net.ParseIP("198.51.100.3"),
	}
	ttls := []uint32{300, 300, 300}
	cache.Insert(podID, answers, ttls, "cdn.example.com", "")

	// Connect to 2nd address
	obs2, ok2 := engine.EvaluateDirectIPEgress(podID, answers[1], pod, nil)
	if ok2 || obs2 != nil {
		t.Errorf("direct IP heuristic must not fire on 2nd address of CDN, got obs=%+v", obs2)
	}

	// Connect to 3rd address
	obs3, ok3 := engine.EvaluateDirectIPEgress(podID, answers[2], pod, nil)
	if ok3 || obs3 != nil {
		t.Errorf("direct IP heuristic must not fire on 3rd address of CDN, got obs=%+v", obs3)
	}
}

func TestDirectIP_MustNotFireOnKeepAliveUnexpired(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	destIP := net.ParseIP("198.51.100.10")
	// Insert with 5s TTL -> floored to 30s by DNSCache minTTL rule
	cache.Insert(podID, []net.IP{destIP}, []uint32{5}, "pool.example.com", "")

	// Advance time by 20s (outliving original 5s TTL, but within 30s floor)
	clk.Advance(20 * time.Second)

	obs, ok := engine.EvaluateDirectIPEgress(podID, destIP, pod, nil)
	if ok || obs != nil {
		t.Errorf("direct IP heuristic must not fire on keep-alive within unexpired floor TTL, got obs=%+v", obs)
	}
}

func TestDirectIP_IgnoresLoopbackAndUnspecified(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	if obs, ok := engine.EvaluateDirectIPEgress(podID, net.ParseIP("127.0.0.1"), pod, nil); ok || obs != nil {
		t.Errorf("must not fire on loopback IP")
	}
	if obs, ok := engine.EvaluateDirectIPEgress(podID, net.ParseIP("0.0.0.0"), pod, nil); ok || obs != nil {
		t.Errorf("must not fire on unspecified IP")
	}
}

// -----------------------------------------------------------------------------
// 2. DNS vs. TLS SNI Mismatch Tests (Appendix C Row 2)
// -----------------------------------------------------------------------------

func TestSNIMismatch_AlertOnMismatch(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	destIP := net.ParseIP("198.51.100.40")
	// Cache resolved api.evil.com -> 198.51.100.40
	cache.Insert(podID, []net.IP{destIP}, []uint32{300}, "api.evil.com", "")

	// TLS ClientHello presents login.legit.com for the same connection
	obs, ok := engine.EvaluateDNSSNIMismatch(podID, destIP, "login.legit.com", ebpf.TLS_CH_OK, pod, nil)
	if !ok || obs == nil {
		t.Fatalf("expected SNI mismatch alert, got ok=%v obs=%v", ok, obs)
	}

	if obs.Severity != SeverityCritical {
		t.Errorf("severity = %q, want %q", obs.Severity, SeverityCritical)
	}
	if obs.Labels["anomaly"] != AnomalyDNSSNIMismatch {
		t.Errorf("anomaly = %q, want %q", obs.Labels["anomaly"], AnomalyDNSSNIMismatch)
	}
	if obs.Labels["dns_domain"] != "api.evil.com" {
		t.Errorf("dns_domain = %q, want api.evil.com", obs.Labels["dns_domain"])
	}
	if obs.Labels["sni"] != "login.legit.com" {
		t.Errorf("sni = %q, want login.legit.com", obs.Labels["sni"])
	}
	if engine.Metrics().DNSSNIMismatchAlerts.Load() != 1 {
		t.Errorf("metric count = %d, want 1", engine.Metrics().DNSSNIMismatchAlerts.Load())
	}
}

func TestSNIMismatch_MustNotFireOnCNAMEAliasChain(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	destIP := net.ParseIP("198.51.100.41")
	// DNS resolved svc.example.com -> CNAME d1abc.cloudfront.net -> 198.51.100.41
	cache.Insert(podID, []net.IP{destIP}, []uint32{300}, "svc.example.com", "d1abc.cloudfront.net")

	// TLS ClientHello with alias name d1abc.cloudfront.net
	obs, ok := engine.EvaluateDNSSNIMismatch(podID, destIP, "d1abc.cloudfront.net", ebpf.TLS_CH_OK, pod, nil)
	if ok || obs != nil {
		t.Errorf("SNI mismatch heuristic must not fire on CNAME alias chain, got obs=%+v", obs)
	}

	// TLS ClientHello with original name svc.example.com
	obs2, ok2 := engine.EvaluateDNSSNIMismatch(podID, destIP, "svc.example.com", ebpf.TLS_CH_OK, pod, nil)
	if ok2 || obs2 != nil {
		t.Errorf("SNI mismatch heuristic must not fire on original CNAME owner, got obs=%+v", obs2)
	}
}

func TestSNIMismatch_MustNotFireOnSharedIPVirtualHost(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	destIP := net.ParseIP("198.51.100.42")
	// DNS resolved vhost1.example.com -> 198.51.100.42
	cache.Insert(podID, []net.IP{destIP}, []uint32{300}, "vhost1.example.com", "")
	// Register vhost2 as virtual host sharing the same IP
	engine.RegisterVirtualHost(podID, destIP, "vhost2.example.com")

	obs, ok := engine.EvaluateDNSSNIMismatch(podID, destIP, "vhost2.example.com", ebpf.TLS_CH_OK, pod, nil)
	if ok || obs != nil {
		t.Errorf("SNI mismatch heuristic must not fire on shared-IP virtual host, got obs=%+v", obs)
	}
}

func TestSNIMismatch_MustNotFireOnNonOKParseStatus(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsDNSCache(cache), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	destIP := net.ParseIP("198.51.100.43")
	cache.Insert(podID, []net.IP{destIP}, []uint32{300}, "site.example.com", "")

	nonOKStatuses := []struct {
		name   string
		status uint8
	}{
		{"TLS_CH_SEGMENTED", ebpf.TLS_CH_SEGMENTED},
		{"TLS_CH_NO_SNI", ebpf.TLS_CH_NO_SNI},
		{"TLS_CH_ENCRYPTED", ebpf.TLS_CH_ENCRYPTED},
		{"TLS_CH_MALFORMED", ebpf.TLS_CH_MALFORMED},
	}

	for _, tc := range nonOKStatuses {
		t.Run(tc.name, func(t *testing.T) {
			obs, ok := engine.EvaluateDNSSNIMismatch(podID, destIP, "other.example.com", tc.status, pod, nil)
			if ok || obs != nil {
				t.Errorf("SNI mismatch heuristic must not fire when parse_status is %s (%d), got obs=%+v", tc.name, tc.status, obs)
			}
		})
	}
}

// -----------------------------------------------------------------------------
// 3. Non-Cluster DNS Resolver Tests (Appendix C Row 3)
// -----------------------------------------------------------------------------

func TestNonClusterResolver_AlertOnUnauthorizedResolver(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	rc := NewResolverCache(WithResolverCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsResolverCache(rc), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	rogueResolver := net.ParseIP("8.8.8.8")

	obs, ok := engine.EvaluateNonClusterResolver(podKey(pod), 1234, rogueResolver, pod, nil)
	if !ok || obs == nil {
		t.Fatalf("expected non-cluster resolver alert, got ok=%v obs=%v", ok, obs)
	}

	if obs.Severity != SeverityWarn {
		t.Errorf("severity = %q, want %q", obs.Severity, SeverityWarn)
	}
	if obs.Labels["anomaly"] != AnomalyNonClusterResolver {
		t.Errorf("anomaly = %q, want %q", obs.Labels["anomaly"], AnomalyNonClusterResolver)
	}
	if obs.Labels["resolver_addr"] != "8.8.8.8" {
		t.Errorf("resolver_addr = %q, want 8.8.8.8", obs.Labels["resolver_addr"])
	}
	if engine.Metrics().NonClusterResolverAlerts.Load() != 1 {
		t.Errorf("metric count = %d, want 1", engine.Metrics().NonClusterResolverAlerts.Load())
	}
}

func TestNonClusterResolver_MustNotFireOnCustomClusterDNSServiceIP(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))

	// Custom cluster DNS IP discovered via API
	customClusterDNS := "10.43.0.10"
	mockLookup := func(ctx context.Context, namespace, name string) (*corev1.Service, error) {
		if namespace == "kube-system" && (name == "kube-dns" || name == "coredns") {
			return &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
				Spec: corev1.ServiceSpec{
					ClusterIP: customClusterDNS,
				},
			}, nil
		}
		return nil, fmt.Errorf("service not found")
	}

	rc := NewResolverCache(
		WithResolverCacheClock(clk),
		WithResolverCacheServiceLookup(mockLookup),
	)
	_ = rc.DiscoverClusterDNSFromAPI(context.Background())

	engine := NewDNSHeuristicsEngine(WithHeuristicsResolverCache(rc), WithHeuristicsClock(clk))
	pod := samplePod("agent-1", "default", "pod-uid-1")

	// Query to the discovered cluster DNS Service IP
	obs, ok := engine.EvaluateNonClusterResolver(podKey(pod), 1234, net.ParseIP(customClusterDNS), pod, nil)
	if ok || obs != nil {
		t.Errorf("non-cluster resolver heuristic must not fire on discovered cluster DNS Service IP, got obs=%+v", obs)
	}
}

func TestNonClusterResolver_MustNotFireOnPodDNSConfigOverride(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))

	// Pod with custom dnsConfig nameserver
	customNS := net.ParseIP("10.200.0.53")
	mockReader := func(pid uint32) ([]net.IP, error) {
		return []net.IP{customNS}, nil
	}

	rc := NewResolverCache(
		WithResolverCacheClock(clk),
		WithResolverCacheResolvReader(mockReader),
	)

	engine := NewDNSHeuristicsEngine(WithHeuristicsResolverCache(rc), WithHeuristicsClock(clk))
	pod := samplePod("agent-1", "default", "pod-uid-1")

	obs, ok := engine.EvaluateNonClusterResolver(podKey(pod), 5432, customNS, pod, nil)
	if ok || obs != nil {
		t.Errorf("non-cluster resolver heuristic must not fire on pod dnsConfig override nameserver, got obs=%+v", obs)
	}
}

func TestNonClusterResolver_MustNotFireOnNodeLocalDNS(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	rc := NewResolverCache(WithResolverCacheClock(clk))
	engine := NewDNSHeuristicsEngine(WithHeuristicsResolverCache(rc), WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	nodeLocalIP := net.ParseIP(DefaultNodeLocalDNSIP)

	obs, ok := engine.EvaluateNonClusterResolver(podKey(pod), 1234, nodeLocalIP, pod, nil)
	if ok || obs != nil {
		t.Errorf("non-cluster resolver heuristic must not fire on NodeLocal DNSCache IP (%s), got obs=%+v", DefaultNodeLocalDNSIP, obs)
	}
}

// -----------------------------------------------------------------------------
// 4. NXDOMAIN Burst / DGA Tests (Appendix C Row 4)
// -----------------------------------------------------------------------------

func TestNXDOMAIN_AlertOnDGAExcess(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	// Send 10 distinct NXDOMAINs -> threshold is 10, so <= 10 does not fire
	for i := 1; i <= 10; i++ {
		qname := fmt.Sprintf("dga-%03d.evil.domain", i)
		obs, ok := engine.EvaluateNXDOMAIN(podID, qname, 3, pod, nil)
		if ok || obs != nil {
			t.Fatalf("expected no alert at %d distinct NXDOMAINs, got obs=%+v", i, obs)
		}
	}

	// 11th distinct NXDOMAIN within 10s window -> fires alert
	obs11, ok11 := engine.EvaluateNXDOMAIN(podID, "dga-011.evil.domain", 3, pod, nil)
	if !ok11 || obs11 == nil {
		t.Fatalf("expected NXDOMAIN burst alert on 11th distinct qname, got ok=%v obs=%v", ok11, obs11)
	}

	if obs11.Severity != SeverityWarn {
		t.Errorf("severity = %q, want %q", obs11.Severity, SeverityWarn)
	}
	if obs11.Labels["anomaly"] != AnomalyNXDOMAINBurst {
		t.Errorf("anomaly = %q, want %q", obs11.Labels["anomaly"], AnomalyNXDOMAINBurst)
	}
	if obs11.Labels["distinct_qnames"] != "11" {
		t.Errorf("distinct_qnames = %q, want 11", obs11.Labels["distinct_qnames"])
	}
	if engine.Metrics().NXDOMAINBurstAlerts.Load() != 1 {
		t.Errorf("metric count = %d, want 1", engine.Metrics().NXDOMAINBurstAlerts.Load())
	}
}

func TestNXDOMAIN_MustNotFireOnRetryLoop(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	// Single unresolvable domain retried 50 times
	singleUnresolvable := "unresolvable-service.internal"
	for i := 0; i < 50; i++ {
		obs, ok := engine.EvaluateNXDOMAIN(podID, singleUnresolvable, 3, pod, nil)
		if ok || obs != nil {
			t.Fatalf("NXDOMAIN heuristic must not fire on retry loop for same name (iteration %d), got obs=%+v", i, obs)
		}
	}
}

func TestNXDOMAIN_MustNotFireUnderThreshold(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	// 5 distinct names (under threshold of 10)
	for i := 1; i <= 5; i++ {
		qname := fmt.Sprintf("typo-%d.example.com", i)
		obs, ok := engine.EvaluateNXDOMAIN(podID, qname, 3, pod, nil)
		if ok || obs != nil {
			t.Errorf("must not fire when under threshold, got obs=%+v", obs)
		}
	}
}

func TestNXDOMAIN_SlidingWindowPurgesOldEntries(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))

	pod := samplePod("agent-1", "default", "pod-uid-1")
	podID := podKey(pod)

	// 6 distinct queries at T=0
	for i := 1; i <= 6; i++ {
		_, _ = engine.EvaluateNXDOMAIN(podID, fmt.Sprintf("old-%d.example.com", i), 3, pod, nil)
	}

	// Advance time by 15s (past the 10s window)
	clk.Advance(15 * time.Second)

	// 6 new distinct queries at T=15s (total across all time = 12, but within window = 6)
	for i := 1; i <= 6; i++ {
		obs, ok := engine.EvaluateNXDOMAIN(podID, fmt.Sprintf("new-%d.example.com", i), 3, pod, nil)
		if ok || obs != nil {
			t.Errorf("must not fire after older entries have aged out of window, got obs=%+v", obs)
		}
	}
}

// -----------------------------------------------------------------------------
// 5. Unparsed Capture Tests (Appendix C Row 5)
// -----------------------------------------------------------------------------

func TestUnparsedCapture_AlertOnDNSParseErrors(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))
	pod := samplePod("agent-1", "default", "pod-uid-1")

	dnsCases := []struct {
		status    uint8
		statusStr string
		counterFn func() uint64
	}{
		{ebpf.DNS_PARSE_TRUNCATED, "DNS_PARSE_TRUNCATED", engine.Metrics().DNSParseTruncated.Load},
		{ebpf.DNS_PARSE_NAME_TOO_LONG, "DNS_PARSE_NAME_TOO_LONG", engine.Metrics().DNSParseNameTooLong.Load},
		{ebpf.DNS_PARSE_COMPRESSED, "DNS_PARSE_COMPRESSED", engine.Metrics().DNSParseCompressed.Load},
		{ebpf.DNS_PARSE_UNSUPPORTED, "DNS_PARSE_UNSUPPORTED", engine.Metrics().DNSParseUnsupported.Load},
	}

	for _, tc := range dnsCases {
		t.Run(tc.statusStr, func(t *testing.T) {
			before := tc.counterFn()
			obs, ok := engine.EvaluateUnparsedCapture("dns", tc.status, "", 0, pod, nil)
			if !ok || obs == nil {
				t.Fatalf("expected unparsed capture alert for DNS status %s", tc.statusStr)
			}
			if obs.Severity != SeverityWarn {
				t.Errorf("severity = %q, want %q", obs.Severity, SeverityWarn)
			}
			if obs.Labels["anomaly"] != AnomalyUnparsedCapture {
				t.Errorf("anomaly = %q, want %q", obs.Labels["anomaly"], AnomalyUnparsedCapture)
			}
			if obs.Labels["parse_status"] != tc.statusStr {
				t.Errorf("parse_status = %q, want %q", obs.Labels["parse_status"], tc.statusStr)
			}
			if tc.counterFn() != before+1 {
				t.Errorf("metric counter did not increment for %s", tc.statusStr)
			}
		})
	}
}

func TestUnparsedCapture_AlertOnTLSClientHelloErrors(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))
	pod := samplePod("agent-1", "default", "pod-uid-1")

	tlsCases := []struct {
		status    uint8
		statusStr string
		counterFn func() uint64
	}{
		{ebpf.TLS_CH_SEGMENTED, "TLS_CH_SEGMENTED", engine.Metrics().TLSCHSegmented.Load},
		{ebpf.TLS_CH_MALFORMED, "TLS_CH_MALFORMED", engine.Metrics().TLSCHMalformed.Load},
	}

	for _, tc := range tlsCases {
		t.Run(tc.statusStr, func(t *testing.T) {
			before := tc.counterFn()
			obs, ok := engine.EvaluateUnparsedCapture("tls", tc.status, "", 0, pod, nil)
			if !ok || obs == nil {
				t.Fatalf("expected unparsed capture alert for TLS status %s", tc.statusStr)
			}
			if obs.Severity != SeverityWarn {
				t.Errorf("severity = %q, want %q", obs.Severity, SeverityWarn)
			}
			if obs.Labels["parse_status"] != tc.statusStr {
				t.Errorf("parse_status = %q, want %q", obs.Labels["parse_status"], tc.statusStr)
			}
			if tc.counterFn() != before+1 {
				t.Errorf("metric counter did not increment for %s", tc.statusStr)
			}
		})
	}
}

func TestUnparsedCapture_AlertOnRingbufferDrops(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))
	pod := samplePod("agent-1", "default", "pod-uid-1")

	reason := "dns_ringbuf_overflow"
	obs, ok := engine.EvaluateUnparsedCapture("dns", ebpf.DNS_PARSE_OK, reason, 7, pod, nil)
	if !ok || obs == nil {
		t.Fatalf("expected unparsed capture alert on ringbuffer drop")
	}

	if obs.Labels["drop_reason"] != reason {
		t.Errorf("drop_reason = %q, want %q", obs.Labels["drop_reason"], reason)
	}
	if obs.Labels["drop_count"] != "7" {
		t.Errorf("drop_count = %q, want 7", obs.Labels["drop_count"])
	}
	if engine.Metrics().GetDropReasonCount(reason) != 1 {
		t.Errorf("drop reason metric = %d, want 1", engine.Metrics().GetDropReasonCount(reason))
	}
}

func TestUnparsedCapture_MustNotFireOnCleanCapture(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))
	pod := samplePod("agent-1", "default", "pod-uid-1")

	// Clean DNS
	if obs, ok := engine.EvaluateUnparsedCapture("dns", ebpf.DNS_PARSE_OK, "", 0, pod, nil); ok || obs != nil {
		t.Errorf("unparsed capture heuristic must not fire on clean DNS parse")
	}

	// Clean TLS
	if obs, ok := engine.EvaluateUnparsedCapture("tls", ebpf.TLS_CH_OK, "", 0, pod, nil); ok || obs != nil {
		t.Errorf("unparsed capture heuristic must not fire on clean TLS handshake")
	}
}

// -----------------------------------------------------------------------------
// 6. Observation and Ingest Wire Contract Tests
// -----------------------------------------------------------------------------

func TestHeuristicsCarryAnomalyLabelsThroughObservation(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	engine := NewDNSHeuristicsEngine(WithHeuristicsClock(clk))
	pod := samplePod("agent-kusari-7d9f", "fe-signalloom-agents", "pod-uid-kusari")

	obs, ok := engine.EvaluateDirectIPEgress(podKey(pod), net.ParseIP("203.0.113.99"), pod, nil)
	if !ok || obs == nil {
		t.Fatal("expected direct IP egress alert")
	}

	if obs.Labels["anomaly"] != AnomalyDirectIPEgress {
		t.Fatalf("expected anomaly label %q, got %q", AnomalyDirectIPEgress, obs.Labels["anomaly"])
	}

	// Verify standard fields are populated
	if obs.Severity != SeverityCritical {
		t.Errorf("severity = %q, want %q", obs.Severity, SeverityCritical)
	}
	if obs.PodName != "agent-kusari-7d9f" {
		t.Errorf("pod_name = %q, want agent-kusari-7d9f", obs.PodName)
	}
	if obs.Namespace != "fe-signalloom-agents" {
		t.Errorf("namespace = %q, want fe-signalloom-agents", obs.Namespace)
	}
}

// -----------------------------------------------------------------------------
// 7. Test Name Aliases Matching Required Filter Patterns
// -----------------------------------------------------------------------------

func TestHeuristicDirectIP(t *testing.T) {
	t.Run("Alert", TestDirectIP_AlertOnDirectEgress)
	t.Run("CDNExclusion", TestDirectIP_MustNotFireOnMultiAnswerCDN)
	t.Run("KeepAliveExclusion", TestDirectIP_MustNotFireOnKeepAliveUnexpired)
}

func TestHeuristicSNIMismatch(t *testing.T) {
	t.Run("Alert", TestSNIMismatch_AlertOnMismatch)
	t.Run("CNAMEExclusion", TestSNIMismatch_MustNotFireOnCNAMEAliasChain)
	t.Run("VHostExclusion", TestSNIMismatch_MustNotFireOnSharedIPVirtualHost)
	t.Run("ParseStatusExclusion", TestSNIMismatch_MustNotFireOnNonOKParseStatus)
}

func TestHeuristicNonClusterResolver(t *testing.T) {
	t.Run("Alert", TestNonClusterResolver_AlertOnUnauthorizedResolver)
	t.Run("CustomClusterDNSExclusion", TestNonClusterResolver_MustNotFireOnCustomClusterDNSServiceIP)
	t.Run("PodDNSConfigExclusion", TestNonClusterResolver_MustNotFireOnPodDNSConfigOverride)
	t.Run("NodeLocalExclusion", TestNonClusterResolver_MustNotFireOnNodeLocalDNS)
}

func TestHeuristicNXDOMAIN(t *testing.T) {
	t.Run("Alert", TestNXDOMAIN_AlertOnDGAExcess)
	t.Run("RetryLoopExclusion", TestNXDOMAIN_MustNotFireOnRetryLoop)
	t.Run("UnderThresholdExclusion", TestNXDOMAIN_MustNotFireUnderThreshold)
}

func TestHeuristicUnparsedCapture(t *testing.T) {
	t.Run("DNSAlert", TestUnparsedCapture_AlertOnDNSParseErrors)
	t.Run("TLSAlert", TestUnparsedCapture_AlertOnTLSClientHelloErrors)
	t.Run("DropAlert", TestUnparsedCapture_AlertOnRingbufferDrops)
	t.Run("CleanExclusion", TestUnparsedCapture_MustNotFireOnCleanCapture)
}
