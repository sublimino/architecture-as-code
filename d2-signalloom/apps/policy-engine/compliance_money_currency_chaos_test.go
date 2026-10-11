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
// buys arithmetic precision on top of an unmeasured input.
//
// THE DECISION TAKEN (fix 3): REFUSE, DO NOT CONVERT. The engine now rejects a
// declared currency with no rate in risk/fx/rates.yaml, at the API boundary,
// naming the currency, the table and its as-of date. The allow-list is exactly
// the table's key set and that equality is asserted against the real YAML by
// TestTheReportableCurrencyAllowListIsExactlyTheCheckedInRateTable. The
// reasoning lives beside the list in compliance.go, where the next person will
// look: converting at four significant figures manufactures rigour the
// calibration cannot support, and imports the table's `as_of` as a second
// staleness axis into a figure whose own provenance is already the weak link.
//
// SO ZZZ, XXX, AAA, QQQ AND KWD ARE REFUSED -- see
// TestAShapeValidCurrencyWithNoRateIsRefused, the re-pointed form of what was
// TestAValidShapeIsNotAValidCurrency. KWD is the instructive row: a perfectly
// real currency, refused because the TABLE has no entry for it. The allow-list
// answers "can this repository anchor a figure in this currency?", not "does
// this currency exist?".
//
// WHAT STILL RELABELS, AND IS STILL A _DEFECT. Every currency that IS in the
// table. A declared USD figure is still a GBP figure wearing a USD label, 21%
// understated; JPY is 99.5% understated and additionally re-quantises to whole
// units so it LOOKS as though a rate was applied. That is unchanged and remains
// characterised by TestADeclaredCurrencyRelabelsWithoutConverting_DEFECT. Fix 3
// narrowed the set of expressible labels to those the repository could in
// principle anchor; it did not make the figures right, and no money golden
// moved -- which is the proof it was a validation change and not a pricing one.
//
// As elsewhere in this chaos work, the remaining _DEFECT tests CHARACTERISE what
// happens today. They are tripwires, not specifications.

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
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

// TestMalformedReportingCurrenciesAreRefused pins the refusals that DO work,
// and the reason it pins the MESSAGE rather than the status is a finding in its
// own right.
//
// WHAT THIS TEST USED TO CLAIM, AND WHY THAT CLAIM IS NOW FALSE HERE.
// money.Currency.Validate enforces exactly three bytes, each in 'A'..'Z'. The
// byte-ness is subtle and used to be load-bearing: `len(c) == 3` counts BYTES,
// so a Unicode lookalike -- "USＤ" (fullwidth D, 3 runes, 5 bytes), "ɃTC" (4
// bytes), an NBSP in "U D" -- is refused by the LENGTH test and never reaches
// the character-range test. This test recorded that cause per case, so that
// anyone "simplifying" Validate to iterate runes would learn from a red test
// that the length check mattered.
//
// Fix 3 made that reasoning inapplicable ON THIS PATH. The rate-table allow-list
// rejects by EXACT SET MEMBERSHIP (`reportableCurrencies[declared]`), which does
// not care how many bytes a non-member has: "usd", "USＤ", "ɃTC" and "US\x00"
// are all absent from a 15-element map and all rejected by the same single
// mechanism. So the allow-list SUBSUMES the shape check as a gate, and deleting
// Validate from riskProfileFor entirely left this test green -- which the
// mutation proof caught as a surviving mutant (M4). A test whose subject can be
// deleted without it noticing is pinning the other guard.
//
// SO WHAT IS THE SHAPE CHECK STILL FOR, HERE? Exactly one thing: the DIAGNOSIS.
// It is NOT the gate any more and this test no longer pretends otherwise. The
// two refusals demand opposite actions from whoever reads them:
//
//	"usd"  -> a typo in the caller's code.      Fix the caller.
//	"KWD"  -> a real currency with no rate.     Add it to risk/fx/rates.yaml.
//
// Reporting the first as the second sends an operator to edit the FX table to
// accept a lowercase string, which it never will. That is a real, nameable
// contribution and it is what the assertions below pin -- the message, not the
// 400, which the allow-list would produce anyway.
//
// IT IS ALSO NOT DELETABLE, which settles the question of whether to remove it
// rather than re-point the test. Validate has eleven other callers inside the
// money package (Money.Round, Add, Sub, Sum, RateTable.Validate, Rate, Convert)
// where it IS the only guard, and migration 062's DB CHECK is deliberately
// `^[A-Z]{3}$` -- a shape check, documented as explicitly NOT a rate-table
// check, with the semantic set enforced in the app layer. So the database
// admits a shape-valid ZZZ, the gateway will send it, and this engine's
// allow-list is the layer that refuses it. The two checks guard different
// things at different layers; only their OUTCOMES coincide at this one call
// site.
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
			code, raw := postScanRaw(t, h, body, map[string]string{"X-Tenant-ID": "t"})

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
					"validate must never be labelled onto a figure. body=%.300q",
					c.cur, c.because, code, raw)
			}

			// THE ASSERTION THAT MAKES THE SHAPE CHECK LOAD-BEARING. The 400 above
			// does not: the allow-list refuses a non-member regardless of how it is
			// malformed, so deleting money.Currency.Validate from riskProfileFor
			// leaves every status code in this table unchanged (that is exactly how
			// M4 survived). What the shape check uniquely buys is the DIAGNOSIS, so
			// that is what is pinned -- and it is pinned from both sides, because a
			// malformed code reported as "no rate in the table" sends an operator to
			// edit risk/fx/rates.yaml to accept a lowercase string.
			if !strings.Contains(raw, "three-letter ISO 4217 code") {
				t.Fatalf("currency %q (%s): refused, but not AS MALFORMED. The message must "+
					"name the shape fault so the caller fixes the caller. body=%.300q",
					c.cur, c.because, raw)
			}
			if strings.Contains(raw, "no rate in risk/fx/rates.yaml") {
				t.Fatalf("currency %q (%s): a malformed code was diagnosed as a missing RATE. "+
					"That sends an operator to add %q to the FX table, which will never "+
					"accept it. body=%.300q", c.cur, c.because, c.cur, raw)
			}
		})
	}
}

// postScanRaw is postScanWithHeaders returning the RAW body.
//
// It exists because the refusals this file now asserts are only visible in the
// body text -- which currency was named, which table, which as-of date -- and
// postScanWithHeaders returns nil rows for any non-200, discarding exactly the
// bytes the assertion needs.
func postScanRaw(
	t *testing.T, h *complianceHandler, body map[string]any, headers map[string]string,
) (int, string) {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.handleScan(w, req)
	return w.Code, w.Body.String()
}

// TestAShapeValidCurrencyWithNoRateIsRefused is the re-pointed form of
// TestAValidShapeIsNotAValidCurrency.
//
// WHAT IT USED TO MEASURE. money.Currency.Validate enforces an ISO-4217 SHAPE
// -- exactly three bytes, each 'A'..'Z' -- and deliberately does not check
// membership of the ISO list, because that list changes and a stale embedded
// copy would reject a legitimate code. Its own comment said the binding
// constraint "IS enforced -- at conversion". But this service never converts,
// so nothing enforced it: ZZZ, XXX, AAA, QQQ and KWD all passed the shape check
// and came back labelling a full set of figures in a currency the repository's
// own converter would refuse. XXX was the sharpest case -- a real ISO-4217 code
// whose meaning is "no currency".
//
// WHAT IT PINS NOW. Those same five are REFUSED at the API boundary, with an
// error a reader can act on. The refusal is checked on four things, each of
// which a lazier implementation would omit:
//
//	the status            400 -- the caller's value, the caller's to fix
//	the currency named    so the operator knows WHICH input was wrong
//	rates.yaml named      so they know what has to change to make it work
//	the as-of date        so they know WHICH table said no
//
// And the set is checked from both sides in the same loop: a currency IN the
// table must still be accepted. A fix that refused everything would satisfy
// "ZZZ is refused" and break the product, so the accept case is not a separate
// test.
//
// KWD IS THE INTERESTING ROW and the reason this is a rate-table allow-list
// rather than an ISO-4217 one. KWD is a perfectly real currency -- the Kuwaiti
// dinar, three minor units, which money.MinorUnits already knows about -- and
// it is refused anyway, because risk/fx/rates.yaml has no entry for it. The
// allow-list answers "can this repository anchor a figure in this currency?",
// not "does this currency exist?". Adding KWD to the table is the supported way
// to make it reportable.
func TestAShapeValidCurrencyWithNoRateIsRefused(t *testing.T) {
	h := contractHandler(t)

	for _, tc := range []struct {
		cur    string
		accept bool
		why    string
	}{
		{"ZZZ", false, "not a currency at all"},
		{"XXX", false, "real ISO-4217 code meaning NO CURRENCY"},
		{"AAA", false, "not a currency at all"},
		{"QQQ", false, "not a currency at all"},
		{"KWD", false, "a real currency with no rate in the checked-in table"},
		{"USD", true, "in the table"},
		{"JPY", true, "in the table, zero minor units"},
		{"GBP", true, "in the table, and the calibration currency"},
	} {
		t.Run(tc.cur, func(t *testing.T) {
			// The shape check passes for every one of these, which is what makes
			// the allow-list the load-bearing guard rather than Validate.
			if err := money.Currency(tc.cur).Validate(); err != nil {
				t.Fatalf("%s fails the SHAPE check (%v), so it cannot demonstrate anything "+
					"about the allow-list", tc.cur, err)
			}

			body := baseScanBody()
			body["reportingCurrency"] = tc.cur
			code, raw := postScanRaw(t, h, body, map[string]string{"X-Tenant-ID": "tenant-fx"})

			if tc.accept {
				if code != http.StatusOK {
					t.Fatalf("%s (%s) was refused with %d: %.300q. A currency the table "+
						"CAN anchor must be reportable.", tc.cur, tc.why, code, raw)
				}
				return
			}

			if code == http.StatusOK {
				t.Fatalf("%s (%s) was ACCEPTED. A figure labelled with a currency the "+
					"repository has no rate for is a relabel nobody can re-derive, and "+
					"XXX in particular means 'no currency'. body=%.300q", tc.cur, tc.why, raw)
			}
			if code != http.StatusBadRequest {
				t.Errorf("%s: got %d, want 400 -- the value came from the caller", tc.cur, code)
			}
			// The refusal has to be actionable, not merely present.
			for _, want := range []string{tc.cur, "rates.yaml", rateTableAsOf} {
				if !strings.Contains(raw, want) {
					t.Errorf("%s: refusal does not mention %q, so the operator cannot tell "+
						"what to change: %.400q", tc.cur, want, raw)
				}
			}
			// And it says what IS reportable.
			if !strings.Contains(raw, "GBP") || !strings.Contains(raw, "USD") {
				t.Errorf("%s: refusal does not list the reportable currencies: %.400q", tc.cur, raw)
			}
			t.Logf("refused %s (%s): %.200q", tc.cur, tc.why, raw)
		})
	}
}

// TestTheReportableCurrencyAllowListIsExactlyTheCheckedInRateTable is the link
// between the allow-list in code and the table it claims to be drawn from.
//
// WHY THE LIST IS A LITERAL AND NOT A LOAD. The engine runs offline with no
// cluster, no network and no configuration, so making a REQUEST VALIDATOR
// depend on a file path would add a deployment-shaped failure mode to a refusal
// that has to work -- and the failure would be silent in the worst direction
// (no table found, so nothing refused). The rates themselves are checked in for
// the same family of reasons.
//
// The honest cost of that choice is that two things have to agree, and an
// agreement nobody checks is an agreement that drifts. So this test reads the
// REAL risk/fx/rates.yaml through money.LoadRateTable -- the repository's own
// loader, not a mirror -- and compares the key sets in BOTH directions:
//
//	in the table but not the list  -> a real currency is being refused
//	in the list but not the table  -> a currency is accepted whose figures
//	                                  cannot be anchored, i.e. the whole defect
//
// It also pins rateTableAsOf against the table's own `as_of`, because that date
// is quoted verbatim in every refusal: an error naming the wrong table is worse
// than one naming none.
func TestTheReportableCurrencyAllowListIsExactlyTheCheckedInRateTable(t *testing.T) {
	const path = "../../../risk/fx/rates.yaml"
	table, err := money.LoadRateTable(path)
	if err != nil {
		t.Fatalf("loading %s: %v. The allow-list claims to be drawn from this file; if the "+
			"file has moved, this test and the comment on reportableCurrencies are both "+
			"wrong and the refusal message names a path that does not exist.", path, err)
	}

	inTable := map[money.Currency]bool{}
	for _, c := range table.Currencies() {
		inTable[c] = true
	}
	if len(inTable) == 0 {
		t.Fatal("the rate table reports no currencies; this test would then pass vacuously " +
			"against an empty allow-list")
	}

	for c := range inTable {
		if !reportableCurrencies[c] {
			t.Errorf("%s is in risk/fx/rates.yaml but NOT in reportableCurrencies, so the "+
				"engine refuses a currency the repository can anchor. Add it to the "+
				"allow-list in compliance.go.", c)
		}
	}
	for c := range reportableCurrencies {
		if !inTable[c] {
			t.Errorf("%s is in reportableCurrencies but NOT in risk/fx/rates.yaml, so the "+
				"engine accepts a declared currency it has no rate for -- which is exactly "+
				"the defect the allow-list exists to close.", c)
		}
	}

	if table.AsOf != rateTableAsOf {
		t.Errorf("rateTableAsOf = %q but the table says %q. That date is quoted verbatim in "+
			"every refusal, and an error naming the wrong table is worse than one naming "+
			"no table at all.", rateTableAsOf, table.AsOf)
	}
	t.Logf("allow-list and risk/fx/rates.yaml agree on %d currencies, as of %s",
		len(inTable), table.AsOf)
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
