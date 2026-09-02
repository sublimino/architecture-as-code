// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package spirea

import (
	"strings"
	"sync"
	"time"
)

// IdentityTracker maintains thread-safe mappings between SPIFFE IDs and active OpenBao credentials.
type IdentityTracker struct {
	mu           sync.RWMutex
	identities   map[string]*ActiveIdentityLease // keyed by SPIFFEID
	accessorMap  map[string]string               // keyed by AccessorHash -> SPIFFEID
}

// NewIdentityTracker initializes an identity lease tracker.
func NewIdentityTracker() *IdentityTracker {
	return &IdentityTracker{
		identities:  make(map[string]*ActiveIdentityLease),
		accessorMap: make(map[string]string),
	}
}

// RecordIssuance records a newly issued or renewed SPIFFE SVID.
func (it *IdentityTracker) RecordIssuance(event *SVIDIssuanceEvent) {
	if event == nil || event.SPIFFEID == "" {
		return
	}

	it.mu.Lock()
	defer it.mu.Unlock()

	ns := event.PodNamespace
	sa := event.ServiceAccount
	if ns == "" || sa == "" {
		ns, sa = parseSPIFFEID(event.SPIFFEID)
	}

	agentRole := sa
	if strings.HasPrefix(sa, "agent-") {
		agentRole = strings.TrimPrefix(sa, "agent-")
		agentRole = strings.TrimSuffix(agentRole, "-sa")
	}

	lease, exists := it.identities[event.SPIFFEID]
	if !exists {
		lease = &ActiveIdentityLease{
			SPIFFEID:       event.SPIFFEID,
			Namespace:      ns,
			ServiceAccount: sa,
			AgentRole:      agentRole,
			ActiveLeases:   make([]string, 0),
		}
		it.identities[event.SPIFFEID] = lease
	}

	lease.IssuedAt = event.IssuedAt
	lease.ExpiresAt = event.ExpiresAt
	lease.LastActivity = event.Timestamp
}

// BindAccessor associates an OpenBao client token accessor hash with a SPIFFE ID.
func (it *IdentityTracker) BindAccessor(spiffeID, accessorHash, leaseID string) {
	if spiffeID == "" || accessorHash == "" {
		return
	}

	it.mu.Lock()
	defer it.mu.Unlock()

	it.accessorMap[accessorHash] = spiffeID

	if lease, exists := it.identities[spiffeID]; exists {
		lease.AccessorHash = accessorHash
		lease.LastActivity = time.Now().UTC()
		if leaseID != "" {
			lease.ActiveLeases = append(lease.ActiveLeases, leaseID)
		}
	}
}

// LookupByAccessor returns the SPIFFE ID and lease metadata for a given accessor hash.
func (it *IdentityTracker) LookupByAccessor(accessorHash string) (*ActiveIdentityLease, bool) {
	it.mu.RLock()
	defer it.mu.RUnlock()

	spiffeID, found := it.accessorMap[accessorHash]
	if !found {
		return nil, false
	}

	lease, exists := it.identities[spiffeID]
	return lease, exists
}

// LookupBySPIFFEID returns the identity lease metadata for a SPIFFE ID.
func (it *IdentityTracker) LookupBySPIFFEID(spiffeID string) (*ActiveIdentityLease, bool) {
	it.mu.RLock()
	defer it.mu.RUnlock()

	lease, exists := it.identities[spiffeID]
	return lease, exists
}

// FindAbandonedCredentials identifies workloads whose SVID has expired but still possess active OpenBao leases.
func (it *IdentityTracker) FindAbandonedCredentials(now time.Time) []*ActiveIdentityLease {
	it.mu.RLock()
	defer it.mu.RUnlock()

	abandoned := make([]*ActiveIdentityLease, 0)
	for _, lease := range it.identities {
		if !lease.ExpiresAt.IsZero() && now.After(lease.ExpiresAt) && len(lease.ActiveLeases) > 0 {
			abandoned = append(abandoned, lease)
		}
	}
	return abandoned
}

// EvictExpired removes expired identity mappings older than retention duration.
func (it *IdentityTracker) EvictExpired(now time.Time, retention time.Duration) int {
	it.mu.Lock()
	defer it.mu.Unlock()

	evicted := 0
	cutoff := now.Add(-retention)

	for id, lease := range it.identities {
		if !lease.ExpiresAt.IsZero() && lease.ExpiresAt.Before(cutoff) {
			if lease.AccessorHash != "" {
				delete(it.accessorMap, lease.AccessorHash)
			}
			delete(it.identities, id)
			evicted++
		}
	}
	return evicted
}

func parseSPIFFEID(id string) (namespace, serviceAccount string) {
	// spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa
	parts := strings.Split(id, "/")
	for i, p := range parts {
		if p == "ns" && i+1 < len(parts) {
			namespace = parts[i+1]
		}
		if p == "sa" && i+1 < len(parts) {
			serviceAccount = parts[i+1]
		}
	}
	return namespace, serviceAccount
}
