package main

// Adversarial tests for the compliance surface.
//
// roundTo2 is the only rounding function used on every FAIR figure emitted by the compliance
// scanner. It is simpler than money.roundHalfAwayFromZero — and that simplicity hides three
// distinct failure modes.

import (
	"math"
	"testing"
)

// TestRoundTo2NegativeValues demonstrates that the naive int(v*100+0.5)/100 formula truncates
// toward zero, which gives the WRONG answer for negative values at the rounding boundary.
//
// THE DEFECT. Go's int() truncation is toward zero, not toward negative infinity. For positive
// values this is irrelevant because +0.5 shifts the number above the boundary, and truncation
// goes in the same direction as floor. For negative values it goes in the OPPOSITE direction:
//
//     roundTo2(-2.675)
//       = float64(int(-2.675*100 + 0.5)) / 100
//       = float64(int(-267.5 + 0.5)) / 100
//       = float64(int(-267.0)) / 100
//       = -2.67
//
// A reader with a calculator gets -2.68. The money package goes to extraordinary lengths to
// produce the reader's answer (see roundHalfAwayFromZero); this function silently contradicts it.
//
// Worse: roundTo2(-0.006) = float64(int(-0.6+0.5))/100 = float64(int(-0.1))/100 = 0.0,
// which erases the sign entirely. On a compliance surface that's a "no risk" figure where
// there is risk.
func TestRoundTo2NegativeValues(t *testing.T) {
	cases := []struct {
		input float64
		want  float64
	}{
		{-2.675, -2.68},
		// -1.005: the nearest float64 is -1.00499999..., so floor-based rounding legitimately
		// gives -1.00. This is a representation limit, not a logic bug. The money package
		// solves it with decimal-string rounding; this function operates on the binary value.
		{-1.005, -1.0},
		{-0.006, -0.01},  // Sign should survive
		{-0.015, -0.02},  // Another boundary
		{-99.995, -100.0},
	}
	for _, tc := range cases {
		got := roundTo2(tc.input)
		if got != tc.want {
			t.Errorf("roundTo2(%g) = %g, want %g; the formula int(v*100+0.5)/100 truncates "+
				"toward zero, which gives the wrong answer for negative values at the rounding boundary",
				tc.input, got, tc.want)
		}
	}
}

// TestRoundTo2NaN demonstrates that NaN silently becomes 0.0 — a plausible figure.
//
// THE DEFECT. In Go, converting NaN to int produces 0 (since Go 1.22 this is defined behavior,
// not UB). So roundTo2(NaN) = float64(int(NaN*100+0.5))/100 = float64(0)/100 = 0.0.
//
// A NaN risk figure means something went wrong upstream — a missing rate, a division by zero,
// a degenerate distribution. Turning it into 0.0 is silent corruption: the compliance surface
// reports "zero risk" where it should report "computation failed".
func TestRoundTo2NaN(t *testing.T) {
	got := roundTo2(math.NaN())
	if !math.IsNaN(got) {
		t.Errorf("roundTo2(NaN) = %g, want NaN; a non-finite input must not silently become "+
			"a plausible number on a compliance surface", got)
	}
}

// TestRoundTo2Inf demonstrates that ±Inf silently becomes a large but finite number.
//
// THE DEFECT. int(+Inf) produces a large integer (implementation-defined, typically MaxInt64
// or MinInt64), and dividing by 100 produces a finite number that looks like a real risk figure.
// On a compliance surface this is a fabricated number with no upstream computation behind it.
func TestRoundTo2Inf(t *testing.T) {
	for _, v := range []float64{math.Inf(1), math.Inf(-1)} {
		got := roundTo2(v)
		if !math.IsInf(got, 0) {
			t.Errorf("roundTo2(%g) = %g, want ±Inf; a non-finite input must not silently become "+
				"a plausible number on a compliance surface", v, got)
		}
	}
}
