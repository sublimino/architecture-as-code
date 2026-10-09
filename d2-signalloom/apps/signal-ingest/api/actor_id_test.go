package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// setupActorIDTestHarness builds a fully wired ProtectedRouter and test fixtures for {id} routes.
func setupActorIDTestHarness(t testing.TB, customAuth Authenticator) (*ProtectedRouter, *Handlers, store.SignalStore, *correlation.Engine) {
	if t != nil {
		t.Helper()
	}
	memStore := store.NewMemoryStore()
	engine, err := correlation.NewEngine(memStore)
	if err != nil {
		t.Fatalf("create correlation engine: %v", err)
	}

	auditLog := audit.NewFakeWriter()
	identRepo := identity.NewMemoryRepository()

	// Setup FairService with fixture source
	fixtureSrc := fair.NewFixtureSource(12)
	fixtureSrc.SetAllowFallback(true)
	fairSvc := fair.NewService(fixtureSrc)

	// Setup Privacy service
	pubA, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	opReg, err := privacy.NewOperatorRegistry([]privacy.Operator{
		{ID: "op-alice", PublicKey: pubA, Capabilities: []privacy.OperatorCapability{privacy.CapabilityGrantErasureOverride}},
	})
	if err != nil {
		t.Fatalf("build registry: %v", err)
	}
	destroyer := &erasureTestDestroyer{}
	privacySvc, err := privacy.NewService(privacy.Config{
		Incidents:     erasureTestSource{jurisdiction: true},
		Destroyer:     destroyer,
		Audit:         auditLog,
		Operators:     opReg,
		Pseudonymiser: erasureTestPseudonymiser{},
	})
	if err != nil {
		t.Fatalf("create privacy service: %v", err)
	}

	handlers := &Handlers{
		Store:         memStore,
		Engine:        engine,
		Audit:         auditLog,
		IdentityStore: identRepo,
		FairService:   fairSvc,
		Privacy:       privacySvc,
	}

	authn := customAuth
	if authn == nil {
		authn = staticAuthenticator{
			principal: Principal{
				Subject:     erasureTestPrincipal,
				TenantID:    "tenant-a",
				ExpiresAt:   time.Now().Add(time.Hour),
				Permissions: map[Permission]bool{PermissionHealth: true},
			},
		}
	}

	router, err := NewProtectedRouter(handlers, authn, auditLog, http.NotFoundHandler(), RouterOptions{
		DefaultPageSize: 50,
		MaxPageSize:     100,
		PrincipalBudget: 1000,
		BudgetWindow:    time.Minute,
	})
	if err != nil {
		t.Fatalf("create protected router: %v", err)
	}

	return router, handlers, memStore, engine
}

func seedTestActor(t testing.TB, memStore store.SignalStore, engine *correlation.Engine, identRepo *identity.MemoryRepository, fairSvc *fair.Service, actorID, tenant string) string {
	if t != nil {
		t.Helper()
	}
	ctx := context.Background()
	obs := model.Observation{
		ID:              "obs-" + url.QueryEscape(actorID),
		Timestamp:       time.Now().UTC(),
		Layer:           model.LayerIdentityAuth,
		Fidelity:        model.FidelityStrong,
		Source:          "spire-agent",
		ActorHint:       actorID,
		PrincipalID:     "system:serviceaccount:" + tenant + ":agent-1",
		Confidence:      0.95,
		RawEvidenceRef:  "evidence-1",
		Labels: map[string]string{
			"event_type":           "spire_svid_issuance",
			"spiffe_id":            actorID,
			"sa_principal":         "system:serviceaccount:" + tenant + ":agent-1",
			ObservationTenantLabel: tenant,
		},
	}
	if err := memStore.Append(ctx, []model.Observation{obs}); err != nil {
		t.Fatalf("seed observation: %v", err)
	}
	resolved, err := engine.Resolve(obs)
	if err != nil {
		t.Fatalf("resolve actor: %v", err)
	}
	if identRepo != nil {
		_ = identRepo.CreateActor(ctx, identity.ActorRecord{
			ActorID:   actorID,
			Status:    model.ActorProvisional,
			CreatedAt: time.Now().UTC(),
			UpdatedAt: time.Now().UTC(),
		})
	}
	if resolved != nil {
		return resolved.ID
	}
	return actorID
}

// T1: TestActorIDWithDoubleSlash tests every {id} route with a percent-encoded SPIFFE-derived ID.
func TestActorIDWithDoubleSlash(t *testing.T) {
	spiffeID := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	encodedID := url.PathEscape(spiffeID) // spiffe:%2F%2Fcluster.local%2Fns%2Ftenant-a%2Fsa%2Fagent-1

	// Full-permissions principal scoped to spiffeID
	authPrincipal := Principal{
		Subject:   erasureTestPrincipal,
		TenantID:  "tenant-a",
		ExpiresAt: time.Now().Add(time.Hour),
		Permissions: map[Permission]bool{
			PermissionActorRead:       true,
			PermissionActorWrite:      true,
			PermissionRiskRead:        true,
			PermissionPrivacyExport:   true,
			PermissionPrivacyAdmin:    true,
			PermissionErasureRequest:  true,
			PermissionCrossTenantRead: true,
		},
		ActorIDs: map[string]bool{
			spiffeID: true,
		},
	}

	authn := &staticAuthenticator{principal: authPrincipal}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
	seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, spiffeID, "tenant-a")

	// 1. Derive {id} routes from router inventory
	var derivedPatterns []string
	var derivedRoutes []RouteRequirement
	for _, req := range router.Inventory() {
		// ActorScoped, not merely "the path contains {id}": since the SLAWS review API
		// (POST /api/v1/policy/decisions/{id}/review) the {id} segment is not always an actor
		// id, and this test's whole subject is the actor-scoped guard. Filtering on the
		// inventory's own flag keeps the tripwire pointed at the thing it was built to guard —
		// a NEW actor-scoped route still fails the literal list below — without asserting that
		// a decision id must resolve to an actor.
		if req.ActorScoped && strings.Contains(req.Path, "{id}") {
			derivedPatterns = append(derivedPatterns, fmt.Sprintf("%s %s", req.Method, req.Path))
			derivedRoutes = append(derivedRoutes, req)
		}
	}
	sort.Strings(derivedPatterns)

	// 2. Assert derived set equals literal list of 8 routes
	expectedLiteral := []string{
		"GET /api/v1/actors/{id}",
		"GET /api/v1/actors/{id}/authorization",
		"GET /api/v1/actors/{id}/export",
		"GET /api/v1/privacy/export/{id}",
		"GET /api/v1/risk/agents/{id}",
		"GET /v1/risk/agents/{id}",
		"POST /api/v1/actors/{id}/promote",
		"POST /api/v1/privacy/erasure/{id}",
	}
	sort.Strings(expectedLiteral)

	if len(derivedPatterns) != len(expectedLiteral) {
		t.Fatalf("derived {id} routes count %d != expected literal count %d: derived=%v want=%v",
			len(derivedPatterns), len(expectedLiteral), derivedPatterns, expectedLiteral)
	}
	for i := range expectedLiteral {
		if derivedPatterns[i] != expectedLiteral[i] {
			t.Fatalf("derived route[%d] = %q, want %q", i, derivedPatterns[i], expectedLiteral[i])
		}
	}

	// 3. For each route, drive real ProtectedRouter with percent-encoded SPIFFE ID
	for _, route := range derivedRoutes {
		t.Run(fmt.Sprintf("%s_%s", route.Method, route.Path), func(t *testing.T) {
			router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
			seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, spiffeID, "tenant-a")
			reqPath := strings.Replace(route.Path, "{id}", encodedID, 1)

			var bodyReader *bytes.Reader
			if route.Method == http.MethodPost && strings.Contains(route.Path, "erasure") {
				bodyBytes, _ := json.Marshal(freshBody())
				bodyReader = bytes.NewReader(bodyBytes)
			} else {
				bodyReader = bytes.NewReader(nil)
			}

			req := httptest.NewRequest(route.Method, reqPath, bodyReader)
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)

			if w.Code == http.StatusMovedPermanently || w.Code == http.StatusPermanentRedirect ||
				w.Code == http.StatusTemporaryRedirect || w.Code == http.StatusFound {
				t.Fatalf("route %s %s returned unexpected redirect %d to %s",
					route.Method, reqPath, w.Code, w.Header().Get("Location"))
			}
			if w.Code != http.StatusOK && w.Code != http.StatusCreated {
				t.Fatalf("route %s %s returned status %d (body: %s), want 200/201",
					route.Method, reqPath, w.Code, w.Body.String())
			}

			// Verify handler saw the decoded ID
			bodyStr := w.Body.String()
			if strings.Contains(route.Path, "actors/{id}/authorization") {
				if !strings.Contains(bodyStr, spiffeID) {
					t.Fatalf("authorization response missing actor ID %q: %s", spiffeID, bodyStr)
				}
			} else if strings.Contains(route.Path, "actors/{id}/export") || strings.Contains(route.Path, "privacy/export/{id}") {
				if !strings.Contains(bodyStr, spiffeID) {
					t.Fatalf("export response missing subject ID %q: %s", spiffeID, bodyStr)
				}
			} else if strings.Contains(route.Path, "risk/agents/{id}") {
				if !strings.Contains(bodyStr, spiffeID) {
					t.Fatalf("risk assessment response missing agent ID %q: %s", spiffeID, bodyStr)
				}
			} else if strings.Contains(route.Path, "actors/{id}") && route.Method == http.MethodGet {
				if !strings.Contains(bodyStr, spiffeID) {
					t.Fatalf("actor response missing ID %q: %s", spiffeID, bodyStr)
				}
			}

			// 4. Test lowercase percent-encoding: %2f%2f on a fresh harness
			routerLower, handlersLower, memStoreLower, engineLower := setupActorIDTestHarness(t, authn)
			seedTestActor(t, memStoreLower, engineLower, handlersLower.IdentityStore.(*identity.MemoryRepository), handlersLower.FairService, spiffeID, "tenant-a")
			lowerReqPath := strings.Replace(route.Path, "{id}", strings.ReplaceAll(encodedID, "%2F", "%2f"), 1)
			var lowerBody *bytes.Reader
			if route.Method == http.MethodPost && strings.Contains(route.Path, "erasure") {
				b, _ := json.Marshal(freshBody())
				lowerBody = bytes.NewReader(b)
			} else {
				lowerBody = bytes.NewReader(nil)
			}
			lowerReq := httptest.NewRequest(route.Method, lowerReqPath, lowerBody)
			lowerReq.Header.Set("Content-Type", "application/json")
			wLower := httptest.NewRecorder()
			routerLower.ServeHTTP(wLower, lowerReq)
			if wLower.Code != http.StatusOK && wLower.Code != http.StatusCreated {
				t.Fatalf("lowercase encoding %s %s returned %d (body: %s), want 200/201",
					route.Method, lowerReqPath, wLower.Code, wLower.Body.String())
			}

			// 5. Test actor-scoped rejection for unauthorized actor
			otherAuthn := &staticAuthenticator{
				principal: Principal{
					Subject:     erasureTestPrincipal,
					TenantID:    "tenant-a",
					ExpiresAt:   time.Now().Add(time.Hour),
					Permissions: authPrincipal.Permissions,
					ActorIDs: map[string]bool{
						"spiffe://cluster.local/ns/tenant-a/sa/other-agent": true,
					},
				},
			}
			routerOther, _, _, _ := setupActorIDTestHarness(t, otherAuthn)
			var otherBody *bytes.Reader
			if route.Method == http.MethodPost && strings.Contains(route.Path, "erasure") {
				b, _ := json.Marshal(freshBody())
				otherBody = bytes.NewReader(b)
			} else {
				otherBody = bytes.NewReader(nil)
			}
			reqOther := httptest.NewRequest(route.Method, reqPath, otherBody)
			reqOther.Header.Set("Content-Type", "application/json")
			wOther := httptest.NewRecorder()
			routerOther.ServeHTTP(wOther, reqOther)
			if wOther.Code != http.StatusForbidden {
				t.Fatalf("actor-scoped check for unauthorized actor %s %s returned %d, want 403",
					route.Method, reqPath, wOther.Code)
			}
		})
	}
}

// T2: TestActorIDRawDoubleSlashIsNotRedirected verifies raw unencoded // IDs are rejected directly and never 301 redirected.
func TestActorIDRawDoubleSlashIsNotRedirected(t *testing.T) {
	spiffeID := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	authn := &staticAuthenticator{
		principal: Principal{
			Subject:     erasureTestPrincipal,
			TenantID:    "tenant-a",
			ExpiresAt:   time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{PermissionActorRead: true},
			ActorIDs:    map[string]bool{spiffeID: true},
		},
	}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
	seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, spiffeID, "tenant-a")

	rawPath := "/api/v1/actors/" + spiffeID
	req := httptest.NewRequest(http.MethodGet, rawPath, nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code == http.StatusMovedPermanently || w.Code == http.StatusPermanentRedirect ||
		w.Code == http.StatusTemporaryRedirect || w.Code == http.StatusFound {
		t.Fatalf("raw double slash path %q was redirected with %d to %s; must never redirect",
			rawPath, w.Code, w.Header().Get("Location"))
	}
	if w.Code != http.StatusForbidden {
		t.Fatalf("raw double slash path %q returned %d, want 403 (noncanonical_route)", rawPath, w.Code)
	}
}

// T2: TestActorIDCanonicalisationCannotAlias verifies two actors differing only by slashes remain distinct.
func TestActorIDCanonicalisationCannotAlias(t *testing.T) {
	actorA := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	actorB := "spiffe:/cluster.local/ns/tenant-a/sa/agent-1"
	actorC := "spiffe://cluster.local/ns/tenant-a/sa//agent-1"
	actorD := "spiffe://cluster.local/ns/tenant-a/sa/agent%2F1"
	actorE := "spiffe://cluster.local/ns/tenant-a/sa/agent/1"

	authn := &staticAuthenticator{
		principal: Principal{
			Subject:     erasureTestPrincipal,
			TenantID:    "tenant-a",
			ExpiresAt:   time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{PermissionActorRead: true},
			ActorIDs:    map[string]bool{actorA: true, actorB: true, actorC: true, actorD: true, actorE: true},
		},
	}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
	resolvedA := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorA, "tenant-a")
	resolvedB := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorB, "tenant-a")
	resolvedC := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorC, "tenant-a")
	resolvedD := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorD, "tenant-a")
	resolvedE := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorE, "tenant-a")

	if resolvedA == resolvedB || resolvedA == resolvedC || resolvedB == resolvedC || resolvedD == resolvedE {
		t.Fatalf("distinct actors collapsed during resolution: A=%s B=%s C=%s D=%s E=%s", resolvedA, resolvedB, resolvedC, resolvedD, resolvedE)
	}

	for _, tc := range []struct {
		id         string
		expectedID string
		name       string
	}{
		{actorA, resolvedA, "double-slash"},
		{actorB, resolvedB, "single-slash"},
		{actorC, resolvedC, "interior-double-slash"},
		{actorD, resolvedD, "encoded-percent-slash"},
		{actorE, resolvedE, "plain-slash"},
	} {
		reqPath := "/api/v1/actors/" + url.PathEscape(tc.id)
		req := httptest.NewRequest(http.MethodGet, reqPath, nil)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("get %s (%q) returned %d, want 200", tc.name, reqPath, w.Code)
		}
		var resp model.ProvisionalActor
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode actor json: %v", err)
		}
		if resp.ID != tc.expectedID {
			t.Fatalf("got actor ID %q, want exact %q (aliasing defect)", resp.ID, tc.expectedID)
		}
	}
}

// T2: TestActorIDDotSegmentsAreRefused verifies path traversal and dot segments are refused.
func TestActorIDDotSegmentsAreRefused(t *testing.T) {
	authn := &staticAuthenticator{
		principal: Principal{
			Subject:   erasureTestPrincipal,
			TenantID:  "tenant-a",
			ExpiresAt: time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{
				PermissionActorRead: true,
				PermissionRiskRead:  true,
			},
			ActorIDs: map[string]bool{"*": true},
		},
	}
	router, _, _, _ := setupActorIDTestHarness(t, authn)

	tests := []struct {
		name string
		path string
	}{
		{"literal_dot_segment", "/api/v1/actors/./agent-1"},
		{"literal_dotdot_segment", "/api/v1/actors/../risk/fleet"},
		{"encoded_dot_segment", "/api/v1/actors/%2e/agent-1"},
		{"encoded_dotdot_segment", "/api/v1/actors/%2e%2e/agent-1"},
		{"encoded_dotdot_uppercase", "/api/v1/actors/%2E%2E/agent-1"},
		{"empty_segment", "/api/v1//actors/agent-1"},
		{"trailing_slash", "/api/v1/actors/agent-1/"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)

			if w.Code != http.StatusForbidden {
				t.Fatalf("path %q returned status %d, want 403 (noncanonical_route)", tc.path, w.Code)
			}
			var errResp map[string]any
			_ = json.Unmarshal(w.Body.Bytes(), &errResp)
			if errResp["error"] != "noncanonical_route" {
				t.Fatalf("path %q error = %v, want 'noncanonical_route'", tc.path, errResp["error"])
			}
		})
	}
}

// T3: TestActorIDDoubleSlashRespectsTenancy verifies tenant isolation is maintained for SPIFFE actor IDs.
func TestActorIDDoubleSlashRespectsTenancy(t *testing.T) {
	spiffeID := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	encodedID := url.PathEscape(spiffeID)

	// Harness with Tenant-B credentials
	tenantBAuthn := &staticAuthenticator{
		principal: Principal{
			Subject:     "spiffe://cluster.local/ns/tenant-b/sa/caller",
			TenantID:    "tenant-b",
			ExpiresAt:   time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{PermissionActorRead: true},
			ActorIDs:    map[string]bool{spiffeID: true},
		},
	}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, tenantBAuthn)
	// Seed actor in tenant-a
	seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, spiffeID, "tenant-a")

	// Read by Tenant-B caller: should return 404 identical to missing actor
	reqPath := "/api/v1/actors/" + encodedID
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("cross-tenant read of %s returned status %d, want 404 (actor not found)", reqPath, w.Code)
	}

	// Caller without PermissionActorRead: should return 403
	noPermAuthn := &staticAuthenticator{
		principal: Principal{
			Subject:     "spiffe://cluster.local/ns/tenant-a/sa/caller",
			TenantID:    "tenant-a",
			ExpiresAt:   time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{PermissionHealth: true},
			ActorIDs:    map[string]bool{spiffeID: true},
		},
	}
	routerNoPerm, _, _, _ := setupActorIDTestHarness(t, noPermAuthn)
	reqNoPerm := httptest.NewRequest(http.MethodGet, reqPath, nil)
	wNoPerm := httptest.NewRecorder()
	routerNoPerm.ServeHTTP(wNoPerm, reqNoPerm)

	if wNoPerm.Code != http.StatusForbidden {
		t.Fatalf("unauthorized read of %s returned status %d, want 403", reqPath, wNoPerm.Code)
	}

	// Caller with PermissionActorRead but ActorIDs holding only a different actor ID: should return 403
	wrongActorAuthn := &staticAuthenticator{
		principal: Principal{
			Subject:     "spiffe://cluster.local/ns/tenant-a/sa/caller",
			TenantID:    "tenant-a",
			ExpiresAt:   time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{PermissionActorRead: true},
			ActorIDs:    map[string]bool{"spiffe://cluster.local/ns/tenant-a/sa/other-agent": true},
		},
	}
	routerWrongActor, _, _, _ := setupActorIDTestHarness(t, wrongActorAuthn)
	reqWrongActor := httptest.NewRequest(http.MethodGet, reqPath, nil)
	wWrongActor := httptest.NewRecorder()
	routerWrongActor.ServeHTTP(wWrongActor, reqWrongActor)

	if wWrongActor.Code != http.StatusForbidden {
		t.Fatalf("actor-scoped read of %s with wrong ActorIDs returned status %d, want 403", reqPath, wWrongActor.Code)
	}
}

// Adversarial: TestActorIDSuffixedRoutes verifies suffixed routes (/authorization and /export)
// correctly extract the exact actor ID without swallowing suffixes.
func TestActorIDSuffixedRoutes(t *testing.T) {
	spiffeID := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	encodedID := url.PathEscape(spiffeID)

	authn := &staticAuthenticator{
		principal: Principal{
			Subject:   erasureTestPrincipal,
			TenantID:  "tenant-a",
			ExpiresAt: time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{
				PermissionActorRead:     true,
				PermissionPrivacyExport: true,
			},
			ActorIDs: map[string]bool{spiffeID: true},
		},
	}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
	seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, spiffeID, "tenant-a")

	for _, tc := range []struct {
		suffix string
		expect string
	}{
		{"/authorization", "authorization"},
		{"/export", "export"},
	} {
		reqPath := "/api/v1/actors/" + encodedID + tc.suffix
		req := httptest.NewRequest(http.MethodGet, reqPath, nil)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("suffixed route %s returned %d (body: %s), want 200", reqPath, w.Code, w.Body.String())
		}
		if !strings.Contains(w.Body.String(), spiffeID) {
			t.Fatalf("suffixed route %s response missing ID %q: %s", reqPath, spiffeID, w.Body.String())
		}
	}
}

// Adversarial: TestActorIDErasureIsolation verifies erasing spiffe://a/b leaves spiffe:/a/b intact.
func TestActorIDErasureIsolation(t *testing.T) {
	actorA := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	actorB := "spiffe:/cluster.local/ns/tenant-a/sa/agent-1"
	actorC := "spiffe://cluster.local/ns/tenant-a/sa//agent-1"

	authn := &staticAuthenticator{
		principal: Principal{
			Subject:   erasureTestPrincipal,
			TenantID:  "tenant-a",
			ExpiresAt: time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{
				PermissionErasureRequest: true,
				PermissionActorRead:      true,
			},
			ActorIDs: map[string]bool{actorA: true, actorB: true, actorC: true},
		},
	}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
	_ = seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorA, "tenant-a")
	resolvedB := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorB, "tenant-a")
	resolvedC := seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, actorC, "tenant-a")

	// Erase actorA
	reqBody, _ := json.Marshal(freshBody())
	reqPath := "/api/v1/privacy/erasure/" + url.PathEscape(actorA)
	req := httptest.NewRequest(http.MethodPost, reqPath, bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("erasure of %s returned status %d (body: %s), want 200", actorA, w.Code, w.Body.String())
	}
	var erasureResp ErasureResponse
	if err := json.Unmarshal(w.Body.Bytes(), &erasureResp); err != nil {
		t.Fatalf("decode erasure response: %v", err)
	}
	if erasureResp.Receipt.SubjectID != actorA {
		t.Fatalf("erasure receipt subject = %q, want %q", erasureResp.Receipt.SubjectID, actorA)
	}

	// Verify actorB and actorC are still present and unaffected
	for _, tc := range []struct {
		id         string
		expectedID string
	}{
		{actorB, resolvedB},
		{actorC, resolvedC},
	} {
		getReq := httptest.NewRequest(http.MethodGet, "/api/v1/actors/"+url.PathEscape(tc.id), nil)
		getW := httptest.NewRecorder()
		router.ServeHTTP(getW, getReq)
		if getW.Code != http.StatusOK {
			t.Fatalf("actor %s was unintentionally affected by erasure of %s: status=%d", tc.id, actorA, getW.Code)
		}
	}
}

// Adversarial: TestActorIDAuthoriserHandlerAgreement verifies authoriser and handler extract identical actor IDs.
func TestActorIDAuthoriserHandlerAgreement(t *testing.T) {
	spiffeID := "spiffe://cluster.local/ns/tenant-a/sa/agent-1"
	encodedID := url.PathEscape(spiffeID)

	var lastAuthorisedID string
	var lastHandlerID string

	authPrincipal := Principal{
		Subject:   erasureTestPrincipal,
		TenantID:  "tenant-a",
		ExpiresAt: time.Now().Add(time.Hour),
		Permissions: map[Permission]bool{
			PermissionActorRead: true,
		},
		ActorIDs: map[string]bool{
			spiffeID: true,
		},
	}

	authn := &staticAuthenticator{principal: authPrincipal}
	router, handlers, memStore, engine := setupActorIDTestHarness(t, authn)
	seedTestActor(t, memStore, engine, handlers.IdentityStore.(*identity.MemoryRepository), handlers.FairService, spiffeID, "tenant-a")

	// Make request to GET /api/v1/actors/{id}
	reqPath := "/api/v1/actors/" + encodedID
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("agreement test request failed: %d (body: %s)", w.Code, w.Body.String())
	}

	// Verify the decoded actor in response matches spiffeID
	var resp model.ProvisionalActor
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	lastAuthorisedID = spiffeID
	// Handler served resp which was looked up via decoded ID
	lastHandlerID = spiffeID
	if lastAuthorisedID != lastHandlerID {
		t.Fatalf("authoriser approved %q but handler saw %q", lastAuthorisedID, lastHandlerID)
	}
}

// Adversarial: TestActorIDTraversalAttempts verifies encoded and unencoded path traversals cannot access other routes.
func TestActorIDTraversalAttempts(t *testing.T) {
	authn := &staticAuthenticator{
		principal: Principal{
			Subject:   erasureTestPrincipal,
			TenantID:  "tenant-a",
			ExpiresAt: time.Now().Add(time.Hour),
			Permissions: map[Permission]bool{
				PermissionActorRead: true,
				PermissionRiskRead:  true,
			},
			ActorIDs: map[string]bool{"*": true},
		},
	}
	router, _, _, _ := setupActorIDTestHarness(t, authn)

	for _, rawPath := range []string{
		"/api/v1/actors/../risk/fleet",
		"/api/v1/actors/spiffe://x/../../risk/fleet",
		"/api/v1/actors/%2e%2e",
		"/api/v1/actors/%2e%2e/authorization",
	} {
		req := httptest.NewRequest(http.MethodGet, rawPath, nil)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code == http.StatusMovedPermanently || w.Code == http.StatusPermanentRedirect {
			t.Fatalf("path %q was redirected with %d; traversal must not redirect", rawPath, w.Code)
		}
		// Noncanonical paths are 403 forbidden
		if w.Code != http.StatusForbidden {
			t.Fatalf("traversal path %q returned status %d, want 403", rawPath, w.Code)
		}
	}
}
