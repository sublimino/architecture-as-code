package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func setupDelegationsTestServer(t *testing.T) (*http.ServeMux, identity.Repository, store.SignalStore) {
	t.Helper()

	s := store.NewMemoryStore()
	repo := identity.NewMemoryRepository()
	resolverStore := identity.NewGraphResolverStore(repo)
	engine, _ := correlation.NewEngine(s)

	// Pre-seed an operator
	_ = repo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID:   "user@example.com",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "role": "operator", "capabilities": []string{"agent:*", "deploy:staging"}},
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
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

func TestDelegationsEndpoint_InvalidPayload_400(t *testing.T) {
	mux, _, _ := setupDelegationsTestServer(t)

	// Test surface check: POST with {"invalid": "payload"} -> 400 Bad Request
	reqBody := []byte(`{"invalid":"payload"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400 for invalid payload, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDelegationsEndpoint_CreateAndResolveAuthorizationRoundtrip(t *testing.T) {
	mux, _, _ := setupDelegationsTestServer(t)

	// 1. Create delegation for agent-1 claimed by user@example.com
	createPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-1",
		PrincipalActorID: "user@example.com",
		AuthzRef:         "claim-agent-1-seed",
		Capabilities:     []string{"agent:operate"},
	}
	body, _ := json.Marshal(createPayload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected HTTP 201 on create delegation, got %d: %s", rec.Code, rec.Body.String())
	}

	// 2. Query authorization for agent-1: GET /api/v1/actors/agent-1/authorization
	authReq := httptest.NewRequest(http.MethodGet, "/api/v1/actors/agent-1/authorization", nil)
	authRec := httptest.NewRecorder()

	mux.ServeHTTP(authRec, authReq)

	if authRec.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200 on actor authorization query, got %d: %s", authRec.Code, authRec.Body.String())
	}

	var chain AuthorizationChainResponse
	if err := json.Unmarshal(authRec.Body.Bytes(), &chain); err != nil {
		t.Fatalf("failed to decode authorization response: %v", err)
	}

	if chain.AgentIdentity != "agent-1" {
		t.Errorf("expected AgentIdentity=agent-1, got %q", chain.AgentIdentity)
	}
	if chain.Principal != "user@example.com" {
		t.Errorf("expected Principal=user@example.com, got %q", chain.Principal)
	}
	if len(chain.DelegationChain) != 1 {
		t.Errorf("expected 1 delegation hop, got %d", len(chain.DelegationChain))
	}
}

func TestDelegationsEndpoint_ScopeExceeded_403(t *testing.T) {
	mux, repo, _ := setupDelegationsTestServer(t)

	// Create a restricted delegator
	_ = repo.CreateActor(context.Background(), identity.ActorRecord{
		ActorID:   "restricted-operator@example.com",
		Status:    model.ActorActionable,
		Metadata:  map[string]any{"type": "human", "capabilities": []string{"read:logs"}},
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
	})

	createPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-target",
		PrincipalActorID: "restricted-operator@example.com",
		AuthzRef:         "claim-unauthorized",
		Capabilities:     []string{"deploy:prod", "admin:all"}, // Exceeds read:logs
	}
	body, _ := json.Marshal(createPayload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected HTTP 403 on scope exceeded, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDelegationsEndpoint_LandlockContainmentEnforced_403(t *testing.T) {
	mux, _, _ := setupDelegationsTestServer(t)

	createPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-nono-evidenced",
		PrincipalActorID: "user@example.com",
		AuthzRef:         "claim-nono-missing-landlock",
		Capabilities:     []string{"agent:operate"},
		// Missing ContainmentClaims for Landlock
	}
	body, _ := json.Marshal(createPayload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected HTTP 403 for missing landlock on agent-nono-evidenced, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDelegationsEndpoint_ClampDelegation_200(t *testing.T) {
	mux, _, _ := setupDelegationsTestServer(t)

	// Create active delegation
	createPayload := CreateDelegationRequest{
		DelegateActorID:  "agent-clamp-target",
		PrincipalActorID: "user@example.com",
		AuthzRef:         "claim-clamp-123",
		Capabilities:     []string{"agent:operate"},
	}
	body, _ := json.Marshal(createPayload)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/delegations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", rec.Code)
	}

	// Clamp the delegation
	clampPayload := ClampDelegationRequest{
		AuthzRef: "claim-clamp-123",
	}
	cBody, _ := json.Marshal(clampPayload)
	cReq := httptest.NewRequest(http.MethodPost, "/api/v1/delegations/clamp", bytes.NewReader(cBody))
	cReq.Header.Set("Content-Type", "application/json")
	cRec := httptest.NewRecorder()
	mux.ServeHTTP(cRec, cReq)

	if cRec.Code != http.StatusOK {
		t.Fatalf("expected 200 on clamp, got %d: %s", cRec.Code, cRec.Body.String())
	}
}

func TestDelegations_MethodGatesAndHEADBodySuppression(t *testing.T) {
	_, _, s := setupDelegationsTestServer(t)
	engine, _ := correlation.NewEngine(s)
	h := &Handlers{Store: s, Engine: engine}

	// 1. handleCreateDelegation: POST only (disallowed: GET, PUT, DELETE, PATCH)
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/api/v1/delegations", nil)
		rec := httptest.NewRecorder()
		h.handleCreateDelegation(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleCreateDelegation status = %d, want 405", m, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Errorf("%s handleCreateDelegation Allow = %q, want POST, OPTIONS", m, allow)
		}
		if rec.Body.Len() == 0 {
			t.Errorf("%s handleCreateDelegation expected non-empty error body", m)
		}
	}

	// Direct HEAD on handleCreateDelegation: 405 with Allow: POST, OPTIONS and 0-byte body
	headReq := httptest.NewRequest(http.MethodHead, "/api/v1/delegations", nil)
	headRec := httptest.NewRecorder()
	h.handleCreateDelegation(headRec, headReq)
	if headRec.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD handleCreateDelegation status = %d, want 405", headRec.Code)
	}
	if allow := headRec.Header().Get("Allow"); allow != "POST, OPTIONS" {
		t.Errorf("HEAD handleCreateDelegation Allow = %q, want POST, OPTIONS", allow)
	}
	if headRec.Body.Len() != 0 {
		t.Errorf("HEAD handleCreateDelegation expected 0 body bytes, got %d", headRec.Body.Len())
	}

	// 2. handleClampDelegation: POST, DELETE (disallowed: GET, PUT, PATCH)
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodPatch} {
		req := httptest.NewRequest(m, "/api/v1/delegations/clamp", nil)
		rec := httptest.NewRecorder()
		h.handleClampDelegation(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s handleClampDelegation status = %d, want 405", m, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, DELETE, OPTIONS" {
			t.Errorf("%s handleClampDelegation Allow = %q, want 'POST, DELETE, OPTIONS'", m, allow)
		}
		if rec.Body.Len() == 0 {
			t.Errorf("%s handleClampDelegation expected non-empty error body", m)
		}
	}

	// Direct HEAD on handleClampDelegation: 405 with Allow: POST, DELETE, OPTIONS and 0-byte body
	headClampReq := httptest.NewRequest(http.MethodHead, "/api/v1/delegations/clamp", nil)
	headClampRec := httptest.NewRecorder()
	h.handleClampDelegation(headClampRec, headClampReq)
	if headClampRec.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD handleClampDelegation status = %d, want 405", headClampRec.Code)
	}
	if allow := headClampRec.Header().Get("Allow"); allow != "POST, DELETE, OPTIONS" {
		t.Errorf("HEAD handleClampDelegation Allow = %q, want 'POST, DELETE, OPTIONS'", allow)
	}
	if headClampRec.Body.Len() != 0 {
		t.Errorf("HEAD handleClampDelegation expected 0 body bytes, got %d", headClampRec.Body.Len())
	}
}
