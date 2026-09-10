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

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// setupCascadeTestAPI initializes the API test harness with memory store and identity repository.
func setupCascadeTestAPI(t *testing.T) (*http.ServeMux, identity.Repository, store.SignalStore) {
	t.Helper()

	s := store.NewMemoryStore()
	repo := identity.NewMemoryRepository()
	resolverStore := identity.NewGraphResolverStore(repo)
	engine, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatalf("failed to create correlation engine: %v", err)
	}

	// Register root human principal
	now := time.Now().UTC()
	_ = repo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID:   "root-operator@example.com",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "role": "sre", "capabilities": []string{"agent:operate", "logs:read"}},
		CreatedAt: now,
		UpdatedAt: now,
	})

	h := &Handlers{
		Store:         s,
		Engine:        engine,
		IdentityStore: resolverStore,
	}

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	return mux, repo, s
}

// Vector 1: Cascading Impersonation
// An unauthorized agent attempts to claim intermediate borrowed authority in a multi-hop delegation chain.
// Assert that unauthenticated or broken intermediate hops are rejected and authorization chain is marked incomplete (complete: false).
func TestAdversarialCascade_Vector1_CascadingImpersonation(t *testing.T) {
	mux, repo, _ := setupCascadeTestAPI(t)
	ctx := context.Background()
	now := time.Now().UTC()

	// 1. Legitimate hop 1: root-operator delegates to agent-hop-1
	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "agent-hop-1",
		Status:    model.ActorProvisional,
		CreatedAt: now,
		UpdatedAt: now,
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "agent-hop-1",
		PrincipalActorID: "root-operator@example.com",
		AuthzRef:         "claim-legit-hop-1",
		ValidFrom:        now.Add(-1 * time.Hour),
		ValidTo:          nil,
		CreatedAt:        now,
	})

	// 2. Impersonation attempt: unauthorized agent-impersonator-3 claims delegation from an unauthenticated intermediate agent-hop-2
	// Note: agent-hop-2 was never delegated authority by agent-hop-1.
	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "agent-hop-2-unauthorized",
		Status:    model.ActorProvisional,
		CreatedAt: now,
		UpdatedAt: now,
	})
	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "agent-impersonator-3",
		Status:    model.ActorProvisional,
		CreatedAt: now,
		UpdatedAt: now,
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "agent-impersonator-3",
		PrincipalActorID: "agent-hop-2-unauthorized", // broken provenance: not connected to root-operator
		AuthzRef:         "claim-impersonation-forged",
		ValidFrom:        now.Add(-1 * time.Hour),
		ValidTo:          nil,
		CreatedAt:        now,
	})

	// Query authorization for agent-impersonator-3
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/agent-impersonator-3/authorization", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200 with complete=false, got status %d: %s", rec.Code, rec.Body.String())
	}

	var chain AuthorizationChainResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &chain); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if chain.Complete {
		t.Errorf("CRITICAL SECURITY VIOLATION: cascading impersonator was evaluated as complete: true!")
	}
	if chain.Principal == "root-operator@example.com" {
		t.Errorf("CRITICAL SECURITY VIOLATION: impersonator linked to root-operator@example.com!")
	}
}

// Vector 2: Cyclic Delegation loop
// Malicious agents attempt to inject circular delegation chains to induce unbounded recursion.
// Assert cycle detection trips in <5ms and reports cycleDetected or rejects registration.
func TestAdversarialCascade_Vector2_CyclicDelegation(t *testing.T) {
	mux, repo, _ := setupCascadeTestAPI(t)
	ctx := context.Background()
	now := time.Now().UTC()

	// Register cycle participants: A -> B -> C -> A
	nodes := []string{"cycle-node-a", "cycle-node-b", "cycle-node-c"}
	for _, n := range nodes {
		_ = repo.CreateActor(ctx, identity.ActorRecord{
			ActorID:   n,
			Status:    model.ActorProvisional,
			CreatedAt: now,
			UpdatedAt: now,
		})
	}

	// Create A -> B and B -> C
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "cycle-node-b",
		PrincipalActorID: "cycle-node-a",
		AuthzRef:         "del-a-b",
		ValidFrom:        now.Add(-10 * time.Minute),
		CreatedAt:        now,
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "cycle-node-c",
		PrincipalActorID: "cycle-node-b",
		AuthzRef:         "del-b-c",
		ValidFrom:        now.Add(-10 * time.Minute),
		CreatedAt:        now,
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		DelegateActorID:  "cycle-node-a",
		PrincipalActorID: "cycle-node-c", // Closes cycle: A -> B -> C -> A
		AuthzRef:         "del-c-a",
		ValidFrom:        now.Add(-10 * time.Minute),
		CreatedAt:        now,
	})

	// Benchmark cycle query latency (< 5ms SLA)
	start := time.Now()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors/cycle-node-c/authorization", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	elapsed := time.Since(start)

	if elapsed > 5*time.Millisecond {
		t.Fatalf("cycle detection SLA exceeded: took %v (limit: 5ms)", elapsed)
	}

	if rec.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200 query response, got %d: %s", rec.Code, rec.Body.String())
	}

	var chain AuthorizationChainResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &chain); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if !chain.CycleDetected {
		t.Errorf("expected cycleDetected == true, got false")
	}
	if chain.Complete {
		t.Errorf("expected complete == false for cyclic delegation, got true")
	}

	// Also verify reflexive self-delegation attack is rejected immediately at API registration
	selfDelPayload := CreateDelegationRequest{
		DelegateActorID:  "self-delegating-agent",
		PrincipalActorID: "self-delegating-agent",
		AuthzRef:         "claim-reflexive",
		Capabilities:     []string{"agent:operate"},
	}
	body, _ := json.Marshal(selfDelPayload)
	sReq := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	sReq.Header.Set("Content-Type", "application/json")
	sRec := httptest.NewRecorder()
	mux.ServeHTTP(sRec, sReq)

	if sRec.Code == http.StatusCreated {
		t.Fatalf("CRITICAL SECURITY VIOLATION: reflexive self-delegation was allowed (HTTP 201)")
	}
}

// Vector 3: Rapid lease expiry spoofing
// An attacker attempts to create or spoof delegations with valid_to in the past.
// Assert immediate rejection with HTTP 403 / 400 ExpiredLease.
func TestAdversarialCascade_Vector3_RapidLeaseExpiry(t *testing.T) {
	mux, _, _ := setupCascadeTestAPI(t)

	now := time.Now().UTC()
	pastTime := now.Add(-1 * time.Hour)

	expiredPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-expired-lease",
		PrincipalActorID: "root-operator@example.com",
		AuthzRef:         "claim-expired-lease",
		Capabilities:     []string{"agent:operate"},
		ValidFrom:        &pastTime,
		ValidTo:          &pastTime, // valid_to in the past
	}
	body, _ := json.Marshal(expiredPayload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden && rec.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 403 or 400 for expired lease, got %d: %s", rec.Code, rec.Body.String())
	}

	bodyStr := rec.Body.String()
	if !strings.Contains(bodyStr, "ExpiredLease") && !strings.Contains(bodyStr, "expired") && !strings.Contains(bodyStr, "past") {
		t.Errorf("expected rejection reason referencing expired lease, got: %s", bodyStr)
	}
}

// Vector 4: Scope escalation attack
// A sub-agent attempts to request capabilities outside the delegator scope.
// Assert ScopeExceededError with HTTP 403 Forbidden.
func TestAdversarialCascade_Vector4_ScopeEscalation(t *testing.T) {
	mux, repo, _ := setupCascadeTestAPI(t)
	ctx := context.Background()
	now := time.Now().UTC()

	// Create restricted operator with only read:metrics
	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "junior-analyst@example.com",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "capabilities": []string{"read:metrics"}},
		CreatedAt: now,
		UpdatedAt: now,
	})

	escalationPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-privilege-escalator",
		PrincipalActorID: "junior-analyst@example.com",
		AuthzRef:         "claim-escalation-attack",
		Capabilities:     []string{"deploy:production", "cluster:admin", "secret:read"}, // Massive escalation
	}
	body, _ := json.Marshal(escalationPayload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected HTTP 403 on scope escalation attack, got %d: %s", rec.Code, rec.Body.String())
	}

	bodyStr := rec.Body.String()
	if !strings.Contains(bodyStr, "ScopeExceededError") {
		t.Errorf("expected ScopeExceededError in violation response, got: %s", bodyStr)
	}
}

// Vector 5: Forged witness attestation payload
// An attacker attempts to submit a delegation with an invalid or forged witness attestation signature.
// Assert AttestationFailed with HTTP 403 Forbidden.
func TestAdversarialCascade_Vector5_ForgedWitnessAttestation(t *testing.T) {
	mux, _, _ := setupCascadeTestAPI(t)

	forgedPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-forged-signature",
		PrincipalActorID: "root-operator@example.com",
		AuthzRef:         "claim-forged-signature",
		Capabilities:     []string{"agent:operate"},
		Signature:        "forged-signature-corrupted-bytes",
		Metadata: map[string]any{
			"witness_signature": "forged-rsa-signature",
			"attestation_valid": false,
		},
	}
	body, _ := json.Marshal(forgedPayload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected HTTP 403 on forged witness attestation, got %d: %s", rec.Code, rec.Body.String())
	}

	bodyStr := rec.Body.String()
	if !strings.Contains(bodyStr, "AttestationFailed") {
		t.Errorf("expected AttestationFailed in violation response, got: %s", bodyStr)
	}
}
