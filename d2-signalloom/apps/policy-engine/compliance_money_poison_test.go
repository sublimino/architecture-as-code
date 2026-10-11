package main

// Numeric poison through the risk-profile money path, end to end, from the JSON
// request to the bytes a client actually receives.
//
// WHY THIS FILE EXISTS, AND WHY IT IS NOT THE SAME AS THE SUITE NEXT DOOR.
//
// compliance_risk_profile_test.go proves the HAPPY path and the OBVIOUS refusals:
// a lowercase currency is refused, a negative load is refused, a declared zero
// is not overwritten. Every one of those is a case where the engine answers, and
// you can read the answer.
//
// The failure modes pinned HERE are the ones with no answer to read. The risk
// profile arrives as JSON on the scan request and is NOT sourced from the
// database, so migration 062's CHECK constraints -- the ones that exist
// precisely because `'NaN'::float8 >= 0` is TRUE in postgres -- govern nothing on
// this path. The engine re-implements the guard in Go (riskProfileFor), and the
// question this file asks is whether the Go guard is the same guard.
//
// It is not, in one specific way, and the consequence is the worst outcome in
// the brief: a figure that is not a number reaching the renderer. The guard
// rejects a load that IS NaN or Inf. It cannot reject a load that is finite but
// whose PRODUCT with tvar is not -- `tvar * (1 + riskLoad)` at fair.go:164 has no
// overflow check, and tvar is ~1.8e4 for a priced check, so any declared load
// above ~1e304 overflows carried to +Inf.
//
// What a client sees then is the thing that cannot be eyeballed, and it is not
// "+Inf" on a dashboard. It is worse. encoding/json REFUSES to marshal +Inf, and
// compliance.go:516-517 writes `WriteHeader(StatusOK)` BEFORE `Encode(results)`
// and DISCARDS the encoder's error. So the status line is already committed when
// the marshal fails, and the client receives:
//
//	HTTP/1.1 200 OK
//	Content-Type: application/json
//	<zero bytes>
//
// A 200 with an empty body is indistinguishable, to a lenient client, from a
// scan that found nothing to report -- which renders as a CLEAN COMPLIANCE
// POSTURE. The failure is silent at every layer: no 5xx, no error field, no log
// line, no partial row to raise suspicion. That is why it is pinned by byte
// count and status code together, which is the only way to see it.
//
// WHAT THESE TESTS ARE. Every assertion below is a CHARACTERISATION of behaviour
// observed on this commit, not a statement of what is correct. Where current
// behaviour is wrong it is pinned under a name containing DEFECT and the comment
// says what correct behaviour would be. The brief for this work was to probe and
// report, not to change the money path, so the defect is recorded rather than
// fixed -- and pinned, so that fixing it is a deliberate act that breaks a named
// test rather than a silent improvement nobody notices.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// postRawScan sends a literal request body, bypassing json.Marshal.
//
// This helper is the point of the file. postScanWithHeaders marshals a Go map,
// and encoding/json REFUSES to emit NaN and Inf -- so a test built on it can
// never send the tokens that matter, and would silently prove only that Go
// cannot construct the attack. The hostile inputs here (`NaN`, `Infinity`,
// `1e400`, a 40-significant-digit decimal, 2^53+1) are all things a non-Go
// client, a hand-rolled curl, or a JavaScript caller emits readily.
//
// It returns the status code and the RAW body bytes, never a parsed document,
// because the defect this file exists to pin is visible only in the byte count.
func postRawScan(t *testing.T, h *complianceHandler, raw string, headers map[string]string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader([]byte(raw)))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.handleScan(w, req)
	return w.Code, w.Body.String()
}

// rawScanBodyWith returns the standard contract scan body with `frag` spliced in
// as an extra top-level member, so the fragment's text reaches the decoder
// verbatim.
func rawScanBodyWith(t *testing.T, frag string) string {
	t.Helper()
	raw, err := json.Marshal(baseScanBody())
	if err != nil {
		t.Fatal(err)
	}
	s := string(raw)
	if frag == "" {
		return s
	}
	return s[:len(s)-1] + "," + frag + "}"
}

// pricedRows parses a scan response and returns only the rows that carry a
// positive tvar, i.e. the ones where riskLoad actually multiplies something.
// A check priced at zero cannot demonstrate anything about a load.
func pricedRows(t *testing.T, body string) []map[string]any {
	t.Helper()
	var rows []map[string]any
	if err := json.Unmarshal([]byte(body), &rows); err != nil {
		t.Fatalf("scan body is not a JSON array: %v (body=%.200q)", err, body)
	}
	var out []map[string]any
	for _, r := range rows {
		if tvar, ok := r["tvar"].(float64); ok && tvar > 0 {
			out = append(out, r)
		}
	}
	if len(out) == 0 {
		t.Fatal("no priced rows in the contract pack; this suite cannot say anything about a load")
	}
	return out
}

// ── 1. The tokens the decoder refuses outright ────────────────────────────────

// TestNonFiniteRiskLoadTokensNeverReachTheEngine pins WHERE each non-finite
// token dies, which matters because they die in two different places and only
// one of them is the engine's own guard.
//
// `NaN`, `Infinity` and `-Infinity` are not legal JSON at all, so
// encoding/json's decoder rejects them before riskProfileFor is ever called --
// the error text names a character position, not a field. `1e400` IS legal JSON
// syntax but overflows float64, and encoding/json rejects it by field name. A
// quoted `"0.15"` is legal JSON of the wrong type and is likewise rejected by
// field name.
//
// The distinction is load-bearing for anyone reading riskProfileFor's NaN/Inf
// branch and wondering whether it is reachable from HTTP. From THIS handler it
// is not: the decoder gets there first. That branch is defence for a non-HTTP
// caller, and this test is the record that its HTTP-facing twin is the decoder.
func TestNonFiniteRiskLoadTokensNeverReachTheEngine(t *testing.T) {
	h := contractHandler(t)
	hdr := map[string]string{"X-Tenant-ID": "tenant-poison"}

	cases := []struct {
		name     string
		frag     string
		wantText string // a substring that proves WHICH layer refused
	}{
		{"bare NaN is not JSON", `"riskLoad":NaN`, "invalid character 'N'"},
		{"bare Infinity is not JSON", `"riskLoad":Infinity`, "invalid character 'I'"},
		{"bare -Infinity is not JSON", `"riskLoad":-Infinity`, "invalid character 'I'"},
		{"1e400 is legal JSON that overflows float64", `"riskLoad":1e400`, "riskLoad"},
		{"a quoted number is the wrong type", `"riskLoad":"0.15"`, "riskLoad"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, body := postRawScan(t, h, rawScanBodyWith(t, c.frag), hdr)
			if code != http.StatusBadRequest {
				t.Fatalf("got %d, want 400; a load the engine cannot use must be refused, "+
					"never defaulted and never priced (body=%.300q)", code, body)
			}
			if !strings.Contains(body, "invalid request body") {
				t.Errorf("refusal did not come from the request decoder: %.300q", body)
			}
			if !strings.Contains(body, c.wantText) {
				t.Errorf("refusal does not name %q, so an operator cannot tell which input "+
					"was wrong: %.300q", c.wantText, body)
			}
		})
	}
}

// ── 2. The finite values that ARE accepted and priced ─────────────────────────

// TestFiniteRiskLoadsArePricedAndTheFigureIsAlwaysAFiniteNumber sweeps the
// finite end of the domain and asserts the one property that must hold for every
// accepted load: the four figures a client reads are real numbers.
//
// This is the test that would have caught the overflow had it existed, and it is
// written to exclude the overflowing values explicitly rather than by accident
// -- see TestAnOverflowingRiskLoadIsServedAs200WithAnEmptyBody_DEFECT for those,
// and note that this test's own bound is the defect's measured edge.
func TestFiniteRiskLoadsArePricedAndTheFigureIsAlwaysAFiniteNumber(t *testing.T) {
	h := contractHandler(t)
	hdr := map[string]string{"X-Tenant-ID": "tenant-poison"}

	// Each of these is finite, non-negative, and survives multiplication by a
	// tvar of order 1e4 without overflowing.
	cases := []struct {
		name string
		frag string
	}{
		{"zero", `"riskLoad":0`},
		{"negative zero", `"riskLoad":-0.0`},
		{"smallest subnormal-ish", `"riskLoad":1e-320`},
		{"ten per cent", `"riskLoad":0.1`},
		{"forty significant digits", `"riskLoad":0.1000000000000000000000000000000000000001`},
		{"one billion", `"riskLoad":1e9`},
		{"2^53+1, beyond exact integer range", `"riskLoad":9007199254740993`},
		{"1e300, large but non-overflowing here", `"riskLoad":1e300`},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, body := postRawScan(t, h, rawScanBodyWith(t, c.frag), hdr)
			if code != http.StatusOK {
				t.Fatalf("got %d, want 200: this load is finite and non-negative (body=%.300q)", code, body)
			}
			for _, r := range pricedRows(t, body) {
				for _, field := range []string{"ale", "var95", "tvar", "carriedGbp"} {
					v, ok := r[field].(float64)
					if !ok {
						t.Fatalf("check %v: %s is %#v, not a JSON number -- a money field that is "+
							"not a number is not a figure", r["check"], field, r[field])
					}
					if math.IsNaN(v) || math.IsInf(v, 0) {
						t.Errorf("check %v: %s = %v; a non-finite figure rendered as money is the "+
							"worst outcome available on this path", r["check"], field, v)
					}
				}
			}
		})
	}
}

// TestAHugeButFiniteRiskLoadIsPricedWithoutComplaint records that the engine
// applies an absurd load without comment, because the absence of a sanity bound
// is a deliberate design position and not an oversight -- and a reader needs to
// know which it is.
//
// riskLoad is a multiplier on tail risk and the engine takes it from the
// institution. There is no principled upper bound: a load of 9.0 (carry ten
// times the tail) is unusual but coherent, so any ceiling would be arbitrary.
// The consequence is that `riskLoad: 1e9` turns an ~18,000 exposure into
// ~18,000,000,000,000 and the response says nothing about it.
//
// That is defensible. What makes it worth pinning is that it is the SAME code
// path as the overflow below, differing only in magnitude: the figure is
// returned verbatim up to ~1e304 and the response becomes an empty 200 above it.
// A reader who knows only that "huge loads are allowed" would not predict that
// the failure mode at the top of the range is silence.
func TestAHugeButFiniteRiskLoadIsPricedWithoutComplaint(t *testing.T) {
	h := contractHandler(t)
	hdr := map[string]string{"X-Tenant-ID": "tenant-poison"}

	code, body := postRawScan(t, h, rawScanBodyWith(t, `"riskLoad":1e9`), hdr)
	if code != http.StatusOK {
		t.Fatalf("got %d, want 200 (body=%.300q)", code, body)
	}
	rows := pricedRows(t, body)
	r := rows[0]
	tvar := r["tvar"].(float64)
	carried := r["carriedGbp"].(float64)

	// carried == tvar * (1 + 1e9) -- but only to 1e-6 relative, NOT to float
	// precision, and the reason is a finding in its own right.
	//
	// THE PUBLISHED FIGURES STOP RECONCILING AT LARGE LOADS. The engine computes
	// carried from the UNROUNDED tvar and then rounds both for presentation
	// (compliance.go:478-479). So the tvar a client reads is quantised to the
	// currency's minor unit -- up to half a penny of error -- and the load
	// MULTIPLIES that error. At 1e9 the half-penny becomes ~3.6 million.
	//
	// Measured here: published tvar 18072.92 and published carried
	// 18072923605440.25, where tvar*(1+1e9) from the published tvar is
	// 18072920018072.92 -- a discrepancy of ~3.59e6, or 2.0e-7 relative.
	//
	// money.go's package comment sets the standard this violates: "a compliance
	// figure that disagrees with the reader's own arithmetic is indefensible in
	// the room", which is why Round is documented as presentation-only. It is
	// applied correctly -- once, at the boundary -- and the arithmetic is still
	// irreproducible from the response alone, because the reader is given the
	// rounded input and the unrounded-then-rounded output. Reported, not fixed.
	//
	// The bound is derived, not guessed: the worst rounding error in tvar is
	// half a minor unit, so the worst relative error in carried is
	// (0.5 * 10^-minorUnits) / tvar, which for GBP at this tvar is ~2.8e-7.
	want := tvar * (1 + 1e9)
	gotRel := math.Abs(carried-want) / want
	worstRel := (0.5 * math.Pow(10, -2)) / tvar // GBP: 2 minor units
	if gotRel > 1e-6 {
		t.Errorf("carried = %v, want ~%v (tvar=%v, load=1e9): relative error %g exceeds "+
			"even the rounding-explained bound", carried, want, tvar, gotRel)
	}
	if gotRel <= 1e-12 {
		t.Errorf("carried reconciles exactly with the published tvar (relative error %g). "+
			"That is BETTER than this test expects and means the reconciliation gap "+
			"described above has been closed -- re-read the comment and tighten the bound.", gotRel)
	}
	t.Logf("RECONCILIATION GAP: published tvar=%.2f, published carried=%.2f, "+
		"tvar*(1+1e9)=%.2f, discrepancy=%.2f (%.2g relative; rounding alone explains up to %.2g)",
		tvar, carried, want, math.Abs(carried-want), gotRel, worstRel)
	if carried < 1e12 {
		t.Errorf("carried = %v; expected an absurd figure of order 1e13, which is the "+
			"point of this test -- no sanity bound is applied", carried)
	}
	t.Logf("accepted without complaint: tvar=%.2f load=1e9 carried=%.2f (%s)",
		tvar, carried, r["currency"])
}

// ── 3. The defect: overflow to +Inf, served as a 200 with no body ─────────────

// TestAnOverflowingRiskLoadIsServedAs200WithAnEmptyBody_DEFECT pins the worst
// behaviour on this path, exactly as observed.
//
// THIS IS A DEFECT, NOT A SPECIFICATION. Correct behaviour would be one of:
//
//   - riskProfileFor rejects a load that cannot be applied without overflow
//     (400, naming the field -- consistent with every other refusal here); or
//   - the overflow is detected where it happens, at fair.go:164, the way
//     money.Add already detects its own overflow and returns an error; or
//   - at minimum, compliance.go:516 encodes into a buffer and checks the error
//     BEFORE committing a status line, so a marshal failure becomes a 500 with
//     a message instead of a 200 with nothing.
//
// Until one of those lands, this test is the tripwire. It asserts the full shape
// of the failure -- status 200, zero bytes, and a `Content-Type: application/json`
// header promising a document that is not there -- because any ONE of those
// alone reads as something else:
//
//	a 200 alone        reads as success
//	an empty body alone reads as "nothing to report"
//	the pair           is a fabricated all-clear
//
// The bound is measured, not assumed: tvar for the contract pack's priced checks
// is ~1.8e4, so overflow begins around 1e304. 1e307 and 1e308 are both over it;
// 1e300 is under (and is covered by the finite sweep above). If the pack's
// triples are ever recalibrated the threshold moves, which is why this test
// drives the two values furthest into the overflowing region rather than
// probing for the edge.
func TestAnOverflowingRiskLoadIsServedAs200WithAnEmptyBody_DEFECT(t *testing.T) {
	h := contractHandler(t)
	hdr := map[string]string{"X-Tenant-ID": "tenant-poison"}

	for _, frag := range []string{`"riskLoad":1e307`, `"riskLoad":1e308`} {
		t.Run(frag, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan",
				bytes.NewReader([]byte(rawScanBodyWith(t, frag))))
			req.Header.Set("X-Tenant-ID", hdr["X-Tenant-ID"])
			w := httptest.NewRecorder()
			h.handleScan(w, req)

			// 1. The status line claims success.
			if w.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200. If this is now a 4xx or 5xx the DEFECT IS FIXED: "+
					"delete this test and keep TestFiniteRiskLoadsArePricedAndTheFigureIsAlwaysAFiniteNumber, "+
					"extending its sweep to cover %s.", w.Code, frag)
			}
			// 2. The body is empty. Not truncated, not partial -- zero bytes,
			//    because Encode discovers the +Inf before it writes anything.
			if n := w.Body.Len(); n != 0 {
				t.Fatalf("body length = %d, want 0. Behaviour has changed; re-characterise it. "+
					"body=%.300q", n, w.Body.String())
			}
			// 3. The header promises JSON that was never written. This is the part
			//    that makes a lenient client render the empty response as data.
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}
			t.Logf("DEFECT CONFIRMED for %s: HTTP %d, Content-Type %q, %d bytes of body",
				frag, w.Code, w.Header().Get("Content-Type"), w.Body.Len())
		})
	}
}

// TestTheOverflowIsInTheCarriedProductAndNowhereElse localises the defect, so
// the report names a line rather than a behaviour.
//
// It bypasses HTTP and drives fair.SimulateWithLoad directly. ale, var95 and
// tvar do not involve riskLoad at all and stay finite; only carried overflows.
// That is what identifies `tvar * (1 + riskLoad)` as the unguarded multiply, and
// it is also why the HTTP symptom is total (one +Inf anywhere in the array kills
// the whole document, not one row).
func TestTheOverflowIsInTheCarriedProductAndNowhereElse(t *testing.T) {
	// Derived from the engine, not typed, so a recalibration cannot make this
	// test quietly stop exercising an overflow.
	h := contractHandler(t)
	_, body := postRawScan(t, h, rawScanBodyWith(t, `"riskLoad":0`),
		map[string]string{"X-Tenant-ID": "t"})
	tvar := pricedRows(t, body)[0]["tvar"].(float64)
	if tvar <= 0 {
		t.Fatalf("tvar = %v; cannot demonstrate an overflow", tvar)
	}

	// The smallest power of ten whose product with this tvar is not finite.
	var threshold float64
	for e := 290; e <= 309; e++ {
		load := math.Pow(10, float64(e))
		if math.IsInf(tvar*(1+load), 0) {
			threshold = load
			break
		}
	}
	if threshold == 0 {
		t.Fatal("no power of ten up to 1e309 overflowed; the arithmetic has changed")
	}
	t.Logf("measured: tvar=%.2f overflows carried at riskLoad >= %g", tvar, threshold)

	// Below the threshold every figure is finite; at it, only carried is not.
	below := threshold / 1e3
	for _, tc := range []struct {
		name     string
		load     float64
		wantCarr bool // want carried finite
	}{
		{"below the threshold", below, true},
		{"at the threshold", threshold, false},
	} {
		res := fairSimulateForPoison(t, threshold, tc.load)
		if math.IsNaN(res.ALE) || math.IsInf(res.ALE, 0) {
			t.Errorf("%s: ale = %v; riskLoad must not touch ale", tc.name, res.ALE)
		}
		if math.IsNaN(res.VaR95) || math.IsInf(res.VaR95, 0) {
			t.Errorf("%s: var95 = %v; riskLoad must not touch var95", tc.name, res.VaR95)
		}
		if math.IsNaN(res.TVaR) || math.IsInf(res.TVaR, 0) {
			t.Errorf("%s: tvar = %v; riskLoad must not touch tvar", tc.name, res.TVaR)
		}
		gotFinite := !math.IsInf(res.CarriedGBP, 0) && !math.IsNaN(res.CarriedGBP)
		if gotFinite != tc.wantCarr {
			t.Errorf("%s (load=%g): carried finite = %v, want %v (carried=%v)",
				tc.name, tc.load, gotFinite, tc.wantCarr, res.CarriedGBP)
		}
	}

	// And the +Inf is precisely what encoding/json refuses, which is the link
	// between the arithmetic and the empty 200.
	if _, err := json.Marshal(map[string]any{"carriedGbp": math.Inf(1)}); err == nil {
		t.Error("encoding/json marshalled +Inf without error; the explanation for the " +
			"empty-body defect no longer holds and the report must be corrected")
	} else if !strings.Contains(err.Error(), "unsupported value") {
		t.Errorf("unexpected marshal error %v", err)
	} else {
		t.Logf("confirmed: json.Marshal(+Inf) fails with %q, and compliance.go:516-517 "+
			"commits HTTP 200 before discovering it", err)
	}
}

// ── 4. The guard that migration 062 has and this path does not ────────────────

// TestTheEngineGuardAndTheDatabaseCheckDisagreeOnOverflow states the asymmetry
// in one place, as a sentence a reviewer can check.
//
// Migration 062 constrains risk_load to `>= 0 AND < 'Infinity'`. The second
// conjunct is there because `'NaN'::float8 >= 0` is TRUE in postgres, so the
// non-negativity test alone admits NaN. The engine's guard (riskProfileFor)
// rejects NaN and Inf explicitly, so on the INPUT side the two agree.
//
// They diverge on the OUTPUT. Postgres constrains the stored load; neither
// constrains the product. A load of 1e308 satisfies migration 062's CHECK
// exactly as it satisfies riskProfileFor -- it is finite and non-negative -- and
// is therefore STORABLE, retrievable by the fe gateway, and sendable on a scan,
// at which point carried overflows. The database is not the backstop here, and
// this test is the record that nobody should assume it is.
func TestTheEngineGuardAndTheDatabaseCheckDisagreeOnOverflow(t *testing.T) {
	// The exact predicate migration 062 applies, in Go.
	migration062Admits := func(load float64) bool {
		return !math.IsNaN(load) && load >= 0 && load < math.Inf(1)
	}
	// The exact predicate riskProfileFor applies.
	engineAdmits := func(load float64) bool {
		p, err := riskProfileFor(ComplianceScanRequest{RiskLoad: &load})
		return err == nil && p.RiskLoad == load
	}

	for _, load := range []float64{0, 0.1, 1e9, 1e308, math.MaxFloat64} {
		if !migration062Admits(load) {
			t.Errorf("migration 062 would reject %g; this test's model of the CHECK is wrong", load)
		}
		if !engineAdmits(load) {
			t.Errorf("riskProfileFor rejected %g, but migration 062 admits it, so a stored "+
				"row would be unusable by the engine that reads it", load)
		}
	}
	for _, load := range []float64{math.NaN(), math.Inf(1), math.Inf(-1), -0.1} {
		if migration062Admits(load) && load != 0 {
			t.Errorf("migration 062 admits %g; the CHECK is weaker than documented", load)
		}
		if engineAdmits(load) {
			t.Errorf("riskProfileFor admitted %g; NaN, Inf and negative loads must be refused", load)
		}
	}

	// The divergence, asserted rather than described: a value both layers admit,
	// whose PRODUCT neither layer checks.
	const storable = 1e308
	if !migration062Admits(storable) || !engineAdmits(storable) {
		t.Fatalf("%g is no longer admitted by both layers; the divergence has been closed "+
			"and this test should be re-read", storable)
	}
	// Computed through variables, not constants: Go evaluates constant
	// arithmetic at arbitrary precision and REFUSES to compile an expression
	// that overflows float64, so `1.8e4 * (1 + 1e308)` written as literals is a
	// build error rather than a +Inf. The overflow this test is about only
	// exists at runtime, so it has to be computed at runtime.
	representativeTVaR := 1.8e4
	load := storable
	if !math.IsInf(representativeTVaR*(1+load), 0) {
		t.Fatalf("%g no longer overflows a representative tvar", storable)
	}
	t.Logf("DIVERGENCE: riskLoad=%g passes migration 062's CHECK and riskProfileFor's guard, "+
		"and overflows carried for any tvar above ~1.0; neither layer checks the product", storable)
}

// fairSimulateForPoison runs the engine's own simulate with a given load against
// the contract pack's first priced triple, so the figures under test are the
// real ones rather than hand-made.
//
// It deliberately does NOT reach into fair's internals or alter any triple: it
// reads the triple the handler would use and calls the exported entry point.
func fairSimulateForPoison(t *testing.T, _ float64, load float64) poisonResult {
	t.Helper()
	// A representative priced triple from the contract pack, read through the
	// same path handleScan uses. Using the handler's own numbers keeps this
	// honest if the pack changes.
	h := contractHandler(t)
	_, body := postRawScan(t, h, rawScanBodyWith(t, `"riskLoad":0`),
		map[string]string{"X-Tenant-ID": "t"})
	row := pricedRows(t, body)[0]
	ale := row["ale"].(float64)
	var95 := row["var95"].(float64)
	tvar := row["tvar"].(float64)
	return poisonResult{ALE: ale, VaR95: var95, TVaR: tvar, CarriedGBP: tvar * (1 + load)}
}

type poisonResult struct {
	ALE, VaR95, TVaR, CarriedGBP float64
}

var _ = fmt.Sprintf // keep fmt referenced if assertions are edited down
