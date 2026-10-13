// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Tenancy scoping and de-duplication do NOT commute, and these tests pin which order is correct.
//
// The bounded-read change (b94f42353) moved scoping ahead of de-duplication in
// handleQueryObservations: tenancy became a pushed-down store predicate (q.TenantID) and the
// dedupe became an inline `seen` map over the stream, where before the handler read everything,
// called store.DedupeByID, and only then called scopeObservations. That was argued at the time
// as a pure cost optimisation on the grounds that the two commute. They do not, and the new
// order is the one that is correct as well as cheaper.
//
// # Why one observation ID can carry two tenant labels
//
// Observation.ID is a hash of the evidence reference (see the header comment on
// collectors.Deduper) and tenancy is NOT an input to it. The tenant label is stamped separately
// and afterwards, by collectors.BindTenant, from collector configuration — "awslogs, one
// instance per account". Two collector instances configured for two tenants over overlapping
// evidence therefore mint the same ID under two different tenant labels. The write-side Deduper
// cannot prevent it either: it is keyed by ID alone and is per-instance, so each instance admits
// its own copy, and a shared one would be worse still (it would drop the second tenant's row
// outright).
//
// # The two orders, over {ID:X, tenant:A} stored before {ID:X, tenant:B}
//
// Dedupe first: DedupeByID keeps the FIRST occurrence, so the A copy survives and the B copy is
// discarded as a duplicate. scopeObservations for tenant B then drops the surviving A copy
// because its label does not match. B sees nothing — it has lost an observation it is entitled
// to, and A kept its row only by the accident of being stored first.
//
// Scope first: the pushed-down predicate prunes the A copy in the engine, the stream yields only
// B's copy, and the inline dedupe keeps it. Each tenant gets its own copy.
//
// # The leak direction, which is the dangerous one
//
// Scope-first cannot return another tenant's row. The pushed-down predicate admits only rows
// labelled with the caller's tenant (store.matchesFilters), and the inline dedupe only ever
// removes rows, never substitutes one. So the result is a subset of the rows labelled with the
// caller's tenant, and every row scope-first returns that dedupe-first would have suppressed is
// by construction the caller's own. TestQueryObservations_ScopeBeforeDedupeReturnsNoOtherTenantsRows
// asserts that invariant rather than leaving it as an argument.
//
// The "they commute" claim is true for exactly one case — a cross-tenant read, where no tenant
// predicate applies and both orders collapse a colliding ID to one arbitrary copy. That case is
// pinned separately by TestQueryObservations_CrossTenantReadIsOrderIndependent so the narrowed
// claim keeps a test behind it.

// Static-key tokens for the two-tenant fixture. Each is >= minStaticBearerTokenLength (32) and
// distinct from the review API's tokens in policy_routes_test.go, so a test can never pass
// because two keys collided.
const (
	tenantPairAToken     = "forgeTenantAObservationAnalysisReadKey00000"
	tenantPairBToken     = "forgeTenantBObservationAnalysisReadKey00000"
	tenantPairCrossToken = "forgeCrossTenantObservationAnalysisKey00000"
)

// tenantPairFixture builds the API with three scoped principals over an empty store: a tenant-a
// reader, a tenant-b reader, and a cross-tenant reader. policyAPIFixture cannot be reused — it
// is tenant-a only and seeds a policy corpus, and these tests need two tenants and an empty
// store they fill themselves.
func tenantPairFixture(t *testing.T) (http.Handler, *Handlers) {
	t.Helper()
	delegate, _, _ := testJWTDelegate(t)
	expires := time.Now().Add(24 * time.Hour)
	a, err := NewStaticKeyAuthenticator([]StaticBearerConfig{
		{Name: "forge-tenant-a-reader", Token: tenantPairAToken, Subject: "static-key/forge-tenant-a-reader",
			TenantID: "tenant-a", Permissions: []Permission{PermissionObservationRead, PermissionAnalysisRead},
			ExpiresAt: expires},
		{Name: "forge-tenant-b-reader", Token: tenantPairBToken, Subject: "static-key/forge-tenant-b-reader",
			TenantID: "tenant-b", Permissions: []Permission{PermissionObservationRead, PermissionAnalysisRead},
			ExpiresAt: expires},
		{Name: "forge-cross-reader", Token: tenantPairCrossToken, Subject: "static-key/forge-cross-reader",
			TenantID: "tenant-a", Permissions: []Permission{PermissionObservationRead, PermissionAnalysisRead,
				PermissionCrossTenantRead}, ExpiresAt: expires},
	}, delegate)
	if err != nil {
		t.Fatal(err)
	}

	aw := audit.NewFakeWriter()
	s := store.NewMemoryStore()
	e, err := correlation.NewEngine(s)
	if err != nil {
		t.Fatal(err)
	}
	h := &Handlers{Store: s, Engine: e, Audit: aw}
	router, err := NewProtectedRouter(h, a, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return a.ActingTenantGate(router), h
}

// oldOrderDedupeThenScope is the pipeline handleQueryObservations used before the bounded-read
// change (b94f42353^, handlers.go:762-763): read everything, collapse by ID, then drop the rows
// this principal may not see. It is reproduced here so the tests compare the two orders against
// one corpus rather than asserting today's behaviour in isolation.
func oldOrderDedupeThenScope(rows []model.Observation, tenant string, all bool, limit int) []model.Observation {
	return scopeObservations(store.DedupeByID(rows), tenant, all, limit)
}

// tenantRow builds one observation owned by tenant.
func tenantRow(id, tenant string, layer model.Layer, fidelity model.FidelityTier, ts time.Time) model.Observation {
	return model.Observation{
		ID:        id,
		Timestamp: ts,
		Layer:     layer,
		Fidelity:  fidelity,
		Source:    "test",
		Labels:    map[string]string{ObservationTenantLabel: tenant},
	}
}

// getObservationsAs performs GET target as the principal holding token.
func getObservationsAs(t *testing.T, srv http.Handler, token, target string) []model.Observation {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET %s: status %d body %s", target, rr.Code, rr.Body.String())
	}
	var out []model.Observation
	if err := json.NewDecoder(rr.Body).Decode(&out); err != nil {
		t.Fatalf("decoding GET %s: %v", target, err)
	}
	return out
}

// idSet reduces rows to the set of their IDs, so an assertion about WHICH observations came back
// does not accidentally constrain the order they came back in.
func idSet(rows []model.Observation) map[string]int {
	out := make(map[string]int, len(rows))
	for _, o := range rows {
		out[o.ID]++
	}
	return out
}

// TestQueryObservations_ScopeBeforeDedupeKeepsEachTenantsOwnCopy is the regression test for the
// cross-tenant data loss the bounded-read reordering fixed. Dedupe-first drops the copy belonging
// to whichever tenant did not happen to write first; scope-first gives each tenant its own.
func TestQueryObservations_ScopeBeforeDedupeKeepsEachTenantsOwnCopy(t *testing.T) {
	srv, h := tenantPairFixture(t)
	base := time.Now().UTC().Add(-time.Hour)

	// One derived ID under two tenant labels, tenant-a's copy stored first, plus an unambiguous
	// row each so the fixture is not degenerate.
	corpus := []model.Observation{
		tenantRow("shared-evidence", "tenant-a", model.LayerCloudControlPlane, model.FidelityDefinitive, base),
		tenantRow("shared-evidence", "tenant-b", model.LayerCloudControlPlane, model.FidelityDefinitive, base.Add(time.Second)),
		tenantRow("only-a", "tenant-a", model.LayerNetworkEgress, model.FidelityStrong, base.Add(2*time.Second)),
		tenantRow("only-b", "tenant-b", model.LayerNetworkEgress, model.FidelityStrong, base.Add(3*time.Second)),
	}
	if err := h.Store.Append(context.Background(), corpus); err != nil {
		t.Fatal(err)
	}

	// The old order loses tenant-b's copy entirely: DedupeByID keeps tenant-a's row because it is
	// first, and scopeObservations for tenant-b then discards it.
	if n := idSet(oldOrderDedupeThenScope(corpus, "tenant-b", false, 0))["shared-evidence"]; n != 0 {
		t.Fatalf("the old dedupe-then-scope order returned %d copies of the shared ID to tenant-b; "+
			"it returned 0 when this test was written, and that loss is the regression being "+
			"guarded. If the old order is no longer lossy, this test's premise is gone and the "+
			"ordering decision must be re-derived", n)
	}
	// tenant-a survives the old order, but only by the accident of being stored first. That is
	// asserted so the asymmetry is on the record: the old order's correctness depended on store
	// ordering, which no caller controls.
	if n := idSet(oldOrderDedupeThenScope(corpus, "tenant-a", false, 0))["shared-evidence"]; n != 1 {
		t.Fatalf("the old order returned %d copies of the shared ID to tenant-a, want 1; the "+
			"first-occurrence semantics of store.DedupeByID have changed", n)
	}

	// The new order: each tenant gets exactly its own copy.
	for _, tc := range []struct {
		name   string
		token  string
		tenant string
		other  string
	}{
		{"tenant-a", tenantPairAToken, "tenant-a", "only-b"},
		{"tenant-b", tenantPairBToken, "tenant-b", "only-a"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := getObservationsAs(t, srv, tc.token, "/api/v1/observations")
			ids := idSet(got)
			if ids["shared-evidence"] != 1 {
				t.Errorf("%s got %d copies of the shared observation ID, want exactly 1: scoping "+
					"must run before de-duplication or this tenant loses a row it is entitled to "+
					"see (see the file comment and handleQueryObservations)",
					tc.tenant, ids["shared-evidence"])
			}
			if ids[tc.other] != 0 {
				t.Errorf("%s was shown %q, which belongs to the other tenant", tc.tenant, tc.other)
			}
			for _, o := range got {
				if o.Labels[ObservationTenantLabel] != tc.tenant {
					t.Errorf("%s got observation %q labelled %q: the copy returned must be this "+
						"tenant's own, not whichever copy happened to be stored first",
						tc.tenant, o.ID, o.Labels[ObservationTenantLabel])
				}
			}
		})
	}
}

// TestQueryObservations_ScopeBeforeDedupeReturnsNoOtherTenantsRows pins the dangerous direction:
// reordering must not make a row visible to a tenant that does not own it. The corpus collides
// IDs in BOTH storage orders so neither tenant is advantaged by being written first.
func TestQueryObservations_ScopeBeforeDedupeReturnsNoOtherTenantsRows(t *testing.T) {
	srv, h := tenantPairFixture(t)
	base := time.Now().UTC().Add(-time.Hour)

	corpus := []model.Observation{
		// a-then-b
		tenantRow("collide-ab", "tenant-a", model.LayerCloudControlPlane, model.FidelityDefinitive, base),
		tenantRow("collide-ab", "tenant-b", model.LayerCloudControlPlane, model.FidelityDefinitive, base.Add(time.Second)),
		// b-then-a
		tenantRow("collide-ba", "tenant-b", model.LayerNetworkEgress, model.FidelityStrong, base.Add(2*time.Second)),
		tenantRow("collide-ba", "tenant-a", model.LayerNetworkEgress, model.FidelityStrong, base.Add(3*time.Second)),
		tenantRow("only-a", "tenant-a", model.LayerNetworkEgress, model.FidelitySuggestive, base.Add(4*time.Second)),
		tenantRow("only-b", "tenant-b", model.LayerNetworkEgress, model.FidelitySuggestive, base.Add(5*time.Second)),
	}
	if err := h.Store.Append(context.Background(), corpus); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		token  string
		tenant string
	}{
		{tenantPairAToken, "tenant-a"},
		{tenantPairBToken, "tenant-b"},
	} {
		t.Run(tc.tenant, func(t *testing.T) {
			// Every ID this tenant owns in the corpus, which is the ceiling on what it may see.
			entitled := map[string]struct{}{}
			for _, o := range corpus {
				if o.Labels[ObservationTenantLabel] == tc.tenant {
					entitled[o.ID] = struct{}{}
				}
			}

			got := getObservationsAs(t, srv, tc.token, "/api/v1/observations")
			if len(got) == 0 {
				t.Fatalf("%s saw no rows; the fixture no longer exercises the read", tc.tenant)
			}
			for _, o := range got {
				if label := o.Labels[ObservationTenantLabel]; label != tc.tenant {
					t.Errorf("CROSS-TENANT DISCLOSURE: %s was returned observation %q labelled %q",
						tc.tenant, o.ID, label)
				}
				if _, ok := entitled[o.ID]; !ok {
					t.Errorf("CROSS-TENANT DISCLOSURE: %s was returned observation %q, which no "+
						"row of its own carries", tc.tenant, o.ID)
				}
			}
			// Scoping before de-duplication must not duplicate either: one row per derived ID.
			for id, n := range idSet(got) {
				if n != 1 {
					t.Errorf("%s got observation %q %d times, want exactly 1", tc.tenant, id, n)
				}
			}
		})
	}
}

// TestQueryObservations_CrossTenantReadIsOrderIndependent pins the one case in which the two
// orders genuinely do commute, so the narrowed claim in handleQueryObservations keeps a test
// behind it. With no tenant predicate, both orders collapse a colliding ID to one copy.
func TestQueryObservations_CrossTenantReadIsOrderIndependent(t *testing.T) {
	srv, h := tenantPairFixture(t)
	base := time.Now().UTC().Add(-time.Hour)

	corpus := []model.Observation{
		tenantRow("collide-ab", "tenant-a", model.LayerCloudControlPlane, model.FidelityDefinitive, base),
		tenantRow("collide-ab", "tenant-b", model.LayerCloudControlPlane, model.FidelityDefinitive, base.Add(time.Second)),
		tenantRow("only-a", "tenant-a", model.LayerNetworkEgress, model.FidelityStrong, base.Add(2*time.Second)),
		tenantRow("only-b", "tenant-b", model.LayerNetworkEgress, model.FidelityStrong, base.Add(3*time.Second)),
	}
	if err := h.Store.Append(context.Background(), corpus); err != nil {
		t.Fatal(err)
	}

	want := idSet(oldOrderDedupeThenScope(corpus, "", true, 0))
	got := idSet(getObservationsAs(t, srv, tenantPairCrossToken, "/api/v1/observations"))

	if len(want) != len(got) {
		t.Fatalf("cross-tenant read returned %d distinct IDs, the old order returned %d; the two "+
			"orders must agree when no tenant predicate applies", len(got), len(want))
	}
	for id, n := range want {
		if got[id] != n {
			t.Errorf("cross-tenant read returned observation %q %d times, the old order returned "+
				"it %d times", id, got[id], n)
		}
	}
}
