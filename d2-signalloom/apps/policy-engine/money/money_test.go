package money

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// testTable is a fixed table used by the arithmetic tests. It is deliberately NOT the shipped
// risk/fx table: these tests assert the behaviour of the conversion function, and pinning them to
// the shipped rates would make every future rate update look like a code regression.
func testTable() *RateTable {
	return &RateTable{
		AsOf: "2026-08-01",
		Base: "USD",
		Rates: map[Currency]float64{
			"USD": 1.0,
			"GBP": 0.79,
			"EUR": 0.92,
			"JPY": 155.0,
		},
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The identity case. A conversion to the currency you already hold must not touch the number.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestConvertSameCurrencyIsExactIdentity(t *testing.T) {
	tbl := testTable()
	src := Money{Amount: 1234.567891, Currency: "GBP"}

	got, err := tbl.Convert(src, "GBP")
	if err != nil {
		t.Fatalf("same-currency conversion failed: %v", err)
	}
	// Bit-identical, not merely close. GBP->GBP is the regression anchor for every existing FAIR
	// figure in the repository; if it drifts by an ulp the golden numbers drift with it.
	if got.Amount != src.Amount {
		t.Fatalf("GBP->GBP moved the number: got %v, want exactly %v", got.Amount, src.Amount)
	}
	if got.Rate != 1.0 {
		t.Fatalf("GBP->GBP rate = %v, want exactly 1.0", got.Rate)
	}
	if got.Currency != "GBP" || got.Source != src {
		t.Fatalf("identity conversion lost its provenance: %+v", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Cross-rate arithmetic.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestConvertCrossRateViaBase(t *testing.T) {
	tbl := testTable()

	// GBP -> USD. rate = rates[USD]/rates[GBP] = 1.0/0.79 = 1.26582...
	got, err := tbl.Convert(Money{Amount: 1000, Currency: "GBP"}, "USD")
	if err != nil {
		t.Fatalf("GBP->USD failed: %v", err)
	}
	want := 1000 * (1.0 / 0.79)
	if math.Abs(got.Amount-want) > 1e-9 {
		t.Fatalf("GBP->USD = %.10f, want %.10f", got.Amount, want)
	}
	if math.Abs(got.Rate-(1.0/0.79)) > 1e-12 {
		t.Fatalf("rate = %.12f, want %.12f", got.Rate, 1.0/0.79)
	}
	if got.AsOf != "2026-08-01" {
		t.Fatalf("as_of = %q, want the table's effective date", got.AsOf)
	}
	// The working must be shown: a figure a reader cannot re-derive is not evidence.
	if got.Source.Amount != 1000 || got.Source.Currency != "GBP" {
		t.Fatalf("converted figure did not carry its source: %+v", got.Source)
	}
}

func TestConvertNeitherSideIsBase(t *testing.T) {
	tbl := testTable()
	// GBP -> EUR crosses through USD: 0.92/0.79.
	got, err := tbl.Convert(Money{Amount: 500, Currency: "GBP"}, "EUR")
	if err != nil {
		t.Fatalf("GBP->EUR failed: %v", err)
	}
	want := 500 * (0.92 / 0.79)
	if math.Abs(got.Amount-want) > 1e-9 {
		t.Fatalf("GBP->EUR = %.10f, want %.10f", got.Amount, want)
	}
}

// Round-tripping must return the original to within floating-point noise.
//
// TOLERANCE JUSTIFICATION. A round trip is amount * (r_b/r_a) * (r_a/r_b). In exact arithmetic that
// is the identity. In IEEE-754 double it is two multiplications and two divisions, each of which can
// introduce at most half an ulp of relative error -- so the accumulated relative error is bounded at
// a few ulps, i.e. of order 1e-15. We assert 1e-9 relative, six orders of magnitude of headroom,
// because the purpose of the test is to catch a WRONG rate direction (which shows up as a factor of
// ~1.6, not as 1e-15), not to police the last bit of the mantissa.
//
// Note this tolerance holds only because Convert does NOT round. Rounding to minor units mid-trip
// would bound the error at half a penny scaled by the rate instead -- see TestRoundIsPresentationOnly.
func TestRoundTripIsWithinFloatingPointNoise(t *testing.T) {
	tbl := testTable()
	for _, pair := range [][2]Currency{{"GBP", "USD"}, {"GBP", "EUR"}, {"EUR", "JPY"}, {"USD", "GBP"}} {
		start := Money{Amount: 123456.789, Currency: pair[0]}

		out, err := tbl.Convert(start, pair[1])
		if err != nil {
			t.Fatalf("%s->%s: %v", pair[0], pair[1], err)
		}
		back, err := tbl.Convert(out.Money(), pair[0])
		if err != nil {
			t.Fatalf("%s->%s: %v", pair[1], pair[0], err)
		}

		relErr := math.Abs(back.Amount-start.Amount) / start.Amount
		if relErr > 1e-9 {
			t.Fatalf("%s->%s->%s relative error %.3e exceeds 1e-9 (got %.6f, want %.6f)",
				pair[0], pair[1], pair[0], relErr, back.Amount, start.Amount)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The failure mode that puts a wrong number on a slide: a silent pass-through.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestMissingRateIsAnErrorNamingThePair(t *testing.T) {
	tbl := testTable()

	_, err := tbl.Convert(Money{Amount: 100, Currency: "GBP"}, "CHF")
	if err == nil {
		t.Fatal("converting to an unknown currency returned no error; a silent 1.0 puts a wrong figure on a slide")
	}
	msg := err.Error()
	// The message must name BOTH sides of the pair, or the operator cannot tell which one to add.
	for _, want := range []string{"GBP", "CHF", "2026-08-01"} {
		if !strings.Contains(msg, want) {
			t.Errorf("error %q does not name %q", msg, want)
		}
	}

	if _, err := tbl.Convert(Money{Amount: 100, Currency: "ZWL"}, "USD"); err == nil {
		t.Fatal("converting FROM an unknown currency returned no error")
	}
}

func TestMissingRateNeverReturnsAUsableNumber(t *testing.T) {
	tbl := testTable()
	got, err := tbl.Convert(Money{Amount: 100, Currency: "GBP"}, "CHF")
	if err == nil {
		t.Fatal("expected an error")
	}
	// The zero Converted must not read as "100 CHF" to a caller that ignores the error.
	if got.Amount != 0 || got.Currency != "" {
		t.Fatalf("failed conversion returned a usable-looking figure %+v; it must be the zero value", got)
	}
}

func TestZeroRateIsRejected(t *testing.T) {
	tbl := testTable()
	tbl.Rates["XXX"] = 0
	if _, err := tbl.Convert(Money{Amount: 100, Currency: "XXX"}, "USD"); err == nil {
		t.Fatal("a zero rate must be rejected, not divided by")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Currency code hygiene.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestCurrencyValidateRejectsMalformedCodes(t *testing.T) {
	for _, bad := range []Currency{"", "gbp", "GB", "GBPP", "G8P", "£"} {
		if err := bad.Validate(); err == nil {
			t.Errorf("Currency(%q).Validate() = nil, want an error", bad)
		}
	}
	for _, good := range []Currency{"GBP", "USD", "JPY"} {
		if err := good.Validate(); err != nil {
			t.Errorf("Currency(%q).Validate() = %v, want nil", good, err)
		}
	}
}

func TestMoneyWithoutCurrencyIsInvalid(t *testing.T) {
	if err := (Money{Amount: 100}).Validate("appetite.tolerance"); err == nil {
		t.Fatal("money with no currency must be invalid; that is the entire point of the type")
	} else if !strings.Contains(err.Error(), "appetite.tolerance") {
		t.Fatalf("error %q does not name the offending field", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Rounding is a presentation concern and must never touch the arithmetic.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestRoundIsPresentationOnly(t *testing.T) {
	tbl := testTable()
	got, err := tbl.Convert(Money{Amount: 1000, Currency: "GBP"}, "USD")
	if err != nil {
		t.Fatal(err)
	}
	// Convert leaves full precision behind. 1000/0.79 = 1265.8227848101266...
	if got.Amount == math.Round(got.Amount*100)/100 {
		t.Fatalf("Convert appears to have rounded: %.10f", got.Amount)
	}
	if r := got.Money().Round().Amount; r != 1265.82 {
		t.Fatalf("Round() = %v, want 1265.82", r)
	}
}

func TestRoundHalfAwayFromZero(t *testing.T) {
	// Go's strconv/fmt default to round-half-to-even. A compliance figure should match what a human
	// gets with a calculator, so we round half AWAY from zero and assert it explicitly.
	cases := []struct {
		in   float64
		want float64
	}{
		{2.005, 2.01},   // exactly-representable-ish half case
		{2.675, 2.68},   // the classic float-repr trap
		{-2.675, -2.68}, // symmetric about zero
		{0.125, 0.13},
		{-0.125, -0.13},
	}
	for _, c := range cases {
		got := Money{Amount: c.in, Currency: "GBP"}.Round().Amount
		if got != c.want {
			t.Errorf("Round(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestRoundRespectsMinorUnitExponent(t *testing.T) {
	// JPY has no minor unit. Rounding it to 2dp would print a figure that cannot exist.
	if got := (Money{Amount: 1234.567, Currency: "JPY"}).Round().Amount; got != 1235 {
		t.Fatalf("JPY rounded to %v, want 1235 (zero-decimal currency)", got)
	}
	if got := (Money{Amount: 1234.567, Currency: "GBP"}).Round().Amount; got != 1234.57 {
		t.Fatalf("GBP rounded to %v, want 1234.57", got)
	}
	// An unknown-but-well-formed code falls back to 2, the overwhelmingly common case.
	if got := (Money{Amount: 1.005, Currency: "XAU"}).Round().Amount; got != 1.01 {
		t.Fatalf("unknown currency rounded to %v, want 1.01", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Determinism. The same inputs must produce the same bytes, forever.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestConversionIsPureAndDeterministic(t *testing.T) {
	tbl := testTable()
	src := Money{Amount: 987654.321, Currency: "GBP"}

	first, err := tbl.Convert(src, "JPY")
	if err != nil {
		t.Fatal(err)
	}
	firstJSON, _ := json.Marshal(first)

	for i := 0; i < 100; i++ {
		got, err := tbl.Convert(src, "JPY")
		if err != nil {
			t.Fatal(err)
		}
		gotJSON, _ := json.Marshal(got)
		if string(gotJSON) != string(firstJSON) {
			t.Fatalf("conversion is not deterministic:\n run 1: %s\n run %d: %s", firstJSON, i+2, gotJSON)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Wire shape. The other half of this change is built against these exact field names.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestMoneyJSONShape(t *testing.T) {
	b, err := json.Marshal(Money{Amount: 1000, Currency: "GBP"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(b), `{"amount":1000,"currency":"GBP"}`; got != want {
		t.Fatalf("Money JSON = %s, want %s", got, want)
	}
}

func TestConvertedJSONShape(t *testing.T) {
	c := Converted{
		Amount:   1265.8,
		Currency: "USD",
		Source:   Money{Amount: 1000, Currency: "GBP"},
		Rate:     1.2658,
		AsOf:     "2026-08-01",
	}
	b, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"amount":1265.8,"currency":"USD","source":{"amount":1000,"currency":"GBP"},"rate":1.2658,"as_of":"2026-08-01"}`
	if string(b) != want {
		t.Fatalf("Converted JSON =\n  %s\nwant\n  %s", b, want)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// YAML ergonomics. A bare scalar is allowed ONLY because the file declares its currency once, and
// a file that declares money without a currency is a load error rather than a silent default.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestMoneyYAMLAcceptsBothForms(t *testing.T) {
	var doc struct {
		Bare     Money `yaml:"bare"`
		Explicit Money `yaml:"explicit"`
	}
	src := "bare: 4000\nexplicit: { amount: 250, currency: EUR }\n"
	if err := yaml.Unmarshal([]byte(src), &doc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if doc.Bare.Amount != 4000 || doc.Bare.Currency != "" {
		t.Fatalf("bare scalar = %+v, want amount 4000 and an UNSET currency awaiting resolution", doc.Bare)
	}
	if doc.Explicit.Amount != 250 || doc.Explicit.Currency != "EUR" {
		t.Fatalf("explicit mapping = %+v, want 250 EUR", doc.Explicit)
	}
}

func TestResolveFillsOnlyUnsetCurrencies(t *testing.T) {
	bare := Money{Amount: 4000}
	explicit := Money{Amount: 250, Currency: "EUR"}

	got, err := bare.Resolve("GBP", "pack.controls[0].annual_cost")
	if err != nil {
		t.Fatal(err)
	}
	if got.Currency != "GBP" {
		t.Fatalf("bare money resolved to %q, want the document default GBP", got.Currency)
	}

	// An explicitly denominated amount must NEVER be silently redenominated by the file default.
	got, err = explicit.Resolve("GBP", "pack.controls[1].annual_cost")
	if err != nil {
		t.Fatal(err)
	}
	if got.Currency != "EUR" {
		t.Fatalf("explicit EUR was overwritten with %q by the document default", got.Currency)
	}
}

func TestResolveWithoutADefaultIsAnError(t *testing.T) {
	_, err := Money{Amount: 4000}.Resolve("", "org.appetite.tolerance")
	if err == nil {
		t.Fatal("a bare amount with no document currency must fail; defaulting it is how the wrong currency reaches a slide")
	}
	if !strings.Contains(err.Error(), "org.appetite.tolerance") {
		t.Fatalf("error %q does not name the offending field", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Rate table loading and validation.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestRateTableValidateRejectsBadTables(t *testing.T) {
	cases := map[string]RateTable{
		"no as_of":        {Base: "USD", Rates: map[Currency]float64{"USD": 1}},
		"no base":         {AsOf: "2026-08-01", Rates: map[Currency]float64{"USD": 1}},
		"base not listed": {AsOf: "2026-08-01", Base: "USD", Rates: map[Currency]float64{"GBP": 0.79}},
		"base not 1.0":    {AsOf: "2026-08-01", Base: "USD", Rates: map[Currency]float64{"USD": 1.5}},
		"negative rate":   {AsOf: "2026-08-01", Base: "USD", Rates: map[Currency]float64{"USD": 1, "GBP": -0.79}},
		"bad code":        {AsOf: "2026-08-01", Base: "USD", Rates: map[Currency]float64{"USD": 1, "gbp": 0.79}},
		"empty":           {AsOf: "2026-08-01", Base: "USD"},
	}
	for name, tbl := range cases {
		if err := tbl.Validate(); err == nil {
			t.Errorf("%s: Validate() = nil, want an error", name)
		}
	}
	if err := testTable().Validate(); err != nil {
		t.Fatalf("well-formed table rejected: %v", err)
	}
}

func TestParseRateTableRoundTrip(t *testing.T) {
	src := `
as_of: 2026-08-01
base: USD
rates:
  USD: 1.0
  GBP: 0.79
`
	tbl, err := ParseRateTable([]byte(src), "inline")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if tbl.AsOf != "2026-08-01" || tbl.Base != "USD" || tbl.Rates["GBP"] != 0.79 {
		t.Fatalf("parsed table = %+v", tbl)
	}
}

// The shipped table must be loadable and must carry the currencies the repository's own data uses.
// If someone adds an EUR-denominated org file and forgets the rate, this fails here rather than at
// a demo.
func TestShippedRateTableIsValid(t *testing.T) {
	tbl, err := LoadRateTable("../../../../risk/fx/rates.yaml")
	if err != nil {
		t.Fatalf("the shipped rate table must load: %v", err)
	}
	for _, c := range []Currency{"USD", "GBP", "EUR"} {
		if _, ok := tbl.Rates[c]; !ok {
			t.Errorf("shipped table has no rate for %s", c)
		}
	}
	if tbl.AsOf == "" {
		t.Error("shipped table has no effective date; an undated rate is not auditable")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Currency-safe arithmetic. Adding or comparing across denominations must be impossible.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestAddRefusesMixedCurrencies(t *testing.T) {
	_, err := Add(Money{Amount: 100, Currency: "GBP"}, Money{Amount: 100, Currency: "USD"})
	if err == nil {
		t.Fatal("adding GBP to USD succeeded; that is how a Total Cost of Risk becomes a fiction")
	}
	for _, want := range []string{"GBP", "USD"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not name %s", err, want)
		}
	}
}

func TestAddSameCurrencyIsExact(t *testing.T) {
	// NOTE ON HOW THIS TEST IS WRITTEN. The expected value is computed from float64 VARIABLES, not
	// from the literal expression `100.10 + 200.20`. Go evaluates a constant expression at arbitrary
	// precision and rounds once, giving 300.30000000000001136...; Add rounds each operand to float64
	// first and then sums, giving 300.29999999999998294... The two differ in the last three digits.
	//
	// Asserting against the constant would fail, and the natural "fix" — comparing with a tolerance,
	// or rounding inside Add — would be wrong. Add must NOT round: it is used to accumulate Total
	// Cost of Risk, and rounding each partial sum is exactly the accumulation error the package
	// comment forbids. So the test asserts what the function genuinely promises: plain float64
	// addition, unrounded.
	a, b := 100.10, 200.20
	got, err := Add(Money{Amount: a, Currency: "GBP"}, Money{Amount: b, Currency: "GBP"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Currency != "GBP" || got.Amount != a+b {
		t.Fatalf("got %v, want the unrounded float64 sum %v in GBP", got.Amount, a+b)
	}
	// And confirm it really is unrounded — a rounding Add would return exactly 300.30.
	if got.Amount == 300.30 {
		t.Fatal("Add appears to round its result; partial sums must stay at full precision")
	}
}

func TestSumAndSub(t *testing.T) {
	got, err := Sum(
		Money{Amount: 1, Currency: "GBP"},
		Money{Amount: 2, Currency: "GBP"},
		Money{Amount: 3, Currency: "GBP"},
	)
	if err != nil || got.Amount != 6 {
		t.Fatalf("Sum = %+v, err %v; want 6 GBP", got, err)
	}
	if _, err := Sum(); err == nil {
		t.Fatal("an empty sum has no denomination and must be an error, not zero pounds")
	}
	if _, err := Sum(Money{Amount: 1, Currency: "GBP"}, Money{Amount: 1, Currency: "EUR"}); err == nil {
		t.Fatal("Sum across denominations must fail")
	}
	d, err := Money{Amount: 5, Currency: "GBP"}.Sub(Money{Amount: 2, Currency: "GBP"})
	if err != nil || d.Amount != 3 {
		t.Fatalf("Sub = %+v, err %v; want 3 GBP", d, err)
	}
}

func TestGreaterThanRefusesMixedCurrencies(t *testing.T) {
	// 30,000 USD is ~23,700 GBP: BELOW a 25,000 GBP tolerance band. Compared naively as floats it
	// reads as above, and the control is wrongly promoted to the gate.
	_, err := Money{Amount: 30000, Currency: "USD"}.GreaterThan(Money{Amount: 25000, Currency: "GBP"})
	if err == nil {
		t.Fatal("a threshold comparison across denominations must fail; it yields a wrong VERDICT")
	}
	above, err := Money{Amount: 30000, Currency: "GBP"}.GreaterThan(Money{Amount: 25000, Currency: "GBP"})
	if err != nil || !above {
		t.Fatalf("same-currency comparison broken: %v %v", above, err)
	}
}
