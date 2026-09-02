// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"sync"
	"time"
)

type tombstoneEntry struct {
	meta      *PodMetadata
	expiredAt time.Time
}

// TombstoneCache preserves cgroup -> Pod mappings for 60 seconds after container termination
// to eliminate attribution races for delayed TCP_CLOSE events.
type TombstoneCache interface {
	Get(cgroupID uint64) (*PodMetadata, bool)
	Put(cgroupID uint64, meta *PodMetadata)
	EvictExpired() int
	Size() int
}

type tombstoneCacheImpl struct {
	mu      sync.RWMutex
	entries map[uint64]tombstoneEntry
	ttl     time.Duration
}

// NewTombstoneCache creates a tombstone cache with the given TTL (defaults to 60s).
func NewTombstoneCache(ttl time.Duration) TombstoneCache {
	if ttl <= 0 {
		ttl = 60 * time.Second
	}
	return &tombstoneCacheImpl{
		entries: make(map[uint64]tombstoneEntry),
		ttl:     ttl,
	}
}

func (c *tombstoneCacheImpl) Get(cgroupID uint64) (*PodMetadata, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	entry, ok := c.entries[cgroupID]
	if !ok {
		return nil, false
	}

	if time.Now().After(entry.expiredAt) {
		return nil, false
	}

	return entry.meta, true
}

func (c *tombstoneCacheImpl) Put(cgroupID uint64, meta *PodMetadata) {
	if meta == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	c.entries[cgroupID] = tombstoneEntry{
		meta:      meta,
		expiredAt: time.Now().Add(c.ttl),
	}
}

func (c *tombstoneCacheImpl) EvictExpired() int {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	evicted := 0
	for k, v := range c.entries {
		if now.After(v.expiredAt) {
			delete(c.entries, k)
			evicted++
		}
	}
	return evicted
}

func (c *tombstoneCacheImpl) Size() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries)
}
