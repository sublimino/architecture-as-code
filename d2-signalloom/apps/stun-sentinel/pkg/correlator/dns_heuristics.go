// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bufio"
	"container/list"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// Anomaly type identifiers matching Appendix C of the SLWD specification.
const (
	AnomalyDirectIPEgress     = "direct_ip_egress"
	AnomalyDNSSNIMismatch     = "dns_sni_mismatch"
	AnomalyNonClusterResolver = "non_cluster_resolver"
	AnomalyNXDOMAINBurst      = "nxdomain_burst"
	AnomalyUnparsedCapture    = "unparsed_capture"

	// DefaultNXDOMAINBurstThreshold is the maximum distinct unresolvable qnames before DGA alert.
	DefaultNXDOMAINBurstThreshold = 10
	// DefaultNXDOMAINBurstWindow is the sliding window for distinct NXDOMAIN tracking.
	DefaultNXDOMAINBurstWindow = 10 * time.Second

	// DefaultResolverCacheTTL is the duration for which discovered resolvers are cached per pod.
	DefaultResolverCacheTTL = 60 * time.Second
	// DefaultResolverCacheCapacity is the maximum number of pods in the resolver cache.
	DefaultResolverCacheCapacity = 1024

	// DefaultNodeLocalDNSIP is the standard Kubernetes NodeLocal DNSCache link-local IP.
	DefaultNodeLocalDNSIP = "169.254.20.10"
)

// PodResolvConfReaderFunc reads nameserver IP addresses from a pod's mount namespace /etc/resolv.conf.
type PodResolvConfReaderFunc func(pid uint32) ([]net.IP, error)

// ServiceLookupFunc fetches a Kubernetes Service object by namespace and name.
type ServiceLookupFunc func(ctx context.Context, namespace, name string) (*corev1.Service, error)

// HeuristicMetrics maintains counters for anomaly detections, unparsed capture outcomes,
// and ringbuffer drops per reason.
type HeuristicMetrics struct {
	DirectIPEgressAlerts     atomic.Uint64
	DNSSNIMismatchAlerts     atomic.Uint64
	NonClusterResolverAlerts atomic.Uint64
	NXDOMAINBurstAlerts      atomic.Uint64
	UnparsedCaptureAlerts    atomic.Uint64

	// DNS parse outcomes
	DNSParseTruncated   atomic.Uint64
	DNSParseNameTooLong atomic.Uint64
	DNSParseCompressed  atomic.Uint64
	DNSParseUnsupported atomic.Uint64

	// TLS parse outcomes
	TLSCHSegmented atomic.Uint64
	TLSCHNoSNI     atomic.Uint64
	TLSCHEncrypted atomic.Uint64
	TLSCHMalformed atomic.Uint64

	// Drop reason counters
	dropReasonCounters sync.Map // string -> *atomic.Uint64
}

// IncrementDropReason increments the drop counter for a named reason.
func (m *HeuristicMetrics) IncrementDropReason(reason string) {
	if reason == "" {
		reason = "unknown"
	}
	actual, _ := m.dropReasonCounters.LoadOrStore(reason, &atomic.Uint64{})
	actual.(*atomic.Uint64).Add(1)
}

// GetDropReasonCount returns the drop counter value for a given reason.
func (m *HeuristicMetrics) GetDropReasonCount(reason string) uint64 {
	val, ok := m.dropReasonCounters.Load(reason)
	if !ok {
		return 0
	}
	return val.(*atomic.Uint64).Load()
}

// cachedResolvers stores discovered resolver addresses for a pod with an expiry deadline.
type cachedResolvers struct {
	podOrCgroup string
	resolvers   map[string]struct{}
	expiresAt   time.Time
}

// ResolverCache provides a bounded, short-TTL cache for discovered pod and cluster resolvers.
// It avoids blocking I/O (procfs reads and Kubernetes API calls) on the packet evaluation hot path.
type ResolverCache struct {
	mu           sync.RWMutex
	capacity     int
	ttl          time.Duration
	clock        Clock
	entries      map[string]*list.Element
	lruList      *list.List
	nodeLocalIPs map[string]struct{}
	clusterDNS   map[string]struct{}

	resolvReader  PodResolvConfReaderFunc
	serviceLookup ServiceLookupFunc
	procRoot      string
}

// ResolverCacheOption configures a ResolverCache instance.
type ResolverCacheOption func(*ResolverCache)

// WithResolverCacheClock configures the time source for ResolverCache.
func WithResolverCacheClock(clk Clock) ResolverCacheOption {
	return func(rc *ResolverCache) {
		rc.clock = clk
	}
}

// WithResolverCacheTTL configures the TTL and capacity of the ResolverCache.
func WithResolverCacheTTL(ttl time.Duration, capacity int) ResolverCacheOption {
	return func(rc *ResolverCache) {
		if ttl > 0 {
			rc.ttl = ttl
		}
		if capacity > 0 {
			rc.capacity = capacity
		}
	}
}

// WithResolverCacheProcRoot configures the proc filesystem root for reading resolv.conf.
func WithResolverCacheProcRoot(procRoot string) ResolverCacheOption {
	return func(rc *ResolverCache) {
		rc.procRoot = procRoot
	}
}

// WithResolverCacheResolvReader overrides the pod /etc/resolv.conf reader function.
func WithResolverCacheResolvReader(fn PodResolvConfReaderFunc) ResolverCacheOption {
	return func(rc *ResolverCache) {
		rc.resolvReader = fn
	}
}

// WithResolverCacheServiceLookup configures the Kubernetes Service lookup function.
func WithResolverCacheServiceLookup(fn ServiceLookupFunc) ResolverCacheOption {
	return func(rc *ResolverCache) {
		rc.serviceLookup = fn
	}
}

// WithResolverCacheNodeLocalIP adds a NodeLocal DNSCache IP address.
func WithResolverCacheNodeLocalIP(ip string) ResolverCacheOption {
	return func(rc *ResolverCache) {
		if norm := normalizeIPStr(ip); norm != "" {
			rc.nodeLocalIPs[norm] = struct{}{}
		}
	}
}

// WithResolverCacheClusterDNSIP adds a known Cluster DNS Service IP address.
func WithResolverCacheClusterDNSIP(ip string) ResolverCacheOption {
	return func(rc *ResolverCache) {
		if norm := normalizeIPStr(ip); norm != "" {
			rc.clusterDNS[norm] = struct{}{}
		}
	}
}

// NewResolverCache creates a new ResolverCache instance.
func NewResolverCache(opts ...ResolverCacheOption) *ResolverCache {
	rc := &ResolverCache{
		capacity:     DefaultResolverCacheCapacity,
		ttl:          DefaultResolverCacheTTL,
		clock:        realClock{},
		entries:      make(map[string]*list.Element),
		lruList:      list.New(),
		nodeLocalIPs: make(map[string]struct{}),
		clusterDNS:   make(map[string]struct{}),
		procRoot:     DefaultProcRoot,
	}

	// Always allow the standard NodeLocal DNS address by default
	rc.nodeLocalIPs[DefaultNodeLocalDNSIP] = struct{}{}

	for _, opt := range opts {
		opt(rc)
	}

	if rc.resolvReader == nil {
		rc.resolvReader = rc.defaultResolvConfReader
	}

	return rc
}

// defaultResolvConfReader reads nameservers from /proc/<pid>/root/etc/resolv.conf.
func (rc *ResolverCache) defaultResolvConfReader(pid uint32) ([]net.IP, error) {
	if pid == 0 {
		return nil, nil
	}
	path := filepath.Join(rc.procRoot, strconv.Itoa(int(pid)), "root/etc/resolv.conf")
	file, err := os.Open(filepath.Clean(path))
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var nameservers []net.IP
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "nameserver" {
			for _, nsStr := range fields[1:] {
				if parsed := net.ParseIP(nsStr); parsed != nil {
					nameservers = append(nameservers, parsed)
				}
			}
		}
	}
	return nameservers, scanner.Err()
}

// DiscoverClusterDNSFromAPI attempts to discover cluster DNS Service IPs using the configured ServiceLookupFunc.
func (rc *ResolverCache) DiscoverClusterDNSFromAPI(ctx context.Context) error {
	if rc.serviceLookup == nil {
		return nil
	}

	// Probe standard service names in kube-system
	candidates := []struct {
		ns   string
		name string
	}{
		{"kube-system", "kube-dns"},
		{"kube-system", "coredns"},
	}

	var found bool
	for _, c := range candidates {
		svc, err := rc.serviceLookup(ctx, c.ns, c.name)
		if err == nil && svc != nil {
			rc.mu.Lock()
			if svc.Spec.ClusterIP != "" && svc.Spec.ClusterIP != corev1.ClusterIPNone {
				if norm := normalizeIPStr(svc.Spec.ClusterIP); norm != "" {
					rc.clusterDNS[norm] = struct{}{}
					found = true
				}
			}
			for _, ip := range svc.Spec.ClusterIPs {
				if ip != "" && ip != corev1.ClusterIPNone {
					if norm := normalizeIPStr(ip); norm != "" {
						rc.clusterDNS[norm] = struct{}{}
						found = true
					}
				}
			}
			rc.mu.Unlock()
			if found {
				break
			}
		}
	}

	return nil
}

// AddClusterDNS adds an explicit cluster DNS Service IP to the allowed set.
func (rc *ResolverCache) AddClusterDNS(ip string) {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	if norm := normalizeIPStr(ip); norm != "" {
		rc.clusterDNS[norm] = struct{}{}
	}
}

// AddNodeLocalDNS adds an explicit NodeLocal DNS IP to the allowed set.
func (rc *ResolverCache) AddNodeLocalDNS(ip string) {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	if norm := normalizeIPStr(ip); norm != "" {
		rc.nodeLocalIPs[norm] = struct{}{}
	}
}

// SetPodResolvers explicitly caches the allowed resolvers for a pod or cgroup.
func (rc *ResolverCache) SetPodResolvers(podOrCgroup string, ips []net.IP) {
	if podOrCgroup == "" {
		return
	}
	now := rc.clock.Now()
	resMap := make(map[string]struct{}, len(ips))
	for _, ip := range ips {
		if norm := ipToString(ip); norm != "" {
			resMap[norm] = struct{}{}
		}
	}

	rc.mu.Lock()
	defer rc.mu.Unlock()

	if elem, exists := rc.entries[podOrCgroup]; exists {
		entry := elem.Value.(*cachedResolvers)
		entry.resolvers = resMap
		entry.expiresAt = now.Add(rc.ttl)
		rc.lruList.MoveToFront(elem)
		return
	}

	// Evict oldest if at capacity
	if rc.lruList.Len() >= rc.capacity {
		if back := rc.lruList.Back(); back != nil {
			oldest := back.Value.(*cachedResolvers)
			delete(rc.entries, oldest.podOrCgroup)
			rc.lruList.Remove(back)
		}
	}

	newEntry := &cachedResolvers{
		podOrCgroup: podOrCgroup,
		resolvers:   resMap,
		expiresAt:   now.Add(rc.ttl),
	}
	elem := rc.lruList.PushFront(newEntry)
	rc.entries[podOrCgroup] = elem
}

// IsAllowedResolver checks whether the given resolver IP is among the allowed resolvers
// (pod resolv.conf nameservers, cluster DNS Service IP, or NodeLocal DNSCache IP).
func (rc *ResolverCache) IsAllowedResolver(podOrCgroup string, pid uint32, resolver net.IP) bool {
	if resolver == nil || resolver.IsUnspecified() {
		return false
	}
	resStr := ipToString(resolver)
	if resStr == "" {
		return false
	}

	rc.mu.RLock()
	// 1. Check NodeLocal DNS IPs
	if _, ok := rc.nodeLocalIPs[resStr]; ok {
		rc.mu.RUnlock()
		return true
	}
	// 2. Check Discovered Cluster DNS Service IPs
	if _, ok := rc.clusterDNS[resStr]; ok {
		rc.mu.RUnlock()
		return true
	}

	// 3. Check Pod Resolv.conf Cache
	now := rc.clock.Now()
	if elem, exists := rc.entries[podOrCgroup]; exists {
		entry := elem.Value.(*cachedResolvers)
		if now.Before(entry.expiresAt) {
			_, ok := entry.resolvers[resStr]
			rc.mu.RUnlock()
			return ok
		}
	}
	rc.mu.RUnlock()

	// 4. Cache miss or expired: attempt dynamic discovery for this pod
	if pid > 0 && rc.resolvReader != nil {
		nameservers, err := rc.resolvReader(pid)
		if err == nil && len(nameservers) > 0 {
			rc.SetPodResolvers(podOrCgroup, nameservers)
			for _, ns := range nameservers {
				if ipToString(ns) == resStr {
					return true
				}
			}
		}
	}

	return false
}

// nxdomainTracker tracks NXDOMAIN responses per pod within a sliding window.
type nxdomainTracker struct {
	mu        sync.Mutex
	window    time.Duration
	threshold int
	clock     Clock
	// podOrCgroup -> map[qname]firstSeen
	records map[string]map[string]time.Time
}

func newNXDOMAINTracker(threshold int, window time.Duration, clk Clock) *nxdomainTracker {
	if threshold < 1 {
		threshold = DefaultNXDOMAINBurstThreshold
	}
	if window <= 0 {
		window = DefaultNXDOMAINBurstWindow
	}
	if clk == nil {
		clk = realClock{}
	}
	return &nxdomainTracker{
		threshold: threshold,
		window:    window,
		clock:     clk,
		records:   make(map[string]map[string]time.Time),
	}
}

// RecordNXDOMAIN records an NXDOMAIN response and returns the current distinct qname count
// within the sliding window, and whether the threshold was exceeded.
func (t *nxdomainTracker) RecordNXDOMAIN(podOrCgroup, qname string) (int, bool) {
	normQName := normalizeDomain(qname)
	if podOrCgroup == "" || normQName == "" {
		return 0, false
	}

	now := t.clock.Now()
	cutoff := now.Add(-t.window)

	t.mu.Lock()
	defer t.mu.Unlock()

	podMap, exists := t.records[podOrCgroup]
	if !exists {
		podMap = make(map[string]time.Time)
		t.records[podOrCgroup] = podMap
	}

	// Purge stale entries outside the sliding window
	for name, ts := range podMap {
		if ts.Before(cutoff) {
			delete(podMap, name)
		}
	}

	// Record or refresh entry
	if _, seen := podMap[normQName]; !seen {
		podMap[normQName] = now
	}

	distinctCount := len(podMap)
	exceeded := distinctCount > t.threshold
	return distinctCount, exceeded
}

// DNSHeuristicsEngine evaluates network and TLS events against the five Appendix C anomaly heuristics.
type DNSHeuristicsEngine struct {
	dnsCache       *DNSCache
	resolverCache  *ResolverCache
	nxdomainTrack  *nxdomainTracker
	metrics        *HeuristicMetrics
	clock          Clock
	vhostMap       map[string]map[string]struct{} // (podOrCgroup:ip) -> set of domains for shared vhost
	vhostMu        sync.RWMutex
}

// DNSHeuristicsOption configures a DNSHeuristicsEngine instance.
type DNSHeuristicsOption func(*DNSHeuristicsEngine)

// WithHeuristicsDNSCache sets the DNSCache reference.
func WithHeuristicsDNSCache(cache *DNSCache) DNSHeuristicsOption {
	return func(e *DNSHeuristicsEngine) {
		e.dnsCache = cache
	}
}

// WithHeuristicsResolverCache sets the ResolverCache reference.
func WithHeuristicsResolverCache(rc *ResolverCache) DNSHeuristicsOption {
	return func(e *DNSHeuristicsEngine) {
		e.resolverCache = rc
	}
}

// WithHeuristicsClock sets the clock provider.
func WithHeuristicsClock(clk Clock) DNSHeuristicsOption {
	return func(e *DNSHeuristicsEngine) {
		e.clock = clk
		if e.nxdomainTrack != nil {
			e.nxdomainTrack.clock = clk
		}
	}
}

// WithHeuristicsNXDOMAINThreshold configures NXDOMAIN burst detection.
func WithHeuristicsNXDOMAINThreshold(threshold int, window time.Duration) DNSHeuristicsOption {
	return func(e *DNSHeuristicsEngine) {
		e.nxdomainTrack = newNXDOMAINTracker(threshold, window, e.clock)
	}
}

// NewDNSHeuristicsEngine creates a new DNSHeuristicsEngine.
func NewDNSHeuristicsEngine(opts ...DNSHeuristicsOption) *DNSHeuristicsEngine {
	clk := realClock{}
	e := &DNSHeuristicsEngine{
		clock:         clk,
		metrics:       &HeuristicMetrics{},
		nxdomainTrack: newNXDOMAINTracker(DefaultNXDOMAINBurstThreshold, DefaultNXDOMAINBurstWindow, clk),
		resolverCache: NewResolverCache(WithResolverCacheClock(clk)),
		vhostMap:      make(map[string]map[string]struct{}),
	}

	for _, opt := range opts {
		opt(e)
	}

	if e.dnsCache == nil {
		e.dnsCache = NewDNSCache(WithDNSCacheClock(e.clock))
	}

	return e
}

// Metrics returns the heuristic metrics collector.
func (e *DNSHeuristicsEngine) Metrics() *HeuristicMetrics {
	return e.metrics
}

// ResolverCache returns the underlying ResolverCache.
func (e *DNSHeuristicsEngine) ResolverCache() *ResolverCache {
	return e.resolverCache
}

// RegisterVirtualHost associates an additional domain name with an IP for a pod/cgroup
// to represent shared-IP virtual hosts.
func (e *DNSHeuristicsEngine) RegisterVirtualHost(podOrCgroup string, ip net.IP, domain string) {
	if podOrCgroup == "" || ip == nil || domain == "" {
		return
	}
	ipStr := ipToString(ip)
	if ipStr == "" {
		return
	}
	key := podOrCgroup + ":" + ipStr
	normDomain := normalizeDomain(domain)

	e.vhostMu.Lock()
	defer e.vhostMu.Unlock()
	set, exists := e.vhostMap[key]
	if !exists {
		set = make(map[string]struct{})
		e.vhostMap[key] = set
	}
	set[normDomain] = struct{}{}
}

// isSharedVirtualHost checks whether the SNI domain is known to resolve to the same IP for the pod.
func (e *DNSHeuristicsEngine) isSharedVirtualHost(podOrCgroup string, ip net.IP, sni string) bool {
	if ip == nil || sni == "" {
		return false
	}
	ipStr := ipToString(ip)
	if ipStr == "" {
		return false
	}
	normSNI := normalizeDomain(sni)

	e.vhostMu.RLock()
	defer e.vhostMu.RUnlock()
	key := podOrCgroup + ":" + ipStr
	if set, exists := e.vhostMap[key]; exists {
		if _, ok := set[normSNI]; ok {
			return true
		}
	}
	return false
}

// buildObservation formats a TelemetryObservation record carrying an anomaly label.
func (e *DNSHeuristicsEngine) buildObservation(
	anomaly string,
	severity string,
	syscall string,
	target string,
	pod *corev1.Pod,
	labels map[string]string,
	baseObs *TelemetryObservation,
) *TelemetryObservation {
	now := e.clock.Now().UTC().Format(time.RFC3339Nano)

	obs := &TelemetryObservation{
		Timestamp:      now,
		Severity:       severity,
		Syscall:        syscall,
		Target:         target,
		DirectReaction: ReactionNone,
		Labels:         make(map[string]string),
	}

	if baseObs != nil {
		*obs = *baseObs
		if obs.Labels == nil {
			obs.Labels = make(map[string]string)
		} else {
			cpy := make(map[string]string, len(baseObs.Labels)+len(labels)+1)
			for k, v := range baseObs.Labels {
				cpy[k] = v
			}
			obs.Labels = cpy
		}
	}

	if pod != nil {
		if obs.PodName == "" {
			obs.PodName = pod.Name
		}
		if obs.Namespace == "" {
			obs.Namespace = pod.Namespace
		}
		if obs.ActorID == "" {
			obs.ActorID = pod.Name
		}
		if obs.TenantID == "" && pod.Labels != nil {
			obs.TenantID = pod.Labels["tenant"]
		}
	}

	obs.Severity = severity
	if syscall != "" {
		obs.Syscall = syscall
	}
	if target != "" {
		obs.Target = target
	}

	obs.Labels["anomaly"] = anomaly
	for k, v := range labels {
		if v != "" {
			obs.Labels[k] = v
		}
	}

	return obs
}

// -----------------------------------------------------------------------------
// 1. Direct IP Outbound Egress (Appendix C Row 1)
// -----------------------------------------------------------------------------

// EvaluateDirectIPEgress inspects a connect() event and fires a CRITICAL security alert
// if the destination address has no matching unexpired resolution in DNSCache for the pod.
//
// Must not fire on:
// - A second or later address of a multi-answer CDN record.
// - A connection outliving a short TTL on an unexpired cached record.
func (e *DNSHeuristicsEngine) EvaluateDirectIPEgress(
	podOrCgroup string,
	destIP net.IP,
	pod *corev1.Pod,
	baseObs *TelemetryObservation,
) (*TelemetryObservation, bool) {
	if destIP == nil || destIP.IsUnspecified() || destIP.IsLoopback() {
		return nil, false
	}
	ipStr := ipToString(destIP)
	if ipStr == "" {
		return nil, false
	}

	// Check primary pod/cgroup identifier in DNSCache
	if e.dnsCache != nil {
		if _, found := e.dnsCache.Lookup(podOrCgroup, ipStr); found {
			return nil, false
		}
		// Also check pod UID if available
		if pod != nil && string(pod.UID) != "" && string(pod.UID) != podOrCgroup {
			if _, found := e.dnsCache.Lookup(string(pod.UID), ipStr); found {
				return nil, false
			}
		}
	}

	e.metrics.DirectIPEgressAlerts.Add(1)

	target := ipStr
	if baseObs != nil && baseObs.Target != "" {
		target = baseObs.Target
	}

	obs := e.buildObservation(
		AnomalyDirectIPEgress,
		SeverityCritical,
		SyscallNameConnect,
		target,
		pod,
		map[string]string{
			"dest_ip": ipStr,
		},
		baseObs,
	)

	return obs, true
}

// -----------------------------------------------------------------------------
// 2. DNS vs. TLS SNI Mismatch (Appendix C Row 2)
// -----------------------------------------------------------------------------

// EvaluateDNSSNIMismatch evaluates TLS ClientHello Server Name Indication (SNI) against
// the DNS-resolved domain for the connection's destination address.
//
// Fires a CRITICAL alert when DNS domain != SNI AND neither is a CNAME alias of the other.
//
// Must not fire on:
// - A CNAME alias chain (e.g. svc.example.com -> d1abc.cloudfront.net).
// - A shared-IP virtual host where both names resolved to the same IP.
// - Any non-OK parse status (TLS_CH_SEGMENTED, TLS_CH_NO_SNI, TLS_CH_ENCRYPTED, TLS_CH_MALFORMED).
func (e *DNSHeuristicsEngine) EvaluateDNSSNIMismatch(
	podOrCgroup string,
	destIP net.IP,
	sni string,
	parseStatus uint8,
	pod *corev1.Pod,
	baseObs *TelemetryObservation,
) (*TelemetryObservation, bool) {
	// Exclusion 1: Never fire on non-OK parse outcomes
	if parseStatus != ebpf.TLS_CH_OK {
		return nil, false
	}

	normSNI := normalizeDomain(sni)
	if normSNI == "" || destIP == nil || destIP.IsUnspecified() || destIP.IsLoopback() {
		return nil, false
	}

	ipStr := ipToString(destIP)
	if ipStr == "" || e.dnsCache == nil {
		return nil, false
	}

	dnsDomain, found := e.dnsCache.Lookup(podOrCgroup, ipStr)
	if !found && pod != nil && string(pod.UID) != "" && string(pod.UID) != podOrCgroup {
		dnsDomain, found = e.dnsCache.Lookup(string(pod.UID), ipStr)
	}

	// If no DNS record was observed at all for this IP, DNS vs SNI mismatch does not apply
	// (direct-to-IP egress heuristic handles the un-cached scenario).
	if !found || dnsDomain == "" {
		return nil, false
	}

	normDNS := normalizeDomain(dnsDomain)

	// Exclusion 2: Exact domain match
	if normDNS == normSNI {
		return nil, false
	}

	// Exclusion 3: CNAME alias chain (either direction)
	if e.dnsCache.IsAlias(podOrCgroup, normDNS, normSNI) || e.dnsCache.IsAlias(podOrCgroup, normSNI, normDNS) {
		return nil, false
	}
	if pod != nil && string(pod.UID) != "" {
		if e.dnsCache.IsAlias(string(pod.UID), normDNS, normSNI) || e.dnsCache.IsAlias(string(pod.UID), normSNI, normDNS) {
			return nil, false
		}
	}

	// Exclusion 4: Shared-IP virtual host
	if e.isSharedVirtualHost(podOrCgroup, destIP, normSNI) {
		return nil, false
	}
	if pod != nil && string(pod.UID) != "" && e.isSharedVirtualHost(string(pod.UID), destIP, normSNI) {
		return nil, false
	}

	// Check if the SNI domain's canonical name matches the DNS entry's canonical name
	canonDNS := e.dnsCache.CanonicalName(podOrCgroup, normDNS)
	canonSNI := e.dnsCache.CanonicalName(podOrCgroup, normSNI)
	if canonDNS != "" && canonDNS == canonSNI {
		return nil, false
	}

	e.metrics.DNSSNIMismatchAlerts.Add(1)

	obs := e.buildObservation(
		AnomalyDNSSNIMismatch,
		SeverityCritical,
		"tls_client_hello",
		normSNI,
		pod,
		map[string]string{
			"dns_domain": normDNS,
			"sni":        normSNI,
			"dest_ip":    ipStr,
		},
		baseObs,
	)

	return obs, true
}

// -----------------------------------------------------------------------------
// 3. Non-Cluster DNS Resolver (Appendix C Row 3)
// -----------------------------------------------------------------------------

// EvaluateNonClusterResolver evaluates whether a DNS query was directed to an unauthorized resolver.
//
// Fires a WARN alert when resolver_addr is not among discovered resolvers.
//
// Must not fire on:
// - A cluster whose DNS Service is a custom non-default IP.
// - A pod with a legitimate dnsConfig override in resolv.conf.
// - NodeLocal DNSCache address (169.254.20.10).
func (e *DNSHeuristicsEngine) EvaluateNonClusterResolver(
	podOrCgroup string,
	pid uint32,
	resolverIP net.IP,
	pod *corev1.Pod,
	baseObs *TelemetryObservation,
) (*TelemetryObservation, bool) {
	if resolverIP == nil || resolverIP.IsUnspecified() {
		return nil, false
	}

	if e.resolverCache != nil && e.resolverCache.IsAllowedResolver(podOrCgroup, pid, resolverIP) {
		return nil, false
	}
	if pod != nil && string(pod.UID) != "" && e.resolverCache != nil {
		if e.resolverCache.IsAllowedResolver(string(pod.UID), pid, resolverIP) {
			return nil, false
		}
	}

	e.metrics.NonClusterResolverAlerts.Add(1)

	resStr := ipToString(resolverIP)
	obs := e.buildObservation(
		AnomalyNonClusterResolver,
		SeverityWarn,
		"dns_query",
		resStr,
		pod,
		map[string]string{
			"resolver_addr": resStr,
		},
		baseObs,
	)

	return obs, true
}

// -----------------------------------------------------------------------------
// 4. NXDOMAIN Burst / DGA (Appendix C Row 4)
// -----------------------------------------------------------------------------

// EvaluateNXDOMAIN tracks NXDOMAIN responses and fires a WARN alert when more than 10
// NXDOMAIN responses for DISTINCT qnames occur from one pod within 10 seconds.
//
// Must not fire on:
// - A retry loop against one unresolvable name (counts once).
func (e *DNSHeuristicsEngine) EvaluateNXDOMAIN(
	podOrCgroup string,
	qname string,
	rcode uint8,
	pod *corev1.Pod,
	baseObs *TelemetryObservation,
) (*TelemetryObservation, bool) {
	// Rcode 3 == NXDOMAIN (RFC 1035)
	if rcode != 3 {
		return nil, false
	}

	normQName := normalizeDomain(qname)
	if normQName == "" || e.nxdomainTrack == nil {
		return nil, false
	}

	identifier := podOrCgroup
	if identifier == "" && pod != nil {
		identifier = podKey(pod)
	}

	distinctCount, exceeded := e.nxdomainTrack.RecordNXDOMAIN(identifier, normQName)
	if !exceeded {
		return nil, false
	}

	e.metrics.NXDOMAINBurstAlerts.Add(1)

	obs := e.buildObservation(
		AnomalyNXDOMAINBurst,
		SeverityWarn,
		"dns_response",
		normQName,
		pod,
		map[string]string{
			"distinct_qnames": strconv.Itoa(distinctCount),
			"last_qname":      normQName,
		},
		baseObs,
	)

	return obs, true
}

// -----------------------------------------------------------------------------
// 5. Unparsed Capture (Appendix C Row 5)
// -----------------------------------------------------------------------------

// EvaluateUnparsedCapture reports unparsed packet captures and ringbuffer drops as WARN alerts,
// incrementing per-parse_status and per-drop-reason metrics without suppression.
//
// Blind spots are reported, never swallowed.
func (e *DNSHeuristicsEngine) EvaluateUnparsedCapture(
	captureType string,
	parseStatus uint8,
	dropReason string,
	dropCount uint64,
	pod *corev1.Pod,
	baseObs *TelemetryObservation,
) (*TelemetryObservation, bool) {
	var isAnomaly bool
	var statusStr string

	switch strings.ToLower(captureType) {
	case "dns":
		switch parseStatus {
		case ebpf.DNS_PARSE_OK:
			// Normal clean parse
		case ebpf.DNS_PARSE_TRUNCATED:
			e.metrics.DNSParseTruncated.Add(1)
			isAnomaly = true
			statusStr = "DNS_PARSE_TRUNCATED"
		case ebpf.DNS_PARSE_NAME_TOO_LONG:
			e.metrics.DNSParseNameTooLong.Add(1)
			isAnomaly = true
			statusStr = "DNS_PARSE_NAME_TOO_LONG"
		case ebpf.DNS_PARSE_COMPRESSED:
			e.metrics.DNSParseCompressed.Add(1)
			isAnomaly = true
			statusStr = "DNS_PARSE_COMPRESSED"
		case ebpf.DNS_PARSE_UNSUPPORTED:
			e.metrics.DNSParseUnsupported.Add(1)
			isAnomaly = true
			statusStr = "DNS_PARSE_UNSUPPORTED"
		default:
			isAnomaly = true
			statusStr = fmt.Sprintf("DNS_PARSE_UNKNOWN(%d)", parseStatus)
		}

	case "tls":
		switch parseStatus {
		case ebpf.TLS_CH_OK:
			// Normal clean handshake
		case ebpf.TLS_CH_SEGMENTED:
			e.metrics.TLSCHSegmented.Add(1)
			isAnomaly = true
			statusStr = "TLS_CH_SEGMENTED"
		case ebpf.TLS_CH_NO_SNI:
			e.metrics.TLSCHNoSNI.Add(1)
			// No SNI is not an unparsed error per Appendix C, but counted in metrics
		case ebpf.TLS_CH_ENCRYPTED:
			e.metrics.TLSCHEncrypted.Add(1)
			// Encrypted ClientHello is not an unparsed error per Appendix C, but counted
		case ebpf.TLS_CH_MALFORMED:
			e.metrics.TLSCHMalformed.Add(1)
			isAnomaly = true
			statusStr = "TLS_CH_MALFORMED"
		default:
			isAnomaly = true
			statusStr = fmt.Sprintf("TLS_CH_UNKNOWN(%d)", parseStatus)
		}
	}

	if dropCount > 0 {
		isAnomaly = true
		e.metrics.IncrementDropReason(dropReason)
	}

	if !isAnomaly {
		return nil, false
	}

	e.metrics.UnparsedCaptureAlerts.Add(1)

	labels := map[string]string{
		"capture_type": captureType,
	}
	if statusStr != "" {
		labels["parse_status"] = statusStr
	}
	if dropReason != "" {
		labels["drop_reason"] = dropReason
	}
	if dropCount > 0 {
		labels["drop_count"] = strconv.FormatUint(dropCount, 10)
	}

	obs := e.buildObservation(
		AnomalyUnparsedCapture,
		SeverityWarn,
		"unparsed_capture",
		captureType,
		pod,
		labels,
		baseObs,
	)

	return obs, true
}

// NewKubernetesServiceLookup creates an injectable ServiceLookupFunc from a kubernetes.Interface.
func NewKubernetesServiceLookup(clientset kubernetes.Interface) ServiceLookupFunc {
	if clientset == nil {
		return nil
	}
	return func(ctx context.Context, namespace, name string) (*corev1.Service, error) {
		return clientset.CoreV1().Services(namespace).Get(ctx, name, metav1.GetOptions{})
	}
}
