package api

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// The fe-signalloom gateway serves every tenant's dashboard users through one key. Its key holds
// tenant:act-for; fe sends the verified user tenant as X-SignalLoom-Acting-Tenant and signal-ingest
// scopes the request to it. The header is honoured ONLY for that grant: for every other key it is
// ignored (not refused), exactly like X-Tenant-ID. A gateway request with no acting tenant is a
// 400, never an unscoped read. "*" (a superadmin) needs act-for AND tenant:cross-read.

func actingRequest(method, path, token string, acting ...string) *http.Request {
	r := bearerRequest(method, path, token)
	for _, a := range acting {
		r.Header.Add(ActingTenantHeader, a)
	}
	return r
}

func serve(router http.Handler, r *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	return w
}

// Tenant A through the gateway sees no tenant-B (or untagged) row on any read route.
func TestGatewayActingForATenantSeesOnlyThatTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	own, foreign := tenancyActors["obs-0-tenant-a"], tenancyActors["obs-1-tenant-b"]
	for _, path := range []string{"/api/v1/observations", "/api/v1/actors", "/api/v1/store/stats", "/api/v1/authorization"} {
		w := serve(router, actingRequest(http.MethodGet, path, gatewayToken, "tenant-a"))
		if w.Code != http.StatusOK {
			t.Fatalf("gateway acting for tenant-a GET %s: %d %s", path, w.Code, w.Body.String())
		}
		for _, leak := range []string{"tenant-b", "obs-2-", foreign} {
			if strings.Contains(w.Body.String(), leak) {
				t.Errorf("gateway acting for tenant-a GET %s leaks %q: %s", path, leak, w.Body.String())
			}
		}
	}
	if got := strings.Join(getObservationIDsActing(t, router, "tenant-a"), ","); got != "obs-0-tenant-a,obs-3-tenant-a" {
		t.Fatalf("gateway acting for tenant-a reads %s", got)
	}
	if w := serve(router, actingRequest(http.MethodGet, "/api/v1/actors/"+own, gatewayToken, "tenant-a")); w.Code != http.StatusOK {
		t.Fatalf("own actor: %d", w.Code)
	}
	if w := serve(router, actingRequest(http.MethodGet, "/api/v1/actors/"+foreign, gatewayToken, "tenant-a")); w.Code != http.StatusNotFound {
		t.Fatalf("tenant-b actor via gateway acting for tenant-a: %d, want 404", w.Code)
	}
	var stats StoreStatsResponse
	w := serve(router, actingRequest(http.MethodGet, "/api/v1/store/stats", gatewayToken, "tenant-a"))
	_ = json.Unmarshal(w.Body.Bytes(), &stats)
	if stats.TotalObservations != 2 || stats.ActorCount != 1 {
		t.Fatalf("gateway acting for tenant-a stats: %+v", stats)
	}
}

func getObservationIDsActing(t *testing.T, router http.Handler, acting string) []string {
	t.Helper()
	w := serve(router, actingRequest(http.MethodGet, "/api/v1/observations", gatewayToken, acting))
	var got []model.Observation
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	var ids []string
	for _, o := range got {
		ids = append(ids, o.ID)
	}
	return ids
}

// Writes through the gateway are the acting tenant's: stamped with it, and refused for another.
func TestGatewayWritesAreBoundToTheActingTenant(t *testing.T) {
	router, h := tenancyRouter(t)
	post := func(acting, tenantLabel string) *httptest.ResponseRecorder {
		labels := map[string]string{}
		if tenantLabel != "" {
			labels[ObservationTenantLabel] = tenantLabel
		}
		body, _ := json.Marshal([]model.Observation{{ID: "gw-" + acting + tenantLabel, Timestamp: nowUTC(), Layer: model.LayerEndpointHost,
			Fidelity: model.FidelityStrong, Source: "test", Confidence: 0.5, RawEvidenceRef: "ref", Labels: labels}})
		r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+gatewayToken)
		r.Header.Set(ActingTenantHeader, acting)
		return serve(router, r)
	}
	if w := post("tenant-a", ""); w.Code != http.StatusCreated {
		t.Fatalf("untagged write acting for tenant-a: %d %s", w.Code, w.Body.String())
	}
	if w := post("tenant-a", "tenant-b"); w.Code != http.StatusForbidden || strings.TrimSpace(w.Body.String()) != `{"error":"tenant_mismatch"}` {
		t.Fatalf("tenant-b write acting for tenant-a: %d %s, want 403 tenant_mismatch", w.Code, w.Body.String())
	}
	if got := storedTenants(t, h); !strings.Contains(strings.Join(got, ","), "gw-tenant-a=tenant-a") {
		t.Fatalf("gateway write not stamped with the acting tenant: %v", got)
	}
}

// No acting tenant, two of them, or a malformed one: 400, never an unscoped read.
func TestGatewayRequestWithoutAValidActingTenantIs400(t *testing.T) {
	router, _ := tenancyRouter(t)
	for name, tc := range map[string]struct {
		acting []string
		body   string
	}{
		"absent":            {nil, `{"error":"acting_tenant_required"}`},
		"empty":             {[]string{""}, `{"error":"acting_tenant_required"}`},
		"duplicated":        {[]string{"tenant-a", "tenant-b"}, `{"error":"acting_tenant_invalid"}`},
		"homoglyph":         {[]string{"kusarі"}, `{"error":"acting_tenant_invalid"}`},
		"quarantine tenant": {[]string{"__unattributed__"}, `{"error":"acting_tenant_invalid"}`},
		"list syntax":       {[]string{"tenant-a,tenant-b"}, `{"error":"acting_tenant_invalid"}`},
	} {
		w := serve(router, actingRequest(http.MethodGet, "/api/v1/observations", gatewayToken, tc.acting...))
		if w.Code != http.StatusBadRequest || strings.TrimSpace(w.Body.String()) != tc.body {
			t.Errorf("%s: %d %s, want 400 %s", name, w.Code, w.Body.String(), tc.body)
		}
	}
}

// "*" (fe maps a superadmin to it) reads across tenants only when the key also holds cross-read.
func TestGatewayActingForAllTenantsNeedsCrossRead(t *testing.T) {
	router, _ := tenancyRouter(t)
	var buf bytes.Buffer
	restore := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	defer slog.SetDefault(restore)

	r := actingRequest(http.MethodGet, "/api/v1/observations", gatewayToken, "*")
	r.Header.Set(ActingSubjectHeader, "admin@signalloom.local")
	w := serve(router, r)
	if w.Code != http.StatusOK || strings.Count(w.Body.String(), `"id":"obs-`) != 5 {
		t.Fatalf("superadmin via gateway: %d %s, want all 5 rows", w.Code, w.Body.String())
	}
	if !strings.Contains(buf.String(), "admin@signalloom.local") || !strings.Contains(buf.String(), `"key":"gateway"`) {
		t.Fatalf("an all-tenants request is not logged with the user subject and key: %s", buf.String())
	}
	w = serve(router, actingRequest(http.MethodGet, "/api/v1/observations", gatewayScopedToken, "*"))
	if w.Code != http.StatusForbidden || strings.TrimSpace(w.Body.String()) != `{"error":"cross_tenant_read_required"}` {
		t.Fatalf("\"*\" through a gateway key without cross-read: %d %s, want 403 cross_tenant_read_required", w.Code, w.Body.String())
	}
	// A gateway acting for one tenant must not keep the cross-read it holds for "*".
	if got := strings.Join(getObservationIDsActing(t, router, "tenant-b"), ","); got != "obs-1-tenant-b,obs-4-tenant-b" {
		t.Fatalf("gateway acting for tenant-b reads %s; its cross-read leaked into a scoped request", got)
	}
}

// For every key without act-for, the header is ignored — not refused, and not honoured.
func TestActingTenantHeaderIsIgnoredForOrdinaryKeys(t *testing.T) {
	router, _ := tenancyRouter(t)
	w := serve(router, actingRequest(http.MethodGet, "/api/v1/observations", tenantAToken, "tenant-b"))
	if w.Code != http.StatusOK || strings.Contains(w.Body.String(), "tenant-b") || !strings.Contains(w.Body.String(), "obs-0-tenant-a") {
		t.Fatalf("tenant-a key with a forged acting tenant: %d %s, want 200 with its own rows", w.Code, w.Body.String())
	}
	w = serve(router, actingRequest(http.MethodGet, "/api/v1/observations", tenantAToken, "*"))
	if w.Code != http.StatusOK || strings.Contains(w.Body.String(), "tenant-b") {
		t.Fatalf("tenant-a key forging \"*\": %d %s, want 200 own rows", w.Code, w.Body.String())
	}
	w = serve(router, actingRequest(http.MethodGet, "/api/v1/observations", tenantAToken, "kusarі", "x"))
	if w.Code != http.StatusOK {
		t.Fatalf("malformed acting header on an ordinary key must be ignored, got %d", w.Code)
	}
}

func nowUTC() time.Time { return time.Now().UTC() }
