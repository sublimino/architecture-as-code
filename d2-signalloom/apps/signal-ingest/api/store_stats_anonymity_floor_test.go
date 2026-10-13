// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// GET /api/v1/store/stats deliberately does NOT apply the k-anonymity floor, and these tests pin
// that decision so it does not have to be re-derived.
//
// The bounded-read change (b94f42353) turned store/stats from "read every row and tally in Go"
// into a genuine grouped aggregate query (store.SignalStore.ObservationStats, computed in the
// engine). That raised a fair question: store declares MinAggregateGroupSize = 5 and
// ErrGroupSizeBelowAnonymityFloor "for grouped/statistical queries", so is store/stats now in the
// class the floor protects? It is not, on the following evidence.
//
// # What the floor actually guards
//
// There is exactly one enforcement site in the repository: codingagent.(*MemoryStore).Aggregate
// (codingagent/store.go), surfaced as HTTP 422 by api.Handlers.handleAggregateCodingAgentTelemetry
// (telemetry_handler.go). codingagent.MinAggregateGroupSize is a plain alias of the store
// constant. At that site the unit of the floor is DISTINCT DATA SUBJECTS — groupSize is
// len(subjects) over a key of Subject + ":" + SessionID — and the response publishes GroupSize
// alongside measured per-cohort quantities (TotalTokensIn, TotalTokensOut, TotalStepCount,
// TotalElapsedS). With a cohort of one, those quantities are attributable to one identifiable
// developer. That is the disclosure channel the floor exists to close, and
// codingagent.TestTelemetryStore_KAnonymityGroupSize is the test that keeps it closed.
//
// # Why ObservationStats is not in that class
//
// Three reasons, each independently sufficient:
//
//  1. Its group keys are closed schema enums, not subject attributes. ObservationStats groups by
//     model.Layer and model.FidelityTier only. Knowing that a tenant holds three rows at
//     (cloud_control_plane, definitive) names no person; there is no actor, principal, session or
//     pseudonym dimension anywhere in the type.
//  2. It counts rows, not people. "Group size" in the floor's sense — a cohort of data subjects —
//     is not a quantity ObservationStats computes, so the constant is not even type-compatible
//     with what would be suppressed here. A count of 1 means one evidence row exists, not that
//     one person does.
//  3. It attributes no measured quantity to a cohort. There is no per-group sum that a cohort of
//     one would expose; the count IS the value.
//
// The result is already tenant-scoped (handleStoreStats sets q.TenantID from
// observationReadScope, and a principal with neither a tenant nor a cross-tenant grant gets empty
// maps), so the counts are the caller's own rows.
//
// # What the documentation says, and one discrepancy worth knowing about
//
// docs/security/zero-customer-payload.mdx — the Zero-Customer-Payload privacy architecture page —
// makes no claim about aggregates at all: across its 166 lines it never mentions k-anonymity,
// aggregation, cohorts, re-identification or suppression. It governs field-level collection at
// the host sensor, which is a different boundary.
//
// docs/signalloom/sldp-p5-3-proof.md:55 does claim the floor is enforced "for any statistical or
// grouped queries". That claim is broader than the code has ever been — store/stats applied no
// floor before b94f42353 either, when it tallied the same two groupings in Go. It is a
// documentation overclaim rather than a code defect, and it is recorded here rather than silently
// corrected because that proof record is a historical artefact of the SLDP-P5-3 card.
//
// # The one thing that could change the answer
//
// Permission note, because it weakens the easy argument: store/stats requires
// PermissionAnalysisRead while GET /api/v1/observations requires PermissionObservationRead, and
// the shipped signalfusion-demo key in deploy/jwt-auth-config.yaml holds analysis:read WITHOUT
// observations:read. So store/stats is not merely a coarser view of a row set that every stats
// caller could already enumerate — for that principal it is the only view. It is still not a
// disclosure channel, for reasons 1-3 above: what that caller learns is a distribution over two
// closed enums, which narrows no individual.
//
// Adding a subject-derived group key would reverse all of this, which is what
// TestObservationStats_HasNoSubjectDerivedGroupKey exists to catch.

// TestStoreStats_ReportsTrueCountsBelowTheAnonymityFloor pins the decision not to suppress. A
// tenant holding fewer rows than MinAggregateGroupSize — including a group of exactly one — gets
// its true counts, not a 422 and not a silently zeroed map.
func TestStoreStats_ReportsTrueCountsBelowTheAnonymityFloor(t *testing.T) {
	srv, h := tenantPairFixture(t)
	base := time.Now().UTC().Add(-time.Hour)

	// Two rows, well under the k=5 floor, in two distinct (layer, fidelity) pairs so that both
	// groupings contain a cell of size 1 — the smallest cell suppression would ever target.
	corpus := []model.Observation{
		tenantRow("stats-1", "tenant-a", model.LayerCloudControlPlane, model.FidelityDefinitive, base),
		tenantRow("stats-2", "tenant-a", model.LayerNetworkEgress, model.FidelityStrong, base.Add(time.Second)),
		// A second tenant's row, to prove the totals are scoped and not estate-wide.
		tenantRow("stats-b", "tenant-b", model.LayerNetworkEgress, model.FidelityStrong, base.Add(2*time.Second)),
	}
	if err := h.Store.Append(t.Context(), corpus); err != nil {
		t.Fatal(err)
	}

	if store.MinAggregateGroupSize <= 2 {
		t.Fatalf("MinAggregateGroupSize is %d; this fixture's 2 rows are no longer below the "+
			"floor and the test has stopped testing anything", store.MinAggregateGroupSize)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/store/stats", nil)
	req.Header.Set("Authorization", "Bearer "+tenantPairAToken)
	rr := httptest.NewRecorder()
	srv.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/store/stats: status %d, want 200. A 422 here means the k-anonymity "+
			"floor has been applied to ObservationStats; see the decision recorded in this "+
			"file's comment and in store/store.go before changing it. Body: %s",
			rr.Code, rr.Body.String())
	}
	if body := rr.Body.String(); strings.Contains(body, "anonymity floor") {
		t.Fatalf("the response mentions the anonymity floor: %s", body)
	}

	var got StoreStatsResponse
	if err := json.NewDecoder(rr.Body).Decode(&got); err != nil {
		t.Fatalf("decoding the response: %v", err)
	}

	if got.TotalObservations != 2 {
		t.Errorf("total_observations = %d, want 2 (tenant-a's real row count, unsuppressed and "+
			"not inflated by tenant-b's row)", got.TotalObservations)
	}
	for _, tc := range []struct {
		dimension string
		counts    map[string]int
		key       string
	}{
		{"observations_by_layer", got.ObservationsByLayer, string(model.LayerCloudControlPlane)},
		{"observations_by_layer", got.ObservationsByLayer, string(model.LayerNetworkEgress)},
		{"observations_by_fidelity", got.ObservationsByFidelity, string(model.FidelityDefinitive)},
		{"observations_by_fidelity", got.ObservationsByFidelity, string(model.FidelityStrong)},
	} {
		if n := tc.counts[tc.key]; n != 1 {
			t.Errorf("%s[%q] = %d, want 1. A group of one must report its true count: suppression "+
				"that returned 0 would be indistinguishable from an empty group and would turn a "+
				"real count into a lie", tc.dimension, tc.key, n)
		}
	}
}

// TestObservationStats_HasNoSubjectDerivedGroupKey is the structural guard on the decision above.
//
// The whole argument for not applying the floor to store/stats rests on ObservationStats having
// no subject-derived group key. Adding one — by actor, principal, session or pseudonym — would
// move the type into the class the floor protects, and would do so silently, because every
// existing test would still pass. This fails the moment the shape changes.
func TestObservationStats_HasNoSubjectDerivedGroupKey(t *testing.T) {
	want := map[string]bool{"ByLayer": true, "ByFidelity": true}

	got := map[string]bool{}
	rt := reflect.TypeOf(store.ObservationStats{})
	for i := 0; i < rt.NumField(); i++ {
		if f := rt.Field(i); f.Type.Kind() == reflect.Map {
			got[f.Name] = true
		}
	}

	const guidance = "ObservationStats' grouping dimensions have changed. Every new group key must " +
		"be checked for subject identity: the k-anonymity floor (store.MinAggregateGroupSize) is " +
		"not applied to this type precisely because it groups only by the closed schema enums " +
		"model.Layer and model.FidelityTier. A key derived from an actor, principal, session or " +
		"pseudonym moves this into the floor's class, and the decision recorded in store/store.go " +
		"and in store_stats_anonymity_floor_test.go must be revisited before shipping it"

	for name := range got {
		if !want[name] {
			t.Errorf("new grouping field %q on store.ObservationStats. %s", name, guidance)
		}
	}
	for name := range want {
		if !got[name] {
			t.Errorf("grouping field %q has been removed from or renamed on store.ObservationStats. %s",
				name, guidance)
		}
	}
}
