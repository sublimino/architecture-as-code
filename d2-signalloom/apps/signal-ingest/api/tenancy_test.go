package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// Review finding (2026-10-02): no read handler consulted the principal's tenant, so ANY principal
// holding observations:read read every tenant's observations, whatever tenant its binding named.
// Observation tenancy is labels.tenant_id (the only tenant attribution the data carries). A
// principal reads its own tenant's observations; untagged and other tenants' observations need the
// explicit PermissionCrossTenantRead grant.

const (
	tenantAToken = "aaaaTenantAkey00000000000000000000000000000"
	tenantBToken = "bbbbTenantBkey00000000000000000000000000000"
	crossToken   = "xxxxCrossTenantKey0000000000000000000000000"
)

// tenancyActors maps the observation an actor was resolved from to the actor's ID.
var tenancyActors = map[string]string{}

func tenancyRouter(t *testing.T) (*ProtectedRouter, *Handlers) {
	t.Helper()
	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	if sunset, _ := time.Parse(time.DateOnly, StaticBearerSunset); expires.After(sunset) {
		expires = sunset
	}
	read := []Permission{PermissionObservationRead, PermissionStream, PermissionActorList, PermissionActorRead, PermissionAnalysisRead}
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "reader-a", Token: tenantAToken, Subject: "static-key/reader-a", TenantID: "tenant-a", Permissions: read, ExpiresAt: expires},
		{Name: "reader-b", Token: tenantBToken, Subject: "static-key/reader-b", TenantID: "tenant-b", Permissions: read, ExpiresAt: expires},
		{Name: "reader-all", Token: crossToken, Subject: "static-key/reader-all", TenantID: "tenant-a",
			Permissions: append([]Permission{PermissionCrossTenantRead}, read...), ExpiresAt: expires},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}
	aw := audit.NewFakeWriter()
	h, _ := newTestHandlersWithAudit(t, aw)
	base := time.Now().UTC().Add(-time.Minute)
	var obs []model.Observation
	for i, tenant := range []string{"tenant-a", "tenant-b", "", "tenant-a", "tenant-b"} {
		o := model.Observation{
			ID: "obs-" + string(rune('0'+i)) + "-" + tenant, Timestamp: base.Add(time.Duration(i) * time.Second),
			Layer: model.LayerEndpointHost, Fidelity: model.FidelityStrong, Source: "test", Confidence: 0.9,
			RawEvidenceRef: "ref", Labels: map[string]string{},
		}
		if tenant != "" {
			o.Labels["tenant_id"] = tenant
		}
		obs = append(obs, o)
	}
	if err := h.Store.Append(context.Background(), obs); err != nil {
		t.Fatal(err)
	}
	for i, o := range obs[:3] { // one actor per tenant-a, tenant-b and untagged observation
		o.ActorHint = "agent-" + string(rune('a'+i))
		actor, err := h.Engine.Resolve(o)
		if err != nil {
			t.Fatalf("resolve %s: %v", o.ID, err)
		}
		tenancyActors[o.ID] = actor.ID
	}
	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return router, h
}

func getObservationIDs(t *testing.T, router http.Handler, token, query string) []string {
	t.Helper()
	w := httptest.NewRecorder()
	router.ServeHTTP(w, bearerRequest(http.MethodGet, "/api/v1/observations"+query, token))
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/observations%s: %d %s, want 200", query, w.Code, w.Body.String())
	}
	var got []model.Observation
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("body is not a list of observations: %v (%s)", err, w.Body.String())
	}
	ids := make([]string, 0, len(got))
	for _, o := range got {
		ids = append(ids, o.ID)
	}
	sort.Strings(ids)
	return ids
}

func TestObservationReadsAreScopedToThePrincipalsTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	for _, tc := range []struct {
		name, token, want string
	}{
		{"tenant-a key", tenantAToken, "obs-0-tenant-a,obs-3-tenant-a"},
		{"tenant-b key", tenantBToken, "obs-1-tenant-b,obs-4-tenant-b"},
		{"cross-tenant key", crossToken, "obs-0-tenant-a,obs-1-tenant-b,obs-2-,obs-3-tenant-a,obs-4-tenant-b"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := strings.Join(getObservationIDs(t, router, tc.token, ""), ","); got != tc.want {
				t.Fatalf("read %s, want %s", got, tc.want)
			}
		})
	}
}

// The limit applies to what the principal may see, not to the store before filtering: otherwise a
// page of another tenant's rows starves the caller's own.
func TestObservationLimitCountsOnlyTheTenantsOwnRows(t *testing.T) {
	router, _ := tenancyRouter(t)
	if got := strings.Join(getObservationIDs(t, router, tenantBToken, "?limit=1"), ","); got != "obs-1-tenant-b" {
		t.Fatalf("tenant-b limit=1 read %q, want obs-1-tenant-b", got)
	}
}

// A forged tenant header or query parameter changes nothing: tenancy comes from the key.
func TestObservationScopeIgnoresForgedTenantInputs(t *testing.T) {
	router, _ := tenancyRouter(t)
	w := httptest.NewRecorder()
	r := bearerRequest(http.MethodGet, "/api/v1/observations?tenant_id=tenant-b", tenantAToken)
	r.Header.Set("X-Tenant-ID", "tenant-b")
	r.Header.Set("X-SignalLoom-Tenant", "tenant-b")
	router.ServeHTTP(w, r)
	if w.Code != http.StatusOK || strings.Contains(w.Body.String(), "tenant-b") {
		t.Fatalf("forged tenant inputs: %d %s, want 200 with tenant-a rows only", w.Code, w.Body.String())
	}
}

// The stream's Last-Event-ID replay reads the store too, so it is scoped the same way.
func TestObservationStreamReplayIsScopedToThePrincipalsTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	since := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	r := bearerRequest(http.MethodGet, "/api/v1/observations/stream?last_event_id="+since, tenantAToken).WithContext(ctx)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	body := w.Body.String()
	if w.Code != http.StatusOK || !strings.Contains(body, "obs-0-tenant-a") || !strings.Contains(body, "obs-3-tenant-a") {
		t.Fatalf("tenant-a replay: %d, missing its own rows: %s", w.Code, body)
	}
	for _, foreign := range []string{"obs-1-tenant-b", "obs-4-tenant-b", "obs-2-"} {
		if strings.Contains(body, foreign) {
			t.Fatalf("tenant-a replay carries %s: %s", foreign, body)
		}
	}
}

func getJSON(t *testing.T, router http.Handler, token, path string, wantStatus int, into any) string {
	t.Helper()
	w := httptest.NewRecorder()
	router.ServeHTTP(w, bearerRequest(http.MethodGet, path, token))
	if w.Code != wantStatus {
		t.Fatalf("GET %s: %d %s, want %d", path, w.Code, w.Body.String(), wantStatus)
	}
	if into != nil {
		if err := json.Unmarshal(w.Body.Bytes(), into); err != nil {
			t.Fatalf("GET %s body: %v (%s)", path, err, w.Body.String())
		}
	}
	return strings.TrimSpace(w.Body.String())
}

// An actor's tenant is the tenant of the observations it was correlated from. A principal sees an
// actor only when every evidence observation is its own tenant's; anything else is cross-tenant.
func TestActorReadsAreScopedToThePrincipalsTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	own, foreign, untagged := tenancyActors["obs-0-tenant-a"], tenancyActors["obs-1-tenant-b"], tenancyActors["obs-2-"]
	if own == "" || foreign == "" || untagged == "" || own == foreign || own == untagged {
		t.Fatalf("fixture actors not distinct: %v", tenancyActors)
	}

	var actors []model.ProvisionalActor
	getJSON(t, router, tenantAToken, "/api/v1/actors", http.StatusOK, &actors)
	if len(actors) != 1 || actors[0].ID != own {
		t.Fatalf("tenant-a lists %d actors %+v, want only %s", len(actors), actors, own)
	}
	getJSON(t, router, crossToken, "/api/v1/actors", http.StatusOK, &actors)
	if len(actors) != 3 {
		t.Fatalf("cross-tenant key lists %d actors, want 3", len(actors))
	}

	getJSON(t, router, tenantAToken, "/api/v1/actors/"+own, http.StatusOK, nil)
	for _, id := range []string{foreign, untagged} {
		// Exactly the body a genuinely absent actor gets: no existence oracle across tenants.
		if body := getJSON(t, router, tenantAToken, "/api/v1/actors/"+id, http.StatusNotFound, nil); body != `{"error":"actor not found"}` {
			t.Fatalf("tenant-a GET actor %s body = %s", id, body)
		}
	}
	getJSON(t, router, tenantBToken, "/api/v1/actors/"+foreign, http.StatusOK, nil)
	getJSON(t, router, crossToken, "/api/v1/actors/"+untagged, http.StatusOK, nil)
}

func TestActorAuthorizationIsScopedToThePrincipalsTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	foreign := tenancyActors["obs-1-tenant-b"]
	getJSON(t, router, tenantAToken, "/api/v1/actors/"+tenancyActors["obs-0-tenant-a"]+"/authorization", http.StatusOK, nil)
	if body := getJSON(t, router, tenantAToken, "/api/v1/actors/"+foreign+"/authorization", http.StatusNotFound, nil); !strings.Contains(body, "not found") {
		t.Fatalf("tenant-a authorization for a tenant-b actor: %s", body)
	}
}

// Aggregates count only what the principal may read.
func TestStoreStatsCountOnlyThePrincipalsTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	var stats StoreStatsResponse
	getJSON(t, router, tenantAToken, "/api/v1/store/stats", http.StatusOK, &stats)
	if stats.TotalObservations != 2 || stats.ActorCount != 1 {
		t.Fatalf("tenant-a stats: %d observations, %d actors; want 2 and 1", stats.TotalObservations, stats.ActorCount)
	}
	getJSON(t, router, crossToken, "/api/v1/store/stats", http.StatusOK, &stats)
	if stats.TotalObservations != 5 || stats.ActorCount != 3 {
		t.Fatalf("cross-tenant stats: %d observations, %d actors; want 5 and 3", stats.TotalObservations, stats.ActorCount)
	}
}
