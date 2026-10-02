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

func tenancyRouter(t *testing.T) (*ProtectedRouter, *Handlers) {
	t.Helper()
	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	if sunset, _ := time.Parse(time.DateOnly, StaticBearerSunset); expires.After(sunset) {
		expires = sunset
	}
	read := []Permission{PermissionObservationRead, PermissionStream}
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
