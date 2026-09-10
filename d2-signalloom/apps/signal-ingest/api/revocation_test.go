package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestAuthorizationQueryRevoked(t *testing.T) {
	h, mux := newTestHandlers(t)
	identityRepo := identity.NewMemoryRepository()
	bus := identity.NewInProcessEventBus()
	stunMock := identity.NewMockStunSentinelClient()

	h.IdentityStore = identityRepo
	h.EventBus = bus
	h.StunClient = stunMock

	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	t0 := now.Add(-30 * time.Minute)
	tRevoke := now.Add(-5 * time.Minute)
	tAfter := now

	// 1. Setup Actor and Delegation in identity graph
	_ = identityRepo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID:   "agent-cardvault-sa",
		Status:    model.ActorActionable,
		CreatedAt: t0,
		UpdatedAt: t0,
	})
	_ = identityRepo.AddAlias(context.Background(), identity.AliasRecord{
		ActorID:    "agent-cardvault-sa",
		AliasType:  "spiffe",
		AliasValue: "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		ValidFrom:  t0,
	})
	_ = identityRepo.AddDelegation(context.Background(), identity.DelegationRecord{
		DelegateActorID:  "agent-cardvault-sa",
		PrincipalActorID: "secops-lead@controlplane.io",
		AuthzRef:         "supercred-policy-grant-998",
		ValidFrom:        t0,
		CreatedAt:        t0,
	})

	// Add observation to signal store for rich 7-hop resolution
	obs := []model.Observation{
		{
			ID:             "obs-k8s-audit-001",
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			ActorHint:      "agent-cardvault-sa",
			PrincipalID:    "secops-lead@controlplane.io",
			RawEvidenceRef: "k8s-audit://clusters/osramp/namespaces/fe-signalloom-agents/secrets/cardvault-root",
			Confidence:     0.95,
			Timestamp:      t0,
			Description:    "secrets.get",
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
		t.Fatal("expected correlated actors")
	}

	targetActorID := actors[0].ID

	// 2. Query authorization before revocation (as of t0 + 10m): must return 200 OK with authorized decision
	reqBefore := httptest.NewRequest(http.MethodGet, "/api/v1/actors/"+targetActorID+"/authorization?as_of="+t0.Add(10*time.Minute).Format(time.RFC3339), nil)
	wBefore := httptest.NewRecorder()
	mux.ServeHTTP(wBefore, reqBefore)

	if wBefore.Code != http.StatusOK {
		t.Fatalf("want 200 OK before revocation, got %d (body: %s)", wBefore.Code, wBefore.Body.String())
	}
	var respBefore AuthorizationChainResponse
	if err := json.Unmarshal(wBefore.Body.Bytes(), &respBefore); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if !respBefore.Complete {
		t.Errorf("expected complete authorization chain before revocation, got false")
	}
	if strings.HasPrefix(respBefore.Decision, "REVOKED") {
		t.Errorf("expected non-revoked decision before revocation, got %s", respBefore.Decision)
	}

	// 3. Trigger revocation via POST /api/v1/delegations/revoke
	startRevoke := time.Now()
	revokePayload := RevokeDelegationRequest{
		ActorID:   "agent-cardvault-sa",
		AgentIP:   "10.244.0.42",
		Reason:    "stun execution halt triggered by sentinel",
		RevokedAt: &tRevoke,
	}
	bodyBytes, _ := json.Marshal(revokePayload)
	reqRevoke := httptest.NewRequest(http.MethodPost, "/api/v1/delegations/revoke", bytes.NewReader(bodyBytes))
	reqRevoke.Header.Set("Content-Type", "application/json")
	wRevoke := httptest.NewRecorder()
	mux.ServeHTTP(wRevoke, reqRevoke)

	revokeElapsed := time.Since(startRevoke)
	if wRevoke.Code != http.StatusOK {
		t.Fatalf("want 200 OK for revocation, got %d (body: %s)", wRevoke.Code, wRevoke.Body.String())
	}
	if revokeElapsed >= 50*time.Millisecond {
		t.Errorf("revocation HTTP call took %v, exceeding sub-50ms constraint", revokeElapsed)
	}

	var revokeResp map[string]any
	if err := json.Unmarshal(wRevoke.Body.Bytes(), &revokeResp); err != nil {
		t.Fatalf("failed to unmarshal revocation response: %v", err)
	}
	if revokeResp["status"] != "revoked" {
		t.Errorf("expected status 'revoked', got %v", revokeResp["status"])
	}

	// 4. Query authorization after revocation (as of tAfter / now): must return HTTP 403 Forbidden with REVOKED badge
	startQuery := time.Now()
	reqAfter := httptest.NewRequest(http.MethodGet, "/api/v1/actors/"+targetActorID+"/authorization?as_of="+tAfter.Format(time.RFC3339), nil)
	wAfter := httptest.NewRecorder()
	mux.ServeHTTP(wAfter, reqAfter)

	queryElapsed := time.Since(startQuery)
	if queryElapsed >= 50*time.Millisecond {
		t.Errorf("authorization query took %v, exceeding sub-50ms constraint", queryElapsed)
	}

	if wAfter.Code != http.StatusForbidden {
		t.Fatalf("want 403 Forbidden after revocation, got %d (body: %s)", wAfter.Code, wAfter.Body.String())
	}
	if statusHeader := wAfter.Header().Get("X-Authorization-Status"); statusHeader != "REVOKED" {
		t.Errorf("expected X-Authorization-Status 'REVOKED', got %s", statusHeader)
	}

	var respAfter AuthorizationChainResponse
	if err := json.Unmarshal(wAfter.Body.Bytes(), &respAfter); err != nil {
		t.Fatalf("failed to decode post-revocation response: %v", err)
	}
	if respAfter.Decision != "REVOKED" {
		t.Errorf("expected decision 'REVOKED', got %s", respAfter.Decision)
	}
	if respAfter.Complete {
		t.Errorf("expected complete=false on revoked chain, got true")
	}

	// 5. Query authorization query endpoint /api/v1/authorization?actor_id=... after revocation
	reqQuery := httptest.NewRequest(http.MethodGet, "/api/v1/authorization?actor_id="+targetActorID, nil)
	wQuery := httptest.NewRecorder()
	mux.ServeHTTP(wQuery, reqQuery)

	if wQuery.Code != http.StatusForbidden {
		t.Fatalf("want 403 Forbidden on /api/v1/authorization?actor_id=..., got %d", wQuery.Code)
	}

	// 6. Verify historical query as-of t0 + 10m STILL returns 200 OK (temporal audit immutability)
	reqHist := httptest.NewRequest(http.MethodGet, "/api/v1/actors/"+targetActorID+"/authorization?as_of="+t0.Add(10*time.Minute).Format(time.RFC3339), nil)
	wHist := httptest.NewRecorder()
	mux.ServeHTTP(wHist, reqHist)

	if wHist.Code != http.StatusOK {
		t.Fatalf("want 200 OK for historical as_of query, got %d (body: %s)", wHist.Code, wHist.Body.String())
	}
}

func TestRevokeDelegationEndpoint_InvalidPayload(t *testing.T) {
	h, mux := newTestHandlers(t)
	identityRepo := identity.NewMemoryRepository()
	h.IdentityStore = identityRepo

	// Missing identifier should return 400
	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations/revoke", bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("want 400 Bad Request for empty body, got %d", w.Code)
	}

	// Unknown delegation ID gracefully returns 200 with status revoked and 0 rows updated
	reqInvalid := httptest.NewRequest(http.MethodPost, "/api/v1/delegations/revoke", bytes.NewReader([]byte(`{"delegation_id":"invalid"}`)))
	reqInvalid.Header.Set("Content-Type", "application/json")
	wInvalid := httptest.NewRecorder()
	mux.ServeHTTP(wInvalid, reqInvalid)

	if wInvalid.Code != http.StatusOK {
		t.Errorf("want 200 OK for invalid delegation_id, got %d (body: %s)", wInvalid.Code, wInvalid.Body.String())
	}
}

func TestEndToEndRevocationDispatch_Sub500ms(t *testing.T) {
	h, mux := newTestHandlers(t)
	identityRepo := identity.NewMemoryRepository()
	stunMock := identity.NewMockStunSentinelClient()

	h.IdentityStore = identityRepo
	h.StunClient = stunMock

	now := time.Now().UTC()
	_ = identityRepo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID:   "agent-speed-test",
		Status:    model.ActorActionable,
		CreatedAt: now.Add(-time.Hour),
	})
	_ = identityRepo.AddDelegation(context.Background(), identity.DelegationRecord{
		DelegateActorID:  "agent-speed-test",
		PrincipalActorID: "operator@controlplane.io",
		AuthzRef:         "authz-latency-benchmark",
		ValidFrom:        now.Add(-time.Hour),
	})

	// Benchmark 100 end-to-end API revocation calls to Stun Sentinel trigger
	var maxDuration time.Duration
	var totalDuration time.Duration
	iterations := 100

	for i := 0; i < iterations; i++ {
		start := time.Now()
		req := RevokeDelegationRequest{
			ActorID: "agent-speed-test",
			AgentIP: "10.244.0.55",
			Reason:  "stun containment trigger benchmark",
		}
		bodyBytes, _ := json.Marshal(req)
		httpReq := httptest.NewRequest(http.MethodPost, "/api/v1/delegations/revoke", bytes.NewReader(bodyBytes))
		httpReq.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httpReq)

		dur := time.Since(start)
		totalDuration += dur
		if dur > maxDuration {
			maxDuration = dur
		}

		if w.Code != http.StatusOK {
			t.Fatalf("iteration %d failed with code %d", i, w.Code)
		}
	}

	avgDuration := totalDuration / time.Duration(iterations)
	t.Logf("End-to-end Revocation Dispatch: %d iterations, avg=%v, max=%v (threshold <= 500ms)", iterations, avgDuration, maxDuration)

	if maxDuration > 500*time.Millisecond {
		t.Errorf("max revocation latency %v exceeded 500ms threshold", maxDuration)
	}
}

func BenchmarkRevocationDispatch(b *testing.B) {
	h, mux := newTestHandlers(b)
	identityRepo := identity.NewMemoryRepository()
	stunMock := identity.NewMockStunSentinelClient()

	h.IdentityStore = identityRepo
	h.StunClient = stunMock

	now := time.Now().UTC()
	_ = identityRepo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID:   "agent-bench-agent",
		Status:    model.ActorActionable,
		CreatedAt: now.Add(-time.Hour),
	})
	_ = identityRepo.AddDelegation(context.Background(), identity.DelegationRecord{
		DelegateActorID:  "agent-bench-agent",
		PrincipalActorID: "operator@controlplane.io",
		AuthzRef:         "authz-bench",
		ValidFrom:        now.Add(-time.Hour),
	})

	req := RevokeDelegationRequest{
		ActorID: "agent-bench-agent",
		AgentIP: "10.244.0.55",
		Reason:  "stun benchmark",
	}
	bodyBytes, _ := json.Marshal(req)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		httpReq := httptest.NewRequest(http.MethodPost, "/api/v1/delegations/revoke", bytes.NewReader(bodyBytes))
		httpReq.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httpReq)
	}
}
