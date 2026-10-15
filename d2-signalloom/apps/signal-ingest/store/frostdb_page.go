//go:build frostdb

package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/polarsignals/frostdb/query/logicalplan"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// pageInitialSpan is the width of the newest slice a bounded QueryPage reads first.
//
// The dashboard asks for the newest 50 or 100 rows with no lower bound, and a store under any
// ingest at all holds that many inside the last hour, so the common page is answered by one slice
// that touches the newest block and nothing else.
const pageInitialSpan = time.Hour

// pageMaxSpan stops the doubling well before a slice boundary could leave the range of a
// UnixNano literal. A slice that would be wider than this is read as the open-ended remainder.
const pageMaxSpan = 50 * 365 * 24 * time.Hour

// queryPageSliced answers a bounded QueryPage by reading the store newest-first in time slices,
// stopping as soon as the page is full.
//
// The single scan it replaces had no timestamp predicate whenever the caller gave no `after`,
// which is every dashboard page load, so FrostDB opened and decoded every persisted block to
// return 50 rows. Its cost was the store, not the page: on kind-osramp (2026-10-15) the Weave
// page's six per-layer reads plus the summary read were each a full decode of a 22-block,
// 485 MB store, and signal-ingest was OOM-killed at 2 GiB 28 times.
//
// Slice i covers [lo_i, hi_i), half-open exactly as buildFilter's After/Before are, and slice
// i+1 ends where slice i began, so the slices partition the requested range and no row is read
// twice or skipped. The first slice is open above (or bounded by Before / the cursor) so a row
// stamped in the future is still the newest. Widths double, so a sparse store costs O(log span)
// slices rather than O(span). The heap only ever holds rows at or after the current slice's
// lower bound, and every row of an older slice is strictly earlier, so once the heap is full no
// older slice can contribute and the read stops. Between slices a one-row probe asks whether
// anything older exists at all; it stops at the first row, so it costs one record rather than a
// scan.
//
// Two other things here used to pin memory to the size of the read:
//   - de-duplication kept a set of every ID scanned, and those IDs were strings aliasing the
//     Arrow buffers they were read from. It now tracks only the IDs in the heap (at most Limit).
//   - a row entering the heap is copied off the Arrow record. Otherwise one retained row keeps
//     its whole record — every column of up to a thousand rows — alive until the page is written.
//
// See TestFrostDB_QueryPageCostDoesNotGrowWithOlderBlocks and
// TestFrostDB_QueryPageSlicedMatchesFullScan.
func (f *FrostDBStore) queryPageSliced(ctx context.Context, q PageQuery, base Query, hasCursor bool) ([]model.Observation, error) {
	h := newObservationMinHeap(q.Limit)
	inHeap := make(map[string]struct{}, q.Limit)

	upper := base.Before
	if hasCursor && !q.CursorTimestamp.IsZero() {
		// A row at the cursor's own timestamp with a smaller ID is still on the next page, so
		// the slice bound is one nanosecond past it; the row-level cursor test does the rest.
		c := q.CursorTimestamp.Add(time.Nanosecond)
		if upper.IsZero() || c.Before(upper) {
			upper = c
		}
	}
	anchor := f.now().UTC()
	if !upper.IsZero() && upper.Before(anchor) {
		anchor = upper
	}

	span := pageInitialSpan
	hi := upper
	lo := anchor.Add(-span)
	for {
		final := false
		if !base.After.IsZero() && !lo.After(base.After) {
			lo, final = base.After, true
		}
		slice := base
		slice.After, slice.Before = lo, hi
		if err := f.scanPageSlice(ctx, slice, q, hasCursor, h, inHeap); err != nil {
			return nil, err
		}
		if len(h.items) >= q.Limit || final || lo.IsZero() {
			break
		}
		older, err := f.anyRowBefore(ctx, base, lo)
		if err != nil {
			return nil, err
		}
		if !older {
			break
		}
		hi = lo
		span *= 2
		if span > pageMaxSpan {
			lo = base.After // zero when the caller set no lower bound: the open-ended remainder
		} else {
			lo = hi.Add(-span)
		}
	}
	return h.sorted(), nil
}

// scanPageSlice reads one slice into the heap. The caller holds f.mu.
func (f *FrostDBStore) scanPageSlice(ctx context.Context, slice Query, q PageQuery, hasCursor bool, h *observationMinHeap, inHeap map[string]struct{}) error {
	filter, err := buildFilter(slice, f.pseudonymiser)
	if err != nil {
		return fmt.Errorf("frostdb: build filter: %w", err)
	}
	builder := f.engine.ScanTable(tableName)
	if filter != nil {
		builder = builder.Filter(filter)
	}
	builder = builder.Project(logicalplan.All())

	err = builder.Execute(ctx, func(_ context.Context, r arrow.Record) error {
		n := int(r.NumRows())
		if n == 0 {
			return nil
		}
		schema := r.Schema()
		colIdx := make(map[string]int, schema.NumFields())
		for i, field := range schema.Fields() {
			colIdx[field.Name] = i
		}
		tenantColIdx, hasTenantCol := colIdx["labels.tenant_id"]
		tsColIdx, hasTsCol := colIdx["timestamp"]
		idColIdx, hasIDCol := colIdx["id"]

		for i := 0; i < n; i++ {
			if !q.AllTenants {
				if q.Tenant == "" || !hasTenantCol {
					continue
				}
				if stringAt(r.Column(tenantColIdx), i) != q.Tenant {
					continue
				}
			}
			var rowTs time.Time
			if hasTsCol {
				if ns := int64At(r.Column(tsColIdx), i); ns > 0 {
					rowTs = time.Unix(0, ns).UTC()
				}
			}
			var rowID string
			if hasIDCol {
				rowID = stringAt(r.Column(idColIdx), i)
			}
			if hasCursor {
				if !(rowTs.Before(q.CursorTimestamp) || (rowTs.Equal(q.CursorTimestamp) && rowID < q.CursorID)) {
					continue
				}
			}
			if rowID != "" {
				if _, dup := inHeap[rowID]; dup {
					continue
				}
			}
			candidate := model.Observation{ID: rowID, Timestamp: rowTs}
			if len(h.items) == h.cap && len(h.items) > 0 {
				if !obsIsLess(&h.items[0], &candidate) {
					continue
				}
				delete(inHeap, h.items[0].ID)
			}
			o := decodeObservationAt(r, i, colIdx)
			cloneObservationStrings(&o)
			h.push(o)
			if o.ID != "" {
				inHeap[o.ID] = struct{}{}
			}
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("frostdb: query page execute: %w", err)
	}
	return nil
}

// anyRowBefore reports whether any row matching base lies strictly before `before`. It stops at
// the first non-empty record, so it reads one record however much older data there is. The
// caller holds f.mu.
func (f *FrostDBStore) anyRowBefore(ctx context.Context, base Query, before time.Time) (bool, error) {
	if !base.After.IsZero() && !base.After.Before(before) {
		return false, nil
	}
	probe := base
	probe.Before = before
	filter, err := buildFilter(probe, f.pseudonymiser)
	if err != nil {
		return false, fmt.Errorf("frostdb: build filter: %w", err)
	}
	builder := f.engine.ScanTable(tableName)
	if filter != nil {
		builder = builder.Filter(filter)
	}
	builder = builder.Project(colRef(colTimestamp))

	found := false
	execErr := builder.Execute(ctx, func(_ context.Context, r arrow.Record) error {
		if r.NumRows() > 0 {
			found = true
			return errScanLimitReached
		}
		return nil
	})
	if execErr != nil && !errors.Is(execErr, errScanLimitReached) {
		return false, fmt.Errorf("frostdb: probe older rows: %w", execErr)
	}
	return found, nil
}

// cloneObservationStrings copies every string field of o off whatever buffer it aliases, so a
// retained row does not keep its source Arrow record reachable.
func cloneObservationStrings(o *model.Observation) {
	o.ID = strings.Clone(o.ID)
	o.Layer = model.Layer(strings.Clone(string(o.Layer)))
	o.Fidelity = model.FidelityTier(strings.Clone(string(o.Fidelity)))
	o.Source = strings.Clone(o.Source)
	o.ActorHint = strings.Clone(o.ActorHint)
	o.RawEvidenceRef = strings.Clone(o.RawEvidenceRef)
	o.Description = strings.Clone(o.Description)
	o.PrincipalID = strings.Clone(o.PrincipalID)
	o.ActorID = strings.Clone(o.ActorID)
	o.SessionID = strings.Clone(o.SessionID)
	o.ImpersonatedUser = strings.Clone(o.ImpersonatedUser)
	o.SchemaVersion = strings.Clone(o.SchemaVersion)
	o.HMACActorHint = strings.Clone(o.HMACActorHint)
	o.HMACActorID = strings.Clone(o.HMACActorID)
	o.HMACPrincipalID = strings.Clone(o.HMACPrincipalID)
	o.HMACSessionID = strings.Clone(o.HMACSessionID)
	o.HMACImpersonatedUser = strings.Clone(o.HMACImpersonatedUser)
	o.EvidenceRefDigest = strings.Clone(o.EvidenceRefDigest)
	if len(o.Labels) > 0 {
		labels := make(map[string]string, len(o.Labels))
		for k, v := range o.Labels {
			labels[strings.Clone(k)] = strings.Clone(v)
		}
		o.Labels = labels
	}
}
