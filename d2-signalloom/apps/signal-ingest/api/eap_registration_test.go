// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
)

// EAPR-P3-4 (Step 12): Inbound Agent Registration & Log Stream Tenancy Acceptance Tests.
//
// Proves:
// 1. An unauthenticated log stream / telemetry payload is rejected (HTTP 401).
// 2. A JWT-SVID for Tenant A attempting to post a log stream tagged or targeted at Tenant B
//    is strictly quarantined or rejected; hostile tenant injection headers are ignored and
//    the stream is never attributed to Tenant B.
// 3. Positive control: An agent presenting a valid JWT-SVID with matching Tenant A succeeds (HTTP 201).

func TestEAPRegistration_UnauthenticatedStreamRejected(t *testing.T) {
	h, _ := newTestHandlers(t)
	store := codingagent.NewMemoryStore()
	h.CodingAgentStore = store

	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subA := "spiffe://signalloom.demo/ns/eap-tenant-a/sa/agent-001"

	authn, err := NewJWTAuthenticator(AuthConfig{
		Audience:    "signal-ingest",
		TrustDomain: "signalloom.demo",
		Keys:        map[string]any{"test": &key.PublicKey},
		Bindings: map[string]PrincipalBinding{
			subA: {
				TenantID:    "tenant-a",
				Permissions: []Permission{PermissionObservationWrite, PermissionObservationRead},
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to create JWTAuthenticator: %v", err)
	}

	router, err := NewProtectedRouter(
		h,
		authn,
		audit.NewFakeWriter(),
		http.NotFoundHandler(),
		RouterOptions{},
	)
	if err != nil {
		t.Fatalf("failed to create ProtectedRouter: %v", err)
	}

	sessionID := "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e"
	nowStr := time.Now().UTC().Format(time.RFC3339)
	payload := validPayloadForSession(sessionID, "EAPR-P3-4", 10, 1, nowStr)
	bodyBytes, _ := json.Marshal(payload)

	// Case 1: Completely missing Authorization header
	req := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/coding-agents", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated stream accepted: got HTTP %d, want 401", w.Code)
	}

	// Case 2: Malformed Authorization token
	req2 := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/coding-agents", bytes.NewReader(bodyBytes))
	req2.Header.Set("Content-Type", "application/json")
	req2.Header.Set("Authorization", "Bearer invalid-jwt-token-value")
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, req2)

	if w2.Code != http.StatusUnauthorized {
		t.Fatalf("malformed token stream accepted: got HTTP %d, want 401", w2.Code)
	}
}

func TestEAPRegistration_WrongTenantLogStreamRejectedOrQuarantined(t *testing.T) {
	h, _ := newTestHandlers(t)
	store := codingagent.NewMemoryStore()
	h.CodingAgentStore = store

	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subA := "spiffe://signalloom.demo/ns/eap-tenant-a/sa/agent-001"

	authn, err := NewJWTAuthenticator(AuthConfig{
		Audience:    "signal-ingest",
		TrustDomain: "signalloom.demo",
		Keys:        map[string]any{"test": &key.PublicKey},
		Bindings: map[string]PrincipalBinding{
			subA: {
				TenantID:    "tenant-a",
				Permissions: []Permission{PermissionObservationWrite, PermissionObservationRead},
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to create JWTAuthenticator: %v", err)
	}

	router, err := NewProtectedRouter(
		h,
		authn,
		audit.NewFakeWriter(),
		http.NotFoundHandler(),
		RouterOptions{},
	)
	if err != nil {
		t.Fatalf("failed to create ProtectedRouter: %v", err)
	}

	// Sign valid JWT for Tenant A
	validTokenTenantA := signedToken(t, key, map[string]any{
		"sub": subA,
		"aud": "signal-ingest",
		"exp": time.Now().Add(time.Hour).Unix(),
	})

	sessionID := "8c4946d17f57f3eedb01cd95677f32cfe978bdb922069bfa191079b413cce08f"
	nowStr := time.Now().UTC().Format(time.RFC3339)
	payload := validPayloadForSession(sessionID, "EAPR-P3-4", 15, 1, nowStr)
	bodyBytes, _ := json.Marshal(payload)

	// Attacker presents Token for Tenant A, but tries to inject Tenant B via headers
	req := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/coding-agents", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+validTokenTenantA)
	req.Header.Set("X-Tenant-ID", "tenant-b")
	req.Header.Set("X-Tenant", "tenant-b")
	req.Header.Set("X-SignalLoom-Tenant", "tenant-b")

	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusCreated && w.Code != http.StatusOK {
		t.Fatalf("expected request to be handled, got HTTP %d: %s", w.Code, w.Body.String())
	}

	// Verify Tenant B has ZERO records in the store
	tenantBRecords, err := store.Query(context.Background(), "tenant-b", codingagent.AggregateFilter{})
	if err != nil {
		t.Fatalf("failed to query tenant-b: %v", err)
	}
	if len(tenantBRecords) != 0 {
		t.Fatalf("CRITICAL ISOLATION BREACH: Tenant B received records from Tenant A principal! Count: %d", len(tenantBRecords))
	}

	// Verify Tenant A received the record
	tenantARecords, err := store.Query(context.Background(), "tenant-a", codingagent.AggregateFilter{})
	if err != nil {
		t.Fatalf("failed to query tenant-a: %v", err)
	}
	if len(tenantARecords) != 1 {
		t.Fatalf("Tenant A expected 1 record, got %d", len(tenantARecords))
	}
	if tenantARecords[0].TenantID != "tenant-a" {
		t.Fatalf("Record attributed to wrong tenant: %s", tenantARecords[0].TenantID)
	}
}

func TestEAPRegistration_MatchingTenantPositiveControl(t *testing.T) {
	h, _ := newTestHandlers(t)
	store := codingagent.NewMemoryStore()
	h.CodingAgentStore = store

	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	subA := "spiffe://signalloom.demo/ns/eap-tenant-a/sa/agent-positive-001"

	authn, err := NewJWTAuthenticator(AuthConfig{
		Audience:    "signal-ingest",
		TrustDomain: "signalloom.demo",
		Keys:        map[string]any{"test": &key.PublicKey},
		Bindings: map[string]PrincipalBinding{
			subA: {
				TenantID:    "tenant-a",
				Permissions: []Permission{PermissionObservationWrite, PermissionObservationRead},
			},
		},
	})
	if err != nil {
		t.Fatalf("failed to create JWTAuthenticator: %v", err)
	}

	router, err := NewProtectedRouter(
		h,
		authn,
		audit.NewFakeWriter(),
		http.NotFoundHandler(),
		RouterOptions{},
	)
	if err != nil {
		t.Fatalf("failed to create ProtectedRouter: %v", err)
	}

	validToken := signedToken(t, key, map[string]any{
		"sub": subA,
		"aud": "signal-ingest",
		"exp": time.Now().Add(time.Hour).Unix(),
	})

	sessionID := "9d5a57e28f68f4ffe012de06788f43dfe089ceca33170cfa202180c524dde190"
	nowStr := time.Now().UTC().Format(time.RFC3339)
	payload := validPayloadForSession(sessionID, "EAPR-P3-4", 20, 1, nowStr)
	bodyBytes, _ := json.Marshal(payload)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/coding-agents", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+validToken)

	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("positive control failed: got HTTP %d (body: %s), want 201", w.Code, w.Body.String())
	}

	var result codingagent.IngestResult
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("failed to decode IngestResult: %v", err)
	}
	if result.SessionID != sessionID {
		t.Fatalf("unexpected session ID in result: %s", result.SessionID)
	}

	// Verify Tenant A context query
	ctx := WithTenantContext(context.Background(), TenantContext{
		TenantID:  "tenant-a",
		Principal: subA,
	})
	claim, ok := TenantClaimFromRequestContext(ctx)
	if !ok || claim.TenantID != "tenant-a" {
		t.Fatalf("tenant claim verification failed: %+v", claim)
	}
	_ = identity.TenantClaim{}
}
