// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package spirea

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

type mockSink struct {
	mu           sync.Mutex
	observations []*model.Observation
}

func (m *mockSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.observations = append(m.observations, obs)
	return nil
}

func (m *mockSink) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.observations)
}

func TestTracker_RecordAndLookup(t *testing.T) {
	tracker := NewIdentityTracker()
	now := time.Now().UTC()

	event := &SVIDIssuanceEvent{
		Timestamp:      now,
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		TrustDomain:    "cluster.local",
		SVIDType:       SVIDTypeJWT,
		JWTID:          "jwt-uuid-12345",
		IssuedAt:       now,
		ExpiresAt:      now.Add(5 * time.Minute),
		TTLSeconds:     300,
		PodNamespace:   "fe-signalloom-agents",
		ServiceAccount: "agent-cardvault-sa",
	}

	tracker.RecordIssuance(event)

	lease, found := tracker.LookupBySPIFFEID("spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa")
	if !found || lease == nil {
		t.Fatalf("expected to find lease by SPIFFE ID")
	}

	if lease.Namespace != "fe-signalloom-agents" || lease.ServiceAccount != "agent-cardvault-sa" {
		t.Fatalf("unexpected namespace/SA: %s/%s", lease.Namespace, lease.ServiceAccount)
	}

	if lease.AgentRole != "cardvault" {
		t.Fatalf("unexpected role extraction: %s", lease.AgentRole)
	}

	if lease.SAPrincipal != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Fatalf("unexpected SAPrincipal: %s", lease.SAPrincipal)
	}
}

func TestTracker_LookupBySAPrincipal(t *testing.T) {
	tracker := NewIdentityTracker()
	now := time.Now().UTC()

	event := &SVIDIssuanceEvent{
		Timestamp:      now,
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		TrustDomain:    "cluster.local",
		SVIDType:       SVIDTypeJWT,
		IssuedAt:       now,
		ExpiresAt:      now.Add(5 * time.Minute),
		PodNamespace:   "fe-signalloom-agents",
		ServiceAccount: "agent-cardvault-sa",
	}

	tracker.RecordIssuance(event)

	lease, found := tracker.LookupBySAPrincipal("system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa")
	if !found || lease == nil {
		t.Fatalf("expected to find lease by SA principal")
	}

	if lease.SPIFFEID != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Errorf("SPIFFE ID = %s, want spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa", lease.SPIFFEID)
	}

	// Negative lookup
	_, foundMissing := tracker.LookupBySAPrincipal("system:serviceaccount:default:unknown-sa")
	if foundMissing {
		t.Errorf("expected negative lookup to return false")
	}
}

func TestIdentityJoin_SASPIFFEDiscriminator(t *testing.T) {
	tests := []struct {
		name        string
		saPrincipal string
		spiffeID    string
		wantMatch   bool
		wantNS      string
		wantSA      string
	}{
		{
			name:        "exact match standard cluster.local",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   true,
			wantNS:      "fe-signalloom-agents",
			wantSA:      "agent-cardvault-sa",
		},
		{
			name:        "exact match custom domain",
			saPrincipal: "system:serviceaccount:prod-workloads:payment-processor",
			spiffeID:    "spiffe://prod.corp.internal/ns/prod-workloads/sa/payment-processor",
			wantMatch:   true,
			wantNS:      "prod-workloads",
			wantSA:      "payment-processor",
		},
		{
			name:        "mismatched namespace negative",
			saPrincipal: "system:serviceaccount:default:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "mismatched serviceaccount negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:other-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed spiffe missing sa negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents",
			wantMatch:   false,
		},
		{
			name:        "malformed spiffe missing ns negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed spiffe wrong scheme negative",
			saPrincipal: "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "https://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed sa principal missing prefix negative",
			saPrincipal: "fe-signalloom-agents:agent-cardvault-sa",
			spiffeID:    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			wantMatch:   false,
		},
		{
			name:        "malformed sa principal extra colon negative",
			saPrincipal: "system:serviceaccount:a:b:c",
			spiffeID:    "spiffe://cluster.local/ns/a/sa/b",
			wantMatch:   false,
		},
		{
			name:        "empty strings negative",
			saPrincipal: "",
			spiffeID:    "",
			wantMatch:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			match, ns, sa := MatchSAPrincipalAndSPIFFEID(tt.saPrincipal, tt.spiffeID)
			if match != tt.wantMatch {
				t.Errorf("MatchSAPrincipalAndSPIFFEID(%q, %q) = %v, want %v", tt.saPrincipal, tt.spiffeID, match, tt.wantMatch)
			}
			if tt.wantMatch {
				if ns != tt.wantNS {
					t.Errorf("extracted namespace = %q, want %q", ns, tt.wantNS)
				}
				if sa != tt.wantSA {
					t.Errorf("extracted serviceaccount = %q, want %q", sa, tt.wantSA)
				}
			}
		})
	}
}


func TestTracker_BindAccessor(t *testing.T) {
	tracker := NewIdentityTracker()
	now := time.Now().UTC()

	spiffeID := "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa"
	tracker.RecordIssuance(&SVIDIssuanceEvent{
		SPIFFEID:  spiffeID,
		IssuedAt:  now,
		ExpiresAt: now.Add(10 * time.Minute),
	})

	tracker.BindAccessor(spiffeID, "hmac-accessor-999", "secret/data/cardvault/lease-1")

	lease, found := tracker.LookupByAccessor("hmac-accessor-999")
	if !found || lease == nil {
		t.Fatalf("expected to find lease by accessor hash")
	}

	if lease.SPIFFEID != spiffeID {
		t.Fatalf("unexpected SPIFFE ID: %s", lease.SPIFFEID)
	}

	if len(lease.ActiveLeases) != 1 || lease.ActiveLeases[0] != "secret/data/cardvault/lease-1" {
		t.Fatalf("unexpected active leases: %+v", lease.ActiveLeases)
	}
}

func TestTracker_FindAbandonedCredentials(t *testing.T) {
	tracker := NewIdentityTracker()
	past := time.Now().UTC().Add(-10 * time.Minute)

	spiffeID := "spiffe://cluster.local/ns/default/sa/abandoned-agent"
	tracker.RecordIssuance(&SVIDIssuanceEvent{
		SPIFFEID:  spiffeID,
		IssuedAt:  past.Add(-5 * time.Minute),
		ExpiresAt: past, // Expired 10m ago
	})

	tracker.BindAccessor(spiffeID, "acc-abandoned", "secret/data/orphaned-lease")

	now := time.Now().UTC()
	abandoned := tracker.FindAbandonedCredentials(now)
	if len(abandoned) != 1 {
		t.Fatalf("expected 1 abandoned credential, got %d", len(abandoned))
	}

	if abandoned[0].SPIFFEID != spiffeID {
		t.Fatalf("unexpected abandoned ID: %s", abandoned[0].SPIFFEID)
	}
}

func TestCollector_IngestIssuanceEvent(t *testing.T) {
	sink := &mockSink{}
	collector := NewSPIREIssuanceCollector(sink)
	collector.Start()
	defer collector.Stop()

	now := time.Now().UTC()
	event := &SVIDIssuanceEvent{
		Timestamp:      now,
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		TrustDomain:    "cluster.local",
		SVIDType:       SVIDTypeX509,
		SerialNumber:   "01:02:03:04:05:06",
		IssuedAt:       now,
		ExpiresAt:      now.Add(1 * time.Hour),
		TTLSeconds:     3600,
		PodName:        "agent-cardvault-xyz",
		PodNamespace:   "fe-signalloom-agents",
		ServiceAccount: "agent-cardvault-sa",
	}

	if err := collector.IngestIssuanceEvent(context.Background(), event); err != nil {
		t.Fatalf("IngestIssuanceEvent failed: %v", err)
	}

	if sink.Count() != 1 {
		t.Fatalf("expected 1 observation in sink, got %d", sink.Count())
	}

	obs := sink.observations[0]
	if obs.Layer != model.LayerIdentityAuth {
		t.Fatalf("expected LayerIdentityAuth, got %s", obs.Layer)
	}
	if obs.Fidelity != model.FidelityStrong {
		t.Fatalf("expected FidelityStrong, got %s", obs.Fidelity)
	}
	if obs.ActorHint != "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa" {
		t.Fatalf("unexpected actor hint: %s", obs.ActorHint)
	}
	if obs.PrincipalID != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Fatalf("unexpected principal ID: %s", obs.PrincipalID)
	}
	if obs.Labels["sa_principal"] != "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa" {
		t.Fatalf("unexpected sa_principal label: %s", obs.Labels["sa_principal"])
	}
	if obs.Labels["namespace"] != "fe-signalloom-agents" || obs.Labels["service_account"] != "agent-cardvault-sa" {
		t.Fatalf("unexpected ns/sa labels: %s/%s", obs.Labels["namespace"], obs.Labels["service_account"])
	}
}

func TestCollector_ConcurrentRace(t *testing.T) {
	sink := &mockSink{}
	collector := NewSPIREIssuanceCollector(sink)
	collector.Start()
	defer collector.Stop()

	var wg sync.WaitGroup
	var completed uint64

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				spiffe := fmt.Sprintf("spiffe://cluster.local/ns/ns-%d/sa/sa-%d", workerID, j)
				ev := &SVIDIssuanceEvent{
					Timestamp:      time.Now().UTC(),
					SPIFFEID:       spiffe,
					SVIDType:       SVIDTypeJWT,
					IssuedAt:       time.Now().UTC(),
					ExpiresAt:      time.Now().UTC().Add(5 * time.Minute),
					TTLSeconds:     300,
					PodNamespace:   fmt.Sprintf("ns-%d", workerID),
					ServiceAccount: fmt.Sprintf("sa-%d", j),
				}
				_ = collector.IngestIssuanceEvent(context.Background(), ev)
				collector.Tracker().BindAccessor(spiffe, fmt.Sprintf("acc-%d-%d", workerID, j), "lease-1")
				_, _ = collector.Tracker().LookupByAccessor(fmt.Sprintf("acc-%d-%d", workerID, j))
				atomic.AddUint64(&completed, 1)
			}
		}(i)
	}

	wg.Wait()
	if atomic.LoadUint64(&completed) != 1000 {
		t.Fatalf("expected 1000 operations, got %d", completed)
	}
}

func BenchmarkTracker_Lookup(b *testing.B) {
	tracker := NewIdentityTracker()
	spiffe := "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa"
	tracker.RecordIssuance(&SVIDIssuanceEvent{
		SPIFFEID:  spiffe,
		IssuedAt:  time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(10 * time.Minute),
	})
	tracker.BindAccessor(spiffe, "acc-bench", "lease-bench")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = tracker.LookupByAccessor("acc-bench")
	}
}
