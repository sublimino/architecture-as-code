// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"net"
	"testing"
)

// TestReportConnect_AttributedDomainOnDNSHit proves reportConnect() enriches TelemetryObservation.Domain
// when the destination IP matches an active DNSCache resolution for the pod.
func TestReportConnect_AttributedDomainOnDNSHit(t *testing.T) {
	cache := NewDNSCache()
	pod := agentPod("tenant-agents")
	m, _ := pipeline(t, pod, nil)
	m.dnsCache = cache

	destIP := net.ParseIP("198.51.100.25")
	cache.Insert(podKey(pod), []net.IP{destIP}, []uint32{300}, "api.anthropic.com", "")

	obs, ok := m.handleRecord(rawConnect(1001, destIP, 443))
	if !ok {
		t.Fatal("handleRecord returned ok=false for mapped pod")
	}

	if obs.Domain != "api.anthropic.com" {
		t.Fatalf("obs.Domain = %q, want %q", obs.Domain, "api.anthropic.com")
	}
	if obs.Target != "198.51.100.25:443" {
		t.Fatalf("obs.Target = %q, want %q", obs.Target, "198.51.100.25:443")
	}

	// Verify downstream ingest conversion carries domain label
	ingest := obs.toIngest()
	if ingest.Labels["domain"] != "api.anthropic.com" {
		t.Fatalf("toIngest().Labels[\"domain\"] = %q, want %q", ingest.Labels["domain"], "api.anthropic.com")
	}
}

// TestReportConnect_GracefulFallbackOnDNSMiss proves reportConnect() falls back gracefully
// to raw RemoteEndpoint target with empty Domain when the destination IP is unmapped in DNSCache.
func TestReportConnect_GracefulFallbackOnDNSMiss(t *testing.T) {
	cache := NewDNSCache()
	pod := agentPod("tenant-agents")
	m, _ := pipeline(t, pod, nil)
	m.dnsCache = cache

	// Direct IP connection without any preceding DNS resolution
	destIP := net.ParseIP("203.0.113.88")
	obs, ok := m.handleRecord(rawConnect(1001, destIP, 8080))
	if !ok {
		t.Fatal("handleRecord returned ok=false for direct-IP egress")
	}

	if obs.Domain != "" {
		t.Fatalf("obs.Domain = %q, want empty string on cache miss", obs.Domain)
	}
	if obs.Target != "203.0.113.88:8080" {
		t.Fatalf("obs.Target = %q, want %q", obs.Target, "203.0.113.88:8080")
	}

	// Downstream ingest conversion must NOT carry domain label when empty
	ingest := obs.toIngest()
	if _, exists := ingest.Labels["domain"]; exists {
		t.Fatalf("toIngest() emitted empty domain label: %v", ingest.Labels)
	}
}

// TestReportConnect_MultiKeyLookupFallback proves reportConnect() checks podKey, pod UID,
// and cgroupPath keys so resolutions registered under any valid identifier are resolved.
func TestReportConnect_MultiKeyLookupFallback(t *testing.T) {
	cache := NewDNSCache()
	pod := agentPod("tenant-agents")
	m, _ := pipeline(t, pod, nil)
	m.dnsCache = cache

	destIP1 := net.ParseIP("198.51.100.101")
	destIP2 := net.ParseIP("198.51.100.102")

	// 1. Keyed by pod UID
	cache.Insert(string(pod.UID), []net.IP{destIP1}, []uint32{60}, "uid-service.example.com", "")
	obs1, ok1 := m.handleRecord(rawConnect(1001, destIP1, 443))
	if !ok1 || obs1.Domain != "uid-service.example.com" {
		t.Fatalf("lookup by pod UID failed: ok=%v, domain=%q", ok1, obs1.Domain)
	}

	// 2. Keyed by cgroup path
	cgPath := "/kubepods/burstable/pod" + pipelinePodUID + "/e3b0c44298fc"
	cache.Insert(cgPath, []net.IP{destIP2}, []uint32{60}, "cg-service.example.com", "")

	obs2, ok2 := m.handleRecord(rawConnect(1001, destIP2, 443))
	if !ok2 || obs2.Domain != "cg-service.example.com" {
		t.Fatalf("lookup by cgroup path failed: ok=%v, domain=%q", ok2, obs2.Domain)
	}
}

// TestIfindexToPodMapping_PopulationAndLookup proves ifindex-to-pod registration and resolution.
func TestIfindexToPodMapping_PopulationAndLookup(t *testing.T) {
	pod := CreateTestPod("fe-agents", "agent-scanner", "scanner-uid-7777", "agent-scanner", "kusari")
	m, _ := pipeline(t, pod, nil)

	const hostIfindex = 24
	const cgPath = "/kubelet.slice/kubelet-kubepods.slice/podscanner-uid-7777.slice"

	m.SetIfindexMapping(hostIfindex, pod, cgPath)

	resolvedPod, resolvedCgPath, ok := m.LookupPodByIfindex(hostIfindex)
	if !ok {
		t.Fatalf("LookupPodByIfindex(%d) returned ok=false", hostIfindex)
	}
	if resolvedPod == nil || resolvedPod.Name != "agent-scanner" {
		t.Fatalf("resolved pod mismatch: got %v, want agent-scanner", resolvedPod)
	}
	if resolvedCgPath != cgPath {
		t.Fatalf("resolved cgroup path = %q, want %q", resolvedCgPath, cgPath)
	}

	// ResolveIfindex helper
	p, key, cgp, ok := m.ResolveIfindex(hostIfindex)
	if !ok || p == nil || key != "fe-agents/agent-scanner" || cgp != cgPath {
		t.Fatalf("ResolveIfindex(%d) = (%v, %q, %q, %v)", hostIfindex, p, key, cgp, ok)
	}

	// Unmapped ifindex returns false
	_, _, unmappedOk := m.LookupPodByIfindex(9999)
	if unmappedOk {
		t.Fatal("LookupPodByIfindex(9999) returned ok=true for unmapped interface")
	}
}

// TestIfindex_EvictionOnPodTeardown proves that when a pod is torn down, its ifindex mapping
// is evicted, ensuring a subsequent TC record for that ifindex resolves to no pod.
func TestIfindex_EvictionOnPodTeardown(t *testing.T) {
	pod := CreateTestPod("fe-agents", "agent-ephemeral", "ephemeral-uid-8888", "agent-ephemeral", "kusari")
	m, _ := pipeline(t, pod, nil)

	const ifindex = 42
	m.SetIfindexMapping(ifindex, pod, "/kubelet.slice/pod8888.slice")

	// Verify mapped initially
	if _, _, ok := m.LookupPodByIfindex(ifindex); !ok {
		t.Fatal("initial lookup failed before teardown")
	}

	// Simulate pod teardown via informer DeleteFunc / removePod
	m.removePod(pod)

	// Post-teardown resolution must return no pod
	resolvedPod, _, ok := m.LookupPodByIfindex(ifindex)
	if ok || resolvedPod != nil {
		t.Fatalf("post-teardown lookup succeeded: got pod %v; must resolve to nil/false to prevent misattribution", resolvedPod)
	}

	_, _, _, resolveOk := m.ResolveIfindex(ifindex)
	if resolveOk {
		t.Fatal("ResolveIfindex succeeded for torn-down pod")
	}
}

// TestIfindex_KernelIfindexReuse proves that when the kernel reassigns an ifindex
// to a new pod, the reverse index correctly maps to the new pod without stale misattribution.
func TestIfindex_KernelIfindexReuse(t *testing.T) {
	podOld := CreateTestPod("old-tenant", "agent-old", "uid-old-1", "agent-old", "kusari")
	podNew := CreateTestPod("new-tenant", "agent-new", "uid-new-2", "agent-new", "kusari")

	m, _ := pipeline(t, podOld, nil)

	const reusedIfindex = 55

	// 1. Old pod gets ifindex 55
	m.SetIfindexMapping(reusedIfindex, podOld, "/cgroup/old")
	p1, _, ok1 := m.LookupPodByIfindex(reusedIfindex)
	if !ok1 || p1.Name != "agent-old" {
		t.Fatalf("old pod lookup failed: %v", p1)
	}

	// 2. Old pod torn down
	m.removePod(podOld)

	// 3. New pod assigned same ifindex 55
	m.indexPod(podNew)
	m.SetIfindexMapping(reusedIfindex, podNew, "/cgroup/new")

	p2, cg2, ok2 := m.LookupPodByIfindex(reusedIfindex)
	if !ok2 {
		t.Fatal("new pod lookup failed on reused ifindex")
	}
	if p2.Name != "agent-new" || p2.Namespace != "new-tenant" {
		t.Fatalf("reused ifindex misattributed: got pod %s/%s, want new-tenant/agent-new", p2.Namespace, p2.Name)
	}
	if cg2 != "/cgroup/new" {
		t.Fatalf("cgroup path = %q, want /cgroup/new", cg2)
	}
}

// TestCanonicalAddressHelper_RepresentationConsistency proves that IPv4, IPv4-mapped IPv6,
// and standard IPv6 addresses format identically between DNSCache insertion and reportConnect lookup.
func TestCanonicalAddressHelper_RepresentationConsistency(t *testing.T) {
	cache := NewDNSCache()
	pod := agentPod("test-ns")
	m, _ := pipeline(t, pod, nil)
	m.dnsCache = cache

	// 1. IPv4 canonicalization
	ipV4 := net.ParseIP("192.0.2.50")
	cache.Insert(podKey(pod), []net.IP{ipV4}, []uint32{60}, "ipv4.example.com", "")

	// Raw IPv4 connect
	obsV4, okV4 := m.handleRecord(rawConnect(1001, ipV4, 443))
	if !okV4 || obsV4.Domain != "ipv4.example.com" {
		t.Fatalf("IPv4 representation mismatch: ok=%v, domain=%q", okV4, obsV4.Domain)
	}

	// 2. IPv4-in-IPv6 mapped address (16-byte representation of IPv4)
	ipV4InV6 := net.IP{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 50}
	obsV4Mapped, okV4Mapped := m.handleRecord(rawConnect(1001, ipV4InV6, 443))
	if !okV4Mapped || obsV4Mapped.Domain != "ipv4.example.com" {
		t.Fatalf("IPv4-in-IPv6 mapped representation mismatch: ok=%v, domain=%q", okV4Mapped, obsV4Mapped.Domain)
	}

	// 3. IPv6 standard representation
	ipV6 := net.ParseIP("2001:db8:85a3::8a2e:370:7334")
	cache.Insert(podKey(pod), []net.IP{ipV6}, []uint32{60}, "ipv6.example.com", "")

	obsV6, okV6 := m.handleRecord(rawConnect(1001, ipV6, 443))
	if !okV6 || obsV6.Domain != "ipv6.example.com" {
		t.Fatalf("IPv6 representation mismatch: ok=%v, domain=%q", okV6, obsV6.Domain)
	}
}

// TestToIngest_CarriesDomainLabel proves that TelemetryObservation.toIngest()
// produces labels["domain"] only when Domain is set.
func TestToIngest_CarriesDomainLabel(t *testing.T) {
	// 1. With Domain
	obsWithDomain := sampleObservation()
	obsWithDomain.Domain = "model.anthropic.com"
	ingest1 := obsWithDomain.toIngest()
	if ingest1.Labels["domain"] != "model.anthropic.com" {
		t.Fatalf("Labels[\"domain\"] = %q, want \"model.anthropic.com\"", ingest1.Labels["domain"])
	}

	// 2. Without Domain
	obsWithoutDomain := sampleObservation()
	obsWithoutDomain.Domain = ""
	ingest2 := obsWithoutDomain.toIngest()
	if _, exists := ingest2.Labels["domain"]; exists {
		t.Fatalf("Labels[\"domain\"] present when empty: %v", ingest2.Labels)
	}
}
