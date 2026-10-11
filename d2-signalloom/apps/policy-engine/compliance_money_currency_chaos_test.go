package main

// What a declared reportingCurrency actually does to the figures, and what it
// does not.
//
// THE HEADLINE, STATED FIRST BECAUSE THE REST IS DETAIL. A declared reporting
// currency RELABELS the figures. It does not convert them. compliance.go:476-481
// prices with the pack's GBP-calibrated triples and then calls
// `roundMoney(v, profile.Currency)`, which is `money.Money{v, c}.Round().Amount`
// -- a quantisation to the new currency's minor unit and a new label. No rate is
// looked up, because the policy engine never loads a rate table at all: there is
// no RateTable, no LoadRateTable and no Convert anywhere in the service (grep
// confirms the only references in the package are money's own definitions).
//
// So `reportingCurrency: USD` reports a GBP number under a USD label. The
// repository's own checked-in table (risk/fx/rates.yaml, as of 2026-08-01) quotes
// GBP at 0.79 per USD, so the true USD figure is 1/0.79 = 1.2658x the GBP one and
// the reported figure is 79% of it -- a 21% understatement of exposure. For JPY,
// quoted at 155.0, the true figure is 155.0/0.79 = 196.2x and the report
// understates by 99.5%.
//
// This is, verbatim, the first failure mode money.go's own package comment says
// the money type exists to prevent:
//
//	"Nothing could convert, because no value carried a currency as data. A UI
//	 defaulting to USD over GBP source data would relabel the number rather than
//	 convert it."
//
// The Money type successfully made the denomination data. The engine then used
// that capability to relabel. money.Convert is written, tested, and never called
// from this service.
//
// WHAT THIS FILE DOES NOT CLAIM. It does not claim the engine SHOULD convert.
// Deciding that is a product call with a real argument on the other side: the
// triples are declared expert estimates with no provenance (see the calibration
// note in policy/frameworks/README.md and the `declared-estimate-unanchored`
// value every row carries), so converting an unanchored GBP estimate into USD
// buys arithmetic precision on top of an unmeasured input. A defensible
// alternative is to refuse any reportingCurrency other than the calibration
// currency. What is NOT defensible is the third option, which is what ships: a
// silent relabel that produces a plausible figure, with the wrong label, with no
// warning -- which money.go calls "the single worst failure mode available here".
//
// As elsewhere in this chaos work, the _DEFECT tests CHARACTERISE what happens
// today. They are tripwires, not specifications.

import (
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// ratesAsOf20260801 mirrors risk/fx/rates.yaml so the understatement can be
// quantified without the engine loading a table it does not load.
//
// Duplicated deliberately rather than read from disk: the point of this file is
// that the SERVICE has no rate table, so a test that read the real file would
// be demonstrating its own ability to read YAML, not the engine's behaviour. The
// numbers are quoted as units per 1 USD, exactly as the file quotes them.
var ratesAsOf20260801 = map[money.Currency]float64{
	"USD": 1.0, "GBP": 0.79, "EUR": 0.92, "CHF": 0.88, "JPY": 155.0,
	"CAD": 1.37, "AUD": 1.52, "SEK": 10.60, "NOK": 10.90, "DKK": 6.86,
	"SGD": 1.34, "HKD": 7.81, "INR": 84.0, "ZAR": 18.20, "AED": 3.67,
}

// mustMarshalString renders a value as JSON so a test can assert on the WIRE
// shape rather than on the Go struct.
//
// The distinction is the point in this file: a denomination welded into a json
// tag (`total_exposure_gbp`) is invisible to any assertion made on the Go field,
// because the field is just `TotalExposure float64`. Only the marshalled form
// shows what a client actually receives.
func mustMarshalString(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

// trueRateFromGBP returns the multiplier the checked-in table says should be
// applied to a GBP figure to express it in `to`.
func trueRateFromGBP(to money.Currency) (float64, bool) {
	rt, ok := ratesAsOf20260801[to]
	if !ok {
		return 0, false
	}
	return rt / ratesAsOf20260801["GBP"], true
}

// scanInCurrency runs the contract scan declaring `cur` (or nothing, when
// empty) and returns the priced rows.
func scanInCurrency(t *testing.T, h *complianceHandler, cur string) []map[string]any {
	t.Helper()
	body := baseScanBody()
	headers := map[string]string{}
	if cur != "" {
		body["reportingCurrency"] = cur
		headers["X-Tenant-ID"] = "tenant-fx"
	}
	code, rows := postScanWithHeaders(t, h, body, headers)
	if code != http.StatusOK {
		t.Fatalf("scan in %q: got %d", cur, code)
	}
	var out []map[string]any
	for _, r := range rows {
		if tvar, ok := r["tvar"].(float64); ok && tvar > 0 {
			out = append(out, r)
		}
	}
	if len(out) == 0 {
		t.Fatalf("scan in %q produced no priced rows", cur)
	}
	return out
}

// ── 1. The shape check: what it catches, and what it cannot ───────────────────

// TestMalformedReportingCurrenciesAreRefused pins the refusals that DO work.
//
// money.Currency.Validate enforces exactly three bytes, each in 'A'..'Z'. That
// byte-range test is stricter than it first looks and is worth pinning
// explicitly, because the obvious attack on an ISO-4217 shape check is a Unicode
// lookalike -- and those fail for a reason the code does not state: Validate
// compares len(c) == 3 on BYTES, so any multi-byte rune makes a visually
// three-character code length 4 or more. "USＤ" (fullwidth D, 3 runes, 5 bytes)
// and "ɃTC" (4 bytes) are refused by the length test, never reaching the range
// test. A no-break space (U+00A0) in "U D" fails the same way.
//
// The test records the exact cause for each, so that anyone later "simplifying"
// Validate to iterate runes instead of bytes learns from a red test that the
// length check was load-bearing.
func TestMalformedReportingCurrenciesAreRefused(t *testing.T) {
	h := contractHandler(t)

	cases := []struct {
		name, cur, because string
	}{
		{"lowercase", "usd", "uppercase letters only"},
		{"mixed case", "Usd", "uppercase letters only"},
		{"four letters", "USDX", "not three"},
		{"two letters", "US", "not three"},
		{"three digits", "123", "uppercase letters only"},
		{"empty after trim", "   ", "treated as undeclared, not invalid"},
		{"fullwidth lookalike", "USＤ", "3 runes but 5 bytes"},
		{"latin B with stroke", "ɃTC", "3 runes but 4 bytes"},
		{"no-break space", "U D", "3 runes but 4 bytes"},
		{"leading hyphen", "-US", "uppercase letters only"},
		{"null byte", "US\x00", "uppercase letters only"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			body := baseScanBody()
			body["reportingCurrency"] = c.cur
			code, _ := postScanWithHeaders(t, h, body, map[string]string{"X-Tenant-ID": "t"})

			// A blank-after-trim code is UNDECLARED, not invalid, and is the one
			// case here that is correctly a 200 -- pinned in the same table so
			// the boundary between "invalid" and "absent" is visible in one place.
			if strings.TrimSpace(c.cur) == "" {
				if code != http.StatusOK {
					t.Fatalf("a blank currency must be treated as undeclared (200), got %d", code)
				}
				return
			}
			if code != http.StatusBadRequest {
				t.Fatalf("currency %q (%s): got %d, want 400. A code the engine cannot "+
					"validate must never be labelled onto a figure.", c.cur, c.because, code)
			}
		})
	}
}

// TestAValidShapeIsNotAValidCurrency is the gap the shape check leaves, stated
// as a measurement rather than an opinion.
//
// Validate's doc comment is explicit and correct about why it does not check
// ISO-4217 membership: the list changes, and a stale embedded copy would reject
// a legitimate code with an unactionable message. It then says the binding
// constraint "IS enforced -- at conversion, with a message naming the missing
// pair".
//
// On THIS path there is no conversion, so that sentence does not hold here. ZZZ,
// XXX and AAA are all shape-valid, all absent from risk/fx/rates.yaml, and all
// accepted -- producing a full set of figures labelled with a currency the
// repository's own converter would refuse. XXX is the sharpest case: it is a
// real ISO-4217 code and its meaning is "no currency".
func TestAValidShapeIsNotAValidCurrency(t *testing.T) {
	h := contractHandler(t)

	for _, cur := range []string{"ZZZ", "XXX", "AAA", "QQQ", "KWD"} {
		t.Run(cur, func(t *testing.T) {
			rows := scanInCurrency(t, h, cur)
			if rows[0]["currency"] != cur {
				t.Fatalf("currency = %v, want %v", rows[0]["currency"], cur)
			}
			if _, convertible := trueRateFromGBP(money.Currency(cur)); convertible {
				t.Skipf("%s is in the checked-in table after all; this case no longer "+
					"demonstrates an unconvertible label", cur)
			}
			// The figure exists, is finite, and is denominated in something the
			// repository cannot convert to or from.
			carried, ok := rows[0]["carriedGbp"].(float64)
			if !ok || math.IsNaN(carried) || math.IsInf(carried, 0) {
				t.Fatalf("carried = %#v", rows[0]["carriedGbp"])
			}
			t.Logf("accepted: %.2f labelled %s, which risk/fx/rates.yaml (as of 2026-08-01) "+
				"has no entry for -- money.Rate would refuse this pair with "+
				"\"a conversion is never silently assumed to be 1.0\"", carried, cur)
		})
	}
}

// ── 2. The defect: relabel, not convert ───────────────────────────────────────

// TestADeclaredCurrencyRelabelsWithoutConverting_DEFECT measures the
// misstatement for every currency in the checked-in table.
//
// THIS IS A DEFECT. See the file header for why "the engine should convert" is
// not the only possible fix, and why the current third option is the one nobody
// would choose deliberately.
//
// The assertion is deliberately two-sided. It requires the figures to be
// IDENTICAL to the GBP baseline (proving no conversion happened) AND reports how
// far that is from the table's own answer (proving the gap is material rather
// than a rounding artefact). A test that only checked "differs from the true
// converted value" would also pass if the engine converted with a slightly wrong
// rate, which is a different and much less serious bug.
//
// JPY and the other zero-decimal currencies additionally change the NUMBER,
// without converting it: Round quantises to the currency's minor unit, so an
// 18072.92 GBP exposure is reported as 18073 JPY. The figure moved, which makes
// it look as though something was applied, and what was applied was a rounding
// to whole yen of a pounds figure.
func TestADeclaredCurrencyRelabelsWithoutConverting_DEFECT(t *testing.T) {
	h := contractHandler(t)
	baseline := scanInCurrency(t, h, "")

	byCheck := map[string]map[string]any{}
	for _, r := range baseline {
		byCheck[r["check"].(string)] = r
	}

	// Every currency the repository CAN convert, so the understatement is
	// quantifiable from checked-in data.
	for _, cur := range []string{"USD", "EUR", "JPY", "INR", "CHF"} {
		t.Run(cur, func(t *testing.T) {
			rate, ok := trueRateFromGBP(money.Currency(cur))
			if !ok {
				t.Fatalf("%s missing from this test's mirror of the rate table", cur)
			}
			rows := scanInCurrency(t, h, cur)
			minor := money.Currency(cur).MinorUnits()

			for _, r := range rows {
				base := byCheck[r["check"].(string)]
				if base == nil {
					t.Fatalf("check %v absent from baseline", r["check"])
				}
				gbp := base["tvar"].(float64)
				got := r["tvar"].(float64)

				// The figure is the GBP figure, re-quantised to this currency's
				// minor unit and relabelled. Nothing was converted.
				wantRelabelled := money.Money{Amount: gbp, Currency: money.Currency(cur)}.Round().Amount
				if math.Abs(got-wantRelabelled) > 1e-9 {
					t.Fatalf("check %v in %s: tvar = %v, expected the relabelled GBP figure %v. "+
						"If the engine now CONVERTS, this defect is fixed -- delete this test.",
						r["check"], cur, got, wantRelabelled)
				}

				// And here is what the checked-in table says it should have been.
				trueFigure := gbp * rate
				understatement := 1 - got/trueFigure
				if understatement < 0.01 && minor == 2 {
					t.Errorf("check %v in %s: the relabelled figure is within 1%% of the "+
						"converted one (rate %.4f), so this currency cannot demonstrate the "+
						"defect; pick another", r["check"], cur, rate)
				}
			}

			gbp := byCheck[rows[0]["check"].(string)]["tvar"].(float64)
			got := rows[0]["tvar"].(float64)
			trueFigure := gbp * rate
			t.Logf("DEFECT: %s declared -> reported %.2f %s; rates.yaml says %.2f %s "+
				"(GBP->%s = %.4f). Understatement %.1f%%. Figure %s.",
				cur, got, cur, trueFigure, cur, cur, rate, 100*(1-got/trueFigure),
				map[bool]string{true: "RE-QUANTISED to this currency's minor unit", false: "byte-identical to GBP"}[minor != 2])
		})
	}
}

// TestThePolicyEngineNeverConsultsARateTable is the structural half of the
// finding above, and it is the one that will survive a recalibration.
//
// The measurement test compares against a mirror of rates.yaml, so it would need
// updating if the rates moved. This one asserts the cause rather than the
// symptom: roundMoney -- the only function the priced figures pass through on
// their way to the response -- is a pure round-and-relabel with no rate
// argument, no table and no error return. A conversion cannot happen in a
// function that has no way to fail.
//
// money.Convert's signature is the contrast: it returns (Converted, error) and
// the Converted carries Source, Rate and AsOf precisely so "a reader who
// disagrees with the figure can re-derive it with a calculator". Nothing on the
// scan response carries a rate or an as-of date for the money, because no rate
// was applied.
func TestThePolicyEngineNeverConsultsARateTable(t *testing.T) {
	// roundMoney cannot convert: same input, different target currencies,
	// differing only by the minor-unit quantisation.
	const v = 1000.0
	for _, cur := range []money.Currency{"GBP", "USD", "EUR", "CHF", "ZZZ"} {
		if got := roundMoney(v, cur); got != v {
			t.Errorf("roundMoney(%v, %s) = %v; a two-decimal currency must not move a "+
				"whole-unit figure, which proves no rate was applied", v, cur, got)
		}
	}
	// JPY moves it only by quantisation, and only because 1000.0 has no
	// fraction to lose -- so pick a value that does, to show the move is a
	// rounding and not a conversion.
	const frac = 1000.567
	if got := roundMoney(frac, "JPY"); got != 1001 {
		t.Errorf("roundMoney(%v, JPY) = %v, want 1001 (quantised to whole yen, NOT "+
			"converted -- a conversion at 196.2 would give ~196,311)", frac, got)
	}

	// And the response carries no provenance for the money, because there is
	// none to carry.
	h := contractHandler(t)
	rows := scanInCurrency(t, h, "USD")
	for _, absent := range []string{"rate", "fxRate", "asOf", "fxAsOf", "source"} {
		if _, present := rows[0][absent]; present {
			t.Errorf("row now carries %q. If the engine has started converting, this "+
				"suite's premise has changed and must be re-read.", absent)
		}
	}
	t.Logf("confirmed: roundMoney(v, c) = Money{v, c}.Round().Amount -- no rate, no " +
		"table, no error return; and no row carries a rate or an as-of date for the money")
}

// ── 3. The guard that DOES work: money refuses to mix denominations ───────────

// TestMoneyStillRefusesToMixDenominationsEverywhereItIsUsed is the cross-check
// the brief asks for, and it passes -- which is worth stating as clearly as the
// failures.
//
// Add, Sub, Sum and GreaterThan all refuse across denominations, including the
// single-element Sum that once returned Money{5, ""} as a legitimate result. So
// the attack "get two differently-denominated figures into one sum" cannot be
// mounted THROUGH money.
//
// It can be mounted AROUND money, and that is the real finding: the summary
// reaches its total by `summary.TotalExposure += r.CarriedGBP` on a bare float64
// (compliance.go:602), and the cross-framework roll-up does the same with
// `totalExposure += resp.TotalExposure` (handlers.go:113). Neither goes through
// Add. They are safe today only because every row of one scan shares one
// currency -- an invariant maintained elsewhere, by construction, with no check
// at the point of addition. TestTheSummaryNeverMixesDenominations pins that
// invariant; this test pins the guard that would catch it if the invariant ever
// broke, so the two together say which layer is actually load-bearing.
func TestMoneyStillRefusesToMixDenominationsEverywhereItIsUsed(t *testing.T) {
	gbp := money.Money{Amount: 100, Currency: "GBP"}
	usd := money.Money{Amount: 100, Currency: "USD"}

	if _, err := money.Add(gbp, usd); err == nil {
		t.Error("Add accepted GBP + USD")
	}
	if _, err := gbp.Sub(usd); err == nil {
		t.Error("Sub accepted GBP - USD")
	}
	if _, err := money.Sum(gbp, gbp, usd); err == nil {
		t.Error("Sum accepted a mixed slice")
	}
	if _, err := gbp.GreaterThan(usd); err == nil {
		t.Error("GreaterThan compared across denominations")
	}
	// A single-element Sum validates its own denomination.
	if _, err := money.Sum(money.Money{Amount: 5, Currency: ""}); err == nil {
		t.Error("a one-element Sum accepted an undenominated amount")
	}
	// An empty Sum has no denomination to report.
	if _, err := money.Sum(); err == nil {
		t.Error("an empty Sum returned a figure")
	}
	// Like with like still works, including a shape-valid unconvertible code --
	// money's job is denomination hygiene, not currency existence.
	zzz := money.Money{Amount: 100, Currency: "ZZZ"}
	if sum, err := money.Sum(zzz, zzz); err != nil || sum.Amount != 200 {
		t.Errorf("Sum(ZZZ, ZZZ) = %v, %v; want 200 ZZZ", sum, err)
	}
}

// ── 4. The other roll-up, which predates the declared profile entirely ────────

// TestTheBundleRollUpIgnoresTheDeclaredProfileAndIsDenominatedByItsFieldName_DEFECT
// records that two endpoints of this service disagree about the same tenant's
// money.
//
// The scan path honours migration 062's profile. The bundle-evaluation path does
// not, and structurally cannot:
//
//   - store.go:438 calls `fair.Simulate(rule.RiskTriple, rule.FreqTriple, seed)`
//     -- the no-load variant, hardcoded to DefaultRiskLoad. A tenant's declared
//     risk_load is not read, so a declared 0.25 silently prices at 0.10.
//   - EvaluatePoliciesResponse (types.go:90-102) has NO currency field at all.
//     Its total is `TotalExposure float64` with the json tag
//     `total_exposure_gbp`, so the denomination lives ONLY in the field name --
//     failure mode (3) from money.go's header, "the currency lived in a name,
//     and names are not carried across a wire, a database column, or a chart
//     axis". A declared USD cannot be expressed on this response.
//   - handlers.go:113 rolls that up across frameworks with
//     `totalExposure += resp.TotalExposure`, a bare float, no denomination.
//
// So the same tenant, same controls, gets one exposure figure from
// /compliance/scan reflecting its declared posture and a different one from the
// bundle path reflecting the engine's defaults, mislabelled GBP either way.
//
// THIS IS A DEFECT OF OMISSION -- the bundle path predates the profile and was
// not extended. It is recorded here rather than fixed because wiring a tenant
// profile into it is a change to the money, which this work does not make. The
// test asserts the structure, not a figure, so it stays true under recalibration.
func TestTheBundleRollUpIgnoresTheDeclaredProfileAndIsDenominatedByItsFieldName_DEFECT(t *testing.T) {
	// The response type cannot express a currency.
	var resp EvaluatePoliciesResponse
	if _, hasCurrency := any(&resp).(interface{ GetCurrency() money.Currency }); hasCurrency {
		t.Error("EvaluatePoliciesResponse has gained a currency accessor; re-read this test")
	}
	marshalled := mustMarshalString(t, resp)
	if !strings.Contains(marshalled, `"total_exposure_gbp"`) {
		t.Errorf("EvaluatePoliciesResponse no longer carries total_exposure_gbp; if it now "+
			"carries a denomination as DATA this defect is fixed -- delete this test. Got %s",
			marshalled)
	}
	if strings.Contains(marshalled, `"currency"`) {
		t.Errorf("EvaluatePoliciesResponse now carries a currency field, so the "+
			"denomination is no longer welded into a field name. Re-read this test. Got %s",
			marshalled)
	}

	// And the scan path, by contrast, carries it as data -- which is the
	// asymmetry that makes the two endpoints disagree.
	h := contractHandler(t)
	rows := scanInCurrency(t, h, "USD")
	if rows[0]["currency"] != "USD" {
		t.Fatalf("scan row currency = %v, want USD", rows[0]["currency"])
	}
	if _, ok := rows[0]["carried"].(map[string]any); !ok {
		t.Error("scan row lost its self-describing carried object")
	}
	t.Logf("DEFECT: /compliance/scan carries the denomination as data and honours the "+
		"declared profile; the bundle path prices via fair.Simulate (store.go:438, "+
		"load hardcoded to DefaultRiskLoad=%.2f) and reports total_exposure_gbp with no "+
		"currency field, rolled up across frameworks on a bare float (handlers.go:113)",
		0.10)
}
