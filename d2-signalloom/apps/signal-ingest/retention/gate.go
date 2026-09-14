// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

var (
	// ErrGateOverdue is the acceptance-gate failure: at least one copy is past its deadline.
	ErrGateOverdue = errors.New("retention acceptance gate: storage copies are past their retention propagation deadline")

	// ErrGateVacuous is the acceptance-gate failure nobody expects and everybody needs.
	//
	// A gate asserting "zero overdue objects" against an empty set passes for a reason that has
	// nothing to do with retention working — a fresh install, a misconfigured tenant, a sink list that
	// silently emptied. So the gate refuses to pass on an empty evaluation and says why. Every
	// acceptance criterion must be able to fail; this is the one that makes THIS criterion able to.
	ErrGateVacuous = errors.New("retention acceptance gate: nothing was evaluated, so a pass would be vacuous")
)

// GateReport is the acceptance gate's verdict.
type GateReport struct {
	TenantID    string
	EvaluatedAt time.Time

	// Evaluated is how many copies the gate considered. Zero is a failure, not a pass.
	Evaluated int

	OverdueCount int
	Overdue      []Outstanding

	// OutstandingCount is copies expired but still inside the propagation window. Reported rather than
	// failed, because being mid-propagation is the normal state of a working control.
	OutstandingCount int
}

// Err returns the gate's failure, or nil.
func (r GateReport) Err() error {
	if r.Evaluated == 0 {
		return fmt.Errorf("%w: tenant %q", ErrGateVacuous, r.TenantID)
	}
	if r.OverdueCount > 0 {
		return fmt.Errorf("%w: %d of %d copies overdue for tenant %q: %s",
			ErrGateOverdue, r.OverdueCount, r.Evaluated, r.TenantID, r.Summary())
	}
	return nil
}

// Summary renders the overdue copies as one line, worst breach first.
func (r GateReport) Summary() string {
	if len(r.Overdue) == 0 {
		return "none"
	}
	sorted := append([]Outstanding(nil), r.Overdue...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].OverdueAge(r.EvaluatedAt) > sorted[j].OverdueAge(r.EvaluatedAt)
	})
	parts := make([]string, 0, len(sorted))
	for _, o := range sorted {
		disposition := string(o.Disposition)
		if disposition == "" {
			disposition = "never_evaluated"
		}
		parts = append(parts, fmt.Sprintf("%s[%s overdue by %s]", o.SinkID, disposition, o.OverdueAge(r.EvaluatedAt).Round(time.Second)))
	}
	return strings.Join(parts, ", ")
}

// AcceptanceGate evaluates the overdue-object criterion from the LEDGER.
//
// From the ledger, not from a SweepResult, and that is deliberate: a gate fed by the sweep that just
// ran can only ever confirm what that sweep believed. Reading the ledger independently means the gate
// would catch a sweep that reported success while leaving a copy outstanding.
func AcceptanceGate(outstanding []Outstanding, evaluated int, asOf time.Time, tenantID string) GateReport {
	overdue := Overdue(outstanding, asOf)
	return GateReport{
		TenantID:         tenantID,
		EvaluatedAt:      asOf,
		Evaluated:        evaluated,
		OverdueCount:     len(overdue),
		Overdue:          overdue,
		OutstandingCount: len(outstanding) - len(overdue),
	}
}
