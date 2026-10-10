// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"fmt"
	"net"
	"os"
	"regexp"
	"sync"
	"testing"
	"time"
)

func TestDNSCache_MultiAnswerIndexing(t *testing.T) {
	cache := NewDNSCache()
	pod := "test-pod-ns-1/app-container-1"

	// 4 answer addresses (multi-answer DNS response, e.g. CDN or round-robin pool)
	answers := []net.IP{
		net.ParseIP("198.51.100.1"),
		net.ParseIP("198.51.100.2"),
		net.ParseIP("198.51.100.3"),
		net.ParseIP("2001:db8::1"),
	}
	ttls := []uint32{60, 120, 180, 240}
	qname := "api.example.com"

	cache.Insert(pod, answers, ttls, qname, "")

	// All 4 answers must be retrievable, not just the first one
	for i, ip := range answers {
		got, ok := cache.Lookup(pod, ip.String())
		if !ok {
			t.Fatalf("Lookup(%q, %q) returned not found; every answer address must be indexed", pod, ip.String())
		}
		if got != "api.example.com" {
			t.Fatalf("Lookup(%q, %q) = %q, want %q", pod, ip.String(), got, "api.example.com")
		}

		// Also test LookupIP
		gotIP, okIP := cache.LookupIP(pod, ip)
		if !okIP || gotIP != "api.example.com" {
			t.Fatalf("LookupIP(%q, %v) = (%q, %v), want (api.example.com, true)", pod, ip, gotIP, okIP)
		}

		entry, okEntry := cache.LookupEntry(pod, ip.String())
		if !okEntry || entry.CanonicalName != "api.example.com" {
			t.Fatalf("LookupEntry(%q, %q) = (%+v, %v), want canonical api.example.com", pod, ip.String(), entry, okEntry)
		}
		_ = i
	}

	// Verify tenant isolation: different pod must not hit
	otherPod := "other-pod-ns-2/foreign-container-2"
	if got, ok := cache.Lookup(otherPod, answers[0].String()); ok {
		t.Fatalf("Lookup for foreign pod %q returned %q, want not found (tenant isolation breach)", otherPod, got)
	}

	stats := cache.Stats()
	if stats.Inserted != 4 {
		t.Errorf("Stats().Inserted = %d, want 4", stats.Inserted)
	}
	if stats.Lookups < 8 {
		t.Errorf("Stats().Lookups = %d, want >= 8", stats.Lookups)
	}
	if stats.Hits < 8 {
		t.Errorf("Stats().Hits = %d, want >= 8", stats.Hits)
	}
}

func TestDNSCache_CNAMEChainResolution(t *testing.T) {
	cache := NewDNSCache()
	pod := "test-ns/my-pod"

	// 1. Insert api.example.com -> CNAME cdn.example.net with IP 192.0.2.1
	cache.Insert(pod, []net.IP{net.ParseIP("192.0.2.1")}, []uint32{60}, "api.example.com", "cdn.example.net")

	// 2. Insert cdn.example.net -> CNAME edge.upstream.org with IP 192.0.2.2
	cache.Insert(pod, []net.IP{net.ParseIP("192.0.2.2")}, []uint32{120}, "cdn.example.net", "edge.upstream.org")

	// Both IPs should resolve to the final canonical domain
	got1, ok1 := cache.Lookup(pod, "192.0.2.1")
	if !ok1 || got1 != "edge.upstream.org" {
		t.Errorf("Lookup(192.0.2.1) = (%q, %v), want (edge.upstream.org, true)", got1, ok1)
	}

	got2, ok2 := cache.Lookup(pod, "192.0.2.2")
	if !ok2 || got2 != "edge.upstream.org" {
		t.Errorf("Lookup(192.0.2.2) = (%q, %v), want (edge.upstream.org, true)", got2, ok2)
	}

	// Test IsAlias
	if !cache.IsAlias(pod, "api.example.com", "edge.upstream.org") {
		t.Errorf("IsAlias(api.example.com, edge.upstream.org) = false, want true")
	}
	if !cache.IsAlias(pod, "api.example.com", "cdn.example.net") {
		t.Errorf("IsAlias(api.example.com, cdn.example.net) = false, want true")
	}
	if !cache.IsAlias(pod, "cdn.example.net", "edge.upstream.org") {
		t.Errorf("IsAlias(cdn.example.net, edge.upstream.org) = false, want true")
	}
	if cache.IsAlias(pod, "api.example.com", "unrelated-service.net") {
		t.Errorf("IsAlias(api.example.com, unrelated-service.net) = true, want false")
	}

	// Test CanonicalName
	if canon := cache.CanonicalName(pod, "api.example.com"); canon != "edge.upstream.org" {
		t.Errorf("CanonicalName(api.example.com) = %q, want edge.upstream.org", canon)
	}
	if canon := cache.CanonicalName(pod, "cdn.example.net"); canon != "edge.upstream.org" {
		t.Errorf("CanonicalName(cdn.example.net) = %q, want edge.upstream.org", canon)
	}
}

func TestDNSCache_TTLBoundsAndExpiry(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	cache := NewDNSCache(WithDNSCacheClock(clk))
	pod := "test-ns/ttl-pod"

	// Record A: TTL = 5s (floored to 30s)
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.0.1")}, []uint32{5}, "short-ttl.example.com", "")

	// Record B: TTL = 0s (floored to 30s)
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.0.2")}, []uint32{0}, "zero-ttl.example.com", "")

	// Record C: TTL = 7200s (ceiled to 3600s)
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.0.3")}, []uint32{7200}, "long-ttl.example.com", "")

	// At T+0s: all three should be present
	for _, ip := range []string{"10.0.0.1", "10.0.0.2", "10.0.0.3"} {
		if _, ok := cache.Lookup(pod, ip); !ok {
			t.Fatalf("Lookup(%s) at T+0s returned not found", ip)
		}
	}

	// At T+29s: floored records (30s) must STILL be present
	clk.Advance(29 * time.Second)
	if _, ok := cache.Lookup(pod, "10.0.0.1"); !ok {
		t.Errorf("10.0.0.1 (floored 30s TTL) expired early at T+29s")
	}
	if _, ok := cache.Lookup(pod, "10.0.0.2"); !ok {
		t.Errorf("10.0.0.2 (0s floored to 30s TTL) expired early at T+29s")
	}
	if _, ok := cache.Lookup(pod, "10.0.0.3"); !ok {
		t.Errorf("10.0.0.3 (long TTL) expired at T+29s")
	}

	// At T+31s: floored records (30s) must now be expired
	clk.Advance(2 * time.Second)
	if _, ok := cache.Lookup(pod, "10.0.0.1"); ok {
		t.Errorf("10.0.0.1 should have expired at T+31s (TTL floored at 30s)")
	}
	if _, ok := cache.Lookup(pod, "10.0.0.2"); ok {
		t.Errorf("10.0.0.2 should have expired at T+31s (TTL floored at 30s)")
	}
	// Long record must still be alive (3600s ceiling)
	if _, ok := cache.Lookup(pod, "10.0.0.3"); !ok {
		t.Errorf("10.0.0.3 should still be alive at T+31s")
	}

	// At T+3599s: long record still alive
	clk.Advance(3568 * time.Second) // total 3599s
	if _, ok := cache.Lookup(pod, "10.0.0.3"); !ok {
		t.Errorf("10.0.0.3 should still be alive at T+3599s")
	}

	// At T+3601s: long record ceiled at 3600s must be expired
	clk.Advance(2 * time.Second) // total 3601s
	if _, ok := cache.Lookup(pod, "10.0.0.3"); ok {
		t.Errorf("10.0.0.3 should have expired at T+3601s (TTL ceiled at 3600s)")
	}
}

func TestDNSCache_LRUEvictionAndCounters(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	// Single shard with capacity 2
	cache := NewDNSCache(
		WithDNSCacheClock(clk),
		WithDNSCacheShards(1),
		WithDNSCacheCapacity(2),
	)
	pod := "test-ns/eviction-pod"

	// 1. Insert 2 entries with long TTL (300s)
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.1.1")}, []uint32{300}, "entry1.example.com", "")
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.1.2")}, []uint32{300}, "entry2.example.com", "")

	stats := cache.Stats()
	if stats.Evicted != 0 || stats.EvictedUnexpired != 0 {
		t.Fatalf("Stats after 2 inserts: evicted=%d, evictedUnexpired=%d, want 0, 0", stats.Evicted, stats.EvictedUnexpired)
	}

	// 2. Insert 3rd entry (long TTL) -> forces eviction of entry1 (which is unexpired)
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.1.3")}, []uint32{300}, "entry3.example.com", "")

	stats = cache.Stats()
	if stats.Evicted != 1 {
		t.Errorf("Stats().Evicted = %d, want 1", stats.Evicted)
	}
	if stats.EvictedUnexpired != 1 {
		t.Errorf("Stats().EvictedUnexpired = %d, want 1 (entry1 was unexpired when evicted)", stats.EvictedUnexpired)
	}

	// entry1 should no longer be found
	if _, ok := cache.Lookup(pod, "10.0.1.1"); ok {
		t.Errorf("Lookup(10.0.1.1) found, want evicted")
	}
	// entry2 and entry3 should be found
	if _, ok := cache.Lookup(pod, "10.0.1.2"); !ok {
		t.Errorf("Lookup(10.0.1.2) not found, want present")
	}
	if _, ok := cache.Lookup(pod, "10.0.1.3"); !ok {
		t.Errorf("Lookup(10.0.1.3) not found, want present")
	}

	// 3. Now insert 4th entry with short TTL (30s floor)
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.1.4")}, []uint32{30}, "entry4.example.com", "")
	// This evicts entry2 (which was unexpired at this point)
	stats = cache.Stats()
	if stats.Evicted != 2 || stats.EvictedUnexpired != 2 {
		t.Errorf("Stats after entry4: evicted=%d, evictedUnexpired=%d, want 2, 2", stats.Evicted, stats.EvictedUnexpired)
	}

	// 4. Advance clock by 35s so entry4 expires
	clk.Advance(35 * time.Second)

	// 5. Insert 5th entry -> forces eviction of entry3 (which was at LRU tail) or expired entry
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.1.5")}, []uint32{300}, "entry5.example.com", "")

	stats = cache.Stats()
	if stats.Evicted != 3 {
		t.Errorf("Stats().Evicted = %d, want 3", stats.Evicted)
	}
}

func TestDNSCache_ExpiredEvictionDoesNotCountAsUnexpired(t *testing.T) {
	clk := newMockClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC))
	// Single shard with capacity 1
	cache := NewDNSCache(
		WithDNSCacheClock(clk),
		WithDNSCacheShards(1),
		WithDNSCacheCapacity(1),
	)
	pod := "test-ns/eviction-pod-2"

	// Insert entry with 30s TTL
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.2.1")}, []uint32{30}, "first.example.com", "")

	// Advance clock by 35s so first entry is now expired
	clk.Advance(35 * time.Second)

	// Insert second entry -> forces eviction of expired first entry
	cache.Insert(pod, []net.IP{net.ParseIP("10.0.2.2")}, []uint32{300}, "second.example.com", "")

	stats := cache.Stats()
	if stats.Evicted != 1 {
		t.Errorf("Stats().Evicted = %d, want 1", stats.Evicted)
	}
	if stats.EvictedUnexpired != 0 {
		t.Errorf("Stats().EvictedUnexpired = %d, want 0 (evicted entry was already expired!)", stats.EvictedUnexpired)
	}
}

func TestDNSCache_ConcurrentReadWrite(t *testing.T) {
	cache := NewDNSCache(WithDNSCacheShards(16))
	const numGoroutines = 32
	const opsPerGoroutine = 500

	var wg sync.WaitGroup
	wg.Add(numGoroutines)

	for g := 0; g < numGoroutines; g++ {
		go func(gid int) {
			defer wg.Done()
			pod := fmt.Sprintf("pod-ns-%d/app-%d", gid%8, gid%4)
			for i := 0; i < opsPerGoroutine; i++ {
				ip := net.ParseIP(fmt.Sprintf("10.%d.%d.%d", (gid+i)%250, (i/250)%250, i%250))
				domain := fmt.Sprintf("service-%d.example.com", i%20)
				cname := ""
				if i%3 == 0 {
					cname = fmt.Sprintf("cdn-%d.upstream.net", i%10)
				}

				// Concurrent Insert
				cache.Insert(pod, []net.IP{ip}, []uint32{60}, domain, cname)

				// Concurrent Lookup
				cache.Lookup(pod, ip.String())
				cache.LookupIP(pod, ip)
				cache.IsAlias(pod, domain, cname)
			}
		}(g)
	}

	wg.Wait()

	stats := cache.Stats()
	if stats.Inserted != uint64(numGoroutines*opsPerGoroutine) {
		t.Errorf("Stats().Inserted = %d, want %d", stats.Inserted, numGoroutines*opsPerGoroutine)
	}
	if stats.Lookups < uint64(numGoroutines*opsPerGoroutine*2) {
		t.Errorf("Stats().Lookups = %d, want >= %d", stats.Lookups, numGoroutines*opsPerGoroutine*2)
	}
}

func TestDNSCache_NoSingleAnswerAntiPattern(t *testing.T) {
	// Guard against single-answer indexing anti-pattern
	content, err := os.ReadFile("dns_cache.go")
	if err != nil {
		t.Fatalf("Failed to read dns_cache.go: %v", err)
	}

	re := regexp.MustCompile(`answers\[0\]|Answers\[0\]`)
	if re.Match(content) {
		t.Fatalf("dns_cache.go contains forbidden single-answer index pattern (answers[0])")
	}
}

func TestDNSCache_WithSentinelProbeManagerOption(t *testing.T) {
	cache := NewDNSCache()
	mgr := NewSentinelProbeManager(nil, "http://ingest.invalid", nil, WithDNSCache(cache))
	if mgr.dnsCache != cache {
		t.Fatalf("SentinelProbeManager.dnsCache not set by WithDNSCache option")
	}
}

func TestDNSCache_CorrelationRateFixture(t *testing.T) {
	cache := NewDNSCache()
	const numPods = 10
	const numResolutionsPerPod = 10

	// Fixture set of DNS resolutions
	type connectTarget struct {
		podOrCgroup string
		destIP      string
		expectMatch bool
	}

	var connects []connectTarget

	for p := 0; p < numPods; p++ {
		pod := fmt.Sprintf("tenant-ns-%d/worker-pod-%d", p, p)
		for r := 0; r < numResolutionsPerPod; r++ {
			qname := fmt.Sprintf("api-%d.tenant-%d.internal", r, p)
			answers := []net.IP{
				net.ParseIP(fmt.Sprintf("10.%d.%d.1", p, r)),
				net.ParseIP(fmt.Sprintf("10.%d.%d.2", p, r)),
				net.ParseIP(fmt.Sprintf("10.%d.%d.3", p, r)),
				net.ParseIP(fmt.Sprintf("10.%d.%d.4", p, r)),
			}
			ttls := []uint32{60, 60, 60, 60}
			cache.Insert(pod, answers, ttls, qname, "")

			// Simulate connects to all 4 resolved addresses (should all correlate)
			for _, ip := range answers {
				connects = append(connects, connectTarget{
					podOrCgroup: pod,
					destIP:      ip.String(),
					expectMatch: true,
				})
			}
		}

		// Inject 2 direct-IP egress connections (unresolved IPs)
		connects = append(connects, connectTarget{
			podOrCgroup: pod,
			destIP:      fmt.Sprintf("203.0.113.%d", p+1),
			expectMatch: false,
		})
		connects = append(connects, connectTarget{
			podOrCgroup: pod,
			destIP:      fmt.Sprintf("198.51.100.%d", p+1),
			expectMatch: false,
		})
	}

	// Evaluate correlation rate
	totalConnects := len(connects)
	correlated := 0
	expectedCorrelated := 0

	for _, conn := range connects {
		if conn.expectMatch {
			expectedCorrelated++
		}
		domain, found := cache.Lookup(conn.podOrCgroup, conn.destIP)
		if found && domain != "" {
			correlated++
		}
	}

	rate := float64(correlated) / float64(totalConnects) * 100.0
	t.Logf("DNS-preceded egress correlation fixture results: %d/%d correlated (%.2f%%)", correlated, totalConnects, rate)

	if correlated != expectedCorrelated {
		t.Fatalf("Correlated = %d, want %d", correlated, expectedCorrelated)
	}
}

func BenchmarkDNSCache_Lookup(b *testing.B) {
	cache := NewDNSCache()
	pod := "test-pod-ns/app-container"
	ip := net.ParseIP("192.0.2.1")
	cache.Insert(pod, []net.IP{ip}, []uint32{300}, "benchmark.example.com", "")
	ipStr := ip.String()

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		domain, ok := cache.Lookup(pod, ipStr)
		if !ok || domain == "" {
			b.Fatal("lookup failed")
		}
	}
}

func BenchmarkDNSCache_Insert(b *testing.B) {
	cache := NewDNSCache()
	pod := "test-pod-ns/app-container"
	answers := []net.IP{
		net.ParseIP("192.0.2.1"),
		net.ParseIP("192.0.2.2"),
		net.ParseIP("192.0.2.3"),
		net.ParseIP("192.0.2.4"),
	}
	ttls := []uint32{60, 60, 60, 60}

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		cache.Insert(pod, answers, ttls, "api.example.com", "cdn.example.net")
	}
}

func BenchmarkDNSCache_ParallelLookup(b *testing.B) {
	cache := NewDNSCache(WithDNSCacheShards(16))
	const numPods = 16
	type queryTarget struct {
		pod string
		ip  string
	}
	var targets []queryTarget
	for p := 0; p < numPods; p++ {
		pod := fmt.Sprintf("pod-%d", p)
		for i := 0; i < 10; i++ {
			ipStr := fmt.Sprintf("10.%d.0.%d", p, i)
			ip := net.ParseIP(ipStr)
			cache.Insert(pod, []net.IP{ip}, []uint32{300}, fmt.Sprintf("app-%d.internal", i), "")
			targets = append(targets, queryTarget{pod: pod, ip: ipStr})
		}
	}

	b.ResetTimer()
	b.ReportAllocs()

	b.RunParallel(func(pb *testing.PB) {
		var i int
		n := len(targets)
		for pb.Next() {
			t := targets[i%n]
			i++
			cache.Lookup(t.pod, t.ip)
		}
	})
}
