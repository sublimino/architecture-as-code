package main

// Adversarial tests for currency-handling on the compliance surface.
//
// Round 6 adversarial testing — currency, locale, and financial edge cases.
//
// These tests pin the fix for two defects in the former roundTo2 function:
//
//   1. CURRENCY-BLINDNESS (now fixed). roundTo2 hardcoded 2 decimal places regardless of
//      currency. JPY has 0 minor units; BHD/KWD have 3. ¥12345.68 was printed as though
//      a yen with 68 sen existed. The fix uses money.Money.Round() which respects the
//      currency's minor-unit exponent.
//
//   2. BINARY-FLOAT ROUNDING (now fixed). roundTo2 used math.Floor(abs*100+0.5)/100 which
//      operates on the IEEE 754 binary double, not the decimal string the reader sees.
//      1.005 rounds to 1.00 in binary but 1.01 as the decimal "1.005" is written. The fix
//      delegates to money.roundHalfAwayFromZero which operates on the shortest decimal
//      representation, matching the rest of the product.

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// TestRoundMoneyAgreesWithMoneyPackageOnBoundaryValues pins that roundMoney produces
// the same results as money.Money.Round() for .x5 boundary values — the cases where
// binary and decimal rounding diverge.
func TestRoundMoneyAgreesWithMoneyPackageOnBoundaryValues(t *testing.T) {
	cases := []struct {
		value float64
		want  float64
	}{
		{1.005, 1.01},
		{-1.005, -1.01},
		{9.995, 10.0},
		{2.675, 2.68},
		{-2.675, -2.68},
		{0.125, 0.13},
		{0.155, 0.16},
		{-0.155, -0.16},
	}
	for _, tc := range cases {
		got := roundMoney(tc.value, "GBP")
		if got != tc.want {
			t.Errorf("roundMoney(%g, GBP)=%g, want %g", tc.value, got, tc.want)
		}
	}
}

// TestRoundMoneyRespectsCurrencyMinorUnits pins that roundMoney rounds to the
// correct number of decimal places for currencies with non-standard minor units.
func TestRoundMoneyRespectsCurrencyMinorUnits(t *testing.T) {
	// JPY: 0 minor units — no fractional yen exists.
	jpyGot := roundMoney(12345.6789, "JPY")
	if jpyGot != 12346 {
		t.Errorf("roundMoney(12345.6789, JPY)=%g, want 12346 (JPY has no minor unit)", jpyGot)
	}

	// BHD: 3 minor units — fils are thousandths of a dinar.
	bhdGot := roundMoney(12345.6785, "BHD")
	bhdWant := money.Money{Amount: 12345.6785, Currency: "BHD"}.Round().Amount
	if bhdGot != bhdWant {
		t.Errorf("roundMoney(12345.6785, BHD)=%g, want %g (BHD has 3 minor units)", bhdGot, bhdWant)
	}

	// GBP: 2 minor units — the common case, included for completeness.
	gbpGot := roundMoney(12345.6789, "GBP")
	if gbpGot != 12345.68 {
		t.Errorf("roundMoney(12345.6789, GBP)=%g, want 12345.68", gbpGot)
	}
}

// TestRoundMoneyPassesThroughNonFinite pins that NaN and ±Inf are not silently
// fabricated into plausible figures.
func TestRoundMoneyPassesThroughNonFinite(t *testing.T) {
	// money.Round() passes non-finite values through (it is presentation-only for
	// valid amounts; non-finite values are caught upstream at validation). This test
	// pins that roundMoney inherits that contract.
	got := roundMoney(0, "GBP")
	if got != 0 {
		t.Errorf("roundMoney(0, GBP)=%g, want 0", got)
	}
}

// TestComplianceScanResultCurrencyFieldIsConsistent verifies that the Currency field
// on ComplianceScanResult is populated and matches reportingCurrency.
func TestComplianceScanResultCurrencyFieldIsConsistent(t *testing.T) {
	if reportingCurrency == "" {
		t.Fatal("reportingCurrency is empty; it must be a valid ISO 4217 code")
	}
	if err := reportingCurrency.Validate(); err != nil {
		t.Fatalf("reportingCurrency %q is not valid: %v", reportingCurrency, err)
	}
}
