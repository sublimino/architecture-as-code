package main

// The declared zero: `riskLoad: 0` is a coherent risk posture -- carry the tail
// with no load on top -- and it must survive from the JSON request to the
// carried figure without being mistaken for "absent".
//
// WHY THIS NEEDS ITS OWN SUITE WHEN ONE TEST ALREADY EXISTS.
// TestADeclaredZeroRiskLoadIsDistinctFromUndeclared proves the pointer works at
// the HTTP boundary, which is the important half. It does not probe the three
// ways a caller can make the pointer lie, and it does not look at the OTHER
// engine in this repository, which gets the same question wrong.
//
// THE DIVERGENCE, which is the finding here. There are two FAIR engines:
//
//	d2-signalloom/apps/policy-engine/fair   -- SimulateWithLoad(.., riskLoad float64)
//	                                           called with a load resolved from a
//	                                           *float64, so 0 and absent differ
//	d2-signalloom/apps/signal-ingest/pkg/fair -- Inputs.RiskLoad is a PLAIN float64
//	                                           and WithDefaults() does:
//	                                               if in.RiskLoad == 0 {
//	                                                   in.RiskLoad = DefaultRiskLoad
//	                                               }
//
// In the second engine a declared zero is UNEXPRESSIBLE. It is silently replaced
// by 0.10, which is exactly the failure the policy engine's pointer exists to
// prevent -- and the policy engine's own comment says so in as many words: "a
// plain float64 could not tell it apart from absent, which would silently price
// a declared zero as the 0.10 default". One engine took the lesson; the other
// is the counter-example, still shipping.
//
// Negative zero makes it worse rather than better. In Go `-0.0 == 0` is TRUE and
// `-0.0 < 0` is FALSE, so:
//
//	policy-engine: -0.0 passes the `load < 0` guard, is stored, and prices
//	               carried = tvar * (1 + -0.0) = tvar. Correct, and identical to
//	               a declared positive zero.
//	signal-ingest: -0.0 == 0 is true, so WithDefaults replaces it with 0.10.
//
// And the same `== 0 means unset` pattern governs Seed and Trials in that
// engine, so a deliberately-seeded run with Seed: 0 silently becomes
// DefaultSeed. For an engine whose stated purpose is that "a number nobody can
// reproduce is not evidence", a seed that cannot be set to zero is a reproducible
// -run hazard of the same family.
//
// The signal-ingest half of this finding is REPORTED, not fixed, and is pinned
// in its own package (see pkg/fair/engine_declared_zero_test.go) because
// changing WithDefaults changes figures.

import (
	"math"
	"net/http"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

// carriedAndTVaRFor runs the contract scan with the given raw riskLoad fragment
// and returns the first priced row's (tvar, carried) pair.
func carriedAndTVaRFor(t *testing.T, h *complianceHandler, frag string) (float64, float64, string) {
	t.Helper()
	body := rawScanBodyWith(t, frag)
	code, raw := postRawScan(t, h, body, map[string]string{"X-Tenant-ID": "tenant-zero"})
	if code != http.StatusOK {
		t.Fatalf("scan with %s: got %d (%.200q)", frag, code, raw)
	}
	row := pricedRows(t, raw)[0]
	return row["tvar"].(float64), row["carriedGbp"].(float64), row["check"].(string)
}

// ── 1. A declared zero survives, and absent still defaults ────────────────────

// TestADeclaredZeroSurvivesTheWholePathAndNegativeZeroWithIt asserts both
// directions in one place, because either alone is satisfiable by a bug.
//
// A test that only checked "declared 0 gives carried == tvar" would also pass if
// the engine ignored riskLoad entirely. A test that only checked "absent gives
// carried == 1.10 * tvar" would also pass if every load were forced to 0.10. The
// pair pins the distinction itself, which is the thing the *float64 buys.
//
// Negative zero is included as a third row rather than a separate test because
// its correct behaviour is to be INDISTINGUISHABLE from positive zero, and the
// cheapest way to say that is to assert all three against the same tvar.
func TestADeclaredZeroSurvivesTheWholePathAndNegativeZeroWithIt(t *testing.T) {
	h := contractHandler(t)

	// Absent: the engine's own default must apply.
	tvarAbsent, carriedAbsent, check := carriedAndTVaRFor(t, h, `"riskLoad":null`)
	wantAbsent := tvarAbsent * (1 + fair.DefaultRiskLoad)
	if math.Abs(carriedAbsent-wantAbsent) > 0.02 {
		t.Errorf("check %s: absent load gave carried %v, want %v (tvar %v * %v). "+
			"An omitted load must still price at DefaultRiskLoad.",
			check, carriedAbsent, wantAbsent, tvarAbsent, 1+fair.DefaultRiskLoad)
	}

	// Declared zero, in both signs. carried must equal tvar exactly.
	for _, frag := range []string{`"riskLoad":0`, `"riskLoad":0.0`, `"riskLoad":-0.0`, `"riskLoad":-0`} {
		tvar, carried, ck := carriedAndTVaRFor(t, h, frag)
		if math.Abs(carried-tvar) > 1e-9 {
			t.Errorf("check %s with %s: carried = %v but tvar = %v. A declared zero means "+
				"carry the tail with NO load on top, so they must be equal -- if they "+
				"differ the zero was overwritten by the %v default.",
				ck, frag, carried, tvar, fair.DefaultRiskLoad)
		}
		// And it is genuinely distinct from the default, so the assertion above
		// is not passing because the default happens to be zero.
		if math.Abs(carried-tvar*(1+fair.DefaultRiskLoad)) < 1e-9 {
			t.Errorf("check %s with %s: carried matches the DEFAULT-loaded figure, so the "+
				"declared zero was silently replaced", ck, frag)
		}
		// Negative zero must not leak a sign into the figure. money.Round
		// normalises -0.0 to 0, but carried here is a positive quantity; the
		// check that matters is that the SIGN of the load did not flip anything.
		if math.Signbit(carried) {
			t.Errorf("check %s with %s: carried = %v has its sign bit set; a zero load "+
				"must not make an exposure negative", ck, frag, carried)
		}
	}
}

// TestThePointerIsTheOnlyThingDistinguishingZeroFromAbsent drives riskProfileFor
// directly to show the mechanism, so the report can name it.
//
// This is the unit-level twin of the HTTP test above. It matters separately
// because it demonstrates that `Declared` -- the flag the engine uses to say
// whether a figure reflects an institution's choice or its own fallback -- is
// also correct for a declared zero. A zero that priced correctly but reported
// Declared:false would misattribute the figure, which is the subtler half of
// the same mistake.
func TestThePointerIsTheOnlyThingDistinguishingZeroFromAbsent(t *testing.T) {
	// Absent.
	p, err := riskProfileFor(ComplianceScanRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if p.RiskLoad != fair.DefaultRiskLoad {
		t.Errorf("absent: RiskLoad = %v, want %v", p.RiskLoad, fair.DefaultRiskLoad)
	}
	if p.Declared {
		t.Error("absent: Declared = true; a figure priced by the engine's own fallback " +
			"must never be presented as one the institution chose")
	}

	// Declared zero, both signs.
	for _, load := range []float64{0, math.Copysign(0, -1)} {
		l := load
		p, err := riskProfileFor(ComplianceScanRequest{RiskLoad: &l})
		if err != nil {
			t.Fatalf("declared %v: %v", load, err)
		}
		if p.RiskLoad != 0 {
			t.Errorf("declared %v: RiskLoad = %v, want 0", load, p.RiskLoad)
		}
		if !p.Declared {
			t.Errorf("declared %v: Declared = false; the institution stated a posture and "+
				"the engine must attribute the figure to it", load)
		}
	}

	// And the guard rail: this is exactly what a plain float64 cannot do.
	// Documented as an assertion so the type choice is not "tidied" later.
	var plain float64 // the zero value of the field this used to be
	if plain != 0 {
		t.Fatal("unreachable")
	}
	zero := 0.0
	absent := ComplianceScanRequest{}
	declared := ComplianceScanRequest{RiskLoad: &zero}
	if (absent.RiskLoad == nil) == (declared.RiskLoad == nil) {
		t.Error("absent and declared-zero are no longer distinguishable on the request, " +
			"so a declared zero is being priced as the default")
	}
}

// ── 2. The three ways to make the pointer lie, and what each does ─────────────

// TestTheWaysACallerCanTryToForgeADeclaredZero records the boundary between
// "declared zero", "absent" and "invalid", because all three are reachable from
// JSON and they are easy to confuse.
//
//	"riskLoad": 0        -> declared zero. Priced at 0.
//	"riskLoad": 0.0      -> same value, same result.
//	"riskLoad": -0.0     -> same: -0.0 passes `load < 0` because that comparison
//	                        is FALSE for negative zero, and -0.0 multiplies to
//	                        the identity. Correct, but by coincidence of IEEE 754
//	                        rather than by intent, which is why it is pinned.
//	"riskLoad": null     -> ABSENT. encoding/json leaves a *float64 nil on an
//	                        explicit null, so `"riskLoad": null` and omitting the
//	                        key entirely are the same request. Defaults to 0.10.
//	"riskLoad": "0.0"    -> INVALID. 400, wrong type.
//	key omitted          -> absent.
//
// The `null` row is the one worth knowing about: a client that serialises an
// unset form field as explicit null gets the DEFAULT, not a zero, and there is
// nothing in the response to tell it which happened. That is correct per the
// field's documented semantics, and it is a trap for a form-driven UI.
func TestTheWaysACallerCanTryToForgeADeclaredZero(t *testing.T) {
	h := contractHandler(t)

	type want struct {
		code     int
		zeroLoad bool // carried == tvar
	}
	cases := map[string]want{
		`"riskLoad":0`:     {http.StatusOK, true},
		`"riskLoad":0.0`:   {http.StatusOK, true},
		`"riskLoad":-0.0`:  {http.StatusOK, true},
		`"riskLoad":-0`:    {http.StatusOK, true},
		`"riskLoad":0e0`:   {http.StatusOK, true},
		`"riskLoad":null`:  {http.StatusOK, false}, // absent
		`"riskLoad":"0.0"`: {http.StatusBadRequest, false},
		`"riskLoad":"0"`:   {http.StatusBadRequest, false},
		`"riskLoad":false`: {http.StatusBadRequest, false},
		`"riskLoad":[0]`:   {http.StatusBadRequest, false},
		`"riskLoad":{}`:    {http.StatusBadRequest, false},
	}

	for frag, w := range cases {
		t.Run(frag, func(t *testing.T) {
			code, raw := postRawScan(t, h, rawScanBodyWith(t, frag),
				map[string]string{"X-Tenant-ID": "tenant-zero"})
			if code != w.code {
				t.Fatalf("got %d, want %d (%.200q)", code, w.code, raw)
			}
			if code != http.StatusOK {
				return
			}
			row := pricedRows(t, raw)[0]
			tvar := row["tvar"].(float64)
			carried := row["carriedGbp"].(float64)
			isZeroLoad := math.Abs(carried-tvar) < 1e-9
			if isZeroLoad != w.zeroLoad {
				t.Errorf("carried = %v, tvar = %v: load reads as zero = %v, want %v. "+
					"An explicit JSON null leaves a *float64 nil, so it is ABSENT, "+
					"not a declared zero.", carried, tvar, isZeroLoad, w.zeroLoad)
			}
		})
	}
}

// TestAnOmittedKeyAndAnExplicitNullAreTheSameRequest states the null equivalence
// as its own assertion, because it is the one behaviour above that a reader is
// most likely to assume is the other way round.
func TestAnOmittedKeyAndAnExplicitNullAreTheSameRequest(t *testing.T) {
	h := contractHandler(t)

	_, omittedCarried, _ := carriedAndTVaRFor(t, h, "")
	_, nullCarried, _ := carriedAndTVaRFor(t, h, `"riskLoad":null`)

	if omittedCarried != nullCarried {
		t.Errorf("omitted key gave %v, explicit null gave %v; they must be identical "+
			"because encoding/json leaves a *float64 nil in both cases",
			omittedCarried, nullCarried)
	}
	// And both are the DEFAULT, not zero.
	tvar, _, _ := carriedAndTVaRFor(t, h, "")
	if math.Abs(omittedCarried-tvar) < 1e-9 {
		t.Error("an omitted load priced as a zero load; the default is not being applied")
	}
}
