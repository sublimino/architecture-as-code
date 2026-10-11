package main

// The summary endpoint's shared state, and what one tenant's declared risk
// profile does to another tenant's figures.
//
// WHY THIS FILE IS SEPARATE FROM THE POISON SUITE. The poison suite asks what a
// hostile VALUE does to one response. This one asks what a hostile value does to
// the NEXT response, and to whose. Those are different failure modes and only
// the second one crosses a tenant boundary.
//
// THE STRUCTURE THAT MAKES IT POSSIBLE. compliance.go:510-512 stores every
// scan's results in ONE slot on the handler:
//
//	ch.mu.Lock()
//	ch.lastResults = results
//	ch.lastUngated = ungatedList
//	ch.mu.Unlock()
//
// and handleSummary (compliance.go:560-564) reads that slot back. The slot has
// no tenant key, and handleSummary takes no tenant parameter and reads no
// header -- there is nowhere for a tenant to be checked even if someone wanted
// to. The mutex makes the access race-free; it does not make it tenant-scoped.
// Race-free sharing of the wrong tenant's money is still the wrong tenant's
// money.
//
// So GET /compliance/summary does not mean "my summary". It means "the summary
// of whichever scan this process served most recently", including a scan run by
// another tenant, with that tenant's declared currency and declared load baked
// into every figure. Three consequences are pinned below, in increasing order of
// how badly they read:
//
//  1. B's own ROWS are clean. The per-scan path is properly isolated: the
//     profile is resolved per request and never cached, so an undeclared scan is
//     byte-identical whether or not another tenant declared anything. This is
//     the good news and it is asserted first, because it bounds the defect.
//  2. B's SUMMARY is A's summary -- A's total, under A's currency label.
//  3. If A's scan overflowed, the summary WAS an empty 200 for EVERYONE, and
//     stayed that way until some other scan replaced the slot. FIXED by F4 fix
//     1: the overflowing scan is refused at the point of application, so no
//     unrenderable figure is ever stored, and every encode site buffers and
//     checks before committing a status. Pinned by
//     TestAnOverflowingScanLeavesEverySubsequentSummaryIntact, which compares
//     the post-attack summary field by field against a pre-attack snapshot --
//     not merely "not empty".
//
// (3) was the one with no tell. A dashboard polling /compliance/summary got HTTP
// 200 and zero bytes, and a client that treats an empty body as an empty result
// renders zero controls, zero failures and zero exposure -- a clean compliance
// posture, fabricated, persisting, and triggered by a different tenant.

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
)

// getSummaryRaw calls the summary endpoint and returns the status and the RAW
// body bytes.
//
// WHY THIS EXISTS BESIDE THE getSummary IN compliance_scan_contract_test.go.
// That helper is the right shape for every test that expects a summary and the
// wrong shape for these: it `t.Fatal`s on a non-200 AND on a JSON parse error,
// so an empty 200 reaches the test as "unexpected end of JSON input" -- a fatal
// inside a helper, attributed to a parse, with the status code already
// discarded. The defect under test here is precisely the PAIR (200, zero bytes),
// and a helper that collapses that pair into a parse failure cannot express it.
//
// That is the same hazard this suite is about, one level up: the most convenient
// instrument reports the wrong failure, and reports it confidently.
func getSummaryRaw(t *testing.T, h *complianceHandler) (int, string) {
	t.Helper()
	w := httptest.NewRecorder()
	h.handleSummary(w, httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil))
	return w.Code, w.Body.String()
}

func parseSummary(t *testing.T, body string) map[string]any {
	t.Helper()
	var s map[string]any
	if err := json.Unmarshal([]byte(body), &s); err != nil {
		t.Fatalf("summary body is not JSON: %v (body=%.200q)", err, body)
	}
	return s
}

// ── 1. The good news, asserted so the defect below is correctly bounded ───────

// TestOneTenantsDeclaredProfileNeverMovesAnotherTenantsRows proves the per-scan
// path IS isolated, which is what stops the summary defect from being a general
// cross-tenant pricing bug.
//
// The profile is resolved once per request in riskProfileFor and lives in a
// local, so there is no cache, no package-level variable and no memoisation for
// one tenant's declaration to leak through. This test is the evidence for that
// claim rather than a reading of the code: tenant A declares an aggressive
// posture (USD, load 0.25) and scans; tenant B then scans declaring nothing, and
// B's figures must be byte-identical to a baseline taken on a handler that A
// never touched.
//
// Byte-identical via JSON round-trip, not field-by-field float comparison: a
// field ADDED to the row by a leak would pass a per-field check that only looks
// at the fields the test thought to name.
func TestOneTenantsDeclaredProfileNeverMovesAnotherTenantsRows(t *testing.T) {
	// Baseline: an untouched handler, undeclared scan.
	clean := contractHandler(t)
	codeB0, baseline := postScanWithHeaders(t, clean, baseScanBody(), nil)
	if codeB0 != http.StatusOK {
		t.Fatalf("baseline scan: got %d", codeB0)
	}

	// A handler that tenant A has used aggressively first.
	shared := contractHandler(t)
	aBody := baseScanBody()
	aBody["reportingCurrency"] = "USD"
	aBody["riskLoad"] = 0.25
	codeA, aRows := postScanWithHeaders(t, shared, aBody, map[string]string{"X-Tenant-ID": "tenant-a"})
	if codeA != http.StatusOK {
		t.Fatalf("tenant A scan: got %d", codeA)
	}
	if len(aRows) == 0 {
		t.Fatal("tenant A got no rows")
	}

	// Tenant B, declaring nothing, on the same handler.
	codeB, bRows := postScanWithHeaders(t, shared, baseScanBody(), nil)
	if codeB != http.StatusOK {
		t.Fatalf("tenant B scan: got %d", codeB)
	}

	wantJSON, err := json.Marshal(baseline)
	if err != nil {
		t.Fatal(err)
	}
	gotJSON, err := json.Marshal(bRows)
	if err != nil {
		t.Fatal(err)
	}
	if string(gotJSON) != string(wantJSON) {
		t.Errorf("tenant B's rows differ after tenant A declared a profile on the same "+
			"handler.\n got: %.400s\nwant: %.400s", gotJSON, wantJSON)
	}

	// And A's declaration really was in force for A, so this test is not passing
	// because the declaration was ignored outright.
	if aRows[0]["currency"] != "USD" {
		t.Fatalf("tenant A's rows are in %v, not USD; A's declaration was not applied and "+
			"this test proves nothing about isolation", aRows[0]["currency"])
	}
	if bRows[0]["currency"] != "GBP" {
		t.Errorf("tenant B's rows are in %v, want GBP (the undeclared default)", bRows[0]["currency"])
	}
}

// ── 2. The defect: the summary belongs to whoever scanned last ────────────────

// TestTheSummaryReturnsTheLastScannersFiguresToAnyCaller_DEFECT pins the
// cross-tenant leak.
//
// THIS IS A DEFECT. Correct behaviour would key the stored results by tenant and
// have handleSummary resolve the caller's tenant the way handleScan already
// does, returning 404 (or an empty summary) when that tenant has not scanned.
// The fix is not attempted here -- the brief was to probe and report -- but the
// shape of it matters for the report: handleSummary currently has NO tenant
// input of any kind, so this is a missing parameter, not a mis-used one.
//
// What is asserted: tenant A scans with a declared profile; a caller presenting
// tenant B's header (and then no header at all) receives A's total under A's
// currency label. The assertion is on the CURRENCY and the TOTAL together,
// because either alone is deniable -- a GBP label on a GBP-denominated default
// scan proves nothing, and a matching total could be coincidence. A USD label on
// a summary served to B is not deniable.
func TestTheSummaryReturnsTheLastScannersFiguresToAnyCaller_DEFECT(t *testing.T) {
	h := contractHandler(t)

	// Tenant A: declared USD, declared load 0.25.
	aBody := baseScanBody()
	aBody["reportingCurrency"] = "USD"
	aBody["riskLoad"] = 0.25
	code, aRows := postScanWithHeaders(t, h, aBody, map[string]string{"X-Tenant-ID": "tenant-a"})
	if code != http.StatusOK {
		t.Fatalf("tenant A scan: got %d", code)
	}

	var aTotal float64
	for _, r := range aRows {
		if status, _ := r["status"].(string); status == "pass" || status == "not_evaluated" || status == "not_in_force" {
			continue
		}
		if c, ok := r["carriedGbp"].(float64); ok {
			aTotal += c
		}
	}

	sCode, sBody := getSummaryRaw(t, h)
	if sCode != http.StatusOK {
		t.Fatalf("summary: got %d", sCode)
	}
	s := parseSummary(t, sBody)

	if s["currency"] != "USD" {
		t.Fatalf("summary currency = %v, want USD; tenant A's scan should be in the slot "+
			"and this test cannot demonstrate a leak otherwise", s["currency"])
	}
	if got, ok := s["totalExposureGbp"].(float64); !ok || math.Abs(got-aTotal) > 0.01 {
		t.Fatalf("summary total = %v, want A's %v", s["totalExposureGbp"], aTotal)
	}

	// The leak: the same summary is served to a caller identifying as tenant B,
	// and to a caller identifying as nobody. handleSummary reads no tenant, so
	// the header is decoration -- which is exactly the finding.
	for _, hdr := range []map[string]string{
		{"X-Tenant-ID": "tenant-b"},
		{},
	} {
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		h.handleSummary(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("summary for %v: got %d. If this is now a 404 or 403 the DEFECT IS "+
				"FIXED -- delete this test.", hdr, w.Code)
			continue
		}
		other := parseSummary(t, w.Body.String())
		if other["currency"] != "USD" {
			t.Errorf("summary for %v is labelled %v; the leak may be fixed -- re-read this test",
				hdr, other["currency"])
		}
		if got, ok := other["totalExposureGbp"].(float64); !ok || math.Abs(got-aTotal) > 0.01 {
			t.Errorf("summary for %v totals %v, not A's %v", hdr, other["totalExposureGbp"], aTotal)
		}
	}
	t.Logf("DEFECT CONFIRMED: tenant A scanned declaring USD + load 0.25; "+
		"GET /compliance/summary returns total %.2f USD to tenant-b and to an "+
		"unauthenticated caller alike. handleSummary takes no tenant input at all.", aTotal)
}

// TestTheSummaryNeverMixesDenominations is the property that DOES hold, and it
// is the reason the leak above is a confidentiality problem rather than also an
// arithmetic one.
//
// Every row of a single scan is priced with one resolved profile, so one scan's
// rows share a denomination and the summary's sum is of like with like. The
// summary reads its label from results[0] rather than from the default constant
// (compliance.go:574), so the label always matches the rows it totalled.
//
// Pinned because the alternative -- a sum of mixed denominations under one label
// -- is the failure money.Add exists to prevent, and the summary reaches
// TotalExposure by `+=` on a bare float64 (compliance.go:602), which bypasses
// money.Add entirely. The invariant is therefore maintained by the fact that one
// scan has one currency, NOT by a check at the point of addition. That is a
// standing fragility worth a test: anything that lets two currencies into one
// results slice turns this sum into a silent nonsense.
func TestTheSummaryNeverMixesDenominations(t *testing.T) {
	for _, declared := range []string{"", "USD", "JPY", "EUR"} {
		name := declared
		if name == "" {
			name = "undeclared"
		}
		t.Run(name, func(t *testing.T) {
			h := contractHandler(t)
			body := baseScanBody()
			headers := map[string]string{}
			want := string(defaultReportingCurrency)
			if declared != "" {
				body["reportingCurrency"] = declared
				headers["X-Tenant-ID"] = "t"
				want = declared
			}
			code, rows := postScanWithHeaders(t, h, body, headers)
			if code != http.StatusOK {
				t.Fatalf("scan: got %d", code)
			}
			sCode, sBody := getSummaryRaw(t, h)
			if sCode != http.StatusOK {
				t.Fatalf("summary: got %d", sCode)
			}
			s := parseSummary(t, sBody)

			if s["currency"] != want {
				t.Errorf("summary currency = %v, want %v", s["currency"], want)
			}
			exposure, ok := s["exposure"].(map[string]any)
			if !ok {
				t.Fatal("summary exposure is not an object")
			}
			if exposure["currency"] != want {
				t.Errorf("summary exposure currency = %v, want %v -- the self-describing "+
					"total and its sibling label must never disagree", exposure["currency"], want)
			}
			// Every row shares that denomination, so the sum is of like with like.
			for _, r := range rows {
				if r["currency"] != want {
					t.Errorf("check %v is denominated %v but the summary totals in %v; "+
						"a sum across denominations is not a total",
						r["check"], r["currency"], want)
				}
			}
		})
	}
}

// ── 3. The fix: an overflowing scan leaves every subsequent summary INTACT ────

// TestAnOverflowingScanLeavesEverySubsequentSummaryIntact is the re-pointed
// form of TestAnOverflowingScanLeavesEverySubsequentSummaryEmpty_DEFECT.
//
// WHAT IT USED TO PIN, and why it was the worst finding in this file. On the
// scan endpoint an empty 200 was confined to the request that caused it. On the
// summary endpoint it was not confined at all: the overflowing +Inf was STORED
// in ch.lastResults and summed into TotalExposure on every subsequent summary
// request, so EVERY caller's summary became an HTTP 200 with zero bytes until
// an unrelated healthy scan happened to overwrite the slot. The caller who sent
// the bad load might never read a summary; the tenants who did had sent nothing
// wrong.
//
// And an empty summary read worse than an empty scan. The scan response is an
// array, so an empty body has no plausible reading as "zero rows" in a strict
// client. The summary is a single object whose fields are counts and a total --
// totalControls, passed, failed, totalExposureGbp -- so a client that defaults
// absent numbers to zero rendered a complete, confident, entirely fabricated
// clean posture.
//
// WHAT IT PINS NOW. Both halves of the fix, at their full original strength:
//
//   - the poison scan is REFUSED (400 with a body), so no +Inf is ever stored;
//   - the slot therefore still holds the healthy scan, and every subsequent
//     summary -- for the innocent tenant, for an unauthenticated caller, and
//     for the poisoner itself -- is a complete document with the SAME figures
//     as before the attack.
//
// The second clause is the one that matters and it is stronger than "not
// empty": the summary is compared field by field against the pre-attack
// snapshot, so a fix that merely stopped the emptiness while letting the poison
// scan disturb the stored state would still fail. The cross-caller loop is kept
// because the blast radius -- every caller, not just the poisoner -- was the
// finding.
func TestAnOverflowingScanLeavesEverySubsequentSummaryIntact(t *testing.T) {
	h := contractHandler(t)

	// A healthy scan first, so there is a good summary to contrast against and
	// any later emptiness cannot be mistaken for "nothing has been scanned yet".
	code, _ := postScanWithHeaders(t, h, baseScanBody(), nil)
	if code != http.StatusOK {
		t.Fatalf("healthy scan: got %d", code)
	}
	okCode, okBody := getSummaryRaw(t, h)
	if okCode != http.StatusOK || len(okBody) == 0 {
		t.Fatalf("healthy summary: got %d with %d bytes", okCode, len(okBody))
	}
	healthy := parseSummary(t, okBody)
	if _, ok := healthy["totalExposureGbp"].(float64); !ok {
		t.Fatalf("healthy summary has no numeric total: %.200q", okBody)
	}
	t.Logf("before: summary is %d bytes, totalControls=%v, totalExposureGbp=%v",
		len(okBody), healthy["totalControls"], healthy["totalExposureGbp"])

	// One tenant sends an overflowing load. It is now refused with a document,
	// which is the first half of the fix and is pinned in full by
	// TestAnOverflowingRiskLoadIsRefusedAndNeverServedAsAnEmptySuccess.
	poison := rawScanBodyWith(t, `"riskLoad":1e308`)
	pCode, pBody := postRawScan(t, h, poison, map[string]string{"X-Tenant-ID": "tenant-poison"})
	if pCode == http.StatusOK {
		t.Fatalf("the overflowing scan was answered with a 200 (%d bytes). If this is a 200 "+
			"with ZERO bytes the empty-200 defect is back; if it is a 200 with rows, a "+
			"non-finite figure is being served as money.", len(pBody))
	}
	if len(pBody) == 0 {
		t.Fatalf("the overflowing scan returned %d with zero bytes: a status line with no "+
			"document is the defect, whatever the code", pCode)
	}

	// Now every summary, for every caller, is still the healthy one -- same
	// bytes, same counts, same total. Not merely non-empty: UNDISTURBED.
	for i, hdr := range []map[string]string{
		{"X-Tenant-ID": "tenant-innocent"},
		{},
		{"X-Tenant-ID": "tenant-poison"},
	} {
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		h.handleSummary(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("call %d (%v): status %d, want 200 -- the healthy scan is still the "+
				"last one and its summary must still be served", i, hdr, w.Code)
			continue
		}
		if w.Body.Len() == 0 {
			t.Errorf("call %d (%v): body is ZERO BYTES. One tenant's overflowing load has "+
				"again emptied every caller's summary.", i, hdr)
			continue
		}
		after := parseSummary(t, w.Body.String())
		for _, field := range []string{"totalControls", "passed", "failed", "errored",
			"notEvaluated", "notInForce", "totalExposureGbp", "currency"} {
			if after[field] != healthy[field] {
				t.Errorf("call %d (%v): %s = %v, want the pre-attack %v. The refused scan "+
					"disturbed the stored state, so the attack still moves an innocent "+
					"caller's figures.", i, hdr, field, after[field], healthy[field])
			}
		}
		t.Logf("after: call %d (%v) -> HTTP %d, %d bytes, totalExposureGbp=%v",
			i, hdr, w.Code, w.Body.Len(), after["totalExposureGbp"])
	}

	// And a later healthy scan still works, so nothing was left in a wedged
	// state by the refusal.
	if c, _ := postScanWithHeaders(t, h, baseScanBody(), nil); c != http.StatusOK {
		t.Fatalf("recovery scan: got %d", c)
	}
	rCode, rBody := getSummaryRaw(t, h)
	if rCode != http.StatusOK || len(rBody) == 0 {
		t.Errorf("after a further healthy scan the summary is %d with %d bytes", rCode, len(rBody))
	}
	t.Logf("FIXED: riskLoad=1e308 is refused with a document; GET /compliance/summary "+
		"returned the undisturbed healthy summary to all three callers. Final body %d bytes.",
		len(rBody))
}
