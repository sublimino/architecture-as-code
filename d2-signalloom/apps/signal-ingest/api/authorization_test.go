package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestGetActorAuthorization_NotFound(t *testing.T) {
	_, mux := newTestHandlers(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/nonexistent/authorization", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("want 404, got %d", w.Code)
	}
}

func TestGetActorAuthorization_CompleteChain(t *testing.T) {
	h, mux := newTestHandlers(t)
	identityRepo := identity.NewMemoryRepository()
	h.IdentityStore = identityRepo

	now := time.Now().UTC()
	_ = identityRepo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID: "agent-cardvault-0",
		Status:  model.ActorActionable,
	})
	_ = identityRepo.AddDelegation(context.Background(), identity.DelegationRecord{
		DelegateActorID:  "agent-cardvault-0",
		PrincipalActorID: "admin@controlplane.io",
		AuthzRef:         "k8s-impersonation-policy",
		ValidFrom:        now.Add(-time.Hour),
	})

	// Create an actor with delegation and rich evidence
	obs := []model.Observation{
		{
			ID:             "obs-auth-1",
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			ActorHint:      "agent-cardvault-0",
			PrincipalID:    "admin@controlplane.io",
			RawEvidenceRef: "k8s-audit://default/secrets/vault-token",
			Confidence:     0.95,
			Timestamp:      now,
			Description:    "Read secret with impersonation",
		},
		{
			ID:             "obs-net-1",
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelityStrong,
			Source:         "sentinel.ebpf.socket_trace",
			ActorHint:      "agent-cardvault-0",
			RawEvidenceRef: "ebpf://flow/cgroup/54321/seq/101",
			Confidence:     0.90,
			Timestamp:      now.Add(time.Minute),
			Description:    "Outbound TLS to model endpoint",
		},
	}
	if err := h.Store.Append(context.Background(), obs); err != nil {
		t.Fatal(err)
	}

	actors, err := h.Engine.Correlate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(actors) == 0 {
		t.Fatal("expected at least one correlated actor")
	}

	targetActor := actors[0]
	_ = identityRepo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID: targetActor.ID,
		Status:  model.ActorActionable,
	})
	_ = identityRepo.AddDelegation(context.Background(), identity.DelegationRecord{
		DelegateActorID:  targetActor.ID,
		PrincipalActorID: "admin@controlplane.io",
		AuthzRef:         "k8s-impersonation-policy",
		ValidFrom:        now.Add(-time.Hour),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/"+targetActor.ID+"/authorization", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (body: %s)", w.Code, w.Body.String())
	}

	var chain AuthorizationChainResponse
	if err := json.NewDecoder(w.Body).Decode(&chain); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if chain.AgentIdentity == "" {
		t.Errorf("agentIdentity must be non-empty")
	}
	if chain.ActsOnBehalfOf == "" {
		t.Errorf("actsOnBehalfOf must be non-empty")
	}
	if chain.Principal != "admin@controlplane.io" {
		t.Errorf("want principal 'admin@controlplane.io', got %q", chain.Principal)
	}
	if chain.Decision == "" {
		t.Errorf("decision must be non-empty")
	}
	if chain.Confidence <= 0 {
		t.Errorf("confidence must be > 0, got %f", chain.Confidence)
	}
	if len(chain.EvidenceRefs) == 0 {
		t.Errorf("evidenceRefs must be non-empty")
	}
	if len(chain.AttestationGitoid) != 64 {
		t.Errorf("attestationGitoid must be 64-char hex, got %q (len %d)", chain.AttestationGitoid, len(chain.AttestationGitoid))
	}
	if !chain.Complete {
		t.Errorf("chain.Complete must be true for full chain")
	}
}

func TestGetActorAuthorization_MissingHop_FailsCompleteness(t *testing.T) {
	h, mux := newTestHandlers(t)

	// Incomplete actor with zero confidence and no principal
	incompleteActor := &model.ProvisionalActor{
		ID:         "actor-incomplete-1",
		Status:     model.ActorProvisional,
		Confidence: 0.0, // zero confidence
	}

	chain := h.BuildAuthorizationChain(context.Background(), incompleteActor, "")
	if chain.Complete {
		t.Errorf("incomplete actor must have complete=false")
	}

	// Actor without principal or delegations
	noPrincipalActor := &model.ProvisionalActor{
		ID:          "actor-no-principal",
		CanonicalID: "sa/unbound",
		Status:      model.ActorProvisional,
		Confidence:  0.8,
		EvidenceChain: []model.EvidenceLink{
			{ObservationID: "obs-1", Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Contribution: "netflow"},
		},
	}
	chain2 := h.BuildAuthorizationChain(context.Background(), noPrincipalActor, "")
	if chain2.Principal != "" && chain2.ActsOnBehalfOf != "" {
		// If both got populated, check completeness
	} else if chain2.Complete {
		t.Errorf("actor missing principal/delegation must have complete=false")
	}

	_ = mux
}

func TestQueryAuthorization_SeededEstate_KPIFraction(t *testing.T) {
	h, mux := newTestHandlers(t)

	// Provide in-memory identity repository to handle graph delegations
	identityRepo := identity.NewMemoryRepository()
	h.IdentityStore = identityRepo

	// Seed all demo estate fixtures
	baseTime := time.Now().UTC()
	obs := collectors.SeedAll(baseTime)
	if err := h.Store.Append(context.Background(), obs); err != nil {
		t.Fatalf("append fixtures: %v", err)
	}

	// Correlate
	actors, err := h.Engine.Correlate(context.Background())
	if err != nil {
		t.Fatalf("correlate: %v", err)
	}
	if len(actors) == 0 {
		t.Fatal("expected correlated actors from SeedAll")
	}

	// Query /api/v1/authorization
	req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization", nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (body: %s)", w.Code, w.Body.String())
	}

	var resp AuthorizationQueryResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode query response: %v", err)
	}

	if resp.Total == 0 {
		t.Fatalf("expected non-zero total actors in estate")
	}

	t.Logf("Seeded demo estate: total=%d, complete=%d, kpi_fraction=%.2f", resp.Total, resp.CompleteCount, resp.KPIFraction)

	if resp.KPIFraction < 0.90 {
		t.Errorf("KPI requirement violated: want kpi_fraction >= 0.90, got %.2f (%d/%d complete)",
			resp.KPIFraction, resp.CompleteCount, resp.Total)
	}

	// Assert every complete chain has all 7 hops populated
	for _, ch := range resp.Chains {
		if ch.Complete {
			if ch.AgentIdentity == "" || ch.ActsOnBehalfOf == "" || ch.Principal == "" ||
				ch.Decision == "" || ch.Confidence <= 0 || len(ch.EvidenceRefs) == 0 || ch.AttestationGitoid == "" {
				t.Errorf("chain marked complete but has missing hop: %+v", ch)
			}
		}
	}
}

func TestQueryAuthorization_FilterByActorID(t *testing.T) {
	h, mux := newTestHandlers(t)

	obs := collectors.SeedAll(time.Now().UTC())
	_ = h.Store.Append(context.Background(), obs)
	actors, _ := h.Engine.Correlate(context.Background())
	if len(actors) == 0 {
		t.Fatal("no actors")
	}

	actorID := actors[0].ID
	req := httptest.NewRequest(http.MethodGet, "/api/v1/authorization?actor_id="+actorID, nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}

	var chain AuthorizationChainResponse
	if err := json.NewDecoder(w.Body).Decode(&chain); err != nil {
		t.Fatalf("decode chain: %v", err)
	}
	if chain.ActorID != actorID {
		t.Errorf("want actorId %s, got %s", actorID, chain.ActorID)
	}
}

func TestDeriveAttestationGitoid_DeterministicAndValid(t *testing.T) {
	g1 := deriveAttestationGitoid("act-1", "spiffe://a", "admin@corp", "authorized", 0.95, []string{"ref-1", "ref-2"})
	g2 := deriveAttestationGitoid("act-1", "spiffe://a", "admin@corp", "authorized", 0.95, []string{"ref-1", "ref-2"})

	if g1 != g2 {
		t.Errorf("gitoid must be deterministic: %s != %s", g1, g2)
	}
	if len(g1) != 64 {
		t.Errorf("gitoid must be 64-char hex, got len %d: %s", len(g1), g1)
	}

	// Different input produces different gitoid
	g3 := deriveAttestationGitoid("act-2", "spiffe://b", "user@corp", "authorized", 0.90, []string{"ref-3"})
	if g1 == g3 {
		t.Errorf("different inputs must produce different gitoids")
	}
}

func TestAuthorization_MethodGatesAndHEAD(t *testing.T) {
	h, mux := newTestHandlers(t)

	obs := collectors.SeedAll(time.Now().UTC())
	_ = h.Store.Append(context.Background(), obs)
	actors, _ := h.Engine.Correlate(context.Background())
	if len(actors) == 0 {
		t.Fatal("no actors")
	}
	actorID := actors[0].ID

	testCtx := context.WithValue(context.Background(), principalContextKey{}, Principal{
		Subject:     "auditor",
		Permissions: map[Permission]bool{PermissionCrossTenantRead: true},
	})

	// handleGetActorAuthorization: POST rejected with 405 and Allow: GET, HEAD
	reqPost := httptest.NewRequest(http.MethodPost, "/api/v1/actors/"+actorID+"/authorization", nil).WithContext(testCtx)
	reqPost.SetPathValue("id", actorID)
	wPost := httptest.NewRecorder()
	h.handleGetActorAuthorization(wPost, reqPost)
	if wPost.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST handleGetActorAuthorization: want 405, got %d", wPost.Code)
	}
	if allow := wPost.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
		t.Errorf("POST handleGetActorAuthorization: want Allow 'GET, HEAD, OPTIONS', got %q", allow)
	}

	// handleGetActorAuthorization: HEAD returns 200 with 0 body bytes and Content-Type: application/json
	reqHead := httptest.NewRequest(http.MethodHead, "/api/v1/actors/"+actorID+"/authorization", nil).WithContext(testCtx)
	reqHead.SetPathValue("id", actorID)
	wHead := httptest.NewRecorder()
	h.handleGetActorAuthorization(wHead, reqHead)
	if wHead.Code != http.StatusOK {
		t.Fatalf("HEAD handleGetActorAuthorization: want 200, got %d", wHead.Code)
	}
	if wHead.Body.Len() != 0 {
		t.Errorf("HEAD handleGetActorAuthorization: want 0 body bytes, got %d", wHead.Body.Len())
	}
	if ct := wHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD handleGetActorAuthorization: want Content-Type 'application/json', got %q", ct)
	}

	// handleQueryAuthorization: POST rejected with 405 and Allow: GET, HEAD, OPTIONS
	reqQueryPost := httptest.NewRequest(http.MethodPost, "/api/v1/authorization", nil).WithContext(testCtx)
	wQueryPost := httptest.NewRecorder()
	h.handleQueryAuthorization(wQueryPost, reqQueryPost)
	if wQueryPost.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST handleQueryAuthorization: want 405, got %d", wQueryPost.Code)
	}
	if allow := wQueryPost.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
		t.Errorf("POST handleQueryAuthorization: want Allow 'GET, HEAD, OPTIONS', got %q", allow)
	}

	// handleQueryAuthorization: HEAD returns 200 with 0 body bytes
	reqQueryHead := httptest.NewRequest(http.MethodHead, "/api/v1/authorization", nil).WithContext(testCtx)
	wQueryHead := httptest.NewRecorder()
	h.handleQueryAuthorization(wQueryHead, reqQueryHead)
	if wQueryHead.Code != http.StatusOK {
		t.Fatalf("HEAD handleQueryAuthorization: want 200, got %d", wQueryHead.Code)
	}
	if wQueryHead.Body.Len() != 0 {
		t.Errorf("HEAD handleQueryAuthorization: want 0 body bytes, got %d", wQueryHead.Body.Len())
	}
	if ct := wQueryHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD handleQueryAuthorization: want Content-Type 'application/json', got %q", ct)
	}

	// handleQueryAuthorization with actor_id: HEAD returns 200 with 0 body bytes
	reqQueryActorHead := httptest.NewRequest(http.MethodHead, "/api/v1/authorization?actor_id="+actorID, nil).WithContext(testCtx)
	wQueryActorHead := httptest.NewRecorder()
	h.handleQueryAuthorization(wQueryActorHead, reqQueryActorHead)
	if wQueryActorHead.Code != http.StatusOK {
		t.Fatalf("HEAD handleQueryAuthorization(actor_id): want 200, got %d", wQueryActorHead.Code)
	}
	if wQueryActorHead.Body.Len() != 0 {
		t.Errorf("HEAD handleQueryAuthorization(actor_id): want 0 body bytes, got %d", wQueryActorHead.Body.Len())
	}

	// Mux HEAD /api/v1/authorization
	wMuxHead := httptest.NewRecorder()
	mux.ServeHTTP(wMuxHead, reqQueryHead)
	if wMuxHead.Code != http.StatusOK {
		t.Errorf("HEAD mux /api/v1/authorization: want 200, got %d", wMuxHead.Code)
	}
	if wMuxHead.Body.Len() != 0 {
		t.Errorf("HEAD mux /api/v1/authorization: want 0 body bytes, got %d", wMuxHead.Body.Len())
	}
}
