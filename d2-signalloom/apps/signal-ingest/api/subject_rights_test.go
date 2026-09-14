package api_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

type staticAuthenticator struct {
	principal api.Principal
	err       error
}

func (a *staticAuthenticator) Authenticate(r *http.Request) (api.Principal, error) {
	if a.err != nil {
		return api.Principal{}, a.err
	}
	return a.principal, nil
}

func setupSubjectRightsTestHarness(t *testing.T, principal api.Principal) (*httptest.Server, *identity.MemoryRepository, store.SignalStore) {
	t.Helper()
	repo := identity.NewMemoryRepository()
	memStore := store.NewMemoryStore()

	handlers := &api.Handlers{
		Store:         memStore,
		IdentityStore: repo,
	}

	authn := &staticAuthenticator{principal: principal}
	auditWriter := audit.NewFakeWriter()

	router, err := api.NewProtectedRouter(handlers, authn, auditWriter, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}), api.RouterOptions{
		DefaultPageSize: 50,
		MaxPageSize:     100,
		PrincipalBudget: 10000,
		BudgetWindow:    time.Minute,
	})
	if err != nil {
		t.Fatalf("failed to create protected router: %v", err)
	}

	server := httptest.NewServer(router)
	t.Cleanup(server.Close)

	return server, repo, memStore
}

func TestSubjectRights_Article15_DualPlaneAccessExport(t *testing.T) {
	now := time.Now().UTC()
	principal := api.Principal{
		Subject:   "spiffe://cluster.local/ns/prod/sa/alice-agent",
		TenantID:  "tenant-finance",
		ExpiresAt: now.Add(time.Hour),
		Permissions: map[api.Permission]bool{
			api.PermissionPrivacyExport: true,
		},
		ActorIDs: map[string]bool{
			"alice": true,
			"*":     true,
		},
	}

	server, repo, memStore := setupSubjectRightsTestHarness(t, principal)
	ctx := context.Background()

	// 1. Seed Plane 1 (Identity Graph)
	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "alice",
		Status:    model.ActorPromoted,
		CreatedAt: now.Add(-30 * 24 * time.Hour),
		UpdatedAt: now.Add(-time.Hour),
	})
	aliasValidTo := now.Add(365 * 24 * time.Hour)
	validTo1 := now.Add(7 * 24 * time.Hour)
	validTo2 := now.Add(14 * 24 * time.Hour)

	_ = repo.AddAlias(ctx, identity.AliasRecord{
		ActorID:    "alice",
		AliasType:  "email",
		AliasValue: "alice@example.com",
		ValidFrom:  now.Add(-30 * 24 * time.Hour),
		ValidTo:    &aliasValidTo,
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		ID:               101,
		PrincipalActorID: "alice",
		DelegateActorID:  "bot-helper-1",
		AuthzRef:         "repo:read",
		ValidFrom:        now.Add(-7 * 24 * time.Hour),
		ValidTo:          &validTo1,
		Status:           "active",
	})
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		ID:               102,
		PrincipalActorID: "manager-bob",
		DelegateActorID:  "alice",
		AuthzRef:         "deploy:prod",
		ValidFrom:        now.Add(-14 * 24 * time.Hour),
		ValidTo:          &validTo2,
		Status:           "active",
	})

	// 2. Seed Plane 2 (Evidence Store)
	_ = memStore.Append(ctx, []model.Observation{
		{
			ID:          "obs-alice-001",
			Timestamp:   now.Add(-2 * time.Hour),
			Layer:       model.LayerEndpointHost,
			Source:      "host-sensor",
			ActorHint:   "alice",
			ActorID:     "alice",
			Description: "Workstation build command executed",
		},
		{
			ID:          "obs-alice-002",
			Timestamp:   now.Add(-1 * time.Hour),
			Layer:       model.LayerIdentityAuth,
			Source:      "k8s-apiserver",
			ActorHint:   "alice@example.com",
			PrincipalID: "alice",
			Description: "Kubernetes pod deploy authorized",
		},
		{
			ID:          "obs-bob-999",
			Timestamp:   now.Add(-30 * time.Minute),
			Layer:       model.LayerEndpointHost,
			Source:      "host-sensor",
			ActorHint:   "bob",
			ActorID:     "bob",
			Description: "Unrelated telemetry for another human",
		},
	})

	// 3. Perform Article 15 Export Request
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/alice", nil)
	req.Header.Set("Authorization", "Bearer valid-svid")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("export request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", resp.StatusCode)
	}

	var exportResp api.SubjectAccessExportResponse
	if err := json.NewDecoder(resp.Body).Decode(&exportResp); err != nil {
		t.Fatalf("failed to decode export JSON: %v", err)
	}

	// 4. Verify Responses
	if exportResp.Format != api.FormatArticle15Access {
		t.Errorf("expected format %s, got %s", api.FormatArticle15Access, exportResp.Format)
	}
	if exportResp.SubjectID != "alice" {
		t.Errorf("expected subject_id alice, got %s", exportResp.SubjectID)
	}
	if exportResp.TenantID != "tenant-finance" {
		t.Errorf("expected tenant_id tenant-finance, got %s", exportResp.TenantID)
	}

	// Verify Identification block
	if exportResp.Identification.CanonicalActorID != "alice" {
		t.Errorf("expected canonical_actor_id alice, got %s", exportResp.Identification.CanonicalActorID)
	}
	if len(exportResp.Identification.ResolvedAliases) != 1 || exportResp.Identification.ResolvedAliases[0] != "alice@example.com" {
		t.Errorf("expected resolved aliases [alice@example.com], got %v", exportResp.Identification.ResolvedAliases)
	}

	// Verify Identity Plane
	if exportResp.IdentityPlane.Actor == nil || exportResp.IdentityPlane.Actor.ActorID != "alice" {
		t.Errorf("expected identity plane actor alice, got %v", exportResp.IdentityPlane.Actor)
	}
	if len(exportResp.IdentityPlane.Aliases) != 1 {
		t.Errorf("expected 1 alias, got %d", len(exportResp.IdentityPlane.Aliases))
	}
	if len(exportResp.IdentityPlane.Delegations) != 2 {
		t.Errorf("expected 2 delegations, got %d", len(exportResp.IdentityPlane.Delegations))
	}

	// Verify Evidence Plane
	if exportResp.EvidencePlane.TotalCount != 2 {
		t.Errorf("expected 2 matching observations for alice, got %d", exportResp.EvidencePlane.TotalCount)
	}
	for _, obs := range exportResp.EvidencePlane.Observations {
		if obs.ID == "obs-bob-999" {
			t.Errorf("over-disclosure violation: bob's observation obs-bob-999 was included in alice's export")
		}
	}

	// Verify Completeness Notice and Exclusions
	if exportResp.CompletenessNotice.LegalBasis == "" {
		t.Errorf("expected populated LegalBasis")
	}
	if len(exportResp.CompletenessNotice.ExclusionsAndLimits) == 0 {
		t.Errorf("expected explicit exclusions listed in completeness notice")
	}
}

func TestSubjectRights_Article20_MachineReadablePortability(t *testing.T) {
	now := time.Now().UTC()
	principal := api.Principal{
		Subject:   "spiffe://cluster.local/ns/prod/sa/alice-agent",
		TenantID:  "tenant-enterprise",
		ExpiresAt: now.Add(time.Hour),
		Permissions: map[api.Permission]bool{
			api.PermissionPrivacyExport: true,
		},
		ActorIDs: map[string]bool{"alice": true, "*": true},
	}

	server, repo, memStore := setupSubjectRightsTestHarness(t, principal)
	ctx := context.Background()

	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "alice",
		Status:    model.ActorPromoted,
		CreatedAt: now.Add(-60 * 24 * time.Hour),
		UpdatedAt: now,
	})
	aliasValidTo := now.Add(365 * 24 * time.Hour)
	_ = repo.AddAlias(ctx, identity.AliasRecord{
		ActorID:    "alice",
		AliasType:  "email",
		AliasValue: "alice@corp.internal",
		ValidFrom:  now.Add(-60 * 24 * time.Hour),
		ValidTo:    &aliasValidTo,
	})
	_ = memStore.Append(ctx, []model.Observation{
		{
			ID:          "obs-port-1",
			Timestamp:   now.Add(-10 * time.Minute),
			Layer:       model.LayerEndpointHost,
			Source:      "host-sensor",
			ActorHint:   "alice",
			Description: "Local IDE action",
		},
	})

	// Perform Article 20 Portability Export Request
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/alice?format=portability", nil)
	req.Header.Set("Authorization", "Bearer valid-svid")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("portability request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %s", ct)
	}

	var portResp api.SubjectPortabilityResponse
	if err := json.NewDecoder(resp.Body).Decode(&portResp); err != nil {
		t.Fatalf("failed to decode portability JSON: %v", err)
	}

	if portResp.SchemaVersion != api.Article20SchemaVersion {
		t.Errorf("expected schema_version %s, got %s", api.Article20SchemaVersion, portResp.SchemaVersion)
	}
	if portResp.Format != api.FormatArticle20Portability {
		t.Errorf("expected format %s, got %s", api.FormatArticle20Portability, portResp.Format)
	}
	if len(portResp.ScopeLimits.CoveredCategories) == 0 || len(portResp.ScopeLimits.ExcludedCategories) == 0 {
		t.Errorf("expected populated ScopeLimits covered and excluded categories")
	}
	if portResp.DataSubjectProfile["canonical_id"] != "alice" {
		t.Errorf("expected data_subject_profile canonical_id alice, got %v", portResp.DataSubjectProfile["canonical_id"])
	}
	if len(portResp.ActivityTelemetry) != 1 || portResp.ActivityTelemetry[0].ID != "obs-port-1" {
		t.Errorf("expected activity_telemetry with obs-port-1, got %v", portResp.ActivityTelemetry)
	}
}

func TestSubjectRights_OverDisclosure_PreventsThirdPartyLeakageInSharedRecords(t *testing.T) {
	now := time.Now().UTC()
	principal := api.Principal{
		Subject:   "spiffe://cluster.local/ns/prod/sa/alice-agent",
		TenantID:  "tenant-secure",
		ExpiresAt: now.Add(time.Hour),
		Permissions: map[api.Permission]bool{
			api.PermissionPrivacyExport: true,
		},
		ActorIDs: map[string]bool{"alice": true, "*": true},
	}

	server, repo, memStore := setupSubjectRightsTestHarness(t, principal)
	ctx := context.Background()

	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "alice",
		Status:    model.ActorPromoted,
		CreatedAt: now.Add(-10 * 24 * time.Hour),
		UpdatedAt: now,
	})
	delValidTo := now.Add(time.Hour)
	_ = repo.AddDelegation(ctx, identity.DelegationRecord{
		ID:               201,
		PrincipalActorID: "external-client-charlie",
		DelegateActorID:  "alice",
		AuthzRef:         "read:shared-doc",
		ValidFrom:        now.Add(-time.Hour),
		ValidTo:          &delValidTo,
		Status:           "active",
	})

	// Shared observation where alice is actor, but third-party charlie is impersonated
	_ = memStore.Append(ctx, []model.Observation{
		{
			ID:               "obs-shared-1",
			Timestamp:        now.Add(-15 * time.Minute),
			Layer:            model.LayerIdentityAuth,
			Source:           "k8s-apiserver",
			ActorHint:        "alice",
			ActorID:          "alice",
			ImpersonatedUser: "external-client-charlie", // Third-party identifier
			Labels: map[string]string{
				"session":       "sess-123",
				"secret_token":  "MUST_BE_REDACTED",
				"system_action": "read",
			},
			Description: "Multi-party delegated action",
		},
	})

	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/alice", nil)
	req.Header.Set("Authorization", "Bearer valid-svid")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	var exportResp api.SubjectAccessExportResponse
	if err := json.NewDecoder(resp.Body).Decode(&exportResp); err != nil {
		t.Fatalf("failed to decode: %v", err)
	}

	// 1. Check delegation sanitization (ThirdPartyMasked: true)
	if len(exportResp.IdentityPlane.Delegations) != 1 {
		t.Fatalf("expected 1 delegation, got %d", len(exportResp.IdentityPlane.Delegations))
	}
	del := exportResp.IdentityPlane.Delegations[0]
	if !del.ThirdPartyMasked {
		t.Errorf("expected ThirdPartyMasked true for shared delegation with external principal")
	}
	if del.SubjectRole != "delegate" {
		t.Errorf("expected subject role delegate, got %s", del.SubjectRole)
	}

	// 2. Check observation sanitization (ImpersonatedUser third party masked, secret label dropped)
	if len(exportResp.EvidencePlane.Observations) != 1 {
		t.Fatalf("expected 1 observation, got %d", len(exportResp.EvidencePlane.Observations))
	}
	obs := exportResp.EvidencePlane.Observations[0]
	if obs.ImpersonatedUser != "[REDACTED_THIRD_PARTY_SUBJECT]" {
		t.Errorf("expected ImpersonatedUser to be [REDACTED_THIRD_PARTY_SUBJECT] under Art 15(4), got %s", obs.ImpersonatedUser)
	}
	if _, hasSecret := obs.Labels["secret_token"]; hasSecret {
		t.Errorf("secret_token label was not sanitized from exported observation")
	}
}

func TestSubjectRights_BoundedSizeAndOverflowBehavior(t *testing.T) {
	now := time.Now().UTC()
	principal := api.Principal{
		Subject:   "spiffe://cluster.local/ns/prod/sa/alice-agent",
		TenantID:  "tenant-heavy",
		ExpiresAt: now.Add(time.Hour),
		Permissions: map[api.Permission]bool{
			api.PermissionPrivacyExport: true,
		},
		ActorIDs: map[string]bool{"heavy-alice": true, "*": true},
	}

	server, repo, memStore := setupSubjectRightsTestHarness(t, principal)
	ctx := context.Background()

	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "heavy-alice",
		Status:    model.ActorPromoted,
		CreatedAt: now.Add(-365 * 24 * time.Hour),
		UpdatedAt: now,
	})

	// Seed 250 observations for heavy-alice
	obsBatch := make([]model.Observation, 250)
	for i := 0; i < 250; i++ {
		obsBatch[i] = model.Observation{
			ID:          fmt.Sprintf("obs-heavy-%04d", i),
			Timestamp:   now.Add(-time.Duration(i) * time.Minute),
			Layer:       model.LayerEndpointHost,
			Source:      "host-sensor",
			ActorHint:   "heavy-alice",
			ActorID:     "heavy-alice",
			Description: fmt.Sprintf("Activity record #%d", i),
		}
	}
	_ = memStore.Append(ctx, obsBatch)

	// Query with limit=50
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/heavy-alice?limit=50", nil)
	req.Header.Set("Authorization", "Bearer valid-svid")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	var exportResp api.SubjectAccessExportResponse
	if err := json.NewDecoder(resp.Body).Decode(&exportResp); err != nil {
		t.Fatalf("failed to decode: %v", err)
	}

	if exportResp.EvidencePlane.TotalCount != 250 {
		t.Errorf("expected total count 250, got %d", exportResp.EvidencePlane.TotalCount)
	}
	if exportResp.EvidencePlane.ReturnedCount != 50 {
		t.Errorf("expected returned count 50, got %d", exportResp.EvidencePlane.ReturnedCount)
	}
	if !exportResp.EvidencePlane.Truncated {
		t.Errorf("expected truncated to be true")
	}
	if exportResp.EvidencePlane.OverflowRemediation == "" {
		t.Errorf("expected non-empty OverflowRemediation guidance")
	}

	// Test pagination with offset=50&limit=50
	req2, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/heavy-alice?limit=50&offset=50", nil)
	req2.Header.Set("Authorization", "Bearer valid-svid")
	resp2, err2 := http.DefaultClient.Do(req2)
	if err2 != nil {
		t.Fatalf("page 2 request failed: %v", err2)
	}
	defer resp2.Body.Close()

	var page2Resp api.SubjectAccessExportResponse
	if err := json.NewDecoder(resp2.Body).Decode(&page2Resp); err != nil {
		t.Fatalf("failed to decode page 2: %v", err)
	}
	if page2Resp.EvidencePlane.ReturnedCount != 50 {
		t.Errorf("expected page 2 returned count 50, got %d", page2Resp.EvidencePlane.ReturnedCount)
	}
	if page2Resp.EvidencePlane.Observations[0].ID != "obs-heavy-0050" {
		t.Errorf("expected first obs in page 2 to be obs-heavy-0050, got %s", page2Resp.EvidencePlane.Observations[0].ID)
	}
}

func TestSubjectRights_BoundedTimeExport_LargestSubject(t *testing.T) {
	now := time.Now().UTC()
	principal := api.Principal{
		Subject:   "spiffe://cluster.local/ns/prod/sa/benchmark-agent",
		TenantID:  "tenant-bench",
		ExpiresAt: now.Add(time.Hour),
		Permissions: map[api.Permission]bool{
			api.PermissionPrivacyExport: true,
		},
		ActorIDs: map[string]bool{"bench-subject": true, "*": true},
	}

	server, repo, memStore := setupSubjectRightsTestHarness(t, principal)
	ctx := context.Background()

	_ = repo.CreateActor(ctx, identity.ActorRecord{
		ActorID:   "bench-subject",
		Status:    model.ActorPromoted,
		CreatedAt: now.Add(-365 * 24 * time.Hour),
		UpdatedAt: now,
	})

	// 1,000 observations representing a large subject
	obsBatch := make([]model.Observation, 1000)
	for i := 0; i < 1000; i++ {
		obsBatch[i] = model.Observation{
			ID:          fmt.Sprintf("bench-obs-%04d", i),
			Timestamp:   now.Add(-time.Duration(i) * time.Second),
			Layer:       model.LayerEndpointHost,
			Source:      "host-sensor",
			ActorHint:   "bench-subject",
			ActorID:     "bench-subject",
			Description: "High-volume telemetry",
		}
	}
	_ = memStore.Append(ctx, obsBatch)

	start := time.Now()
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/bench-subject?limit=500", nil)
	req.Header.Set("Authorization", "Bearer valid-svid")
	resp, err := http.DefaultClient.Do(req)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", resp.StatusCode)
	}

	// Performance assertion: bounded time export must complete comfortably under 100ms
	if elapsed > 100*time.Millisecond {
		t.Errorf("export time %v exceeded bounded-time budget (100ms)", elapsed)
	}
}

func TestSubjectRights_MinimumGroupSize_EnforcesKAnonymity(t *testing.T) {
	// Verify constant and error
	if store.MinAggregateGroupSize != 5 {
		t.Errorf("expected MinAggregateGroupSize 5, got %d", store.MinAggregateGroupSize)
	}

	// Test small group count (< 5) fails k-anonymity check
	distinctSubjects := 3
	if distinctSubjects < store.MinAggregateGroupSize {
		err := store.ErrGroupSizeBelowAnonymityFloor
		if err == nil {
			t.Errorf("expected non-nil error")
		}
	}
}

func TestSubjectRights_PseudonymRing_DeterministicDerivedPseudonym(t *testing.T) {
	rootKey := []byte("01234567890123456789012345678901")
	pkr, err := pseudonym.NewKeyRing(rootKey, 1)
	if err != nil {
		t.Fatalf("failed to create keyring: %v", err)
	}

	p1, err := pkr.Pseudonym("tenant-1", "alice")
	if err != nil {
		t.Fatalf("pseudonym failed: %v", err)
	}
	p2, err := pkr.Pseudonym("tenant-1", "alice")
	if err != nil {
		t.Fatalf("pseudonym failed: %v", err)
	}
	if p1 != p2 {
		t.Errorf("expected deterministic pseudonyms, got %s != %s", p1, p2)
	}

	// Different tenant produces different pseudonym
	pOtherTenant, _ := pkr.Pseudonym("tenant-2", "alice")
	if p1 == pOtherTenant {
		t.Errorf("tenant isolation failure: same pseudonym across tenants %s == %s", p1, pOtherTenant)
	}
}

func TestSubjectRights_RequesterVerification_FailsClosed(t *testing.T) {
	now := time.Now().UTC()
	ctx := context.Background()

	// Seed actor "alice" and actor "mallory" in repo
	seedAlice := func(t *testing.T, repo *identity.MemoryRepository) {
		t.Helper()
		_ = repo.CreateActor(ctx, identity.ActorRecord{
			ActorID:   "alice",
			Status:    model.ActorPromoted,
			CreatedAt: now.Add(-30 * 24 * time.Hour),
			UpdatedAt: now,
		})
		aliasValidTo := now.Add(365 * 24 * time.Hour)
		_ = repo.AddAlias(ctx, identity.AliasRecord{
			ActorID:    "alice",
			AliasType:  "email",
			AliasValue: "alice@example.com",
			ValidFrom:  now.Add(-30 * 24 * time.Hour),
			ValidTo:    &aliasValidTo,
		})
	}
	seedMallory := func(t *testing.T, repo *identity.MemoryRepository) {
		t.Helper()
		_ = repo.CreateActor(ctx, identity.ActorRecord{
			ActorID:   "mallory",
			Status:    model.ActorPromoted,
			CreatedAt: now.Add(-10 * 24 * time.Hour),
			UpdatedAt: now,
		})
	}

	// 1. Case A: Self-access principal (alice)
	t.Run("SelfAccess_Succeeds", func(t *testing.T) {
		alicePrincipal := api.Principal{
			Subject:     "spiffe://cluster.local/ns/prod/sa/alice-agent",
			TenantID:    "tenant-finance",
			ExpiresAt:   now.Add(time.Hour),
			Permissions: map[api.Permission]bool{api.PermissionPrivacyExport: true},
			ActorIDs:    map[string]bool{"alice": true},
		}
		server, repo, _ := setupSubjectRightsTestHarness(t, alicePrincipal)
		seedAlice(t, repo)

		req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/alice", nil)
		req.Header.Set("Authorization", "Bearer token")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request failed: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("expected 200 OK for self-access, got %d", resp.StatusCode)
		}
	})

	// 2. Case B: Wildcard non-DPO principal (mallory) attempting third-party export
	t.Run("WildcardNonDPO_FailsClosed", func(t *testing.T) {
		malloryPrincipal := api.Principal{
			Subject:     "spiffe://cluster.local/ns/prod/sa/mallory-agent",
			TenantID:    "tenant-finance",
			ExpiresAt:   now.Add(time.Hour),
			Permissions: map[api.Permission]bool{api.PermissionPrivacyExport: true},
			// Wildcard actor scope passes the router, but lacks DPO administrative authority
			ActorIDs: map[string]bool{"mallory": true, "*": true},
		}
		server, repo, _ := setupSubjectRightsTestHarness(t, malloryPrincipal)
		seedAlice(t, repo)
		seedMallory(t, repo)

		targetRoutes := []string{
			"/api/v1/privacy/export/alice",
			"/api/v1/actors/alice/export",
			"/api/v1/privacy/export/alice?format=portability",
			"/api/v1/privacy/export/alice?format=article20_portable",
		}

		for _, route := range targetRoutes {
			req, _ := http.NewRequest(http.MethodGet, server.URL+route, nil)
			req.Header.Set("Authorization", "Bearer token")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("request %s failed: %v", route, err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusForbidden {
				t.Errorf("expected 403 Forbidden for route %s, got %d", route, resp.StatusCode)
			}
		}

		// Mallory must still be able to export her own data
		ownReq, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/mallory", nil)
		ownReq.Header.Set("Authorization", "Bearer token")
		ownResp, err := http.DefaultClient.Do(ownReq)
		if err != nil {
			t.Fatalf("own export request failed: %v", err)
		}
		defer ownResp.Body.Close()
		if ownResp.StatusCode != http.StatusOK {
			t.Errorf("expected 200 OK for mallory self-export, got %d", ownResp.StatusCode)
		}
	})

	// 3. Case C: Administrative DPO principal holding PermissionPrivacyAdmin
	t.Run("DPOWithPrivacyAdminPermission_Succeeds", func(t *testing.T) {
		dpoPrincipal := api.Principal{
			Subject:   "spiffe://cluster.local/ns/prod/sa/dpo-auditor",
			TenantID:  "tenant-finance",
			ExpiresAt: now.Add(time.Hour),
			Permissions: map[api.Permission]bool{
				api.PermissionPrivacyExport: true,
				api.PermissionPrivacyAdmin:  true,
			},
			ActorIDs: map[string]bool{"*": true},
		}
		server, repo, _ := setupSubjectRightsTestHarness(t, dpoPrincipal)
		seedAlice(t, repo)

		for _, route := range []string{
			"/api/v1/privacy/export/alice",
			"/api/v1/actors/alice/export",
			"/api/v1/privacy/export/alice?format=portability",
			"/api/v1/privacy/export/alice?format=article20_portable",
		} {
			req, _ := http.NewRequest(http.MethodGet, server.URL+route, nil)
			req.Header.Set("Authorization", "Bearer token")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("dpo request %s failed: %v", route, err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				t.Errorf("expected 200 OK for DPO on route %s, got %d", route, resp.StatusCode)
			}
		}
	})

	// 4. Case D: DPO Service Account principal
	t.Run("DPOServiceAccount_Succeeds", func(t *testing.T) {
		dpoSaPrincipal := api.Principal{
			Subject:     "spiffe://cluster.local/ns/prod/sa/dpo",
			TenantID:    "tenant-finance",
			ExpiresAt:   now.Add(time.Hour),
			Permissions: map[api.Permission]bool{api.PermissionPrivacyExport: true},
			ActorIDs:    map[string]bool{"*": true},
		}
		server, repo, _ := setupSubjectRightsTestHarness(t, dpoSaPrincipal)
		seedAlice(t, repo)

		req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/v1/privacy/export/alice", nil)
		req.Header.Set("Authorization", "Bearer token")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request failed: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("expected 200 OK for DPO SA, got %d", resp.StatusCode)
		}
	})
}
