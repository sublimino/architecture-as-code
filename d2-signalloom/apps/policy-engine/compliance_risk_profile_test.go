package main

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// The institution's declared risk posture reaching the engine.
//
// THE TEST THAT MATTERS MOST IN THIS FILE is the first one. Everything else
// here is about the declared path working; that one is about the UNDECLARED
// path not having moved. Every tenant in existence has declared nothing, so if
// a scan that says nothing prices differently by so much as a rounding step,
// this change silently re-priced the entire product. The money goldens pin the
// same property from the other direction (they are asserted inside the
// conformance tier and this change does not touch their values); this test
// pins it at the handler, which is where the regression would actually enter.

// postScanWithHeaders is postScan with control over the request headers, which
// the tenant id arrives in.
func postScanWithHeaders(
	t *testing.T, h *complianceHandler, body map[string]any, headers map[string]string,
) (int, []map[string]any) {
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
	if w.Code != http.StatusOK {
		// The body names WHICH 400 this is, and there are several. Logging it
		// turns "got 400" into a diagnosis.
		t.Logf("scan returned %d: %s", w.Code, w.Body.String())
		return w.Code, nil
	}
	var results []map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &results); err != nil {
		t.Fatal(err)
	}
	return w.Code, results
}

func baseScanBody() map[string]any {
	// policyVersion is deliberately omitted: the pack's version is
	// contractPackVersion, not the directory it lives in, and sending the
	// directory name gets the scan rejected as no_checks_for_framework. The
	// contract tests omit it for the same reason.
	return map[string]any{
		"namespace":  "default",
		"frameworks": []string{contractPackID},
		"agent":      map[string]any{"registered": true},
		"request":    map[string]any{},
	}
}

// moneyOf extracts the four priced figures plus the currency label, which is
// the whole of what a caller sees as "the money".
func moneyOf(t *testing.T, result map[string]any) map[string]any {
	t.Helper()
	out := map[string]any{}
	for _, field := range []string{"ale", "var95", "tvar", "carriedGbp", "currency"} {
		v, ok := result[field]
		if !ok {
			t.Fatalf("result is missing %q, so this test cannot prove anything about it", field)
		}
		out[field] = v
	}
	return out
}

func TestAnUndeclaredTenantIsPricedExactlyAsBefore(t *testing.T) {
	h := contractHandler(t)

	code, results := postScanWithHeaders(t, h, baseScanBody(), nil)
	if code != http.StatusOK {
		t.Fatalf("a scan declaring no risk profile must still succeed, got %d", code)
	}
	if len(results) == 0 {
		t.Fatal("no results, so this test would pass vacuously")
	}

	for _, r := range results {
		m := moneyOf(t, r)
		if m["currency"] != string(defaultReportingCurrency) {
			t.Errorf("check %v: currency = %v, want %v (the pre-change constant)",
				r["check"], m["currency"], defaultReportingCurrency)
		}
		// And the figures are the ones the pre-change code produced, which is
		// the default load through the same sampler and the same seed.
		//
		// The triples come from packCheck, the helper the pack under test was
		// built with, rather than from literals copied here -- copied literals
		// would let the fixture and the expectation drift apart silently.
		check := r["check"].(string)
		c := packCheck(check, "")
		want := fair.SimulateWithLoad(c.RiskTriple, c.FreqTriple, checkSeed(check), fair.DefaultRiskLoad)
		assertClose(t, check, "ale", m["ale"], roundMoney(want.ALE, defaultReportingCurrency))
		assertClose(t, check, "var95", m["var95"], roundMoney(want.VaR95, defaultReportingCurrency))
		assertClose(t, check, "tvar", m["tvar"], roundMoney(want.TVaR, defaultReportingCurrency))
		assertClose(t, check, "carriedGbp", m["carriedGbp"], roundMoney(want.CarriedGBP, defaultReportingCurrency))
	}
}

func assertClose(t *testing.T, check, field string, got any, want float64) {
	t.Helper()
	g, ok := got.(float64)
	if !ok {
		t.Fatalf("check %s: %s is %T, not a number", check, field, got)
	}
	if g != want {
		t.Errorf("check %s: %s = %v, want %v — an undeclared tenant's figures moved", check, field, g, want)
	}
}

func TestAnUndeclaredScanIsByteIdenticalWithOrWithoutATenantHeader(t *testing.T) {
	// Wiring extractTenant in must not itself change a figure: the tenant id is
	// used to refuse an incoherent request, never to price one.
	h := contractHandler(t)

	_, without := postScanWithHeaders(t, h, baseScanBody(), nil)
	_, with := postScanWithHeaders(t, h, baseScanBody(),
		map[string]string{"X-Tenant-ID": "tenant-demo"})

	stripTimestamps(without)
	stripTimestamps(with)
	a, _ := json.Marshal(without)
	b, _ := json.Marshal(with)
	if string(a) != string(b) {
		t.Errorf("a tenant header changed the result:\n without=%s\n with=%s", a, b)
	}
}

func stripTimestamps(results []map[string]any) {
	for _, r := range results {
		delete(r, "scanTimestamp")
	}
}

func TestADeclaredReportingCurrencyLabelsEveryFigure(t *testing.T) {
	h := contractHandler(t)
	body := baseScanBody()
	body["reportingCurrency"] = "USD"

	code, results := postScanWithHeaders(t, h, body,
		map[string]string{"X-Tenant-ID": "tenant-ludlow"})
	if code != http.StatusOK {
		t.Fatalf("got %d", code)
	}
	if len(results) == 0 {
		t.Fatal("no results")
	}
	for _, r := range results {
		if r["currency"] != "USD" {
			t.Errorf("check %v: currency = %v, want USD", r["check"], r["currency"])
		}
		carried, ok := r["carried"].(map[string]any)
		if !ok {
			t.Fatalf("check %v: carried is not an object", r["check"])
		}
		if carried["currency"] != "USD" {
			t.Errorf("check %v: carried.currency = %v, want USD — the self-describing "+
				"figure and its sibling label must never disagree", r["check"], carried["currency"])
		}
	}
}

func TestADeclaredRiskLoadMovesTheCarriedFigureAndNothingElse(t *testing.T) {
	// Carried is TVaR * (1 + load). A declared load must move Carried and must
	// NOT move ALE, VaR95 or TVaR, which are properties of the distribution and
	// not of the institution's appetite.
	h := contractHandler(t)

	_, base := postScanWithHeaders(t, h, baseScanBody(), nil)

	body := baseScanBody()
	load := 0.50
	body["riskLoad"] = load
	_, loaded := postScanWithHeaders(t, h, body, map[string]string{"X-Tenant-ID": "t"})

	byCheck := map[string]map[string]any{}
	for _, r := range base {
		byCheck[r["check"].(string)] = r
	}
	movedSomething := false
	for _, r := range loaded {
		b := byCheck[r["check"].(string)]
		for _, unchanged := range []string{"ale", "var95", "tvar"} {
			if r[unchanged] != b[unchanged] {
				t.Errorf("check %v: %s moved with the risk load (%v -> %v); the load belongs "+
					"to the posture, not to the distribution", r["check"], unchanged, b[unchanged], r[unchanged])
			}
		}
		if tvar, ok := r["tvar"].(float64); ok && tvar > 0 {
			if r["carriedGbp"] == b["carriedGbp"] {
				t.Errorf("check %v: carriedGbp did not move with a declared load", r["check"])
			} else {
				movedSomething = true
			}
		}
	}
	if !movedSomething {
		t.Fatal("no check had a positive TVaR, so this test proved nothing")
	}
}

func TestADeclaredZeroRiskLoadIsDistinctFromUndeclared(t *testing.T) {
	// The reason RiskLoad is a *float64. Zero is a coherent declared posture --
	// carry the tail with no load on top -- and a plain float64 could not tell
	// it from absent, so a tenant declaring 0 would be silently priced at 0.10.
	h := contractHandler(t)

	_, undeclared := postScanWithHeaders(t, h, baseScanBody(), nil)

	body := baseScanBody()
	zero := 0.0
	body["riskLoad"] = zero
	_, declaredZero := postScanWithHeaders(t, h, body, map[string]string{"X-Tenant-ID": "t"})

	byCheck := map[string]map[string]any{}
	for _, r := range undeclared {
		byCheck[r["check"].(string)] = r
	}
	differed := false
	for _, r := range declaredZero {
		b := byCheck[r["check"].(string)]
		if tvar, ok := r["tvar"].(float64); ok && tvar > 0 && r["carriedGbp"] != b["carriedGbp"] {
			differed = true
		}
		// A declared zero means carried == tvar exactly.
		if tvar, ok := r["tvar"].(float64); ok {
			if carried, ok2 := r["carriedGbp"].(float64); ok2 && math.Abs(carried-tvar) > 1e-9 {
				t.Errorf("check %v: declared load 0 gave carried %v for tvar %v; they must be equal",
					r["check"], carried, tvar)
			}
		}
	}
	if !differed {
		t.Fatal("a declared zero load priced identically to undeclared, so the pointer " +
			"is not doing its job and a tenant's declared 0 is being overwritten by the default")
	}
}

func TestADeclaredProfileWithoutATenantIsRefused(t *testing.T) {
	// A priced figure has to belong to someone.
	h := contractHandler(t)
	for _, body := range []map[string]any{
		func() map[string]any { b := baseScanBody(); b["reportingCurrency"] = "USD"; return b }(),
		func() map[string]any { b := baseScanBody(); l := 0.3; b["riskLoad"] = l; return b }(),
	} {
		code, _ := postScanWithHeaders(t, h, body, nil)
		if code != http.StatusBadRequest {
			t.Errorf("declared profile with no tenant: got %d, want 400", code)
		}
	}
}

func TestAnInvalidDeclaredProfileIsRefusedRatherThanDefaulted(t *testing.T) {
	// Invalid is not the same as absent. Silently falling back would price a
	// figure with a value the caller did not mean, which is the exact failure
	// this whole change exists to prevent.
	h := contractHandler(t)
	headers := map[string]string{"X-Tenant-ID": "t"}

	cases := map[string]map[string]any{
		"lowercase currency":  {"reportingCurrency": "usd"},
		"two-letter currency": {"reportingCurrency": "US"},
		"negative load":       {"riskLoad": -0.1},
	}
	for name, overrides := range cases {
		body := baseScanBody()
		for k, v := range overrides {
			body[k] = v
		}
		code, _ := postScanWithHeaders(t, h, body, headers)
		if code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", name, code)
		}
	}
}

func TestRiskProfileForDefaultsToThePreChangeConstants(t *testing.T) {
	// The unit-level statement of the same invariant, so a regression here is
	// named precisely rather than showing up as a drifted figure.
	p, err := riskProfileFor(ComplianceScanRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if p.Currency != defaultReportingCurrency {
		t.Errorf("currency = %v, want %v", p.Currency, defaultReportingCurrency)
	}
	if p.RiskLoad != fair.DefaultRiskLoad {
		t.Errorf("riskLoad = %v, want %v", p.RiskLoad, fair.DefaultRiskLoad)
	}
	if p.Declared {
		t.Error("an empty request must not read as a declared posture")
	}
	if fair.DefaultRiskLoad != 0.10 {
		t.Errorf("fair.DefaultRiskLoad = %v, want 0.10; changing it re-prices every "+
			"tenant that has declared nothing, which is all of them", fair.DefaultRiskLoad)
	}
}

func TestABlankDeclaredCurrencyIsTreatedAsUndeclared(t *testing.T) {
	// The fe gateway sends whatever the column holds, and a column can hold ''
	// in a database that predates the CHECK. Blank must mean undeclared, not
	// invalid: refusing the scan would make an old row unscannable.
	for _, blank := range []string{"", "   "} {
		p, err := riskProfileFor(ComplianceScanRequest{ReportingCurrency: money.Currency(blank)})
		if err != nil {
			t.Fatalf("blank %q: %v", blank, err)
		}
		if p.Currency != defaultReportingCurrency || p.Declared {
			t.Errorf("blank %q: got %+v, want the default and Declared=false", blank, p)
		}
	}
}
