// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// TestEndToEndAttestedAuthorizationChain_FullPipeline tests the complete chain:
// Signal Ingestion -> Deterministic Resolution -> Attestation -> Who-Authorized Query.
// Asserts all 7 hops are populated with non-empty values and complete==true.
func TestEndToEndAttestedAuthorizationChain_FullPipeline(t *testing.T) {
	os.Setenv("LC_ALL", "C")
	os.Setenv("LANG", "C")

	ctx := context.Background()
	baseTime := time.Date(2026, 9, 5, 14, 0, 0, 0, time.UTC)
	t0 := baseTime
	t1 := t0.Add(1 * time.Hour)
	t2 := t0.Add(2 * time.Hour)

	// 1. Initialize Ingest Store & Identity Graph Repository
	memStore := store.NewMemoryStore()
	identityRepo := identity.NewMemoryRepository()
	graphStore := identity.NewGraphResolverStore(identityRepo)

	// 2. Set up identity graph delegations
	// Delegate: agent-cardvault-0 (SPIFFE: spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa)
	// Principal: secops-lead@controlplane.io
	agentActorID := "actor-cardvault-lead"
	principalEmail := "secops-lead@controlplane.io"
	spiffeID := "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa"

	err := identityRepo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   agentActorID,
		Status:    model.ActorActionable,
		CreatedAt: t0,
		UpdatedAt: t0,
	})
	if err != nil {
		t.Fatalf("failed to create agent actor in identity repo: %v", err)
	}

	err = identityRepo.AddAlias(ctx, identity.AliasRecord{
		ActorID:      agentActorID,
		AliasType:    "spiffe",
		AliasValue:   spiffeID,
		EdgeFidelity: model.FidelityDefinitive,
		ValidFrom:    t0,
		ValidTo:      &t2,
		CreatedAt:    t0,
	})
	if err != nil {
		t.Fatalf("failed to add spiffe alias: %v", err)
	}

	err = identityRepo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  agentActorID,
		PrincipalActorID: principalEmail,
		AuthzRef:         "supercred-policy-grant-998",
		ValidFrom:        t0,
		ValidTo:          &t2,
		CreatedAt:        t0,
	})
	if err != nil {
		t.Fatalf("failed to add delegation record: %v", err)
	}

	// 3. Ingest multi-layer observations
	observations := []model.Observation{
		{
			ID:             "obs-k8s-audit-001",
			Timestamp:      t0.Add(10 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			ActorHint:      spiffeID,
			PrincipalID:    principalEmail,
			RawEvidenceRef: "k8s-audit://clusters/osramp/namespaces/fe-signalloom-agents/secrets/cardvault-root",
			Confidence:     0.95,
			Description:    "Read sensitive secret under delegation",
			Labels: map[string]string{
				"action":    "secrets.get",
				"namespace": "fe-signalloom-agents",
			},
		},
		{
			ID:             "obs-openbao-audit-002",
			Timestamp:      t0.Add(12 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "openbao-audit",
			ActorHint:      spiffeID,
			PrincipalID:    principalEmail,
			RawEvidenceRef: "openbao://transit/keys/decrypt-customer-card",
			Confidence:     0.98,
			Description:    "Transit decryption token exchange",
			Labels: map[string]string{
				"action": "transit.decrypt",
			},
		},
		{
			ID:             "obs-sentinel-ebpf-003",
			Timestamp:      t0.Add(15 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelityStrong,
			Source:         "sentinel.ebpf.flow",
			ActorHint:      spiffeID,
			RawEvidenceRef: "ebpf://flow/cgroup/984603/seq/4401",
			Confidence:     0.92,
			Description:    "Outbound egress to payment gateway",
			Labels: map[string]string{
				"dst_port": "443",
			},
		},
	}

	if err := memStore.Append(ctx, observations); err != nil {
		t.Fatalf("failed to append observations to store: %v", err)
	}

	// 4. Run Deterministic Correlation & Identity Resolution Engine
	engine, err := correlation.NewEngineWithVerifier(memStore, correlation.TrustedCollectorAdapter{})
	if err != nil {
		t.Fatalf("failed to initialize correlation engine: %v", err)
	}

	actors, err := engine.Correlate(ctx)
	if err != nil {
		t.Fatalf("correlation failed: %v", err)
	}
	if len(actors) == 0 {
		t.Fatalf("expected at least 1 correlated actor, got 0")
	}

	targetActor := actors[0]
	t.Logf("Resolved actor: ID=%s, Status=%v, Confidence=%.2f, Aliases=%v, EvidenceCount=%d",
		targetActor.ID, targetActor.Status, targetActor.Confidence, targetActor.Aliases, len(targetActor.EvidenceChain))

	// Ensure the identity graph repository has the resolved actor record mapped
	_ = identityRepo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   targetActor.ID,
		Status:    targetActor.Status,
		CreatedAt: t0,
		UpdatedAt: t1,
	})
	_ = identityRepo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  targetActor.ID,
		PrincipalActorID: principalEmail,
		AuthzRef:         "supercred-policy-grant-998",
		ValidFrom:        t0,
		ValidTo:          &t2,
		CreatedAt:        t0,
	})

	// 5. Wire API Handlers with Engine, Store, and Identity Graph
	handlers := &api.Handlers{
		Engine:        engine,
		Store:         memStore,
		IdentityStore: graphStore,
	}
	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux)

	// 6. Test Single Actor Authorization Endpoint: GET /api/v1/actors/{id}/authorization
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/"+targetActor.ID+"/authorization?action=secrets.get", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/actors/{id}/authorization returned status %d: %s", w.Code, w.Body.String())
	}

	var chain api.AuthorizationChainResponse
	if err := json.NewDecoder(w.Body).Decode(&chain); err != nil {
		t.Fatalf("failed to decode authorization response: %v", err)
	}

	// 7. Rigorous Hop-by-Hop Assertions (No Stubbed Hops)
	t.Logf("=== 7-HOP ATTESTED AUTHORIZATION CHAIN ===")
	t.Logf("Hop 1 (Action):              %s", chain.Action)
	t.Logf("Hop 2 (Agent Identity):      %s", chain.AgentIdentity)
	t.Logf("Hop 3 (Acts On Behalf Of):   %s", chain.ActsOnBehalfOf)
	t.Logf("Hop 4 (Principal):           %s", chain.Principal)
	t.Logf("Hop 5 (Decision):            %s", chain.Decision)
	t.Logf("Hop 6 (Confidence):          %.4f", chain.Confidence)
	t.Logf("Hop 6 (Evidence Refs):       %v", chain.EvidenceRefs)
	t.Logf("Hop 7 (Attestation GitOID):  %s", chain.AttestationGitoid)
	t.Logf("Completeness Status:         %v", chain.Complete)
	t.Logf("==========================================")

	if chain.Action == "" {
		t.Errorf("Hop 1 (Action) must not be empty")
	}
	if chain.AgentIdentity == "" {
		t.Errorf("Hop 2 (Agent Identity) must not be empty")
	}
	if chain.ActsOnBehalfOf == "" {
		t.Errorf("Hop 3 (Acts On Behalf Of) must not be empty")
	}
	if chain.Principal != principalEmail {
		t.Errorf("Hop 4 (Principal) want %q, got %q", principalEmail, chain.Principal)
	}
	if chain.Decision == "" {
		t.Errorf("Hop 5 (Decision) must not be empty")
	}
	if chain.Confidence <= 0 {
		t.Errorf("Hop 6 (Confidence) must be > 0, got %f", chain.Confidence)
	}
	if len(chain.EvidenceRefs) < 2 {
		t.Errorf("Hop 6 (Evidence Refs) expected >= 2 references from ingested observation, got %d (%v)",
			len(chain.EvidenceRefs), chain.EvidenceRefs)
	}
	if len(chain.AttestationGitoid) != 64 {
		t.Errorf("Hop 7 (Attestation GitOID) must be 64-char sha256 hex string, got %q (len %d)",
			chain.AttestationGitoid, len(chain.AttestationGitoid))
	}
	if !chain.Complete {
		t.Errorf("Authorization chain must be Complete=true when all hops are valid")
	}

	// 8. Test Estate-Wide Authorization Query Endpoint: GET /api/v1/authorization
	estateReq := httptest.NewRequest(http.MethodGet, "/api/v1/authorization", nil)
	estateW := httptest.NewRecorder()
	mux.ServeHTTP(estateW, estateReq)

	if estateW.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/authorization returned status %d: %s", estateW.Code, estateW.Body.String())
	}

	var estateResp api.AuthorizationQueryResponse
	if err := json.NewDecoder(estateW.Body).Decode(&estateResp); err != nil {
		t.Fatalf("failed to decode estate query response: %v", err)
	}

	if estateResp.Total == 0 {
		t.Errorf("Estate query Total must be > 0, got 0")
	}
	if estateResp.CompleteCount == 0 {
		t.Errorf("Estate query CompleteCount must be > 0, got 0")
	}
	if estateResp.KPIFraction < 1.0 {
		t.Errorf("Expected 100%% complete KPI for this pipeline test, got %.2f", estateResp.KPIFraction)
	}
}

// TestEndToEndAttestedAuthorizationChain_SeededEstate_KPI asserts that the full
// demo estate seeded via SeedAll achieves >= 90% Complete Attested Chains KPI.
func TestEndToEndAttestedAuthorizationChain_SeededEstate_KPI(t *testing.T) {
	os.Setenv("LC_ALL", "C")
	os.Setenv("LANG", "C")

	ctx := context.Background()
	baseTime := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	memStore := store.NewMemoryStore()
	identityRepo := identity.NewMemoryRepository()
	graphStore := identity.NewGraphResolverStore(identityRepo)

	// Seed all demo estate observations
	obs := collectors.SeedAll(baseTime)
	if err := memStore.Append(ctx, obs); err != nil {
		t.Fatalf("failed to append SeedAll observations: %v", err)
	}

	engine, err := correlation.NewEngineWithVerifier(memStore, correlation.TrustedCollectorAdapter{})
	if err != nil {
		t.Fatalf("failed to init correlation engine: %v", err)
	}

	actors, err := engine.Correlate(ctx)
	if err != nil {
		t.Fatalf("correlation error: %v", err)
	}
	if len(actors) == 0 {
		t.Fatalf("expected correlated actors from SeedAll")
	}

	handlers := &api.Handlers{
		Engine:        engine,
		Store:         memStore,
		IdentityStore: graphStore,
	}
	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp api.AuthorizationQueryResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	t.Logf("Seeded Estate Authorization Query: Total=%d, Complete=%d, KPI=%.2f%%",
		resp.Total, resp.CompleteCount, resp.KPIFraction*100)

	if resp.KPIFraction < 0.90 {
		t.Fatalf("KPI requirement violated: want KPI fraction >= 0.90 (>=90%%), got %.4f (%d/%d complete)",
			resp.KPIFraction, resp.CompleteCount, resp.Total)
	}

	for _, chain := range resp.Chains {
		if chain.Complete {
			if chain.AgentIdentity == "" || chain.ActsOnBehalfOf == "" || chain.Principal == "" ||
				chain.Decision == "" || chain.Confidence <= 0 || len(chain.EvidenceRefs) == 0 ||
				len(chain.AttestationGitoid) != 64 {
				t.Errorf("Complete chain has incomplete fields: %+v", chain)
			}
			if !strings.HasPrefix(chain.Decision, "authorized:") && !strings.HasPrefix(chain.Decision, "evaluated:") {
				t.Errorf("Unexpected decision value: %q", chain.Decision)
			}
		}
	}
}
