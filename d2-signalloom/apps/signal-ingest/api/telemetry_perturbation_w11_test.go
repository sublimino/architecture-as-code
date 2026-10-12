// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// W11 perturbation probes for the coding-agent telemetry read routes.
//
// Doctrine: a figure is real iff it is a function of its inputs. These probes test
// whose inputs. A figure derived from caller-supplied data that the caller had no
// permission to write is not a measurement of the estate -- it is the caller's own
// claim, laundered through an aggregate that reads as observed fact.
//
// Each probe holds the request constant and varies exactly ONE axis; the axis is
// named in the test comment.

package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
)

// readOnlyPrincipal holds ONLY PermissionObservationRead. Both coding-agent read
// routes (/aggregate, /ordering) are registered against that permission in auth.go.
func readOnlyPrincipal(tenantID string) Principal {
	return Principal{
		Subject:     "spiffe://cluster.local/ns/prod/sa/dashboard-reader",
		TenantID:    tenantID,
		ExpiresAt:   time.Now().Add(time.Hour),
		Permissions: map[Permission]bool{PermissionObservationRead: true},
	}
}

func postOrdering(t *testing.T, router http.Handler, evA, evB map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]any{"event_a": evA, "event_b": evB})
	if err != nil {
		t.Fatalf("marshal ordering request: %v", err)
	}
	req := httptest.NewRequest("POST", "/api/v1/telemetry/coding-agents/ordering", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

func getAggregate(t *testing.T, router http.Handler) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/telemetry/coding-agents/aggregate", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

// TestW11_PO_A_OrderingMustNotWriteStoreUnderReadPermission
// AXIS: caller permission (read-only), request body held constant.
//
// POST /ordering is registered with PermissionObservationRead, but its handler calls
// store.Ingest twice on caller-supplied event bodies. A read-permission route that
// persists caller data makes every downstream aggregate a function of who queried it.
func TestW11_PO_A_OrderingMustNotWriteStoreUnderReadPermission(t *testing.T) {
	tenantID := "tenant-w11-po-a"
	router, _, _ := setupTestRouterWithPrincipal(t, readOnlyPrincipal(tenantID))

	now := time.Now().UTC()
	evA := validPayloadForSession(fmt.Sprintf("%064x", 0xA11), "TASK-A", 5, 1, now.Format(time.RFC3339Nano))
	evB := validPayloadForSession(fmt.Sprintf("%064x", 0xB22), "TASK-B", 9, 1, now.Add(time.Hour).Format(time.RFC3339Nano))

	if rec := postOrdering(t, router, evA, evB); rec.Code != http.StatusOK {
		t.Fatalf("ordering call setup failed: %d %s", rec.Code, rec.Body.String())
	}

	// A read-only caller stored nothing, so Query must see nothing.
	req := httptest.NewRequest("GET", "/api/v1/telemetry/coding-agents", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("query failed: %d %s", rec.Code, rec.Body.String())
	}
	var records []codingagent.StoredRecord
	if err := json.Unmarshal(rec.Body.Bytes(), &records); err != nil {
		t.Fatalf("parse query response: %v", err)
	}
	if len(records) != 0 {
		t.Errorf("INTEGRITY DEFECT: a principal holding only PermissionObservationRead "+
			"persisted %d telemetry records into tenant %q by calling POST /ordering. "+
			"Every /aggregate figure downstream is now a function of a read-only "+
			"caller's request body, not of observed telemetry.", len(records), tenantID)
	}
}

// TestW11_PO_B_KAnonymityFloorMustNotBeLiftableByAReadOnlyCaller
// AXIS: record count (0 -> 6), driven entirely through a read-permission route.
//
// The k=5 floor is the privacy refusal for /aggregate. If a read-only caller can
// manufacture the cohort that lifts the floor, the refusal is decorative and the
// figures released are the caller's own fabrications reflected back.
func TestW11_PO_B_KAnonymityFloorMustNotBeLiftableByAReadOnlyCaller(t *testing.T) {
	tenantID := "tenant-w11-po-b"
	router, _, _ := setupTestRouterWithPrincipal(t, readOnlyPrincipal(tenantID))

	// Baseline: empty cohort must refuse.
	if rec := getAggregate(t, router); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("baseline aggregate on an empty tenant should refuse with 422, got %d: %s",
			rec.Code, rec.Body.String())
	}

	// Three /ordering calls x two distinct sessions each = cohort of 6, over the k=5 floor.
	now := time.Now().UTC()
	for i := range 3 {
		evA := validPayloadForSession(fmt.Sprintf("%064x", 0xC000+i*2), "TASK-X", 5, 1,
			now.Add(time.Duration(i)*time.Minute).Format(time.RFC3339Nano))
		evB := validPayloadForSession(fmt.Sprintf("%064x", 0xC001+i*2), "TASK-Y", 5, 1,
			now.Add(time.Duration(i)*time.Minute+time.Hour).Format(time.RFC3339Nano))
		if rec := postOrdering(t, router, evA, evB); rec.Code != http.StatusOK {
			t.Fatalf("ordering call %d failed: %d %s", i, rec.Code, rec.Body.String())
		}
	}

	rec := getAggregate(t, router)
	if rec.Code == http.StatusOK {
		var agg codingagent.AggregateResult
		if err := json.Unmarshal(rec.Body.Bytes(), &agg); err != nil {
			t.Fatalf("parse aggregate: %v", err)
		}
		t.Errorf("PRIVACY + INTEGRITY DEFECT: the k=%d anonymity floor was lifted by a "+
			"read-only caller using POST /ordering alone. /aggregate now returns 200 with "+
			"group_size=%d, total_events=%d, total_tokens_in=%d -- every one of those "+
			"figures was supplied by the caller in an ordering request body. Before the "+
			"ordering calls the same request was correctly refused with 422.",
			codingagent.MinAggregateGroupSize, agg.GroupSize, agg.TotalEvents, agg.TotalTokensIn)
	} else if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("unexpected aggregate status %d: %s", rec.Code, rec.Body.String())
	}
}

// TestW11_PO_C_IntraSessionTimeDeltaMustCarryMilliseconds
// AXIS: elapsed_s separation between two events in one session.
//
// On the intra-session branch, time_delta_ms is computed as a difference of the
// synthetic sort key (elapsed_s*1e6 + step_count) and then published under a field
// named *_ms. The number is a function of its inputs but not of the quantity its name
// claims, so any consumer reading it as a duration reads a fabricated one. The paired
// skew_bound_ms=0 asserts a measured bound on a path where no skew was measured.
func TestW11_PO_C_IntraSessionTimeDeltaMustCarryMilliseconds(t *testing.T) {
	tenantID := "tenant-w11-po-c"
	router, _, _ := setupTestRouterWithPrincipal(t, readOnlyPrincipal(tenantID))

	base := time.Now().UTC()
	session := fmt.Sprintf("%064x", 0xD01)
	// Same session, genuinely 10 seconds (10_000 ms) apart.
	evA := validPayloadForSession(session, "TASK-D", 10, 1, base.Format(time.RFC3339Nano))
	evB := validPayloadForSession(session, "TASK-D", 20, 2, base.Add(10*time.Second).Format(time.RFC3339Nano))

	rec := postOrdering(t, router, evA, evB)
	if rec.Code != http.StatusOK {
		t.Fatalf("ordering failed: %d %s", rec.Code, rec.Body.String())
	}
	var res codingagent.OrderingResult
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatalf("parse ordering result: %v", err)
	}

	const wantMs = 10_000.0
	if res.TimeDeltaMs != wantMs {
		t.Errorf("UNIT FABRICATION: events 10s apart in one session reported "+
			"time_delta_ms=%.0f (= %.1f hours) instead of %.0f. The value is the "+
			"sort-key difference (elapsed_s*1e6 + step_count), published under a "+
			"millisecond field name.", res.TimeDeltaMs, res.TimeDeltaMs/3_600_000, wantMs)
	}
}
