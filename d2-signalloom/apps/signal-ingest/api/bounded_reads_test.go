// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// boundedReadFillRows is the size of the haystack. It only has to be large enough that "the
// handler read the whole store" and "the handler read the rows it named" are separated by more
// than noise; the real store on kind-osramp held ~2.5 days of continuous warden ingest, which is
// what turned this defect from a latency cost into an OOM kill.
const boundedReadFillRows = 5000

// boundedReadRowBudget is the most rows ANY single store query may return on a by-ID read path.
// It is generous relative to what the handlers actually need (one row, plus duplicates of it) and
// still two orders of magnitude below the haystack, so the assertion cannot be satisfied by an
// unfiltered scan no matter how the fixture grows.
const boundedReadRowBudget = 64

// countingStore records, per query, how many rows the store handed back, and whether the query
// carried any filter at all.
//
// Counting ROWS is the point. A test that counted queries would pass against the defect: the
// whole-store scan was a single QueryRange call. What made it an outage was the size of its
// result — every Observation in the store decoded into a live Go struct, then copied again
// through DedupeByID.
type countingStore struct {
	store.SignalStore
	queries   []store.Query
	rows      []int
	totalRows int
}

func (c *countingStore) QueryRange(ctx context.Context, q store.Query) ([]model.Observation, error) {
	out, err := c.SignalStore.QueryRange(ctx, q)
	c.queries = append(c.queries, q)
	c.rows = append(c.rows, len(out))
	c.totalRows += len(out)
	return out, err
}

// ScanObservations and ScanIDs count the rows a STREAMING read pulled out of the store.
//
// Without these the harness measures nothing once a handler stops calling QueryRange: cs.queries
// stays empty and every per-query assertion below is vacuously true. Counting streamed rows keeps
// "rows the handler pulled out of the store" the measured quantity whichever door it used, so a
// streaming read that still visits the whole table fails exactly as the materialising one did.
func (c *countingStore) ScanObservations(ctx context.Context, q store.Query, fn func(o *model.Observation) error) error {
	n := 0
	err := c.SignalStore.ScanObservations(ctx, q, func(o *model.Observation) error {
		n++
		return fn(o)
	})
	c.queries = append(c.queries, q)
	c.rows = append(c.rows, n)
	c.totalRows += n
	return err
}

func (c *countingStore) ScanIDs(ctx context.Context, q store.Query, fn func(id string) error) error {
	n := 0
	err := c.SignalStore.ScanIDs(ctx, q, func(id string) error {
		n++
		return fn(id)
	})
	c.queries = append(c.queries, q)
	c.rows = append(c.rows, n)
	c.totalRows += n
	return err
}

// ObservationStats records the query and ZERO rows, which is the honest count: an aggregate
// returns totals, not observations, so nothing crosses the interface for the handler to hold.
// Recording it keeps the call visible to the per-query assertions rather than invisible — a
// handler that quietly went back to QueryRange would otherwise look the same as this one.
func (c *countingStore) ObservationStats(ctx context.Context, q store.Query) (store.ObservationStats, error) {
	out, err := c.SignalStore.ObservationStats(ctx, q)
	c.queries = append(c.queries, q)
	c.rows = append(c.rows, 0)
	return out, err
}

// unfiltered reports whether q asks the store for everything it holds.
func unfiltered(q store.Query) bool {
	return q.IDs == nil && q.After.IsZero() && q.Before.IsZero() &&
		len(q.Layers) == 0 && q.ActorID == "" && q.SubjectID == "" &&
		q.TenantID == "" && q.Limit == 0
}

// fillStore adds n observations that are NOT the row under test, so a handler that reads the
// whole store is distinguishable from one that reads the row it asked for.
func fillStore(t *testing.T, s store.SignalStore, n int) {
	t.Helper()
	now := time.Now()
	batch := make([]model.Observation, 0, n)
	for i := 0; i < n; i++ {
		batch = append(batch, model.Observation{
			ID:        fmt.Sprintf("filler-%06d", i),
			Timestamp: now.Add(-time.Duration(i) * time.Second),
			Layer:     model.LayerNetworkEgress,
			Labels:    map[string]string{ObservationTenantLabel: "tenant-a"},
		})
	}
	if err := s.Append(context.Background(), batch); err != nil {
		t.Fatal(err)
	}
}

// TestObservationByID_DoesNotMaterialiseTheWholeStore pins the fix for the signal-ingest OOM
// crashloop on kind-osramp (13 restarts, exit 137, at a 2 GiB limit).
//
// observationByID used to call QueryRange with an empty store.Query, decode every row in the
// store, copy them all again through store.DedupeByID, scope them, and then scan linearly for a
// single ID. The ID is now a pushed-down filter, so the lookup costs the rows it names.
//
// The assertion is on rows returned, not on wall time or on memory: a timing or RSS assertion
// would be flaky under load and would not say WHY it regressed. "No single query returned more
// than boundedReadRowBudget rows out of boundedReadFillRows in the store" is exact, fast, and
// names the defect directly.
func TestObservationByID_DoesNotMaterialiseTheWholeStore(t *testing.T) {
	srv, h := policyAPIFixture(t)
	fillStore(t, h.Store, boundedReadFillRows)
	cs := &countingStore{SignalStore: h.Store}
	h.Store = cs

	// POST a review against a seeded decision. The route resolves the decision through
	// visibleDecision -> observationByID, which is the read under test.
	req := httptest.NewRequest(http.MethodPost, "/api/v1/policy/decisions/dec-a1/review",
		strings.NewReader(`{"verdict":"true_positive","note":"bounded read proof"}`))
	req.Header.Set("Authorization", "Bearer "+policyReviewerToken)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK && rr.Code != http.StatusCreated {
		t.Fatalf("review POST: status %d body %s", rr.Code, rr.Body.String())
	}

	if len(cs.queries) == 0 {
		t.Fatal("the review path issued no store query; the fixture no longer exercises the read")
	}
	for i, q := range cs.queries {
		if unfiltered(q) {
			t.Errorf("query %d is unfiltered: a by-ID read degenerated into a whole-store scan", i)
		}
		if cs.rows[i] > boundedReadRowBudget {
			t.Errorf("query %d returned %d rows (budget %d, store holds >= %d): the by-ID filter "+
				"is not reaching the store", i, cs.rows[i], boundedReadRowBudget, boundedReadFillRows)
		}
	}
	if cs.totalRows > boundedReadRowBudget*len(cs.queries) {
		t.Errorf("the review path read %d rows in total across %d queries; the store holds >= %d",
			cs.totalRows, len(cs.queries), boundedReadFillRows)
	}
}

// TestActorScope_ResolvesEvidenceByIDNotByWholeStore pins the second half of the same defect.
//
// actorScopeFor used to build a map of EVERY observation ID in the store to its tenant in order to
// check the handful of evidence IDs the request's actors actually cite — so GET
// /api/v1/store/stats issued two full-store scans per request, one here and one of its own.
func TestActorScope_ResolvesEvidenceByIDNotByWholeStore(t *testing.T) {
	srv, h := policyAPIFixture(t)
	fillStore(t, h.Store, boundedReadFillRows)
	cs := &countingStore{SignalStore: h.Store}
	h.Store = cs

	req := httptest.NewRequest(http.MethodGet, "/api/v1/actors", nil)
	req.Header.Set("Authorization", "Bearer "+policyReaderToken)
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)
	// The route may refuse this token for want of an analysis permission; what must never happen
	// is that it answers by reading the whole store.
	if rr.Code == http.StatusOK {
		for i, q := range cs.queries {
			if unfiltered(q) {
				t.Errorf("query %d is unfiltered: actor scoping scanned the whole store", i)
			}
		}
	}

	// The resolver is also asserted directly, because the router-level check above is only as
	// strong as the fixture's permissions. A tenant-scoped scope must resolve evidence tenancy by
	// ID, and must not re-query an ID it has already resolved.
	res := &obsTenantResolver{ctx: context.Background(), store: cs, tenant: make(map[string]string)}
	s := actorScope{tenant: "tenant-a", resolver: res}
	actor := &model.ProvisionalActor{
		ID:            "a1",
		EvidenceChain: []model.EvidenceLink{{ObservationID: "filler-000001"}},
	}
	before := len(cs.queries)
	if _, err := s.visible(actor); err != nil {
		t.Fatal(err)
	}
	if got := len(cs.queries) - before; got != 1 {
		t.Fatalf("resolving one evidence ID issued %d queries, want exactly 1", got)
	}
	if n := cs.rows[len(cs.rows)-1]; n > boundedReadRowBudget {
		t.Fatalf("resolving one evidence ID returned %d rows (budget %d, store holds >= %d)",
			n, boundedReadRowBudget, boundedReadFillRows)
	}
	// Second check, same ID: answered from the memo, no further store read.
	before = len(cs.queries)
	if _, err := s.visible(actor); err != nil {
		t.Fatal(err)
	}
	if got := len(cs.queries) - before; got != 0 {
		t.Fatalf("re-checking a resolved evidence ID issued %d queries, want 0", got)
	}
}

// TestEmptyIDSetReadsNothing guards the fail-closed direction, which is the one that fails
// silently. buildFilter emits no `id` predicate for a zero-length list, so a Query carrying a
// present-but-empty IDs slice would otherwise plan as an unfiltered scan and return the entire
// store to a caller that asked for no rows at all.
func TestEmptyIDSetReadsNothing(t *testing.T) {
	ms := store.NewMemoryStore()
	fillStore(t, ms, 100)
	got, err := ms.QueryRange(context.Background(), store.Query{IDs: []string{}})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("a present-but-empty ID set returned %d rows, want 0: an empty lookup read the store", len(got))
	}
	// And the absent filter still means "everything", which is what every existing caller relies on.
	all, err := ms.QueryRange(context.Background(), store.Query{})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 100 {
		t.Fatalf("a nil ID set returned %d rows, want 100", len(all))
	}
}
