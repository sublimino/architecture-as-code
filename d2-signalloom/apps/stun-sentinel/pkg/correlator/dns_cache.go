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
)

const (
	// DefaultDNSCacheShards is the default number of partitioned shards.
	DefaultDNSCacheShards = 16
	// DefaultDNSCacheCapacity is the default total entry capacity across all shards.
	DefaultDNSCacheCapacity = 65536
	// MinDNSTTL is the minimum TTL enforced for cached DNS resolutions (Appendix C: Direct IP Egress).
	MinDNSTTL = 30 * time.Second
	// MaxDNSTTL is the maximum TTL enforced for cached DNS resolutions (Appendix C: Direct IP Egress).
	MaxDNSTTL = 3600 * time.Second
	// maxCNAMEDepth bounds CNAME alias chain traversal to protect against alias loops.
	maxCNAMEDepth = 16
)

// DNSCacheStats holds a point-in-time snapshot of DNS resolution cache statistics.
type DNSCacheStats struct {
	Inserted         uint64 `json:"inserted"`
	Lookups          uint64 `json:"lookups"`
	Hits             uint64 `json:"hits"`
	Evicted          uint64 `json:"evicted"`
	EvictedUnexpired uint64 `json:"evicted_unexpired"`
}

// DNSEntry represents a cached IP-to-domain resolution for a specific pod or cgroup.
type DNSEntry struct {
	PodOrCgroup   string
	IP            string
	CanonicalName string
	QName         string
	CName         string
	ExpiresAt     time.Time
}

// entryKey composite key for per-shard entry map.
type entryKey struct {
	podOrCgroup string
	ip          string
}

// aliasKey composite key for per-shard CNAME alias map.
type aliasKey struct {
	podOrCgroup string
	name        string
}

// dnsCacheShard is an independently locked shard holding a partition of the cache.
type dnsCacheShard struct {
	mu       sync.RWMutex
	capacity int
	entries  map[entryKey]*list.Element
	lruList  *list.List
	aliases  map[aliasKey]string // qname -> cname
}

// DNSCache provides a partitioned, LRU-bounded, TTL-expiring in-memory cache
// of DNS resolutions keyed by (podOrCgroup, ip).
type DNSCache struct {
	shards    []*dnsCacheShard
	numShards uint32
	clock     Clock
	minTTL    time.Duration
	maxTTL    time.Duration

	inserted         atomic.Uint64
	lookups          atomic.Uint64
	hits             atomic.Uint64
	evicted          atomic.Uint64
	evictedUnexpired atomic.Uint64
}

// DNSCacheOption configures a DNSCache instance.
type DNSCacheOption func(*DNSCache)

// WithDNSCacheClock overrides the time provider (used for testing with mockClock).
func WithDNSCacheClock(clock Clock) DNSCacheOption {
	return func(c *DNSCache) {
		c.clock = clock
	}
}

// WithDNSCacheCapacity sets the total entry capacity across all shards.
func WithDNSCacheCapacity(capacity int) DNSCacheOption {
	return func(c *DNSCache) {
		if capacity < 1 {
			capacity = DefaultDNSCacheCapacity
		}
		perShard := capacity / int(c.numShards)
		if perShard < 1 {
			perShard = 1
		}
		for _, s := range c.shards {
			s.capacity = perShard
		}
	}
}

// WithDNSCacheShards sets the shard count (must be a power of two).
func WithDNSCacheShards(shards int) DNSCacheOption {
	return func(c *DNSCache) {
		if shards < 1 || (shards&(shards-1)) != 0 {
			shards = DefaultDNSCacheShards
		}
		c.numShards = uint32(shards)
		c.shards = make([]*dnsCacheShard, shards)
		perShard := DefaultDNSCacheCapacity / shards
		if perShard < 1 {
			perShard = 1
		}
		for i := 0; i < shards; i++ {
			c.shards[i] = &dnsCacheShard{
				capacity: perShard,
				entries:  make(map[entryKey]*list.Element),
				lruList:  list.New(),
				aliases:  make(map[aliasKey]string),
			}
		}
	}
}

// WithDNSCacheTTLBounds overrides the floor and ceiling TTL bounds.
func WithDNSCacheTTLBounds(minTTL, maxTTL time.Duration) DNSCacheOption {
	return func(c *DNSCache) {
		if minTTL > 0 {
			c.minTTL = minTTL
		}
		if maxTTL >= c.minTTL {
			c.maxTTL = maxTTL
		}
	}
}

// NewDNSCache constructs a new partitioned DNSCache.
func NewDNSCache(opts ...DNSCacheOption) *DNSCache {
	shards := DefaultDNSCacheShards
	c := &DNSCache{
		numShards: uint32(shards),
		clock:     realClock{},
		minTTL:    MinDNSTTL,
		maxTTL:    MaxDNSTTL,
		shards:    make([]*dnsCacheShard, shards),
	}
	perShard := DefaultDNSCacheCapacity / shards
	for i := 0; i < shards; i++ {
		c.shards[i] = &dnsCacheShard{
			capacity: perShard,
			entries:  make(map[entryKey]*list.Element),
			lruList:  list.New(),
			aliases:  make(map[aliasKey]string),
		}
	}

	for _, opt := range opts {
		opt(c)
	}

	return c
}

// fnv1a calculates a fast, zero-allocation 32-bit FNV-1a hash of a string.
func fnv1a(s string) uint32 {
	const offset32 = 2166136261
	const prime32 = 16777619
	hash := uint32(offset32)
	for i := 0; i < len(s); i++ {
		hash ^= uint32(s[i])
		hash *= prime32
	}
	return hash
}

// shardFor returns the shard responsible for podOrCgroup.
func (c *DNSCache) shardFor(podOrCgroup string) *dnsCacheShard {
	idx := fnv1a(podOrCgroup) & (c.numShards - 1)
	return c.shards[idx]
}

// normalizeDomain trims whitespace, trailing dots, and converts to lowercase.
func normalizeDomain(domain string) string {
	d := strings.TrimSpace(domain)
	d = strings.TrimSuffix(d, ".")
	return strings.ToLower(d)
}

// normalizeIPStr normalizes IPv4 and IPv6 string representations.
func normalizeIPStr(raw string) string {
	raw = strings.TrimSpace(raw)
	if parsed := net.ParseIP(raw); parsed != nil {
		if v4 := parsed.To4(); v4 != nil {
			return v4.String()
		}
		return parsed.String()
	}
	return raw
}

// CanonicalIPStr normalizes an IP string representation.
func CanonicalIPStr(raw string) string {
	return normalizeIPStr(raw)
}

// ipToString converts a net.IP to canonical IPv4 or IPv6 string.
func ipToString(ip net.IP) string {
	if ip == nil {
		return ""
	}
	if v4 := ip.To4(); v4 != nil {
		return v4.String()
	}
	return ip.String()
}

// CanonicalIP converts a net.IP to canonical IPv4 or IPv6 string.
func CanonicalIP(ip net.IP) string {
	return ipToString(ip)
}

// resolveCanonicalLocked resolves the final canonical name following CNAME aliases.
// Caller must hold shard read or write lock.
func (s *dnsCacheShard) resolveCanonicalLocked(podOrCgroup, name string) string {
	curr := name
	for depth := 0; depth < maxCNAMEDepth; depth++ {
		target, ok := s.aliases[aliasKey{podOrCgroup: podOrCgroup, name: curr}]
		if !ok || target == "" || target == curr {
			break
		}
		curr = target
	}
	return curr
}

// Insert caches all answer addresses from a DNS response with per-record TTLs,
// resolving any CNAME alias chain to a canonical owning domain.
//
// Every answer address in answers is indexed — keeping only the first address
// is an anti-pattern that creates false direct-IP egress anomalies.
func (c *DNSCache) Insert(podOrCgroup string, answers []net.IP, ttls []uint32, qname, cname string) {
	if len(answers) == 0 && cname == "" {
		return
	}

	normQName := normalizeDomain(qname)
	normCName := normalizeDomain(cname)
	shard := c.shardFor(podOrCgroup)
	now := c.clock.Now()

	shard.mu.Lock()
	defer shard.mu.Unlock()

	// 1. Record CNAME alias relationship if present
	if normQName != "" && normCName != "" && normQName != normCName {
		shard.aliases[aliasKey{podOrCgroup: podOrCgroup, name: normQName}] = normCName
	}

	// 2. Resolve canonical domain for this resolution set
	var canonicalName string
	if normCName != "" {
		canonicalName = shard.resolveCanonicalLocked(podOrCgroup, normCName)
	} else if normQName != "" {
		canonicalName = shard.resolveCanonicalLocked(podOrCgroup, normQName)
	}

	// 3. Index EVERY answer address (multi-answer indexing)
	for i, ip := range answers {
		ipStr := ipToString(ip)
		if ipStr == "" {
			continue
		}

		// Calculate per-record TTL floored at minTTL (30s) and ceiled at maxTTL (3600s)
		var rawTTL uint32
		if i < len(ttls) {
			rawTTL = ttls[i]
		}
		effectiveTTL := time.Duration(rawTTL) * time.Second
		if effectiveTTL < c.minTTL {
			effectiveTTL = c.minTTL
		} else if effectiveTTL > c.maxTTL {
			effectiveTTL = c.maxTTL
		}
		expiresAt := now.Add(effectiveTTL)

		key := entryKey{podOrCgroup: podOrCgroup, ip: ipStr}

		if elem, exists := shard.entries[key]; exists {
			// Update existing entry and move to front of LRU
			entry := elem.Value.(*DNSEntry)
			entry.CanonicalName = canonicalName
			entry.QName = normQName
			entry.CName = normCName
			entry.ExpiresAt = expiresAt
			shard.lruList.MoveToFront(elem)
			c.inserted.Add(1)
		} else {
			// Evict oldest if at capacity
			if shard.lruList.Len() >= shard.capacity {
				oldestElem := shard.lruList.Back()
				if oldestElem != nil {
					oldestEntry := oldestElem.Value.(*DNSEntry)
					oldestKey := entryKey{podOrCgroup: oldestEntry.PodOrCgroup, ip: oldestEntry.IP}
					delete(shard.entries, oldestKey)
					shard.lruList.Remove(oldestElem)

					// Count eviction; specifically distinguish unexpired evictions
					if now.Before(oldestEntry.ExpiresAt) {
						c.evictedUnexpired.Add(1)
					}
					c.evicted.Add(1)
				}
			}

			// Insert new entry at front of LRU
			newEntry := &DNSEntry{
				PodOrCgroup:   podOrCgroup,
				IP:            ipStr,
				CanonicalName: canonicalName,
				QName:         normQName,
				CName:         normCName,
				ExpiresAt:     expiresAt,
			}
			elem := shard.lruList.PushFront(newEntry)
			shard.entries[key] = elem
			c.inserted.Add(1)
		}
	}
}

// Lookup queries the cache for the canonical domain that resolved to ip for podOrCgroup.
// Returns ("", false) if the address is not cached or if the entry has expired.
func (c *DNSCache) Lookup(podOrCgroup string, ip string) (string, bool) {
	c.lookups.Add(1)
	if ip == "" {
		return "", false
	}

	shard := c.shardFor(podOrCgroup)
	key := entryKey{podOrCgroup: podOrCgroup, ip: ip}

	shard.mu.RLock()
	elem, exists := shard.entries[key]
	if !exists {
		normIP := normalizeIPStr(ip)
		if normIP != ip {
			elem, exists = shard.entries[entryKey{podOrCgroup: podOrCgroup, ip: normIP}]
		}
	}
	if !exists {
		shard.mu.RUnlock()
		return "", false
	}

	entry := elem.Value.(*DNSEntry)
	if c.clock.Now().After(entry.ExpiresAt) {
		shard.mu.RUnlock()
		return "", false
	}

	canonical := shard.resolveCanonicalLocked(entry.PodOrCgroup, entry.CanonicalName)
	shard.mu.RUnlock()

	c.hits.Add(1)
	return canonical, true
}

// LookupIP queries the cache using a net.IP address.
func (c *DNSCache) LookupIP(podOrCgroup string, ip net.IP) (string, bool) {
	return c.Lookup(podOrCgroup, ipToString(ip))
}

// LookupEntry returns a full DNSEntry copy if found and unexpired.
func (c *DNSCache) LookupEntry(podOrCgroup string, ip string) (DNSEntry, bool) {
	c.lookups.Add(1)
	if ip == "" {
		return DNSEntry{}, false
	}

	shard := c.shardFor(podOrCgroup)
	key := entryKey{podOrCgroup: podOrCgroup, ip: ip}

	shard.mu.RLock()
	elem, exists := shard.entries[key]
	if !exists {
		normIP := normalizeIPStr(ip)
		if normIP != ip {
			elem, exists = shard.entries[entryKey{podOrCgroup: podOrCgroup, ip: normIP}]
		}
	}
	if !exists {
		shard.mu.RUnlock()
		return DNSEntry{}, false
	}

	entry := elem.Value.(*DNSEntry)
	if c.clock.Now().After(entry.ExpiresAt) {
		shard.mu.RUnlock()
		return DNSEntry{}, false
	}

	cpy := *entry
	cpy.CanonicalName = shard.resolveCanonicalLocked(entry.PodOrCgroup, entry.CanonicalName)
	shard.mu.RUnlock()

	c.hits.Add(1)
	return cpy, true
}

// IsAlias reports whether domainA and domainB resolve to the same canonical domain
// for podOrCgroup via CNAME alias chains.
func (c *DNSCache) IsAlias(podOrCgroup, domainA, domainB string) bool {
	normA := normalizeDomain(domainA)
	normB := normalizeDomain(domainB)
	if normA == "" || normB == "" {
		return false
	}
	if normA == normB {
		return true
	}

	shard := c.shardFor(podOrCgroup)
	shard.mu.RLock()
	defer shard.mu.RUnlock()

	canonA := shard.resolveCanonicalLocked(podOrCgroup, normA)
	canonB := shard.resolveCanonicalLocked(podOrCgroup, normB)

	return canonA != "" && canonA == canonB
}

// CanonicalName returns the canonical domain name following any CNAME alias chain for podOrCgroup.
func (c *DNSCache) CanonicalName(podOrCgroup, domain string) string {
	norm := normalizeDomain(domain)
	if norm == "" {
		return ""
	}

	shard := c.shardFor(podOrCgroup)
	shard.mu.RLock()
	defer shard.mu.RUnlock()

	return shard.resolveCanonicalLocked(podOrCgroup, norm)
}

// Stats returns a point-in-time snapshot of the DNS cache counters.
func (c *DNSCache) Stats() DNSCacheStats {
	return DNSCacheStats{
		Inserted:         c.inserted.Load(),
		Lookups:          c.lookups.Load(),
		Hits:             c.hits.Load(),
		Evicted:          c.evicted.Load(),
		EvictedUnexpired: c.evictedUnexpired.Load(),
	}
}
