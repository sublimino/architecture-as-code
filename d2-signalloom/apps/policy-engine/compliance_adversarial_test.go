package main

// Adversarial tests for the compliance surface — rounding function.
//
// These tests were written against the original roundTo2 (round 3) and have been updated
// to verify that roundMoney (which replaced it) does not reintroduce the same defects.
//
// The three original defects in the int(v*100+0.5)/100 era are no longer possible because
// roundMoney delegates to money.Money.Round(), which uses decimal-string rounding. These
// regression tests pin that the delegation does not break down.

import (
	"math"
	"testing"
)

// TestRoundMoneyNegativeValues verifies that negative values at rounding boundaries
// round correctly (half away from zero). The original roundTo2 truncated toward zero.
func TestRoundMoneyNegativeValues(t *testing.T) {
	cases := []struct {
		input float64
		want  float64
	}{
		{-2.675, -2.68},
		// -1.005: the nearest float64 is -1.00499999..., so binary rounding gives -1.00.
		// Decimal-string rounding sees "1.005" and rounds to 1.01. The money package
		// uses decimal-string rounding, which is the reader's answer.
		{-1.005, -1.01},
		{-0.006, -0.01},  // Sign should survive
		{-0.015, -0.02},  // Another boundary
		{-99.995, -100.0},
	}
	for _, tc := range cases {
		got := roundMoney(tc.input, "GBP")
		if got != tc.want {
			t.Errorf("roundMoney(%g, GBP) = %g, want %g", tc.input, got, tc.want)
		}
	}
}

// TestRoundMoneyNaN verifies that NaN is not silently fabricated into 0.0.
func TestRoundMoneyNaN(t *testing.T) {
	got := roundMoney(math.NaN(), "GBP")
	if !math.IsNaN(got) {
		t.Errorf("roundMoney(NaN, GBP) = %g, want NaN; a non-finite input must not silently become "+
			"a plausible number on a compliance surface", got)
	}
}

// TestRoundMoneyInf verifies that ±Inf is not silently fabricated into a finite number.
func TestRoundMoneyInf(t *testing.T) {
	for _, v := range []float64{math.Inf(1), math.Inf(-1)} {
		got := roundMoney(v, "GBP")
		if !math.IsInf(got, 0) {
			t.Errorf("roundMoney(%g, GBP) = %g, want ±Inf; a non-finite input must not silently become "+
				"a plausible number on a compliance surface", v, got)
		}
	}
}
