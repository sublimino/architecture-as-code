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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
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
	// actor_ids "*" passes the router's per-actor allow-list on the {id} routes, so what is left to
	// decide the reply is tenancy alone.
	anyActor := []string{"*"}
	read := []Permission{PermissionObservationRead, PermissionStream, PermissionActorList, PermissionActorRead, PermissionAnalysisRead, PermissionActorWrite, PermissionAnalysisRun}
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "reader-a", Token: tenantAToken, Subject: "static-key/reader-a", TenantID: "tenant-a", Permissions: read, ActorIDs: anyActor, ExpiresAt: expires},
		{Name: "reader-b", Token: tenantBToken, Subject: "static-key/reader-b", TenantID: "tenant-b", Permissions: read, ActorIDs: anyActor, ExpiresAt: expires},
		{Name: "reader-all", Token: crossToken, Subject: "static-key/reader-all", TenantID: "tenant-a",
			Permissions: append([]Permission{PermissionCrossTenantRead}, read...), ActorIDs: anyActor, ExpiresAt: expires},
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

func postJSON(t *testing.T, router http.Handler, token, path string, wantStatus int) string {
	t.Helper()
	w := httptest.NewRecorder()
	router.ServeHTTP(w, bearerRequest(http.MethodPost, path, token))
	if w.Code != wantStatus {
		t.Fatalf("POST %s: %d %s, want %d", path, w.Code, w.Body.String(), wantStatus)
	}
	return strings.TrimSpace(w.Body.String())
}

// Promoting another tenant's actor is answered like promoting an absent one, and changes nothing.
func TestActorPromotionIsScopedToThePrincipalsTenant(t *testing.T) {
	router, h := tenancyRouter(t)
	foreign := tenancyActors["obs-1-tenant-b"]
	body := postJSON(t, router, tenantAToken, "/api/v1/actors/"+foreign+"/promote", http.StatusNotFound)
	if !strings.Contains(body, "not found") {
		t.Fatalf("tenant-a promoting a tenant-b actor: %s", body)
	}
	if a := h.Engine.GetActor(foreign); a == nil || a.PromotedAt != nil {
		t.Fatalf("the refused promotion changed the actor: %+v", a)
	}
	postJSON(t, router, tenantBToken, "/api/v1/actors/"+foreign+"/promote", http.StatusOK)
}

// Correlation runs over the whole store, but reports back only what the caller may read.
func TestCorrelationReportsOnlyThePrincipalsTenant(t *testing.T) {
	router, _ := tenancyRouter(t)
	var resp struct {
		ActorsDiscovered int                      `json:"actors_discovered"`
		Actors           []model.ProvisionalActor `json:"actors"`
	}
	if err := json.Unmarshal([]byte(postJSON(t, router, tenantAToken, "/api/v1/correlate", http.StatusOK)), &resp); err != nil {
		t.Fatal(err)
	}
	for _, a := range resp.Actors {
		for _, ev := range a.EvidenceChain {
			if !strings.HasSuffix(ev.ObservationID, "tenant-a") {
				t.Fatalf("tenant-a correlation reports actor %s built from %s", a.ID, ev.ObservationID)
			}
		}
	}
	if resp.ActorsDiscovered != len(resp.Actors) || resp.ActorsDiscovered == 0 {
		t.Fatalf("tenant-a correlation: discovered %d, returned %d", resp.ActorsDiscovered, len(resp.Actors))
	}
}

// A quarantine record carries no evidence chain, so its tenant is unknown: the estate-wide
// authorization listing shows it only to a cross-tenant principal.
func TestQuarantinedActorsAreListedCrossTenantOnly(t *testing.T) {
	router, h := tenancyRouter(t)
	if _, err := h.Engine.QuarantineActor(context.Background(), "quarantined-elsewhere",
		model.QuarantineRecord{ActorID: "quarantined-elsewhere", AttemptedAt: time.Now(), QuarantinedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if body := getJSON(t, router, tenantAToken, "/api/v1/authorization", http.StatusOK, nil); strings.Contains(body, "quarantined-elsewhere") {
		t.Fatalf("tenant-a estate listing shows a tenantless quarantined actor: %s", body)
	}
	if body := getJSON(t, router, crossToken, "/api/v1/authorization", http.StatusOK, nil); !strings.Contains(body, "quarantined-elsewhere") {
		t.Fatalf("cross-tenant estate listing omits the quarantined actor: %s", body)
	}
}

// Edge rules of the two scoping helpers, which the router-level tests cannot reach: a principal
// with no tenant reads nothing (not the untagged rows, whose tenant is also ""), and an actor with
// no evidence has no tenant, so it is never visible to a tenant-scoped principal.
func TestScopeHelpersFailClosedOnMissingTenancy(t *testing.T) {
	obs := []model.Observation{{ID: "untagged", Labels: map[string]string{}}, {ID: "a", Labels: map[string]string{ObservationTenantLabel: "tenant-a"}}}
	if got := scopeObservations(obs, "", false, 0); len(got) != 0 {
		t.Fatalf("a principal with no tenant read %d observations, want 0", len(got))
	}
	s := actorScope{tenant: "tenant-a", obsTenant: map[string]string{"a": "tenant-a"}}
	if s.visible(&model.ProvisionalActor{ID: "no-evidence"}) {
		t.Fatal("an actor with no evidence chain is visible to a tenant-scoped principal")
	}
	if !s.visible(&model.ProvisionalActor{ID: "own", EvidenceChain: []model.EvidenceLink{{ObservationID: "a"}}}) {
		t.Fatal("an actor built only from the principal's own observations is not visible")
	}
	if s.visible(&model.ProvisionalActor{ID: "mixed", EvidenceChain: []model.EvidenceLink{{ObservationID: "a"}, {ObservationID: "untagged"}}}) {
		t.Fatal("an actor with mixed-tenant evidence is visible to a tenant-scoped principal")
	}
}

const (
	writerAToken     = "wwwwTenantAwriter000000000000000000000000000"
	crossWriterToken = "cccCrossTenantWriter0000000000000000000000000"
)

func writeRouter(t *testing.T) (*ProtectedRouter, *Handlers) {
	t.Helper()
	delegate, _, _ := testJWTDelegate(t)
	expires, _ := time.Parse(time.DateOnly, StaticBearerSunset)
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "writer-a", Token: writerAToken, Subject: "static-key/writer-a", TenantID: "tenant-a",
			Permissions: []Permission{PermissionObservationWrite, PermissionCollectorWrite}, ExpiresAt: expires},
		{Name: "cross-writer", Token: crossWriterToken, Subject: "static-key/cross-writer", TenantID: "kusari",
			Permissions: []Permission{PermissionObservationWrite, PermissionCrossTenantWrite}, ExpiresAt: expires},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}
	aw := audit.NewFakeWriter()
	h, _ := newTestHandlersWithAudit(t, aw)
	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return router, h
}

func postObservations(t *testing.T, router http.Handler, token string, tenants ...string) *httptest.ResponseRecorder {
	t.Helper()
	var batch []model.Observation
	for i, tenant := range tenants {
		o := model.Observation{ID: "w-" + string(rune('0'+i)), Timestamp: time.Now().UTC(), Layer: model.LayerEndpointHost,
			Fidelity: model.FidelityStrong, Source: "test", Confidence: 0.5, RawEvidenceRef: "ref", Labels: map[string]string{}}
		if tenant != "" {
			o.Labels[ObservationTenantLabel] = tenant
		}
		batch = append(batch, o)
	}
	body, _ := json.Marshal(batch)
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", strings.NewReader(string(body)))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	return w
}

func storedTenants(t *testing.T, h *Handlers) []string {
	t.Helper()
	obs, err := h.Store.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, o := range obs {
		out = append(out, o.ID+"="+o.Labels[ObservationTenantLabel])
	}
	sort.Strings(out)
	return out
}

// A tenant-scoped writer writes its own tenant: an untagged observation is stamped with it, and a
// batch naming any other tenant is refused whole (403, nothing stored).
func TestObservationWritesAreBoundToTheWritersTenant(t *testing.T) {
	router, h := writeRouter(t)
	if w := postObservations(t, router, writerAToken, "", "tenant-a"); w.Code != http.StatusCreated {
		t.Fatalf("own-tenant batch: %d %s, want 201", w.Code, w.Body.String())
	}
	if got := strings.Join(storedTenants(t, h), ","); got != "w-0=tenant-a,w-1=tenant-a" {
		t.Fatalf("stored %s, want both stamped tenant-a", got)
	}
	for _, foreign := range []string{"tenant-b", "__unattributed__", "kusarі"} { // last is a Cyrillic і
		router, h := writeRouter(t)
		w := postObservations(t, router, writerAToken, "tenant-a", foreign)
		if w.Code != http.StatusForbidden || strings.TrimSpace(w.Body.String()) != `{"error":"tenant_mismatch"}` {
			t.Fatalf("tenant-a writing %q: %d %s, want 403 tenant_mismatch", foreign, w.Code, w.Body.String())
		}
		if got := storedTenants(t, h); len(got) != 0 {
			t.Fatalf("a refused batch stored %v", got)
		}
	}
}

// The sentinel is a cross-tenant writer: the payload's tenant stands, including the quarantine
// tenant for an unmapped workload, and an untagged observation stays untagged.
func TestCrossTenantWriterKeepsThePayloadTenant(t *testing.T) {
	router, h := writeRouter(t)
	if w := postObservations(t, router, crossWriterToken, "tenant-b", "__unattributed__", ""); w.Code != http.StatusCreated {
		t.Fatalf("cross-tenant batch: %d %s, want 201", w.Code, w.Body.String())
	}
	if got := strings.Join(storedTenants(t, h), ","); got != "w-0=tenant-b,w-1=__unattributed__,w-2=" {
		t.Fatalf("stored %s", got)
	}
}

// Seeding writes fixtures as the seeding principal's tenant, so a tenant-scoped key can read back
// what it seeded and nothing it did not.
func TestSeededFixturesBelongToTheSeedingTenant(t *testing.T) {
	router, h := writeRouter(t)
	postJSON(t, router, writerAToken, "/api/v1/collectors/seed", http.StatusCreated)
	got := storedTenants(t, h)
	if len(got) == 0 {
		t.Fatal("seed stored nothing")
	}
	for _, row := range got {
		if !strings.HasSuffix(row, "=tenant-a") {
			t.Fatalf("seeded fixture %s is not tenant-a's", row)
		}
	}
}

// Write binding fails closed where the router cannot reach: no principal, or a principal with no
// tenant, writes nothing rather than an untagged (cross-tenant) row.
func TestWriteBindingFailsClosedOnMissingTenancy(t *testing.T) {
	batch := func() []model.Observation { return []model.Observation{{ID: "x", Labels: map[string]string{}}} }
	bare := httptest.NewRequest(http.MethodPost, "/api/v1/observations", nil)
	if err := bindWriteTenancy(bare, batch()); err == nil {
		t.Fatal("a request with no principal was allowed to write")
	}
	noTenant := bare.WithContext(context.WithValue(bare.Context(), principalContextKey{},
		Principal{Subject: "s", Permissions: map[Permission]bool{PermissionObservationWrite: true}}))
	if err := bindWriteTenancy(noTenant, batch()); err == nil {
		t.Fatal("a principal with no tenant was allowed to write")
	}
}
