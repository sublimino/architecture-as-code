package money

// Edge cases at the boundaries of this package's guards.
//
// WHY THIS FILE EXISTS, SEPARATELY FROM money_test.go.
//
// money_test.go covers the behaviour this package promises for well-formed input, and it covers it
// well. These are the cases where a guard that is correct for typical values diverges at the
// boundary — the shape of defect that survives a green suite because both sides agree on the happy
// path and only disagree on an unusual day.
//
// Each test below was written RED against the behaviour at the time, and each names the wrong value
// it observed alongside the right one, so a future reader can tell a regression from a rewrite.

import (
	"math"
	"strings"
	"testing"
)

// TestRateTableRejectsNonFiniteRates pins that a rate which is not a real positive number is
// refused at load, not carried into a figure.
//
// THE DEFECT THIS CAUGHT. Validate guarded rates with
//
//	if r <= 0 { ...reject... }
//
// and the doc comment above it says "rates must be > 0". Those two are not the same statement.
// NaN is not <= 0 — every IEEE-754 comparison against NaN is false — so a NaN rate passed
// validation, and +Inf is not <= 0 either. Rate() carried the same `rf <= 0` / `rt <= 0` shape, so
// neither leg caught it on the way through.
//
// Observed before the fix, from a table declaring `USD: .nan` and `EUR: .inf` (yaml.v3 parses both):
//
//	ParseRateTable err = <nil>                        <- accepted
//	Convert 1000000 GBP -> USD = amount=NaN  err=<nil> <- no error
//	  .Money().String() = "NaN USD"
//	Convert 1000000 GBP -> EUR = amount=+Inf err=<nil>
//	  .Money().String() = "+Inf EUR"
//
// That is worse than the silent-1.0 failure the package comment is built to prevent, because it
// reaches the wire: json.Marshal of the table then fails with `json: unsupported value: +Inf`,
// naming neither the offending currency nor the file, several layers away from the typo.
//
// The correct behaviour is to fail at load with a message naming the currency and the value.
func TestRateTableRejectsNonFiniteRates(t *testing.T) {
	for _, tc := range []struct {
		name string
		yaml string
		bad  string
	}{
		{"NaN rate", "as_of: 2026-08-01\nbase: USD\nrates:\n  USD: 1.0\n  GBP: .nan\n", "GBP"},
		{"positive infinity", "as_of: 2026-08-01\nbase: USD\nrates:\n  USD: 1.0\n  GBP: .inf\n", "GBP"},
		{"negative infinity", "as_of: 2026-08-01\nbase: USD\nrates:\n  USD: 1.0\n  GBP: -.inf\n", "GBP"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tbl, err := ParseRateTable([]byte(tc.yaml), "edge.yaml")
			if err == nil {
				// Show what the accepted table actually produces, so a failure report carries the
				// consequence and not just "expected an error".
				c, cerr := tbl.Convert(Money{Amount: 1_000_000, Currency: "USD"}, Currency(tc.bad))
				t.Fatalf("a %s rate for %s was ACCEPTED at load.\n"+
					"  Converting 1,000,000 USD then yields amount=%v (err=%v), rendered as %q.\n"+
					"  A rate that is not a real positive number must be refused at load, naming the\n"+
					"  currency, rather than becoming a non-finite figure on a risk surface.",
					tc.name, tc.bad, c.Amount, cerr, c.Money().String())
			}
			if !strings.Contains(err.Error(), tc.bad) {
				t.Errorf("error must name the offending currency %q so an operator can fix the line; got: %v",
					tc.bad, err)
			}
		})
	}
}

// TestRateNeverReturnsNonFiniteMultiplier is the second line of defence: a RateTable built in code
// rather than parsed from YAML never runs Validate, so Rate itself must refuse a non-finite leg.
//
// This matters because Rate is the only thing between a rate map and a priced figure, and the
// nearest caller (buildFXTable in tools/riskctl) constructs its pairs matrix by calling Rate for
// every ordered pair.
func TestRateNeverReturnsNonFiniteMultiplier(t *testing.T) {
	for _, tc := range []struct {
		name string
		rate float64
	}{
		{"NaN", math.NaN()},
		{"+Inf", math.Inf(1)},
		{"-Inf", math.Inf(-1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tbl := &RateTable{AsOf: "2026-08-01", Base: "USD", Rates: map[Currency]float64{
				"USD": 1.0,
				"GBP": tc.rate,
			}}
			// Both directions: the bad leg is the denominator in one and the numerator in the other.
			for _, pair := range [][2]Currency{{"USD", "GBP"}, {"GBP", "USD"}} {
				r, err := tbl.Rate(pair[0], pair[1])
				if err == nil {
					t.Errorf("Rate(%s -> %s) with a %s rate returned %v and no error; "+
						"a multiplier that is not a real positive number must be an error, because every "+
						"figure downstream of it is fabricated", pair[0], pair[1], tc.name, r)
				}
			}
		})
	}
}

// TestSumOfOneAmountValidatesItsDenomination pins the n=1 boundary of Sum.
//
// THE DEFECT THIS CAUGHT. Sum seeds its accumulator with ms[0] and then folds ms[1:] through Add.
// Every validation this package performs on a sum lives inside Add — so with exactly one element,
// the loop body never runs and NOTHING is validated. The result is returned as a legitimate Money.
//
// Observed before the fix:
//
//	Sum(Money{5, ""})   -> {Amount:5 Currency:""} err=<nil>     <- an amount with no denomination
//	Sum(Money{5, "zz"}) -> {Amount:5 Currency:"zz"} err=<nil>   <- not an ISO 4217 code
//
// while the same values through a two-element Sum were correctly refused:
//
//	Sum(Money{5,""},   Money{0,""})   -> err = currency is empty; every amount must declare its denomination
//	Sum(Money{5,"zz"}, Money{0,"zz"}) -> err = currency "zz" is not a three-letter ISO 4217 code
//
// An amount whose denomination is unknown "is not money, it is a number" (see the Money doc
// comment) — and a single-scenario estate is the smallest real estate, not a hypothetical one.
func TestSumOfOneAmountValidatesItsDenomination(t *testing.T) {
	for _, bad := range []Currency{"", "zz", "GB", "GBPX", "gbp", "G8P"} {
		t.Run(string("currency="+bad), func(t *testing.T) {
			one := Money{Amount: 5, Currency: bad}

			// Prove the mechanism first: two elements of the SAME bad currency are refused. If this
			// ever stops holding, the n=1 assertion below would pass for the wrong reason.
			if _, err := Sum(one, Money{Amount: 0, Currency: bad}); err == nil {
				t.Fatalf("precondition failed: Sum of TWO %q amounts was accepted, so this test can no "+
					"longer show that n=1 is the special case", bad)
			}

			got, err := Sum(one)
			if err == nil {
				t.Errorf("Sum of ONE amount denominated %q returned %+v with no error, while the same "+
					"value summed with a second element is refused. Validation lives in Add, which a "+
					"one-element Sum never reaches.", bad, got)
			}
		})
	}
}

// TestRoundNeverProducesNegativeZero pins that a small negative amount does not present as "-0.00".
//
// THE DEFECT THIS CAUGHT. roundHalfAwayFromZero rebuilds the number from its decimal string and
// re-parses it, so a value that quantises to zero from below re-parses as IEEE-754 negative zero;
// and the early "already exact at this precision" return hands back a -0.0 input untouched. Round
// is documented as presentation-only, and String formats its output with %.*f, which preserves the
// sign bit.
//
// Observed before the fix:
//
//	Money{-0.001, GBP}.String()  ->  "-0.00 GBP"
//	Money{-0.004, GBP}.String()  ->  "-0.00 GBP"
//	Money{-0.0,   GBP}.String()  ->  "-0.00 GBP"
//
// Negative zero is not a quantity of money. On a risk surface a reader sees a signed figure and
// reasonably concludes the exposure moved in a direction it did not; on an audit surface it is a
// value nobody can reproduce with a calculator, which is the standard this package sets for itself.
//
// Note the positive side is unaffected: 0.001 already rendered as "0.00 GBP".
func TestRoundNeverProducesNegativeZero(t *testing.T) {
	for _, tc := range []struct {
		amount   float64
		currency Currency
		want     string
	}{
		{-0.001, "GBP", "0.00 GBP"},
		{-0.004, "GBP", "0.00 GBP"},
		{math.Copysign(0, -1), "GBP", "0.00 GBP"},
		{-0.4, "JPY", "0 JPY"},        // zero-decimal currency
		{-0.0004, "KWD", "0.000 KWD"}, // three-decimal currency

		// The sign must still survive when there IS a quantity to sign.
		{-0.006, "GBP", "-0.01 GBP"},
		{-2.675, "GBP", "-2.68 GBP"},
		{-0.6, "JPY", "-1 JPY"},
	} {
		t.Run(tc.want, func(t *testing.T) {
			m := Money{Amount: tc.amount, Currency: tc.currency}

			if got := m.String(); got != tc.want {
				t.Errorf("Money{%v, %s}.String() = %q, want %q", tc.amount, tc.currency, got, tc.want)
			}
			// Assert the sign bit directly as well as the rendering: a caller that reads Round().Amount
			// and formats it itself must not receive a negative zero either.
			if r := m.Round().Amount; r == 0 && math.Signbit(r) {
				t.Errorf("Money{%v, %s}.Round().Amount is negative zero; zero has no sign in money",
					tc.amount, tc.currency)
			}
		})
	}
}

// TestMinorUnitsMatchISO4217 checks the static exponent table against a hand-written oracle.
//
// WHY AN ORACLE AND NOT A LOOP OVER THE MAP. Asserting the map against itself proves nothing. The
// values below were written out from ISO 4217 independently of minorUnits, so a wrong entry (or a
// currency silently falling through to the default of 2) is a failure rather than a tautology.
//
// The dashboard derives the same quantity at runtime from Intl.NumberFormat rather than from a
// table — see dashboard-signalloom/src/money/currency.ts. The two must agree or the same figure
// renders to a different number of decimal places on two surfaces; currency.edge.test.ts asserts
// the TypeScript half against this same oracle.
func TestMinorUnitsMatchISO4217(t *testing.T) {
	iso := map[Currency]int{
		// Every currency in risk/fx/rates.yaml, which is also every currency the dashboard offers.
		"USD": 2, "GBP": 2, "EUR": 2, "CHF": 2, "JPY": 0, "CAD": 2, "AUD": 2, "SEK": 2,
		"NOK": 2, "DKK": 2, "SGD": 2, "HKD": 2, "INR": 2, "ZAR": 2, "AED": 2,
		// Boundary cases the shipped table does not exercise: the zero- and three-decimal families.
		"KRW": 0, "VND": 0, "ISK": 0, "CLP": 0, "XOF": 0,
		"KWD": 3, "BHD": 3, "OMR": 3, "JOD": 3, "TND": 3,
	}
	for c, want := range iso {
		if got := c.MinorUnits(); got != want {
			t.Errorf("%s.MinorUnits() = %d, want %d (ISO 4217). A figure quoted to the wrong number of "+
				"decimal places is a quantity of money that cannot exist.", c, got, want)
		}
	}
}

// TestConversionRoundTripsAgainstAnIndependentlyComputedRate checks Rate against the arithmetic a
// reviewer would do by hand, for every ordered pair in the shipped table.
//
// The oracle is deliberately not Rate: it is rates[to]/rates[from] written out here, which is the
// formula the rates.yaml comment tells a reviewer to apply. A direction inversion — the defect that
// turns a 0.79 into a 1.27, a factor of 1.6 on every GBP figure — fails this and cannot fail
// quietly, because the pairs span two orders of magnitude (JPY at 155 per USD against GBP at 0.79).
func TestConversionRoundTripsAgainstAnIndependentlyComputedRate(t *testing.T) {
	tbl, err := LoadRateTable("../../../../risk/fx/rates.yaml")
	if err != nil {
		t.Fatalf("loading the shipped rate table: %v", err)
	}
	currencies := tbl.Currencies()
	if len(currencies) < 2 {
		t.Fatalf("the shipped table has %d currencies; this test needs at least two", len(currencies))
	}

	for _, from := range currencies {
		for _, to := range currencies {
			got, err := tbl.Rate(from, to)
			if err != nil {
				t.Fatalf("Rate(%s -> %s): %v", from, to, err)
			}

			want := tbl.Rates[to] / tbl.Rates[from]
			if from == to {
				want = 1.0
			}
			if math.Abs(got-want) > 1e-12*math.Max(1, math.Abs(want)) {
				t.Errorf("Rate(%s -> %s) = %v, but rates[%s]/rates[%s] = %v. The engine and the "+
					"arithmetic a reviewer performs by hand must agree exactly.",
					from, to, got, to, from, want)
			}

			// Round trip: converting out and back must return the original amount. This catches an
			// inversion that happens to be self-consistent in one direction only.
			const amount = 13346.97276384128
			out, err := tbl.Convert(Money{Amount: amount, Currency: from}, to)
			if err != nil {
				t.Fatalf("Convert(%s -> %s): %v", from, to, err)
			}
			back, err := tbl.Convert(out.Money(), from)
			if err != nil {
				t.Fatalf("Convert(%s -> %s): %v", to, from, err)
			}
			if math.Abs(back.Amount-amount) > 1e-9*amount {
				t.Errorf("%v %s -> %s -> %s returned %v, not the original amount; the two directions "+
					"of this pair disagree", amount, from, to, from, back.Amount)
			}
		}
	}
}
