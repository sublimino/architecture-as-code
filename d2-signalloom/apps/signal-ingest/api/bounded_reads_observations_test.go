// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// The bounded-read fix covered the two BY-ID reads: observationByID and actorScopeFor. It did
// not cover the list reads, and these tests pin what is left.
//
// GET /api/v1/observations is the endpoint behind the dashboard's /api/signals/observations,
// which 502s reproducibly on kind-osramp after a normal login while every other dashboard
// call returns 200. handleQueryObservations parses the caller's `limit`, then sets q.Limit = 0
// before the store read:
//
//	limit := q.Limit
//	q.Limit = 0
//	obs, err := h.Store.QueryRange(r.Context(), q)
//
// A dashboard page load sends no after/before/layer/actor_id, so q is the zero Query and the
// handler materialises the entire store on every call. The reason for dropping the limit is
// real — tenancy scoping and DedupeByID both have to run before the limit, or a page is short
// by however many rows were filtered — but it is paid for by reading everything.
//
// GET /api/v1/store/stats has the matching defect. The commit that bounded actorScopeFor
// describes store/stats as issuing "TWO full-store scans per request -- its own and
// actorScopeFor's" and removes the second; handleStoreStats still opens with
// `h.Store.QueryRange(r.Context(), store.Query{})`, which is the first.
//
// Both assert on rows returned, in the same shape and with the same budget as
// bounded_reads_test.go, so a reader can compare them directly.

// TestQueryObservations_DoesNotMaterialiseTheWholeStore pins the list read behind the 502.
func TestQueryObservations_DoesNotMaterialiseTheWholeStore(t *testing.T) {
	srv, h := policyAPIFixture(t)
	fillStore(t, h.Store, boundedReadFillRows)
	cs := &countingStore{SignalStore: h.Store}
	h.Store = cs

	// Exactly what the dashboard sends: a page request with a limit and no other filter.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/observations?limit=50", nil)
	req.Header.Set("Authorization", "Bearer "+evidenceReaderToken)
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/observations: status %d body %s", rr.Code, rr.Body.String())
	}

	if len(cs.queries) == 0 {
		t.Fatal("the observations list issued no store query; the fixture no longer exercises the read")
	}
	for i, q := range cs.queries {
		if unfiltered(q) {
			t.Errorf("query %d is unfiltered: a page request for 50 rows asked the store for "+
				"everything it holds", i)
		}
		if cs.rows[i] > boundedReadRowBudget {
			t.Errorf("query %d returned %d rows for a 50-row page (budget %d, store holds >= %d): "+
				"the caller's limit is discarded before the store read",
				i, cs.rows[i], boundedReadRowBudget, boundedReadFillRows)
		}
	}
}

// TestStoreStats_DoesNotMaterialiseTheWholeStore pins the half of the store/stats defect that
// the bounded-read fix named but did not remove.
func TestStoreStats_DoesNotMaterialiseTheWholeStore(t *testing.T) {
	srv, h := policyAPIFixture(t)
	fillStore(t, h.Store, boundedReadFillRows)
	cs := &countingStore{SignalStore: h.Store}
	h.Store = cs

	req := httptest.NewRequest(http.MethodGet, "/api/v1/store/stats", nil)
	req.Header.Set("Authorization", "Bearer "+analysisReaderToken)
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)
	// Deliberately not skipped on a 403. The route needs PermissionAnalysisRead, so the
	// fixture carries a key that has it; a skip here would read as coverage while asserting
	// nothing, which is how an unbounded read stays invisible.
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/store/stats: status %d body %s", rr.Code, rr.Body.String())
	}

	if len(cs.queries) == 0 {
		t.Fatal("store/stats issued no store query; the fixture no longer exercises the read")
	}
	for i, q := range cs.queries {
		if unfiltered(q) {
			t.Errorf("query %d is unfiltered: store/stats still scans the whole store to count it", i)
		}
		if cs.rows[i] > boundedReadRowBudget {
			t.Errorf("query %d returned %d rows (budget %d, store holds >= %d)",
				i, cs.rows[i], boundedReadRowBudget, boundedReadFillRows)
		}
	}
}

// TestTenantLabelKeysAgree pins the two declarations of the tenancy label together.
//
// Tenancy is now a pushed-down store predicate, so store needs the label name and cannot
// import api to get it. If the two ever diverge, every scoped read silently filters on a
// column nothing writes: the observations page and store/stats would return empty rather than
// erroring, which reads as "no data" rather than as a bug.
func TestTenantLabelKeysAgree(t *testing.T) {
	if ObservationTenantLabel != store.TenantLabelKey {
		t.Fatalf("api.ObservationTenantLabel = %q but store.TenantLabelKey = %q; a scoped read "+
			"now filters on a column nothing writes and returns empty instead of failing",
			ObservationTenantLabel, store.TenantLabelKey)
	}
}
