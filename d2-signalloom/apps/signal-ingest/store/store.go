// Package store defines the SignalStore interface and its implementations.
package store

import (
	"context"
	"errors"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TenantLabelKey is the label column carrying the owning tenant of an observation.
//
// Declared here, not in api, because tenancy is now a pushed-down store predicate and store
// cannot import api. api.ObservationTenantLabel must stay equal to it; TestTenantLabelKeysAgree
// in the api package fails if the two ever diverge, which would silently scope every read to
// a column nothing writes.
const TenantLabelKey = "tenant_id"

// MinAggregateGroupSize enforces k-anonymity (small-cell suppression floor) on aggregates whose
// groups are cohorts of data subjects.
//
// The unit is distinct data subjects, not rows. The one enforcement site in the repository is
// codingagent.(*MemoryStore).Aggregate, which counts distinct Subject + ":" + SessionID keys and
// refuses below the floor; api.Handlers.handleAggregateCodingAgentTelemetry surfaces that as HTTP
// 422. What makes it a disclosure channel there is that the response publishes measured
// per-cohort quantities (TotalTokensIn, TotalStepCount, TotalElapsedS) beside GroupSize, so a
// cohort of one attributes those figures to one identifiable developer.
//
// ObservationStats is deliberately OUTSIDE this class and applies no floor — the same as before
// it became a real grouped query. Its group keys are the closed schema enums model.Layer and
// model.FidelityTier, it counts rows rather than people, and it attributes no measured quantity
// to a group, so there is no cohort for a floor to protect. Note that
// docs/signalloom/sldp-p5-3-proof.md:55 claims the floor covers "any statistical or grouped
// queries"; that is broader than the code has ever been and is a documentation overclaim, not a
// defect here. The reasoning and the permission caveat behind it are recorded in full in
// api/store_stats_anonymity_floor_test.go, which pins the decision with
// TestStoreStats_ReportsTrueCountsBelowTheAnonymityFloor and
// TestObservationStats_HasNoSubjectDerivedGroupKey.
const MinAggregateGroupSize = 5

// ErrGroupSizeBelowAnonymityFloor is returned when aggregate cohort size is smaller than MinAggregateGroupSize.
var ErrGroupSizeBelowAnonymityFloor = errors.New("aggregate group size falls below k-anonymity floor (k=5)")

// SignalStore is the persistence interface for signal observations.
type SignalStore interface {
	Append(ctx context.Context, observations []model.Observation) error
	QueryRange(ctx context.Context, q Query) ([]model.Observation, error)

	// ScanIDs streams the IDs of the observations matching q, in the same order and with the
	// same row SELECTION as QueryRange, without ever materialising a model.Observation. fn is
	// called once per matching row; returning an error from fn aborts the scan and is
	// returned to the caller unwrapped.
	//
	// Offset and Limit are applied in the natural order — skip Offset rows, then emit at most
	// Limit — and every implementation must agree on that, which is more than can currently
	// be said for QueryRange. With {Offset: 2, Limit: 3} over rows a..j, MemoryStore's
	// QueryRange returns [c d e] but FrostDBStore's returns [c]: FrostDB stops collecting at
	// Limit and only then slices Offset off the truncated result, so offset can never reach
	// past the first Limit rows. That is a pre-existing pagination defect in
	// FrostDBStore.QueryRange, reported separately rather than copied here; ScanIDs is
	// specified once so a caller's pagination cannot depend on which store is configured.
	// Warm is unaffected either way — it passes After and Limit and leaves Offset zero.
	//
	// Callers that need only identity must use this and not QueryRange. Boot warm-up read
	// 192,312 rows through QueryRange to look at nothing but their IDs and OOM-killed
	// signal-ingest on kind-osramp (2026-10-13, exit 137, 15 restarts): QueryRange decodes
	// every column into a fresh model.Observation with its own Labels map, which measured
	// 2,635 bytes per row against ~200 for an ID.
	//
	// This is on the interface rather than an optional capability with a QueryRange
	// fallback, deliberately. A fallback would leave the path that caused the outage
	// reachable from a store that simply forgot to implement the fast one; as a required
	// method the compiler proves every implementation streams.
	//
	// Implementations MUST pass fn an ID that owns its own memory. A columnar backend can
	// return strings aliasing a decode buffer, and an ID retained by the caller would then
	// pin that entire buffer — every column of every row — for as long as the ID is held.
	ScanIDs(ctx context.Context, q Query, fn func(id string) error) error

	// ScanObservations streams the observations matching q, one at a time, with the same row
	// SELECTION and ordering as QueryRange and the same Offset and Limit semantics as ScanIDs.
	// fn is called once per matching row; returning an error aborts the scan and is returned
	// unwrapped, which is how a caller stops early once it has the page it asked for.
	//
	// Callers that page or aggregate must use this and not QueryRange. GET
	// /api/v1/observations discarded the caller's limit before the read and materialised the
	// whole store on every dashboard page load; streaming with an early stop makes the cost
	// the page rather than the table.
	//
	// The *model.Observation handed to fn is valid only for the duration of the call. An
	// implementation may point it at its own storage or at a decode buffer, so a caller that
	// retains a row must copy it — and must bound how many it keeps, or it has rebuilt the
	// defect this method exists to remove.
	//
	// fn must not call back into the store. Implementations may hold a read lock across the
	// scan.
	ScanObservations(ctx context.Context, q Query, fn func(o *model.Observation) error) error

	// ObservationStats answers the counting questions GET /api/v1/store/stats asks, without
	// handing any observation across the interface.
	//
	// Counting is the one read that legitimately concerns every row, so it cannot be bounded
	// by paging; it is bounded by never materialising. The handler used to call
	// QueryRange(Query{}) and tally the result in Go, which is one live Observation per row
	// in the store and was half of the pair of full-store scans that OOM-killed
	// signal-ingest. An implementation must aggregate in its engine and return only the
	// totals.
	//
	// q is honoured as a filter; Offset and Limit are meaningless for an aggregate and are
	// ignored.
	ObservationStats(ctx context.Context, q Query) (ObservationStats, error)

	DropPartition(ctx context.Context, before time.Time) error
	Close() error
}

// ObservationStats is the summary GET /api/v1/store/stats reports. Counts are over rows, not
// over distinct IDs, matching what the handler reported before it was bounded.
//
// It groups by two closed schema enums and by nothing else, which is the whole reason
// MinAggregateGroupSize is not applied to it. Adding a group key derived from an actor,
// principal, session or pseudonym would make each group a cohort of data subjects and move this
// type into the floor's class — silently, because every existing test would still pass. Do not
// add one without revisiting the decision recorded on MinAggregateGroupSize above.
// TestObservationStats_HasNoSubjectDerivedGroupKey fails if the shape changes.
type ObservationStats struct {
	Total         int
	ByLayer       map[string]int
	ByFidelity    map[string]int
	LastIngestion *time.Time
}

// Query specifies filters for observation retrieval.
type Query struct {
	Layers    []model.Layer // filter by layer
	IDs       []string      // optional: filter by observation ID (empty = no ID filter)
	After     time.Time     // start of range
	Before    time.Time     // end of range
	ActorID   string        // optional: filter by correlated actor
	SubjectID string        // optional: filter by data subject identity across pseudonymised columns
	TenantID  string        // optional: filter to one tenant's rows (the tenant_id label)
	Offset    int           // optional: offset for pagination
	Limit     int           // max results (0 = no limit)
}

// LookupIDs returns the Query that reads exactly the named observations.
//
// It exists because "fetch one row by its ID" had no expressible form: Query carried a time
// range, a layer, an actor and a subject, but not an identity, so every by-ID read was written
// as an unfiltered QueryRange followed by a linear scan in Go. That materialises the entire
// store to return one row, which is how a decision lookup came to cost 2 GiB of resident
// memory on kind-osramp (see api.Handlers.observationByID). `id` is a real column in the
// FrostDB Arrow schema, so this pushes down to the engine rather than filtering in the caller.
//
// An empty or nil ids slice would be indistinguishable from "no filter" in the Query struct,
// which is the dangerous direction to fail: a lookup whose ID list came back empty would
// silently read everything. Callers must therefore not call this with an empty slice; the
// stores treat a non-nil-but-empty IDs slice as "match nothing" for the same reason.
func LookupIDs(ids ...string) Query {
	return Query{IDs: ids}
}

// matchesIDs reports whether o passes q's ID filter. A nil IDs slice means the filter is absent
// and everything passes; a present-but-empty slice matches nothing, so a caller that computed an
// empty ID set reads zero rows rather than the whole store.
func (q Query) matchesIDs(id string) bool {
	if q.IDs == nil {
		return true
	}
	for _, want := range q.IDs {
		if want == id {
			return true
		}
	}
	return false
}
