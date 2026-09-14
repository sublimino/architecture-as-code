// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"strings"
	"testing"
	"time"
)

// Compile-time assertions that both ledger implementations satisfy the interface.
//
// Without these, adding a method to Ledger would leave PostgresLedger silently non-conforming until
// something tried to use it — and nothing in this package's unit tests constructs one, because there is
// no DSN here. The compiler is the only check available for that half.
var (
	_ Ledger = (*MemoryLedger)(nil)
	_ Ledger = (*PostgresLedger)(nil)
)

// TestRetentionRegression_DeadlineDoesNotSlideAcrossSweeps is the regression test for the worst defect
// this package shipped in draft.
//
// The defect: the retention boundary is now-minus-period, so it advances every sweep. A deadline derived
// from it advanced too. A copy under a permanent legal hold therefore received a fresh, always-future
// deadline on every sweep, could never go overdue, and the gauge read zero indefinitely — legal hold
// silently became unlimited retention. Crucially, NO single-sweep test could see it: it only appears
// when a reaper keeps sweeping, which is the only mode production runs in.
//
// The mutation that proves this test is load-bearing: delete the EarliestOpenDeadline anchoring block in
// controller.evaluateSink. The test then fails with a deadline that has moved forward by the elapsed
// time. Verified and recorded in docs/signalloom/sldp-p6-1-proof.md.
func TestRetentionRegression_DeadlineDoesNotSlideAcrossSweeps(t *testing.T) {
	sink := inProcessSink("postgres_actors", 1)
	clock := &fixedClock{at: testNow}
	h := newHarness(t, []Sink{sink}, func(c *Config) { c.Clock = clock })
	h.evaluator.deletable = false
	h.evaluator.holdIDs = []string{"hold-permanent"}

	first, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("first sweep: %v", err)
	}
	if len(first.Outstanding) != 1 {
		t.Fatalf("outstanding = %d, want 1", len(first.Outstanding))
	}
	anchored := first.Outstanding[0].Deadline
	if anchored.IsZero() {
		t.Fatal("the held copy has no deadline")
	}

	// Sweep repeatedly as time advances. The deadline must not move.
	for i, advance := range []time.Duration{time.Hour, 24 * time.Hour, 30 * 24 * time.Hour} {
		clock.at = testNow.Add(advance)
		res, err := h.ctrl.Sweep(t.Context(), "tenant-a")
		if err != nil && res.OverdueCount == 0 {
			t.Fatalf("sweep %d: %v", i+2, err)
		}
		if len(res.Outstanding) != 1 {
			t.Fatalf("sweep %d: outstanding = %d, want 1", i+2, len(res.Outstanding))
		}
		if got := res.Outstanding[0].Deadline; !got.Equal(anchored) {
			t.Fatalf("sweep %d after advancing %s: deadline moved from %s to %s. "+
				"A sliding deadline means a permanently held copy never goes overdue and legal hold becomes unlimited retention.",
				i+2, advance, anchored.Format(time.RFC3339), got.Format(time.RFC3339))
		}
	}

	// And the anchored deadline is eventually breached, which is the point of anchoring it.
	clock.at = anchored.Add(time.Hour)
	final, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err == nil {
		t.Fatal("past the anchored deadline the sweep must fail")
	}
	if final.OverdueCount != 1 {
		t.Fatalf("overdue = %d past the anchored deadline, want 1", final.OverdueCount)
	}
	if h.ctrl.Metrics().OverdueCount() != 1 {
		t.Fatal("the gauge did not register the breach")
	}
	// Assert the MECHANISM is present, not only the effect. A future refactor that removes the anchoring
	// but happens to keep this test green (e.g. by freezing the boundary) would still be wrong.
	if !strings.Contains(mustReadFile(t, "controller.go"), "EarliestOpenDeadline(ctx, tenantID, sink.SinkID())") {
		t.Error("the deadline-anchoring call is gone; the sliding-deadline defect can recur")
	}
}

// TestRetentionRegression_SweepResultAbortedMakesOKFalse is the regression test for the second draft
// defect: a clock-aborted sweep had no failures, no unreachable sinks and no overdue copies, so OK()
// read TRUE for a sweep that touched nothing. A caller inspecting only OK() saw a clean bill of health
// for a control that had not run.
func TestRetentionRegression_SweepResultAbortedMakesOKFalse(t *testing.T) {
	aborted := SweepResult{Dispositions: map[Disposition]int{}, Failures: map[string]string{}, Aborted: true}
	if aborted.OK() {
		t.Fatal("an aborted sweep must not report OK(); it did nothing at all")
	}
	clean := SweepResult{Dispositions: map[Disposition]int{}, Failures: map[string]string{}}
	if !clean.OK() {
		t.Fatal("a clean sweep must report OK(), or the flag above is just breaking everything")
	}
}

// TestRetentionRegression_OKIsFalseForEachConditionIndependently exists because a mutation sweep found
// one clause of OK() to be untestable through Sweep.
//
// Mutating `r.Dispositions[DispositionUnreachable] == 0` to `true` SURVIVED the end-to-end test, because
// every code path that produces an unreachable receipt also records a Failures entry, so the Failures
// clause masked the mutation. The clause is therefore redundant today — but it is kept rather than
// deleted, because it is the clause that still holds if a future refactor records an unreachable receipt
// without a failure entry (for instance by treating an expected external-sink refusal as unremarkable).
// A retained defence needs its own test or it is decoration, so each clause is falsified here directly.
func TestRetentionRegression_OKIsFalseForEachConditionIndependently(t *testing.T) {
	cases := map[string]SweepResult{
		"aborted": {Aborted: true, Dispositions: map[Disposition]int{}, Failures: map[string]string{}},
		"failure": {Dispositions: map[Disposition]int{}, Failures: map[string]string{"s": "boom"}},
		"unreachable with no failure entry": {
			Dispositions: map[Disposition]int{DispositionUnreachable: 1},
			Failures:     map[string]string{},
		},
		"overdue": {Dispositions: map[Disposition]int{}, Failures: map[string]string{}, OverdueCount: 1},
	}
	for name, res := range cases {
		if res.OK() {
			t.Errorf("OK() = true for %q; each condition must independently make a sweep not-OK", name)
		}
	}
	// The positive control must NOT share its construction with the cases above, or a change that broke
	// OK() outright would still read as four passes.
	healthy := SweepResult{
		Dispositions: map[Disposition]int{DispositionPurged: 3, DispositionAlreadyAbsent: 1},
		Failures:     map[string]string{},
	}
	if !healthy.OK() {
		t.Fatal("a healthy sweep must report OK(), or the four checks above pass for the wrong reason")
	}
}

// TestRetentionRegression_ResumeDoesNotReCountPriorRemovals is the regression test for the third draft
// defect: a resumed sweep returned the stored complete receipt and the caller added its RecordsRemoved
// to the new sweep's total, overstating removals on every subsequent sweep. Measured at the time: a
// second sweep over one purged sink and one recovered sink reported 10 records removed when 6 were
// removed — a 67% overstatement that would have been reported to a regulator.
func TestRetentionRegression_ResumeDoesNotReCountPriorRemovals(t *testing.T) {
	sink := inProcessSink("postgres_actors", 11)
	h := newHarness(t, []Sink{sink})

	first, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("first sweep: %v", err)
	}
	if first.RecordsRemoved != 11 {
		t.Fatalf("first sweep removed %d, want 11", first.RecordsRemoved)
	}
	if first.AlreadyDischarged != 0 {
		t.Errorf("first sweep discharged %d copies in advance", first.AlreadyDischarged)
	}

	second, err := h.ctrl.Sweep(t.Context(), "tenant-a")
	if err != nil {
		t.Fatalf("second sweep: %v", err)
	}
	if second.RecordsRemoved != 0 {
		t.Fatalf("second sweep reported %d records removed; the prior receipt was re-counted", second.RecordsRemoved)
	}
	if second.AlreadyDischarged != 1 {
		t.Errorf("already_discharged = %d, want 1: 'nothing left to remove' must be distinguishable from 'did not look'", second.AlreadyDischarged)
	}
	if len(second.Receipts) != 0 {
		t.Errorf("second sweep wrote %d receipts for an already-discharged copy", len(second.Receipts))
	}
}

// TestRetentionRegression_PostgresArrayRoundTrip covers the hand-rolled array codec.
//
// Hand-rolled because this module's Postgres access is plain database/sql with no array helper imported
// anywhere else. Hand-rolled codecs are exactly where quoting bugs live, and a hold ID or receipt digest
// containing a quote or backslash would either corrupt the row or, worse, silently truncate the list —
// which for hold_ids means a receipt naming fewer holds than actually blocked it.
func TestRetentionRegression_PostgresArrayRoundTrip(t *testing.T) {
	cases := [][]string{
		nil,
		{},
		{"h1"},
		{"h1", "h2", "h3"},
		{`with "quotes"`},
		{`with\backslash`},
		{`both "and" \ together`},
		{"with,comma"},
		{"", "empty-first"},
		{strings.Repeat("a", 64)},
	}
	for _, want := range cases {
		encoded := textArray(want)
		got := parseTextArray(encoded)
		if len(want) == 0 {
			if len(got) != 0 {
				t.Errorf("textArray(%v) = %q round-tripped to %v, want empty", want, encoded, got)
			}
			continue
		}
		if len(got) != len(want) {
			t.Errorf("textArray(%v) = %q round-tripped to %v (%d elements, want %d)", want, encoded, got, len(got), len(want))
			continue
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("element %d: got %q, want %q (encoded %q)", i, got[i], want[i], encoded)
			}
		}
	}
	// Empty must encode as the PostgreSQL empty-array literal, not as "{\"\"}" which is a one-element
	// array containing the empty string.
	if textArray(nil) != "{}" {
		t.Errorf("textArray(nil) = %q, want {}", textArray(nil))
	}
}

// TestRetentionRegression_TestSelectorMatchesTests guards the required test invocation.
//
// `go test -run TestRetention ./...` is one of this card's required tests. A zero-match selector exits 0
// and reads as a pass, so a rename would silently retire the whole suite. This asserts the prefix still
// matches by counting the test functions that carry it.
func TestRetentionRegression_TestSelectorMatchesTests(t *testing.T) {
	var total int
	for _, file := range []string{"retention_test.go", "controller_test.go", "inventory_parity_test.go", "regression_test.go"} {
		total += strings.Count(mustReadFile(t, file), "\nfunc TestRetention")
	}
	if total < 40 {
		t.Fatalf("only %d test functions match the TestRetention prefix; "+
			"`go test -run TestRetention` exits 0 on zero matches, so a rename would retire the suite silently", total)
	}
	t.Logf("`-run TestRetention` matches %d test functions", total)
}

// TestRetentionRegression_OverdueBoundaryIsExact pins the deadline comparison to the microsecond.
//
// A mutation sweep found that shifting the overdue threshold an hour later SURVIVED every other test,
// because they all advance the clock hours or days past the deadline — so a grace period nobody asked
// for would have been invisible. That is a test insensitivity rather than a bug, and the fix is a test
// that sits exactly on the boundary: at the deadline a copy is NOT yet overdue, one microsecond later it
// is. Anything looser makes "overdue" a matter of opinion.
func TestRetentionRegression_OverdueBoundaryIsExact(t *testing.T) {
	deadline := testNow.Truncate(time.Microsecond)
	o := Outstanding{TenantID: "tenant-a", SinkID: "postgres_actors", Deadline: deadline}

	cases := []struct {
		name    string
		asOf    time.Time
		overdue bool
	}{
		{"one microsecond before the deadline", deadline.Add(-time.Microsecond), false},
		{"exactly at the deadline", deadline, false},
		{"one microsecond after the deadline", deadline.Add(time.Microsecond), true},
		{"one hour after the deadline", deadline.Add(time.Hour), true},
	}
	for _, tc := range cases {
		age := o.OverdueAge(tc.asOf)
		if got := age > 0; got != tc.overdue {
			t.Errorf("%s: overdue = %v (age %s), want %v", tc.name, got, age, tc.overdue)
		}
		if tc.overdue && age != tc.asOf.Sub(deadline) {
			t.Errorf("%s: age = %s, want %s", tc.name, age, tc.asOf.Sub(deadline))
		}
	}
	// A zero deadline must never be overdue — it means "no deadline has been set", and reading it as
	// "overdue since 1970" would flood the gauge with every never-evaluated copy at once.
	if (Outstanding{}).OverdueAge(testNow) != 0 {
		t.Error("a zero deadline reads as overdue")
	}
	// And Overdue() filters on exactly the same rule, so the gauge and the gate cannot disagree.
	if got := Overdue([]Outstanding{o}, deadline); len(got) != 0 {
		t.Errorf("Overdue() returned %d entries at the deadline itself", len(got))
	}
	if got := Overdue([]Outstanding{o}, deadline.Add(time.Microsecond)); len(got) != 1 {
		t.Errorf("Overdue() returned %d entries one microsecond past the deadline, want 1", len(got))
	}
}
