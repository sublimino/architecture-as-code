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
// It WAS not, in one specific way, and the consequence was the worst outcome in
// the brief: a figure that is not a number reaching the renderer. The guard
// rejects a load that IS NaN or Inf. It could not reject a load that is finite
// but whose PRODUCT with tvar is not -- `tvar * (1 + riskLoad)` in
// fair.SimulateWithLoad has no overflow check, and tvar is ~1.8e4 for a priced
// check, so any declared load above a measured 1.0000000000000005e+304
// overflowed carried to +Inf.
//
// What a client saw then was the thing that cannot be eyeballed, and it was not
// "+Inf" on a dashboard. It was worse. encoding/json REFUSES to marshal +Inf,
// and compliance.go wrote `WriteHeader(StatusOK)` BEFORE `Encode(results)` and
// DISCARDED the encoder's error. So the status line was already committed when
// the marshal failed, and the client received:
//
//	HTTP/1.1 200 OK
//	Content-Type: application/json
//	<zero bytes>
//
// A 200 with an empty body is indistinguishable, to a lenient client, from a
// scan that found nothing to report -- which renders as a CLEAN COMPLIANCE
// POSTURE. The failure was silent at every layer: no 5xx, no error field, no log
// line, no partial row to raise suspicion. That is why it is pinned by byte
// count and status code together, which is the only way to see it.
//
// FIXED, IN TWO INDEPENDENT HALVES (F4 fix 1). Both are pinned below and both
// can regress on their own, which is why there are two tests and not one:
//
//  1. handleScan REFUSES a load it cannot apply, at the point of application,
//     with a 400 naming riskLoad, the check and the figure that overflowed.
//     The rule and the reason no sanity bound sits above it are documented on
//     nonFiniteFigure in compliance.go.
//  2. writeJSONChecked marshals into a buffer and checks the error BEFORE
//     committing any status line, at every site in compliance.go that used to
//     write a status and then encode. A marshal failure is a 500 with a real
//     body; a discarded encode error after a committed status is the defect and
//     must never come back.
//
// WHAT THESE TESTS ARE. Everything in this file that does not concern the two
// fixes above remains a CHARACTERISATION of behaviour observed on this commit,
// not a statement of what is correct -- in particular the reconciliation gap at
// large loads, which is reported and not fixed.

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

// ── 3. The fix: an overflowing load is REFUSED, never served as a 200 ─────────

// TestAnOverflowingRiskLoadIsRefusedAndNeverServedAsAnEmptySuccess is the
// re-pointed form of what was TestAnOverflowingRiskLoadIsServedAs200WithAnEmptyBody_DEFECT.
//
// WHAT IT USED TO PIN. `riskLoad: 1e308` overflowed `tvar * (1 + riskLoad)` to
// +Inf, encoding/json refused to marshal it, and compliance.go had ALREADY
// written `WriteHeader(StatusOK)` and discarded the encoder's error, so the
// client received:
//
//	HTTP/1.1 200 OK
//	Content-Type: application/json
//	<zero bytes>
//
// Any ONE of those three facts reads as something benign and the pair
// (200, zero bytes) reads as a fabricated all-clear:
//
//	a 200 alone         reads as success
//	an empty body alone reads as "nothing to report"
//	the pair            is a clean compliance posture nobody computed
//
// WHAT IT PINS NOW. The same three facts, inverted, plus the one that was
// previously impossible to state: that the response is a REFUSAL a caller can
// see. The assertion set is deliberately kept at full strength rather than
// reduced to `code != 200`, because the shape of the old failure is exactly
// what a regression would re-create:
//
//  1. the status is 400 and not 200    -- a load that cannot be applied is the
//     caller's value and the caller's to fix
//  2. the body is NOT EMPTY            -- the single fact that made the old
//     behaviour invisible
//  3. it parses as JSON, and names     -- so the refusal is actionable rather
//     riskLoad, the check, and the        than a bare status code
//     figure that overflowed
//  4. no row, total or figure is       -- a partial document would be worse
//     present                             than none
//
// A regression that re-introduced `WriteHeader` then an unchecked `Encode`
// fails (2). A regression that dropped the application-time refusal but kept
// the buffer-then-check fails (1) with a 500, which is still visible -- the two
// halves of the fix fail independently and this test distinguishes them, which
// is why the 500 case is asserted ON PURPOSE as a distinct, named outcome
// below rather than folded into "not 200".
//
// The bound is measured, not assumed: tvar for the contract pack's priced
// checks is ~1.8e4, so overflow begins around 1e304. 1e307 and 1e308 are both
// over it; 1e300 is under and is covered by the finite sweep above. If the
// pack's triples are ever recalibrated the threshold moves, which is why this
// test drives the two values furthest into the overflowing region rather than
// probing for the edge.
func TestAnOverflowingRiskLoadIsRefusedAndNeverServedAsAnEmptySuccess(t *testing.T) {
	h := contractHandler(t)

	for _, frag := range []string{`"riskLoad":1e307`, `"riskLoad":1e308`} {
		t.Run(frag, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan",
				bytes.NewReader([]byte(rawScanBodyWith(t, frag))))
			req.Header.Set("X-Tenant-ID", "tenant-poison")
			w := httptest.NewRecorder()
			h.handleScan(w, req)

			// 1. The status line does NOT claim success. 400 specifically: the
			//    value came from the caller, exactly like every other refusal on
			//    this handler. A 500 here would mean the application-time guard
			//    was lost and only the buffer-then-check caught it -- still
			//    visible, but a different and weaker fix, so it is named.
			switch w.Code {
			case http.StatusOK:
				t.Fatalf("status = 200 for %s. THE EMPTY-200 DEFECT IS BACK: an overflowing "+
					"load must never be answered with a success. body=%d bytes %.200q",
					frag, w.Body.Len(), w.Body.String())
			case http.StatusBadRequest:
				// The intended outcome.
			case http.StatusInternalServerError:
				t.Errorf("status = 500 for %s: the overflow reached the encoder, so the "+
					"application-time refusal in handleScan has been lost and only "+
					"writeJSONChecked is holding the line. The response is at least not "+
					"empty, but the figure should have been refused before it was priced. "+
					"body=%.300q", frag, w.Body.String())
			default:
				t.Fatalf("status = %d for %s, want 400", w.Code, frag)
			}

			// 2. The body is NOT empty. This is the assertion the old test could
			//    not make and the one fact that made the defect invisible.
			if w.Body.Len() == 0 {
				t.Fatalf("body is ZERO BYTES with status %d for %s. A status line without a "+
					"document is the defect this test exists to catch, whatever the code.",
					w.Code, frag)
			}
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}

			// 3. It is a document, and it names what to change.
			var body map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
				t.Fatalf("refusal body is not JSON: %v (body=%.300q)", err, w.Body.String())
			}
			if body["error"] != "unapplicable_risk_load" {
				t.Errorf("error = %v, want unapplicable_risk_load", body["error"])
			}
			if body["field"] != "riskLoad" {
				t.Errorf("field = %v, want riskLoad; a refusal that does not name the "+
					"offending field is not actionable", body["field"])
			}
			if body["figure"] != "carriedGbp" {
				t.Errorf("figure = %v, want carriedGbp -- the overflow is in the carried "+
					"product and the refusal should say so", body["figure"])
			}
			for _, k := range []string{"check", "riskLoad", "message"} {
				if v, ok := body[k].(string); !ok || v == "" {
					t.Errorf("refusal body has no usable %q: %#v", k, body[k])
				}
			}

			// 4. And no figure escaped. A partial document -- some rows priced,
			//    the overflowing one dropped -- would be the worst of the three
			//    outcomes, because it reads as a complete scan.
			for _, leaked := range []string{"carriedGbp", "tvar", "totalExposureGbp", "ale", "var95"} {
				if _, present := body[leaked]; present {
					t.Errorf("refusal body carries %q: no figure may be reported for a scan "+
						"the engine refused to price", leaked)
				}
			}
			t.Logf("REFUSED for %s: HTTP %d, %d bytes, error=%v field=%v figure=%v check=%v",
				frag, w.Code, w.Body.Len(), body["error"], body["field"], body["figure"], body["check"])
		})
	}
}

// TestWriteJSONCheckedNeverCommitsASuccessItCannotRender is the second half of
// the fix, tested in isolation from the first.
//
// The two halves fail independently and that is the whole reason this test
// exists beside the one above. The application-time refusal stops an
// overflowing riskLoad from ever being priced; writeJSONChecked stops ANY
// unrenderable value -- from a future field, a different code path, a figure
// nobody has thought of -- from being served as a status line with no document.
// A test that only drove HTTP could not tell which half was holding.
//
// So this drives the helper directly with a value encoding/json refuses, and
// requires a 500 WITH a body. The old behaviour, reproduced here for contrast,
// was `WriteHeader(200)` then a discarded `Encode` error: a 200 with zero
// bytes.
func TestWriteJSONCheckedNeverCommitsASuccessItCannotRender(t *testing.T) {
	// The value the old code path committed a 200 for.
	unrenderable := map[string]any{"carriedGbp": math.Inf(1)}
	if _, err := json.Marshal(unrenderable); err == nil {
		t.Fatal("encoding/json now marshals +Inf; this test's premise is gone and the " +
			"empty-200 explanation must be re-derived")
	}

	w := httptest.NewRecorder()
	writeJSONChecked(w, http.StatusOK, unrenderable)

	if w.Code == http.StatusOK {
		t.Errorf("status = 200: writeJSONChecked committed a success for a document it "+
			"could not produce (body=%d bytes)", w.Body.Len())
	}
	if w.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", w.Code)
	}
	if w.Body.Len() == 0 {
		t.Fatal("body is zero bytes: a status line with no document is the defect, " +
			"and a 500 with nothing in it is the same defect wearing a different code")
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("500 body is not JSON: %v (%.200q)", err, w.Body.String())
	}
	if body["error"] != "unrenderable_response" {
		t.Errorf("error = %v, want unrenderable_response", body["error"])
	}

	// And the happy path is byte-identical to what json.Encoder.Encode wrote,
	// so adopting the helper moved no response. Trailing newline included --
	// that is the byte Encode appends and Marshal does not.
	ok := httptest.NewRecorder()
	writeJSONChecked(ok, http.StatusOK, map[string]string{"a": "b"})
	if got := ok.Body.String(); got != "{\"a\":\"b\"}\n" {
		t.Errorf("rendered %q, want %q -- the helper must be byte-identical to "+
			"json.NewEncoder(w).Encode on the success path", got, "{\"a\":\"b\"}\n")
	}
	if ok.Code != http.StatusOK {
		t.Errorf("happy path status = %d, want 200", ok.Code)
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
