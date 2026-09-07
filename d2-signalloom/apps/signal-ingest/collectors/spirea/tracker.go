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
	saMap        map[string]string               // keyed by SAPrincipal -> SPIFFEID
}

// NewIdentityTracker initializes an identity lease tracker.
func NewIdentityTracker() *IdentityTracker {
	return &IdentityTracker{
		identities:  make(map[string]*ActiveIdentityLease),
		accessorMap: make(map[string]string),
		saMap:       make(map[string]string),
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
		_, parsedNS, parsedSA, ok := ParseSPIFFEID(event.SPIFFEID)
		if ok {
			if ns == "" {
				ns = parsedNS
			}
			if sa == "" {
				sa = parsedSA
			}
		} else {
			ns, sa = parseSPIFFEID(event.SPIFFEID)
		}
	}

	saPrincipal := ""
	if ns != "" && sa != "" {
		saPrincipal = FormatSAPrincipal(ns, sa)
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
			SAPrincipal:    saPrincipal,
			AgentRole:      agentRole,
			ActiveLeases:   make([]string, 0),
		}
		it.identities[event.SPIFFEID] = lease
	}

	lease.Namespace = ns
	lease.ServiceAccount = sa
	lease.SAPrincipal = saPrincipal
	lease.IssuedAt = event.IssuedAt
	lease.ExpiresAt = event.ExpiresAt
	lease.LastActivity = event.Timestamp

	if saPrincipal != "" {
		it.saMap[saPrincipal] = event.SPIFFEID
	}
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

// LookupBySAPrincipal returns the identity lease metadata for a Kubernetes service account principal.
func (it *IdentityTracker) LookupBySAPrincipal(saPrincipal string) (*ActiveIdentityLease, bool) {
	it.mu.RLock()
	defer it.mu.RUnlock()

	spiffeID, found := it.saMap[saPrincipal]
	if !found {
		return nil, false
	}

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
			if lease.SAPrincipal != "" {
				delete(it.saMap, lease.SAPrincipal)
			}
			delete(it.identities, id)
			evicted++
		}
	}
	return evicted
}

// ParseSPIFFEID validates and extracts trust domain, namespace, and service account from a SPIFFE ID.
// Expected canonical format: spiffe://<trust_domain>/ns/<namespace>/sa/<service_account>
func ParseSPIFFEID(id string) (trustDomain, namespace, serviceAccount string, ok bool) {
	if !strings.HasPrefix(id, "spiffe://") {
		return "", "", "", false
	}
	raw := strings.TrimPrefix(id, "spiffe://")
	parts := strings.Split(raw, "/")
	if len(parts) < 5 {
		return "", "", "", false
	}
	trustDomain = parts[0]
	if trustDomain == "" {
		return "", "", "", false
	}

	for i := 1; i < len(parts); i++ {
		if parts[i] == "ns" && i+1 < len(parts) {
			namespace = parts[i+1]
		}
		if parts[i] == "sa" && i+1 < len(parts) {
			serviceAccount = parts[i+1]
		}
	}

	if namespace == "" || serviceAccount == "" {
		return "", "", "", false
	}
	return trustDomain, namespace, serviceAccount, true
}

// ParseSAPrincipal validates and extracts namespace and service account from a Kubernetes SA principal.
// Expected canonical format: system:serviceaccount:<namespace>:<service_account>
func ParseSAPrincipal(principal string) (namespace, serviceAccount string, ok bool) {
	if !strings.HasPrefix(principal, "system:serviceaccount:") {
		return "", "", false
	}
	raw := strings.TrimPrefix(principal, "system:serviceaccount:")
	parts := strings.Split(raw, ":")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

// FormatSAPrincipal formats namespace and service account as a Kubernetes SA principal.
func FormatSAPrincipal(namespace, serviceAccount string) string {
	return "system:serviceaccount:" + namespace + ":" + serviceAccount
}

// FormatSPIFFEID formats trust domain, namespace, and service account as a canonical SPIFFE ID.
func FormatSPIFFEID(trustDomain, namespace, serviceAccount string) string {
	if trustDomain == "" {
		trustDomain = "cluster.local"
	}
	return "spiffe://" + trustDomain + "/ns/" + namespace + "/sa/" + serviceAccount
}

// MatchSAPrincipalAndSPIFFEID asserts exact match/no-match discriminator between an SA principal and SPIFFE ID.
func MatchSAPrincipalAndSPIFFEID(saPrincipal, spiffeID string) (bool, string, string) {
	saNS, saName, saOK := ParseSAPrincipal(saPrincipal)
	if !saOK {
		return false, "", ""
	}
	_, spiffeNS, spiffeSA, spiffeOK := ParseSPIFFEID(spiffeID)
	if !spiffeOK {
		return false, "", ""
	}
	if saNS == spiffeNS && saName == spiffeSA {
		return true, saNS, saName
	}
	return false, "", ""
}

func parseSPIFFEID(id string) (namespace, serviceAccount string) {
	_, ns, sa, ok := ParseSPIFFEID(id)
	if ok {
		return ns, sa
	}
	// Fallback for non-standard path layouts
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

