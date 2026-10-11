package main

// The summary endpoint's shared state, and what one tenant's declared risk
// profile does to another tenant's figures.
//
// WHY THIS FILE IS SEPARATE FROM THE POISON SUITE. The poison suite asks what a
// hostile VALUE does to one response. This one asks what a hostile value does to
// the NEXT response, and to whose. Those are different failure modes and only
// the second one crosses a tenant boundary.
//
// THE STRUCTURE THAT MADE IT POSSIBLE. handleScan used to store every scan's
// results in ONE slot on the handler:
//
//	ch.mu.Lock()
//	ch.lastResults = results
//	ch.lastUngated = ungatedList
//	ch.mu.Unlock()
//
// and handleSummary read that slot back. The slot had no tenant key, and
// handleSummary took no tenant parameter and read no header -- there was nowhere
// for a tenant to be checked even if someone had wanted to. The mutex made the
// access race-free; it did not make it tenant-scoped. Race-free sharing of the
// wrong tenant's money is still the wrong tenant's money.
//
// So GET /compliance/summary did not mean "my summary". It meant "the summary of
// whichever scan this process served most recently", including a scan run by
// another tenant, with that tenant's declared currency and declared load baked
// into every figure.
//
// FIXED (fix 2): the store is a map keyed by the tenant extractTenant resolves
// from the request -- the same resolution handleScan performs -- so a tenant
// reads back exactly what it stored and nothing else. The empty key is the
// anonymous caller's own bucket, not a wildcard. A tenant with no scan gets a
// 404 carrying no counts, never a zeroed 200 and never another tenant's
// figures; see TestComplianceSummary_NoScan for why a zeroed 200 is the
// forbidden answer. The store is bounded, because its key comes straight off
// an unauthenticated request; see maxRememberedTenants and
// TestTheScanStoreIsBoundedAndEvictsTheOldest.
//
// Three consequences are pinned below, in the order they are easiest to reason
// about:
//
//  1. B's own ROWS were always clean. The per-scan path is properly isolated:
//     the profile is resolved per request and never cached, so an undeclared
//     scan is byte-identical whether or not another tenant declared anything.
//     This bounded the defect to the summary endpoint and it still holds.
//  2. B's SUMMARY was A's summary -- A's total, under A's currency label. Now
//     each tenant reads its own and only its own.
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
	"fmt"
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
func getSummaryRaw(t *testing.T, h *complianceHandler, headers ...map[string]string) (int, string) {
	t.Helper()
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	// Variadic rather than a required argument: most callers want the anonymous
	// caller, and fix 2 made WHICH tenant asks a load-bearing part of the
	// request. Before it, handleSummary read no tenant at all and a header here
	// would have been decoration.
	for _, hdr := range headers {
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
	}
	h.handleSummary(w, req)
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

// ── 2. FIXED: the summary belongs to the tenant that asked ────────────────────

// TestTheSummaryIsScopedToTheCallingTenant is the re-pointed form of
// TestTheSummaryReturnsTheLastScannersFiguresToAnyCaller_DEFECT, and it is the
// heart of fix 2.
//
// WHAT IT USED TO PIN. handleSummary read ONE unkeyed slot and took no tenant
// input of any kind -- no header, no query parameter, no argument. So
// GET /compliance/summary did not mean "my summary"; it meant "the summary of
// whichever scan this process served most recently". Measured: tenant A's total
// of 136473.64, under A's DECLARED USD label and A's declared load of 0.25, was
// served verbatim to a caller presenting tenant B's header and to a caller
// presenting no header at all. The mutex made that access race-free. Race-free
// sharing of the wrong tenant's money is still the wrong tenant's money.
//
// WHAT IT PINS NOW, and every clause is load-bearing:
//
//  1. A reads back A's OWN figures -- A's total under A's declared currency. If
//     this fails the fix has broken the endpoint rather than scoped it.
//  2. B, who has also scanned, reads B's OWN figures -- B's total under B's
//     currency. Not A's, and specifically NOT A's declared USD label, which is
//     the undeniable tell: a GBP label on a GBP-denominated default scan would
//     prove nothing, and a matching total could be coincidence.
//  3. A tenant that has NOT scanned, and a caller presenting no tenant at all,
//     get 404 -- not A's figures, and not a zeroed 200. See
//     TestComplianceSummary_NoScan for why a zeroed 200 is the forbidden answer.
//  4. The anonymous caller is its own bucket, not a wildcard: it cannot read a
//     named tenant's scan, and a named tenant cannot read an anonymous scan.
//
// (4) is the clause a plausible wrong fix would fail. Treating an absent tenant
// header as "any tenant" -- or as a key that matches the most recent scan --
// would satisfy (1), (2) and (3) and reinstate the whole leak for every
// unauthenticated caller, which is exactly who the original defect exposed it
// to.
func TestTheSummaryIsScopedToTheCallingTenant(t *testing.T) {
	h := contractHandler(t)

	carriedTotal := func(rows []map[string]any) float64 {
		var total float64
		for _, r := range rows {
			if status, _ := r["status"].(string); status == "pass" || status == "not_evaluated" || status == "not_in_force" {
				continue
			}
			if c, ok := r["carriedGbp"].(float64); ok {
				total += c
			}
		}
		return total
	}

	// Tenant A: declared USD, declared load 0.25.
	aBody := baseScanBody()
	aBody["reportingCurrency"] = "USD"
	aBody["riskLoad"] = 0.25
	code, aRows := postScanWithHeaders(t, h, aBody, map[string]string{"X-Tenant-ID": "tenant-a"})
	if code != http.StatusOK {
		t.Fatalf("tenant A scan: got %d", code)
	}
	aTotal := carriedTotal(aRows)

	// Tenant B: declared EUR, declared load 0.5. A DIFFERENT currency and a
	// different load, so B reading A's figures would be visible in two
	// independent fields rather than one.
	bBody := baseScanBody()
	bBody["reportingCurrency"] = "EUR"
	bBody["riskLoad"] = 0.5
	code, bRows := postScanWithHeaders(t, h, bBody, map[string]string{"X-Tenant-ID": "tenant-b"})
	if code != http.StatusOK {
		t.Fatalf("tenant B scan: got %d", code)
	}
	bTotal := carriedTotal(bRows)

	if aTotal == bTotal {
		t.Fatalf("both tenants total %.2f, so this test cannot tell a leak from a "+
			"correct answer; the declared loads must differ in effect", aTotal)
	}

	// 1 and 2: each tenant reads its own. B scanned LAST, so A reading back A's
	// own figures is precisely the clause that failed under the shared slot.
	for _, tc := range []struct {
		tenant   string
		wantCur  string
		wantTotl float64
	}{
		{"tenant-a", "USD", aTotal},
		{"tenant-b", "EUR", bTotal},
	} {
		sCode, sBody := getSummaryRaw(t, h, map[string]string{"X-Tenant-ID": tc.tenant})
		if sCode != http.StatusOK {
			t.Fatalf("summary for %s: got %d (%.200q)", tc.tenant, sCode, sBody)
		}
		s := parseSummary(t, sBody)
		if s["currency"] != tc.wantCur {
			t.Errorf("summary for %s is labelled %v, want %v -- it is being served another "+
				"tenant's denomination", tc.tenant, s["currency"], tc.wantCur)
		}
		if got, ok := s["totalExposureGbp"].(float64); !ok || math.Abs(got-tc.wantTotl) > 0.01 {
			t.Errorf("summary for %s totals %v, want its own %v", tc.tenant, s["totalExposureGbp"], tc.wantTotl)
		}
	}

	// 3 and 4: a tenant that never scanned, and the anonymous caller, get 404 --
	// never the last scanner's figures.
	for _, hdr := range []map[string]string{
		{"X-Tenant-ID": "tenant-c-never-scanned"},
		{},
	} {
		sCode, sBody := getSummaryRaw(t, h, hdr)
		if sCode == http.StatusOK {
			s := parseSummary(t, sBody)
			t.Errorf("summary for %v returned 200 labelled %v totalling %v. THE CROSS-TENANT "+
				"LEAK IS BACK: a caller with no scan of its own is being served somebody "+
				"else's figures.", hdr, s["currency"], s["totalExposureGbp"])
			continue
		}
		if sCode != http.StatusNotFound {
			t.Errorf("summary for %v: got %d, want 404", hdr, sCode)
			continue
		}
		// And the refusal does not quietly carry a figure, so "no scan for you"
		// cannot be read as "scanned, nothing found".
		body := parseSummary(t, sBody)
		for _, leaked := range []string{"totalExposureGbp", "currency", "totalControls", "exposure"} {
			if _, present := body[leaked]; present {
				t.Errorf("the 404 for %v carries %q", hdr, leaked)
			}
		}
	}

	// 4, the other direction: an ANONYMOUS scan is not readable by a named
	// tenant, and does not become readable by being the most recent.
	anonCode, anonRows := postScanWithHeaders(t, h, baseScanBody(), nil)
	if anonCode != http.StatusOK {
		t.Fatalf("anonymous scan: got %d", anonCode)
	}
	anonTotal := carriedTotal(anonRows)
	if c, b := getSummaryRaw(t, h, map[string]string{"X-Tenant-ID": "tenant-c-never-scanned"}); c != http.StatusNotFound {
		t.Errorf("after an anonymous scan, tenant-c's summary is %d (%.200q); the anonymous "+
			"bucket must not be a wildcard", c, b)
	}
	aCode, aBodyAfter := getSummaryRaw(t, h, map[string]string{"X-Tenant-ID": "tenant-a"})
	if aCode != http.StatusOK {
		t.Fatalf("tenant A's summary after an anonymous scan: got %d", aCode)
	}
	aAfter := parseSummary(t, aBodyAfter)
	if got, ok := aAfter["totalExposureGbp"].(float64); !ok || math.Abs(got-aTotal) > 0.01 {
		t.Errorf("tenant A's total moved to %v (its own is %v, the anonymous scan's is %v) "+
			"because a later scan by somebody else replaced the slot A reads",
			aAfter["totalExposureGbp"], aTotal, anonTotal)
	}
	if aAfter["currency"] != "USD" {
		t.Errorf("tenant A's summary is now labelled %v, not its declared USD", aAfter["currency"])
	}

	t.Logf("FIXED: A reads %.2f USD, B reads %.2f EUR, an unscanned tenant and the "+
		"anonymous caller both get 404, and a later anonymous scan of %.2f GBP moved "+
		"neither.", aTotal, bTotal, anonTotal)
}

// TestTheSummaryNeverMixesDenominations is the property that DOES hold, and it
// was the reason the leak above was a confidentiality problem rather than also
// an arithmetic one.
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
			// The summary is read AS THE SCANNING TENANT. Before fix 2 this
			// header was decoration -- handleSummary read no tenant at all --
			// so an unheadered fetch happened to return a declared-currency
			// scan's figures. It now correctly 404s, which is why the header
			// has to be passed through here.
			sCode, sBody := getSummaryRaw(t, h, headers)
			if sCode != http.StatusOK {
				t.Fatalf("summary as %v: got %d (%.200q)", headers, sCode, sBody)
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
// WHAT IT PINS NOW. Both halves of fix 1, plus the containment fix 2 added:
//
//   - the poison scan is REFUSED (400 with a body), so no +Inf is ever stored;
//   - an innocent tenant that HAS scanned reads its own summary back
//     UNDISTURBED -- compared field by field against a pre-attack snapshot, so
//     a change that merely stopped the emptiness while letting the refused scan
//     disturb stored state would still fail;
//   - the poisoner and an anonymous caller, neither of whom has a successful
//     scan, get a 404 carrying no counts -- not an empty 200, and not the
//     innocent tenant's figures.
//
// The third clause is where fix 2 narrowed the blast radius and the test had to
// follow. Before fix 2 "every caller sees the same thing" was itself the
// defect: one slot, no tenant input, so the poison emptied everyone's summary
// AND a healthy scan handed its figures to everyone. Now each tenant can only
// be shown its own, which means the correct post-attack answer differs by
// caller -- and the test asserts all three answers rather than one.
func TestAnOverflowingScanLeavesEverySubsequentSummaryIntact(t *testing.T) {
	h := contractHandler(t)

	const innocent = "tenant-innocent"

	// A healthy scan by an innocent tenant, so there is a good summary to
	// contrast against and any later emptiness cannot be mistaken for "nothing
	// has been scanned yet".
	code, _ := postScanWithHeaders(t, h, baseScanBody(), map[string]string{"X-Tenant-ID": innocent})
	if code != http.StatusOK {
		t.Fatalf("healthy scan: got %d", code)
	}
	okCode, okBody := getSummaryRaw(t, h, map[string]string{"X-Tenant-ID": innocent})
	if okCode != http.StatusOK || len(okBody) == 0 {
		t.Fatalf("healthy summary: got %d with %d bytes", okCode, len(okBody))
	}
	healthy := parseSummary(t, okBody)
	if _, ok := healthy["totalExposureGbp"].(float64); !ok {
		t.Fatalf("healthy summary has no numeric total: %.200q", okBody)
	}
	t.Logf("before: %s's summary is %d bytes, totalControls=%v, totalExposureGbp=%v",
		innocent, len(okBody), healthy["totalControls"], healthy["totalExposureGbp"])

	// Another tenant sends an overflowing load. It is now refused with a
	// document, which is pinned in full by
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

	// The innocent tenant's summary is UNDISTURBED -- not merely non-empty.
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil)
	req.Header.Set("X-Tenant-ID", innocent)
	h.handleSummary(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("%s's summary after the attack: status %d, want 200 (%.300q)",
			innocent, w.Code, w.Body.String())
	}
	if w.Body.Len() == 0 {
		t.Fatal("the innocent tenant's summary is ZERO BYTES: another tenant's overflowing " +
			"load has again emptied it")
	}
	after := parseSummary(t, w.Body.String())
	for _, field := range []string{"totalControls", "passed", "failed", "errored",
		"notEvaluated", "notInForce", "totalExposureGbp", "currency"} {
		if after[field] != healthy[field] {
			t.Errorf("%s: %s = %v, want the pre-attack %v. The refused scan disturbed the "+
				"stored state, so the attack still moves an innocent caller's figures.",
				innocent, field, after[field], healthy[field])
		}
	}
	t.Logf("after: %s -> HTTP %d, %d bytes, totalExposureGbp=%v",
		innocent, w.Code, w.Body.Len(), after["totalExposureGbp"])

	// And the two callers with no successful scan of their own get a 404 that
	// carries no counts -- never the innocent tenant's figures, and never a
	// zeroed 200 that would read as a clean posture.
	for _, hdr := range []map[string]string{
		{"X-Tenant-ID": "tenant-poison"},
		{},
	} {
		c, b := getSummaryRaw(t, h, hdr)
		if c == http.StatusOK {
			s := parseSummary(t, b)
			t.Errorf("summary for %v returned 200 labelled %v totalling %v; a caller whose "+
				"only scan was REFUSED has no summary and must not be shown another "+
				"tenant's", hdr, s["currency"], s["totalExposureGbp"])
			continue
		}
		if c != http.StatusNotFound {
			t.Errorf("summary for %v: got %d, want 404", hdr, c)
			continue
		}
		if len(b) == 0 {
			t.Errorf("the 404 for %v has no body", hdr)
			continue
		}
		ref := parseSummary(t, b)
		for _, leaked := range []string{"totalExposureGbp", "totalControls", "currency"} {
			if _, present := ref[leaked]; present {
				t.Errorf("the 404 for %v carries %q, making 'no scan' readable as "+
					"'scanned, nothing found'", hdr, leaked)
			}
		}
	}

	// And a later healthy scan still works, so nothing was left wedged by the
	// refusal.
	if c, _ := postScanWithHeaders(t, h, baseScanBody(), map[string]string{"X-Tenant-ID": innocent}); c != http.StatusOK {
		t.Fatalf("recovery scan: got %d", c)
	}
	rCode, rBody := getSummaryRaw(t, h, map[string]string{"X-Tenant-ID": innocent})
	if rCode != http.StatusOK || len(rBody) == 0 {
		t.Errorf("after a further healthy scan the summary is %d with %d bytes", rCode, len(rBody))
	}
	t.Logf("FIXED: riskLoad=1e308 is refused with a document; %s's summary was undisturbed "+
		"and the poisoner and the anonymous caller both got 404. Final body %d bytes.",
		innocent, len(rBody))
}

// ── 4. The growth the tenant key introduces, and its bound ────────────────────

// TestTheScanStoreIsBoundedAndEvictsTheOldest pins the cost of fix 2, because
// keying by tenant is not free and the bill is paid in memory.
//
// THE HAZARD. The key is `X-Tenant-ID` (or `?tenant=`) straight off the
// request. The engine has no database and no token introspection, so it cannot
// check that a tenant id corresponds to anything -- "only real tenants appear"
// is not a property this code can rely on. An unkeyed slot could not grow; a
// map keyed by a caller-supplied string with no eviction grows forever, on an
// unauthenticated trigger, one entry per distinct header value.
//
// THE BOUND, AND WHY EVICTION RATHER THAN REFUSAL. The store holds at most
// maxRememberedTenants scans and discards the OLDEST when full. The alternative
// -- refusing new scans once full -- would let one caller with a loop deny the
// scan endpoint to every real tenant, which is a worse failure than losing an
// old summary. The consequence is stated rather than hidden: an evicted tenant
// gets the same 404 as one that never scanned, which is the correct answer to
// "show me my summary" when the engine no longer has one.
//
// What is asserted: the map never exceeds the cap; the most recent scanner is
// still readable; the first scanner has been evicted and 404s rather than
// returning somebody else's figures. The last clause is the one that matters --
// eviction must not degrade into a leak.
func TestTheScanStoreIsBoundedAndEvictsTheOldest(t *testing.T) {
	h := &complianceHandler{}
	row := ComplianceScanResult{Check: "synthetic", Status: VerdictFail, CarriedGBP: 1}

	// One more than the cap, so exactly one eviction is forced.
	for i := 0; i < maxRememberedTenants+1; i++ {
		h.rememberScan(fmt.Sprintf("tenant-%d", i), []ComplianceScanResult{row}, nil)
	}

	h.mu.RLock()
	size := len(h.scans)
	h.mu.RUnlock()
	if size > maxRememberedTenants {
		t.Errorf("store holds %d scans, cap is %d: the map is unbounded and one caller can "+
			"grow it forever with arbitrary X-Tenant-ID values", size, maxRememberedTenants)
	}

	// The newest is readable.
	newest := fmt.Sprintf("tenant-%d", maxRememberedTenants)
	if _, ok := h.scanFor(newest); !ok {
		t.Errorf("%s was evicted; eviction must drop the OLDEST, not the newest", newest)
	}
	// The oldest is gone.
	if _, ok := h.scanFor("tenant-0"); ok {
		t.Errorf("tenant-0 survived %d later scans with a cap of %d",
			maxRememberedTenants, maxRememberedTenants)
	}

	// And an evicted tenant gets 404 -- NOT another tenant's figures. Eviction
	// must not reopen the leak it sits beside.
	c, b := getSummaryRaw(t, h, map[string]string{"X-Tenant-ID": "tenant-0"})
	if c != http.StatusNotFound {
		t.Errorf("an evicted tenant's summary is %d (%.200q), want 404", c, b)
	}

	// Re-scanning an existing tenant REPLACES rather than adds, so a single
	// tenant polling the scan endpoint cannot evict everyone else.
	before := size
	h.rememberScan(newest, []ComplianceScanResult{row, row}, nil)
	h.mu.RLock()
	after := len(h.scans)
	h.mu.RUnlock()
	if after != before {
		t.Errorf("re-scanning an existing tenant changed the store size %d -> %d; a repeat "+
			"scanner must replace its own entry, not add one", before, after)
	}
	if s, _ := h.scanFor(newest); len(s.results) != 2 {
		t.Errorf("%s has %d rows, want the 2 from its latest scan", newest, len(s.results))
	}
}
