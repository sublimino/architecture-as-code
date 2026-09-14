// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"fmt"
	"sort"
	"sync"
)

// CacheName identifies one cache in the registry below.
type CacheName string

// The registry of every in-memory key cache SLDP-P4-PRE §4 enumerated, plus the one this card adds.
//
// It is an enumerated registry rather than a comment because "we cleared the caches" is only a
// meaningful claim if the set of caches is written down and the claim is checked against it. A cache
// nobody listed is a cache nobody cleared, and it is invisible precisely because it was never named.
const (
	// CachePlaintextDEK is the cache this card introduces: unwrapped per-subject data keys, held so
	// a read path does not re-unwrap per record. It is the ONLY cache whose survival would make
	// erasure cosmetic, because it holds plaintext key material scoped to a subject.
	CachePlaintextDEK CacheName = "subjectkey.PlaintextDEKCache"

	// CacheTenantKEKDerivation is Hierarchy.derived — HKDF-derived tenant KEKs.
	CacheTenantKEKDerivation CacheName = "subjectkey.Hierarchy.derived"

	// CachePseudonymKeyRing is pseudonym.KeyRing.derived (pseudonym/pseudonym.go).
	CachePseudonymKeyRing CacheName = "pseudonym.KeyRing.derived"

	// CacheSegmentPseudonymiser is store.SegmentPseudonymiser's wrapped ring.
	CacheSegmentPseudonymiser CacheName = "store.SegmentPseudonymiser.ring"

	// CacheIdentityEncryptorRoot is identity.AESGCMEncryptor's root key field.
	CacheIdentityEncryptorRoot CacheName = "identity.AESGCMEncryptor.key"

	// CacheSecretScrubberSalt is transform.CryptographicSecretScrubber's salt.
	CacheSecretScrubberSalt CacheName = "transform.CryptographicSecretScrubber.salt"
)

// CacheDisposition records whether a per-subject erasure clears a cache, and why.
type CacheDisposition struct {
	Name    CacheName
	Cleared bool
	Reason  string
}

// CacheRegistry is the auditable answer to "which caches does erasure touch?".
//
// Read the Cleared=false entries carefully: each one is a deliberate decision, not an omission.
// Every not-cleared cache holds TENANT-scoped or SERVICE-scoped material that survives erasure by
// design. Clearing them would be a cross-subject side effect dressed as hygiene and would not make
// any destroyed subject DEK less destroyed — while genuinely breaking other subjects' reads.
//
// TestCacheRegistry_CoversEveryPreflightEnumeratedCache asserts this list against the P4-PRE
// inventory, so adding a cache to the codebase without adding it here fails a test rather than
// silently widening the gap.
var CacheRegistry = []CacheDisposition{
	{
		Name:    CachePlaintextDEK,
		Cleared: true,
		Reason:  "holds plaintext per-subject data keys; a survivor would decrypt shredded data until process restart, making erasure cosmetic (SLDP-P4-PRE §4.1)",
	},
	{
		Name:    CacheTenantKEKDerivation,
		Cleared: false,
		Reason:  "tenant-scoped; the tenant KEK survives erasure by design and wraps every other subject's DEK. Purging it would evict other subjects' key material for no erasure benefit",
	},
	{
		Name:    CachePseudonymKeyRing,
		Cleared: false,
		Reason:  "tenant-scoped HMAC keys, not decryption keys. They compute the pseudonym used to FIND the subject's row; erasure needs them intact for the saga's own lookup",
	},
	{
		Name:    CacheSegmentPseudonymiser,
		Cleared: false,
		Reason:  "wraps pseudonym.KeyRing; same reasoning. It cannot decrypt anything",
	},
	{
		Name:    CacheIdentityEncryptorRoot,
		Cleared: false,
		Reason:  "the legacy global service root key. It is outside this hierarchy and is not a per-subject key; clearing it would break every tenant's reads and erase nobody",
	},
	{
		Name:    CacheSecretScrubberSalt,
		Cleared: false,
		Reason:  "a one-way scrubbing salt with no decryption capability; nothing it produced is reversible with or without it",
	},
}

// ClearedCacheNames returns the sorted names of caches a per-subject erasure clears.
func ClearedCacheNames() []string {
	var out []string
	for _, c := range CacheRegistry {
		if c.Cleared {
			out = append(out, string(c.Name))
		}
	}
	sort.Strings(out)
	return out
}

// PlaintextDEKCache holds unwrapped per-subject data keys.
//
// The design constraint that shapes it: erasure must be able to ASSERT the cache is empty for a
// subject afterwards, not assume eviction happened. So the type exposes Len and SubjectKeys rather
// than being an opaque sync.Map, and Purge returns a count the saga checks against a re-read.
//
// "Assert emptiness" is doing real work here. A Purge that silently matched zero entries — wrong key
// format, wrong scoping, a typo in the composite key — looks identical to a Purge that correctly
// evicted everything, and the second read is the only thing that distinguishes them.
type PlaintextDEKCache struct {
	mu      sync.RWMutex
	entries map[string][]byte
}

// NewPlaintextDEKCache constructs an empty cache.
func NewPlaintextDEKCache() *PlaintextDEKCache {
	return &PlaintextDEKCache{entries: make(map[string][]byte)}
}

// cacheKey is the composite key. The separator is NUL so a tenant or pseudonym containing the
// separator cannot forge another entry's key.
func cacheKey(s KeyScope) string {
	return fmt.Sprintf("%s\x00%s\x00%d\x00%d", s.TenantID, s.SubjectPseudonym, s.KeyEpoch, s.KeyVersion)
}

// subjectPrefix is the prefix every version of one subject's entries shares.
func subjectPrefix(tenantID, pseudonym string) string {
	return fmt.Sprintf("%s\x00%s\x00", tenantID, pseudonym)
}

// Put stores a plaintext DEK. The slice is copied, so a caller zeroing its own buffer does not
// silently blank the cache entry — which would make a later emptiness assertion pass for the wrong
// reason.
func (c *PlaintextDEKCache) Put(scope KeyScope, dek []byte) {
	cp := make([]byte, len(dek))
	copy(cp, dek)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[cacheKey(scope)] = cp
}

// Get returns a copy of the cached DEK, if present.
func (c *PlaintextDEKCache) Get(scope KeyScope) ([]byte, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	v, ok := c.entries[cacheKey(scope)]
	if !ok {
		return nil, false
	}
	out := make([]byte, len(v))
	copy(out, v)
	return out, true
}

// Len returns the total number of cached entries.
func (c *PlaintextDEKCache) Len() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries)
}

// SubjectKeys returns the sorted composite keys cached for one subject. It is what makes the saga's
// post-purge emptiness assertion a real probe instead of a hope.
func (c *PlaintextDEKCache) SubjectKeys(tenantID, pseudonym string) []string {
	prefix := subjectPrefix(tenantID, pseudonym)
	c.mu.RLock()
	defer c.mu.RUnlock()
	var out []string
	for k := range c.entries {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// PurgeSubject removes every cached version for one subject and returns how many entries went.
//
// Each plaintext DEK is zeroed before its reference is dropped. That is best-effort — see Zero — but
// the alternative is leaving live key material for the garbage collector to hand to whatever
// allocates next.
func (c *PlaintextDEKCache) PurgeSubject(tenantID, pseudonym string) int {
	prefix := subjectPrefix(tenantID, pseudonym)
	c.mu.Lock()
	defer c.mu.Unlock()
	removed := 0
	for k, v := range c.entries {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			Zero(v)
			delete(c.entries, k)
			removed++
		}
	}
	return removed
}
