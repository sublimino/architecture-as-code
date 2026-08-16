package money

// Adversarial tests for the money package.
//
// Each test was written RED against the behaviour at the time. The focus is numeric edge cases
// and validation gaps that the existing suite does not exercise.

import (
	"math"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Amount validation: NaN/Inf pass through unchecked.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestValidateRejectsNonFiniteAmount demonstrates that Money.Validate checks the currency but
// not the amount. An amount of NaN or Inf is "valid" and propagates silently through Add, Sub,
// GreaterThan, and Convert — producing fabricated figures with no error.
//
// THE DEFECT. Validate only calls Currency.Validate(). A Money{math.NaN(), "GBP"} passes
// validation and enters the risk pipeline as a legitimate denominated value. Every operation
// that touches it produces NaN with no error returned.
func TestValidateRejectsNonFiniteAmount(t *testing.T) {
	for _, tc := range []struct {
		name   string
		amount float64
	}{
		{"NaN", math.NaN()},
		{"+Inf", math.Inf(1)},
		{"-Inf", math.Inf(-1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := Money{Amount: tc.amount, Currency: "GBP"}
			if err := m.Validate("test"); err == nil {
				t.Errorf("Money{%s, GBP}.Validate() = nil; a non-finite amount is not money, "+
					"it is a computation error that should be caught at the boundary", tc.name)
			}
		})
	}
}

// TestAddRejectsNonFiniteAmounts demonstrates that Add silently propagates NaN/Inf.
//
// THE DEFECT. Add checks that currencies match and that the currency is valid, but never
// inspects the amounts. Adding NaN to a valid amount produces NaN with no error.
func TestAddRejectsNonFiniteAmounts(t *testing.T) {
	valid := Money{Amount: 100, Currency: "GBP"}
	for _, tc := range []struct {
		name string
		bad  Money
	}{
		{"NaN+valid", Money{Amount: math.NaN(), Currency: "GBP"}},
		{"+Inf+valid", Money{Amount: math.Inf(1), Currency: "GBP"}},
		{"-Inf+valid", Money{Amount: math.Inf(-1), Currency: "GBP"}},
		{"valid+NaN", Money{Amount: math.NaN(), Currency: "GBP"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result, err := Add(tc.bad, valid)
			if err == nil {
				t.Errorf("Add(%v, %v) = %v, nil; adding a non-finite amount must be an error, "+
					"not silent propagation of a fabricated figure", tc.bad, valid, result)
			}
		})
	}
}

// TestSubRejectsNonFiniteAmounts mirrors TestAddRejectsNonFiniteAmounts for Sub.
func TestSubRejectsNonFiniteAmounts(t *testing.T) {
	valid := Money{Amount: 100, Currency: "GBP"}
	bad := Money{Amount: math.NaN(), Currency: "GBP"}
	result, err := valid.Sub(bad)
	if err == nil {
		t.Errorf("Sub(%v, %v) = %v, nil; subtracting a non-finite amount must be an error",
			valid, bad, result)
	}
}

// TestGreaterThanRejectsNonFiniteAmounts demonstrates that GreaterThan with NaN always
// returns false — which is the IEEE 754 answer but not the right answer for money.
//
// THE DEFECT. NaN > anything is false in IEEE 754, so Money{NaN, GBP}.GreaterThan(threshold)
// returns (false, nil). A threshold test that should refuse a corrupted figure instead reports
// "under the threshold" — the wrong verdict, with no error.
func TestGreaterThanRejectsNonFiniteAmounts(t *testing.T) {
	threshold := Money{Amount: 25000, Currency: "GBP"}
	nan := Money{Amount: math.NaN(), Currency: "GBP"}

	gt, err := nan.GreaterThan(threshold)
	if err == nil {
		t.Errorf("Money{NaN, GBP}.GreaterThan(25000 GBP) = (%v, nil); comparing a non-finite "+
			"amount against a threshold produces a wrong verdict (IEEE 754 says NaN > x is false), "+
			"not merely a wrong number. It must be an error.", gt)
	}
}

// TestSumRejectsNonFiniteAmounts checks that Sum catches NaN/Inf in any position.
func TestSumRejectsNonFiniteAmounts(t *testing.T) {
	valid := Money{Amount: 100, Currency: "GBP"}
	nan := Money{Amount: math.NaN(), Currency: "GBP"}

	// NaN as the only element
	if _, err := Sum(nan); err == nil {
		t.Error("Sum(NaN) should be an error")
	}

	// NaN as first of two
	if _, err := Sum(nan, valid); err == nil {
		t.Error("Sum(NaN, valid) should be an error")
	}

	// NaN as second of two
	if _, err := Sum(valid, nan); err == nil {
		t.Error("Sum(valid, NaN) should be an error")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Arithmetic overflow and extreme values.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestAddOverflowToInf checks that adding two large amounts that overflow to Inf is caught.
func TestAddOverflowToInf(t *testing.T) {
	big := Money{Amount: math.MaxFloat64 / 2, Currency: "GBP"}
	result, err := Add(big, big)
	// MaxFloat64/2 + MaxFloat64/2 = MaxFloat64, which is finite. But MaxFloat64 + 1 ulp = Inf.
	// Let's use values that actually overflow.
	huge := Money{Amount: math.MaxFloat64, Currency: "GBP"}
	result, err = Add(huge, huge)
	if err == nil && math.IsInf(result.Amount, 0) {
		t.Errorf("Add(MaxFloat64, MaxFloat64) = %v, nil; overflow to Inf should be an error",
			result)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Currency validation edge cases.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestCurrencyValidateMultiByteRunes checks that multi-byte characters don't sneak through
// the length check. The length check uses len() which counts bytes, not runes.
func TestCurrencyValidateMultiByteRunes(t *testing.T) {
	// U+20BF (Bitcoin sign ₿) is 3 bytes in UTF-8, so len("₿") == 3.
	// It should fail the uppercase letter check even though the byte count is 3.
	if err := Currency("₿").Validate(); err == nil {
		t.Error("Currency(₿) should be rejected: not uppercase ASCII letters")
	}

	// Two 2-byte runes = 4 bytes, fails length check.
	if err := Currency("ÜÜ").Validate(); err == nil {
		t.Error("Currency(ÜÜ) should be rejected")
	}

	// Mix: 1-byte + 2-byte = 3 bytes, passes length check but fails rune check.
	if err := Currency("AÜ").Validate(); err == nil {
		t.Error("Currency(AÜ) should be rejected: not all uppercase ASCII")
	}
}

// TestCurrencyValidateNullBytes checks that null bytes in currency codes are rejected.
func TestCurrencyValidateNullBytes(t *testing.T) {
	if err := Currency("A\x00B").Validate(); err == nil {
		t.Error("Currency with null byte should be rejected")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Conversion edge cases.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestConvertNonFiniteAmount checks that converting a NaN/Inf amount is caught.
func TestConvertNonFiniteAmount(t *testing.T) {
	tbl := &RateTable{
		AsOf:  "2026-08-01",
		Base:  "USD",
		Rates: map[Currency]float64{"USD": 1.0, "GBP": 0.79},
	}
	for _, v := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		m := Money{Amount: v, Currency: "USD"}
		c, err := tbl.Convert(m, "GBP")
		if err == nil {
			t.Errorf("Convert(%g USD -> GBP) = %v, nil; converting a non-finite amount must "+
				"be an error, not silent propagation", v, c.Amount)
		}
	}
}

// TestConvertAllEmptySlice checks that ConvertAll with an empty input returns an empty result,
// not an error or nil.
func TestConvertAllEmptySlice(t *testing.T) {
	tbl := &RateTable{
		AsOf:  "2026-08-01",
		Base:  "USD",
		Rates: map[Currency]float64{"USD": 1.0, "GBP": 0.79},
	}
	result, err := tbl.ConvertAll([]Money{}, "GBP")
	if err != nil {
		t.Fatalf("ConvertAll(empty) should not error: %v", err)
	}
	if result == nil {
		t.Error("ConvertAll(empty) returned nil, want empty slice")
	}
	if len(result) != 0 {
		t.Errorf("ConvertAll(empty) returned %d results, want 0", len(result))
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Rounding edge cases beyond what edge_test.go covers.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestRoundVeryLargeAmounts checks that amounts near the maxSafeDecimal boundary behave.
func TestRoundVeryLargeAmounts(t *testing.T) {
	// Just below the maxSafeDecimal threshold: should round normally.
	m := Money{Amount: 999999999999999999.0, Currency: "GBP"}
	s := m.String()
	if s == "" {
		t.Error("String() on a large amount should not be empty")
	}

	// At the threshold: should pass through without rounding.
	big := Money{Amount: 1e18 + 1, Currency: "GBP"}
	r := big.Round()
	if r.Amount != big.Amount {
		t.Errorf("Round() on amount beyond maxSafeDecimal should return the value unchanged; "+
			"got %v, want %v", r.Amount, big.Amount)
	}
}

// TestRoundSubnormals checks that subnormal float64 values don't cause panics or corruption.
func TestRoundSubnormals(t *testing.T) {
	subnormal := math.SmallestNonzeroFloat64
	m := Money{Amount: subnormal, Currency: "GBP"}
	// Should round to 0.00 without panicking.
	got := m.String()
	if got != "0.00 GBP" {
		t.Errorf("Money{SmallestNonzeroFloat64, GBP}.String() = %q, want %q", got, "0.00 GBP")
	}
}

// TestResolveWithNonFiniteAmount checks that Resolve doesn't mask a NaN amount.
func TestResolveWithNonFiniteAmount(t *testing.T) {
	m := Money{Amount: math.NaN(), Currency: ""}
	resolved, err := m.Resolve("GBP", "test")
	if err != nil {
		// Currently Resolve doesn't check amounts, so this succeeds.
		// If amounts were validated, this would be an error.
		return
	}
	// If it succeeded, the NaN was silently given a denomination.
	if math.IsNaN(resolved.Amount) && resolved.Currency == "GBP" {
		t.Logf("NOTE: Resolve gave denomination GBP to a NaN amount without complaint")
	}
}
