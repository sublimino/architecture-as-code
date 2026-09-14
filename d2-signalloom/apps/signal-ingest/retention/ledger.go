// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

var (
	// ErrLedgerRefused is returned when a receipt cannot be recorded.
	ErrLedgerRefused = errors.New("retention: ledger refused the receipt")

	// ErrLedgerUnavailable is returned when the ledger backend could not be reached.
	//
	// It is distinct from ErrLedgerRefused because the operational consequence differs: a refusal
	// means the receipt was wrong, unavailability means the deletion may have happened and we cannot
	// prove it. The second is worse and must never be reported as a completed sweep.
	ErrLedgerUnavailable = errors.New("retention: ledger backend unavailable; deletion cannot be proven")
)

// Outstanding is one copy with no complete receipt.
type Outstanding struct {
	TenantID    string
	SinkID      string
	SinkClass   string
	Disposition Disposition
	Deadline    time.Time

	// LastEvaluated is when the copy was last looked at. A zero value means never, which is a
	// materially different state from "evaluated and held" and is rendered as such.
	LastEvaluated time.Time

	HoldIDs []string
}

// OverdueAge returns how far past its deadline this copy is at asOf, or zero if it is not overdue.
func (o Outstanding) OverdueAge(asOf time.Time) time.Duration {
	if o.Deadline.IsZero() || !asOf.After(o.Deadline) {
		return 0
	}
	return asOf.Sub(o.Deadline)
}

// Ledger is the durable record of every retention receipt.
//
// Record is an upsert keyed on OperationID, which is what makes the controller idempotent: a re-run
// after a partial sweep recomputes the same deterministic ID and collapses onto the same row.
type Ledger interface {
	Record(ctx context.Context, receipt DeletionReceipt) error

	// Get returns the receipt for an operation ID, if one exists.
	Get(ctx context.Context, tenantID, operationID string) (DeletionReceipt, bool, error)

	// Outstanding returns every copy in expected that has no complete receipt at asOf.
	//
	// Note the argument: the ledger cannot enumerate what it has never seen, so the expected set is
	// supplied by the caller. A ledger that derived "outstanding" purely from its own rows would
	// report zero on a fresh install — which is the vacuous-pass failure mode the acceptance gate
	// exists to catch, one layer down.
	Outstanding(ctx context.Context, tenantID string, expected []SinkSpec, asOf time.Time) ([]Outstanding, error)

	// CompletedDigests returns the receipt digests of complete receipts for the named sinks.
	CompletedDigests(ctx context.Context, tenantID string, sinkIDs []string) ([]string, error)

	// EarliestOpenDeadline returns the earliest propagation deadline among INCOMPLETE receipts for one
	// sink, if any.
	//
	// It exists to stop a sliding deadline, which was a live defect in the first draft of this package
	// and the most dangerous one it had. Because the retention boundary is now-minus-period, every
	// sweep computes a LATER boundary and therefore a later deadline. A copy blocked by a permanent
	// legal hold would get a fresh, always-future deadline on every sweep, so it would never be
	// overdue, the gauge would read zero forever, and legal hold would silently become unlimited
	// retention — the precise failure the four-outcome design exists to prevent. Anchoring on the
	// earliest open deadline makes the clock run once and keeps running.
	EarliestOpenDeadline(ctx context.Context, tenantID, sinkID string) (time.Time, bool, error)
}

// MemoryLedger is an in-process Ledger.
//
// It is the implementation every unit test drives, and it is a real implementation rather than a mock
// precisely so the fail-closed paths are exercised against something that behaves like the Postgres
// one. Tenant scoping is enforced here as well as in RLS, because a test against the memory ledger
// that passes only because there is one tenant proves nothing about the tenant filter.
type MemoryLedger struct {
	mu sync.RWMutex

	// receipts is keyed by tenant then operation ID, which is how the tenant filter becomes
	// structural rather than a WHERE clause someone can forget.
	receipts map[string]map[string]DeletionReceipt

	// failNext makes unavailability injectable, so the "ledger down" path has a test.
	failNext error
}

// NewMemoryLedger returns an empty ledger.
func NewMemoryLedger() *MemoryLedger {
	return &MemoryLedger{receipts: make(map[string]map[string]DeletionReceipt)}
}

// FailNext makes the next operation return err. Test seam.
func (l *MemoryLedger) FailNext(err error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.failNext = err
}

// takeFailure consumes an injected failure. Callers must hold the write lock.
func (l *MemoryLedger) takeFailure() error {
	if l.failNext == nil {
		return nil
	}
	err := l.failNext
	l.failNext = nil
	return err
}

// takeFailureLocking consumes an injected failure, taking the write lock itself. Used by read paths,
// which would otherwise need to upgrade a read lock — which Go's sync.RWMutex does not support and
// which an earlier draft of this file attempted with an unlock/relock dance that could observe a
// mutation mid-read.
func (l *MemoryLedger) takeFailureLocking() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.takeFailure()
}

// Record upserts the receipt.
func (l *MemoryLedger) Record(_ context.Context, receipt DeletionReceipt) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.takeFailure(); err != nil {
		return err
	}
	if err := receipt.VerifyDigest(); err != nil {
		return fmt.Errorf("%w: %v", ErrLedgerRefused, err)
	}
	byTenant, ok := l.receipts[receipt.TenantID]
	if !ok {
		byTenant = make(map[string]DeletionReceipt)
		l.receipts[receipt.TenantID] = byTenant
	}
	byTenant[receipt.OperationID] = receipt
	return nil
}

// Get returns one receipt.
func (l *MemoryLedger) Get(_ context.Context, tenantID, operationID string) (DeletionReceipt, bool, error) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	r, ok := l.receipts[tenantID][operationID]
	return r, ok, nil
}

// Count returns how many receipts exist for a tenant. Test helper for the idempotence assertions.
func (l *MemoryLedger) Count(tenantID string) int {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return len(l.receipts[tenantID])
}

// Outstanding implements Ledger.
func (l *MemoryLedger) Outstanding(_ context.Context, tenantID string, expected []SinkSpec, asOf time.Time) ([]Outstanding, error) {
	if err := l.takeFailureLocking(); err != nil {
		return nil, err
	}
	l.mu.RLock()
	defer l.mu.RUnlock()

	// latest[sinkID] is the most recently evaluated receipt for that sink.
	latest := make(map[string]DeletionReceipt)
	for _, r := range l.receipts[tenantID] {
		prev, seen := latest[r.SinkID]
		if !seen || r.EvaluatedAt.After(prev.EvaluatedAt) {
			latest[r.SinkID] = r
		}
	}

	var out []Outstanding
	for _, spec := range expected {
		r, seen := latest[spec.ID]
		if seen && r.Disposition.Complete() {
			continue
		}
		entry := Outstanding{
			TenantID:  tenantID,
			SinkID:    spec.ID,
			SinkClass: string(spec.Class),
		}
		if seen {
			entry.Disposition = r.Disposition
			entry.Deadline = r.PropagationDeadline
			entry.LastEvaluated = r.EvaluatedAt
			entry.HoldIDs = r.HoldIDs
		} else {
			// Never evaluated. The deadline is derived from asOf and the propagation delay so that a
			// never-swept copy is outstanding NOW and overdue after the window — rather than carrying
			// a zero deadline, which OverdueAge would read as "not overdue" forever.
			entry.Disposition = ""
			entry.Deadline = asOf.Add(MaxPropagationDelay)
		}
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SinkID < out[j].SinkID })
	return out, nil
}

// CompletedDigests implements Ledger.
func (l *MemoryLedger) CompletedDigests(_ context.Context, tenantID string, sinkIDs []string) ([]string, error) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	want := make(map[string]struct{}, len(sinkIDs))
	for _, id := range sinkIDs {
		want[id] = struct{}{}
	}
	found := make(map[string]string)
	for _, r := range l.receipts[tenantID] {
		if _, ok := want[r.SinkID]; !ok {
			continue
		}
		if !r.Disposition.Complete() {
			continue
		}
		// One digest per sink, the most recent. Returning two digests for one sink would let a
		// continuity sink's "len(digests) >= len(linkage)" precondition pass on a single purged
		// linkage copy, which is exactly the kind of counting bug that reads as a pass.
		prev, seen := found[r.SinkID]
		if !seen || r.ReceiptDigest > prev {
			found[r.SinkID] = r.ReceiptDigest
		}
	}
	out := make([]string, 0, len(found))
	for _, digest := range found {
		out = append(out, digest)
	}
	sort.Strings(out)
	return out, nil
}

// EarliestOpenDeadline implements Ledger.
func (l *MemoryLedger) EarliestOpenDeadline(_ context.Context, tenantID, sinkID string) (time.Time, bool, error) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	var (
		earliest time.Time
		found    bool
	)
	for _, r := range l.receipts[tenantID] {
		if r.SinkID != sinkID || r.Disposition.Complete() {
			continue
		}
		if !found || r.PropagationDeadline.Before(earliest) {
			earliest = r.PropagationDeadline
			found = true
		}
	}
	return earliest, found, nil
}

// Overdue filters an outstanding set down to the entries past their deadline.
func Overdue(outstanding []Outstanding, asOf time.Time) []Outstanding {
	var out []Outstanding
	for _, o := range outstanding {
		if o.OverdueAge(asOf) > 0 {
			out = append(out, o)
		}
	}
	return out
}
