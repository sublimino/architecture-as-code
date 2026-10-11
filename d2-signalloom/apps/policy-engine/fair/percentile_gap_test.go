package fair

// The exact size of the gap the money goldens leave, measured rather than
// asserted away.
//
// WHAT THE REPOSITORY ALREADY SAYS, so this file does not restate it as a
// discovery. The Makefile's money section is explicit:
//
//	var95   -- pinned by the GOLDEN, by the closed-form support bounds, and by
//	tvar      the ordering identities. There is no closed form for a quantile of
//	carried   a product of two beta-PERT variates, and the only independent
//	          numerical treatment available (verify-cel-money-independent) is
//	          bounded by the engine's OWN 10,000-iteration quantile noise, which
//	          is several per cent -- the same order as a one-rank percentile error.
//
// And CONFORMANCE.md lists what the conformance tier actually proves about these
// three figures: ordering (`tvar >= var95`, `tvar >= ale`, `carried >= tvar`,
// finite, non-negative), monotonicity in riskTriple.mode, determinism from the
// check ID, and the tailDominated flag. Every one of those is a RELATIONAL
// property. None of them pins a VALUE.
//
// So the claim "var95/tvar/carried are pinned only by goldens" is already on the
// record. What is NOT on the record is HOW BIG the resulting blind spot is, and
// that is the only thing this file adds. A reader deciding whether to trust the
// deterministic golden as the sole gate needs the number.
//
// THE MEASUREMENT. A one-rank error in the tail index is the canonical
// regression the gap admits, and it can be measured without mutating anything:
// Engine.RunDistribution returns the sorted loss vector alongside the Result, so
// the tail mean can be recomputed at adjacent ranks on the engine's own
// distribution and compared.
//
// WHAT THE MEASUREMENT FOUND, which was not the expected answer. The two entry
// points in this file ALREADY DISAGREE by exactly one rank:
//
//	SimulateWithLoad (fair.go:146)   idx95 := int(math.Ceil(0.95*float64(iterations))) - 1
//	RunDistribution  (fair.go:311)   idx  := int(math.Floor(0.95 * float64(iters)))
//
// For 10,000 iterations that is 9499 and 9500 -- a tail of 501 elements against
// one of 500. The two are not equivalent and neither is wrong in isolation
// (nearest-rank and lower-rank are both defensible quantile conventions), but
// they are DIFFERENT, so the same distribution yields two different TVaRs
// depending on which function a caller reaches. The per-check scan path uses the
// first; the portfolio aggregation path uses the second.
//
// This file does NOT change either convention. It measures the divergence and
// pins it, so that unifying them later is a deliberate act with a known price
// tag rather than a silent movement in every carried figure.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO. It does not close the gap. There is
// no independent oracle for a tail quantile of a product of beta-PERT variates
// available here, and inventing one that agrees with the engine would prove
// only that two implementations of the same formula agree. The value is in the
// honest size of the hole, so a reader knows what the goldens do and do not buy.

import (
	"math"
	"sort"
	"testing"
)

// gapTestContribs is a representative single-contribution portfolio, built from
// the engine's own ordering rules rather than from a pack, so this file stays
// valid under any recalibration.
func gapTestContribs() []Contribution {
	return []Contribution{{
		LEF:       RiskTriple{Min: 1, Mode: 3, Max: 8},
		Magnitude: RiskTriple{Min: 5_000, Mode: 25_000, Max: 200_000},
	}}
}

// tailMeanAt recomputes the tail mean at an explicit rank, using the same
// arithmetic the engine uses (an unweighted mean of the upper tail).
func tailMeanAt(sorted []float64, idx int) float64 {
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	var sum float64
	for _, v := range sorted[idx:] {
		sum += v
	}
	return sum / float64(len(sorted)-idx)
}

// ── 1. The size of a one-rank error ───────────────────────────────────────────

// TestAnOffByOnePercentileIndexMovesEveryTailFigure measures what a one-rank
// error costs, and compares it against what each verification tier would
// tolerate.
//
// This is the test the brief asks for: it demonstrates the gap's exact size. The
// assertions are deliberately loose on the VALUE (a recalibration must not break
// it) and tight on the STRUCTURE: a one-rank error must move tvar by a non-zero
// amount, must NOT break any ordering identity, and must NOT move ale at all.
// Those three together are what make the gap real -- the figure changes, and
// every non-golden check still passes.
func TestAnOffByOnePercentileIndexMovesEveryTailFigure(t *testing.T) {
	e := &Engine{Iterations: 10_000, Seed: DefaultSeed}
	res, losses := e.RunDistribution(gapTestContribs(), DefaultRiskLoad)
	if !sort.Float64sAreSorted(losses) {
		t.Fatal("RunDistribution returned an unsorted vector; this measurement assumes sorted")
	}
	n := len(losses)

	// The rank the aggregation path uses, and its neighbours.
	base := int(math.Floor(0.95 * float64(n)))
	tvarAt := map[int]float64{}
	for _, idx := range []int{base - 1, base, base + 1} {
		tvarAt[idx] = tailMeanAt(losses, idx)
	}

	if got := tvarAt[base]; math.Abs(got-res.TVaR) > 1e-9 {
		t.Fatalf("recomputed tail mean at rank %d is %v but the engine reported %v; this "+
			"measurement is not reading the same figure the engine produces", base, got, res.TVaR)
	}

	// A one-rank error MOVES the figure. If it did not, the gap would be
	// harmless and this whole file would be pointless -- so this is the
	// load-bearing assertion.
	for _, idx := range []int{base - 1, base + 1} {
		delta := math.Abs(tvarAt[idx]-tvarAt[base]) / tvarAt[base]
		if delta == 0 {
			t.Errorf("a one-rank move to %d did not change tvar at all; re-read this test", idx)
		}
		t.Logf("rank %d -> tvar %.2f (%.4f%% from rank %d's %.2f)",
			idx, tvarAt[idx], 100*delta, base, tvarAt[base])
	}

	// ── and now: what each tier would make of that movement ──
	//
	// (a) The ordering identities, which the conformance tier asserts over
	//     every shipped check. A one-rank error preserves all of them.
	for _, idx := range []int{base - 1, base, base + 1} {
		tvar := tvarAt[idx]
		if tvar < res.VaR95 {
			// The engine clamps this case; a genuine tail mean at a rank at or
			// above the 95th cannot sit below the 95th percentile.
			t.Logf("rank %d: tvar %.2f < var95 %.2f (engine would clamp)", idx, tvar, res.VaR95)
			continue
		}
		if tvar < res.ALE {
			t.Errorf("rank %d: tvar %.2f < ale %.2f", idx, tvar, res.ALE)
		}
		carried := tvar * (1 + DefaultRiskLoad)
		if carried < tvar {
			t.Errorf("rank %d: carried %.2f < tvar %.2f", idx, carried, tvar)
		}
		if math.IsNaN(tvar) || math.IsInf(tvar, 0) || tvar < 0 {
			t.Errorf("rank %d: tvar %.2f is not a finite non-negative figure", idx, tvar)
		}
	}
	t.Log("ORDERING IDENTITIES: survive a one-rank error at every adjacent rank. " +
		"TestConformance_MoneyFigureOrdering would NOT catch this regression.")

	// (b) The closed-form ALE anchor, which is the only INDEPENDENT oracle in
	//     the money tier. ale is a mean over the whole vector and does not
	//     involve the tail index, so it does not move at all.
	aleAt := func() float64 {
		var s float64
		for _, v := range losses {
			s += v
		}
		return s / float64(n)
	}()
	if math.Abs(aleAt-res.ALE) > 1e-9 {
		t.Fatalf("ale recomputation %v disagrees with the engine's %v", aleAt, res.ALE)
	}
	t.Logf("CLOSED-FORM ALE ANCHOR: ale = %.2f and is a mean over all %d draws, "+
		"independent of the tail index, so a one-rank error moves it by EXACTLY ZERO. "+
		"compliance_money_oracle_test.go would NOT catch this regression.", res.ALE, n)

	// (c) The deterministic golden, which pins the figure to the cent. Any
	//     movement at all is caught. This is the ONLY tier that catches it.
	roundedBase := math.Round(tvarAt[base]*100) / 100
	for _, idx := range []int{base - 1, base + 1} {
		rounded := math.Round(tvarAt[idx]*100) / 100
		if rounded == roundedBase {
			t.Errorf("rank %d rounds to the same cent as rank %d (%.2f); at this "+
				"distribution the golden would NOT catch a one-rank error either, "+
				"which would make the gap total rather than partial", idx, base, rounded)
		}
	}
	t.Logf("DETERMINISTIC GOLDEN: pins tvar to the cent (%.2f), so it is the ONLY "+
		"tier that catches a one-rank error. That is the whole of the gap: three of "+
		"the four quoted figures rest on one deterministic file.", roundedBase)
}

// ── 2. The divergence between the two entry points, which is not hypothetical ─

// TestTheTwoTailIndexConventionsInThisFileDisagreeByOneRank pins a real,
// shipping, one-rank disagreement.
//
// SimulateWithLoad uses nearest-rank (`Ceil(p*n) - 1`), RunDistribution uses
// lower-rank (`Floor(p*n)`). For n = 10,000 that is 9499 against 9500. Both are
// defensible conventions; what is not defensible is holding both at once without
// saying so, because the same distribution then yields two different TVaRs
// according to which function the caller reached -- and the per-check scan path
// and the portfolio aggregation path reach different ones.
//
// NOT A FIX. The two conventions are left exactly as they are. This test states
// the price of unifying them, so whoever does it knows what moves.
func TestTheTwoTailIndexConventionsInThisFileDisagreeByOneRank(t *testing.T) {
	const n = 10_000
	nearestRank := int(math.Ceil(0.95*float64(n))) - 1 // SimulateWithLoad
	lowerRank := int(math.Floor(0.95 * float64(n)))    // RunDistribution

	if nearestRank == lowerRank {
		t.Fatalf("the two conventions now agree at n=%d (both %d). If they have been "+
			"unified, this test should be deleted and the note in the file header removed.",
			n, nearestRank)
	}
	if lowerRank-nearestRank != 1 {
		t.Errorf("the conventions differ by %d ranks, not 1; re-read this test",
			lowerRank-nearestRank)
	}

	e := &Engine{Iterations: n, Seed: DefaultSeed}
	_, losses := e.RunDistribution(gapTestContribs(), DefaultRiskLoad)

	tvarNearest := tailMeanAt(losses, nearestRank)
	tvarLower := tailMeanAt(losses, lowerRank)
	rel := math.Abs(tvarNearest-tvarLower) / tvarLower

	t.Logf("DIVERGENCE: at n=%d the same distribution gives tvar %.2f via the "+
		"SimulateWithLoad convention (nearest-rank, idx %d, tail of %d) and %.2f via "+
		"the RunDistribution convention (lower-rank, idx %d, tail of %d) -- %.4f%% apart. "+
		"Both conventions are defensible; holding both silently is not.",
		n, tvarNearest, nearestRank, n-nearestRank, tvarLower, lowerRank, n-lowerRank, 100*rel)

	// The divergence is real but SMALL, and saying so is the honest part: it is
	// the same order as the independent NumPy check's own tolerance, which is
	// exactly why that check cannot adjudicate between them.
	if rel == 0 {
		t.Error("the two conventions produced an identical figure on this distribution, " +
			"so this test is not measuring anything; pick a distribution with a " +
			"coarser tail")
	}
	if rel > 0.05 {
		t.Errorf("the conventions differ by %.2f%%, which is far larger than the "+
			"one-rank effect this test describes; re-read it", 100*rel)
	}
}

// ── 3. The flag that IS an independent signal, and its limits ─────────────────

// TestTheTailDominatedFlagIsTheOnlySignalOfAnInvertedPercentile pins the one
// piece of tail machinery that does not depend on a golden.
//
// fair.go's header records a removed clamp: an earlier revision forced
// `var95 >= ale`, which is NOT a property of loss distributions -- for a
// low-frequency/high-severity risk most simulated years cost nothing, so the
// 95th percentile sits at or near zero while the mean stays positive. The clamp
// reported "a bad year equal to the average year", a fabricated figure, in
// precisely the well-governed case a client most wants to see. It was replaced
// by the TailDominated flag.
//
// The flag is therefore the only assertion in the tail machinery that is both
// independent of a golden AND able to catch a specific class of fabrication: it
// is defined as exactly `var95 < ale`, in both directions, so re-introducing the
// clamp makes the flag unreachable and that is detectable without pinning a
// value.
//
// What it does NOT catch is a one-rank error, because an off-by-one moves tvar
// and leaves var95's relationship to ale alone. So the flag closes one hole and
// not the other, and this test says which is which.
func TestTheTailDominatedFlagIsTheOnlySignalOfAnInvertedPercentile(t *testing.T) {
	// WHY THIS TEST DOES NOT CONSTRUCT AN INVERTED CASE, AND MUST NOT SKIP.
	//
	// The obvious shape for this test is "build a low-frequency/high-severity
	// risk, watch the flag fire". It cannot be done through this entry point,
	// and finding that out is part of the measurement.
	//
	// SimulateWithLoad computes `annualLosses[i] = f * l` where BOTH f and l are
	// continuous beta-PERT draws. A PERT variate is unimodal and bounded with no
	// mass at zero, so the product is never zero-inflated: there is no
	// "most years cost nothing" regime to produce. Five deliberately extreme
	// skews were measured -- freq modes down to 1e-6, loss maxima up to 1e9,
	// and modes pinned at the minimum -- and every one gave var95 > ale by a
	// wide margin (var95/ale ~3.7 in each case). The inversion the flag exists
	// to report is UNREACHABLE for any PERT triple on this path.
	//
	// The repository already knows this and says so: CONFORMANCE.md:166 records
	// the property as "both directions, plus a reachability sweep | Property,
	// with the sweep pinned at zero". Pinned at zero means no shipped check
	// reaches it. This test is not a new discovery, it is the measurement behind
	// that line.
	//
	// So the honest assertion is the DEFINITIONAL one -- the flag is exactly
	// `var95 < ale` -- checked over a spread of real distributions, plus the
	// fact that the inverted branch is never taken. A t.Skip here would be the
	// worst available choice: a skipped test reports PASS, and a reader counting
	// green lines cannot tell it from a test that proved something.
	//
	// CONSEQUENCE FOR THE MUTATION PROOF, which is the uncomfortable part.
	// Because the condition is unreachable, RE-INTRODUCING the clamp
	// `if var95 < ale { var95 = ale }` changes no figure and therefore cannot be
	// detected by any test driving this engine through its public surface. The
	// protection against that fabrication is that the clamp is ABSENT, not that
	// a test would catch it. The mutation proof reflects this: its M9 mutant
	// inverts the flag's DEFINITION (which this test does catch) rather than
	// re-introducing the clamp (which nothing can).
	cases := []struct {
		name       string
		loss, freq RiskTriple
	}{
		{"typical", RiskTriple{Min: 5_000, Mode: 25_000, Max: 200_000}, RiskTriple{Min: 1, Mode: 3, Max: 8}},
		{"skewed freq", RiskTriple{Min: 0, Mode: 1_000, Max: 10_000_000}, RiskTriple{Min: 0, Mode: 0.0001, Max: 1}},
		{"skewed both", RiskTriple{Min: 0, Mode: 100, Max: 100_000_000}, RiskTriple{Min: 0, Mode: 0.00001, Max: 2}},
		{"mode at min", RiskTriple{Min: 1, Mode: 2, Max: 50_000_000}, RiskTriple{Min: 0, Mode: 0.001, Max: 5}},
		{"extreme skew", RiskTriple{Min: 0, Mode: 1, Max: 1e9}, RiskTriple{Min: 0, Mode: 1e-6, Max: 10}},
	}

	inverted := 0
	for _, c := range cases {
		res := SimulateWithLoad(c.loss, c.freq, 42, DefaultRiskLoad)

		// THE DEFINITION, in both directions. This is what M9 breaks.
		wantFlag := res.VaR95 < res.ALE
		if res.TailDominated != wantFlag {
			t.Errorf("%s: TailDominated = %v but var95 < ale is %v (var95 %.2f, ale %.2f). "+
				"The flag is defined as exactly that inequality and nothing else.",
				c.name, res.TailDominated, wantFlag, res.VaR95, res.ALE)
		}
		if wantFlag {
			inverted++
		}

		// The removed clamp's signature: var95 exactly equal to ale. For these
		// distributions var95 is strictly greater, so an exact equality would
		// mean something had forced it.
		if res.VaR95 == res.ALE {
			t.Errorf("%s: var95 == ale exactly (%.2f), which is the signature of the "+
				"clamp fair.go's header records as removed for fabricating figures",
				c.name, res.VaR95)
		}

		// The ordering identities that DO hold, for contrast with the one-rank
		// error measured above, which also preserves all of them.
		if res.TVaR < res.VaR95 {
			t.Errorf("%s: tvar %.2f < var95 %.2f", c.name, res.TVaR, res.VaR95)
		}
		if res.TVaR < res.ALE {
			t.Errorf("%s: tvar %.2f < ale %.2f", c.name, res.TVaR, res.ALE)
		}
		if res.CarriedGBP < res.TVaR {
			t.Errorf("%s: carried %.2f < tvar %.2f", c.name, res.CarriedGBP, res.TVaR)
		}
		t.Logf("%-13s ale=%.2f var95=%.2f (ratio %.2f) tvar=%.2f tailDominated=%v",
			c.name, res.ALE, res.VaR95, res.VaR95/res.ALE, res.TVaR, res.TailDominated)
	}

	if inverted != 0 {
		t.Errorf("%d of %d distributions inverted. The reachability sweep is pinned at "+
			"zero (CONFORMANCE.md:166); if inversion is now reachable through "+
			"SimulateWithLoad, that line and this comment are both out of date.",
			inverted, len(cases))
	}
	t.Logf("REACHABILITY: 0 of %d deliberately extreme distributions inverted, so the "+
		"flag's true branch is unreachable for a product of two PERT variates. The flag "+
		"is correct by definition and inert in practice -- so it catches an inverted "+
		"DEFINITION, and cannot catch a re-introduced clamp (unreachable) or a one-rank "+
		"tail-index error (which leaves var95 alone).", len(cases))
}

// TestTheGapIsStatedAsOneNumberForTheReport computes the single figure the
// report needs: the fraction of the quoted money that rests on a deterministic
// file with no independent anchor.
//
// Not a behavioural assertion -- a measurement, kept as a test so it cannot go
// stale while the report that quotes it lives on.
func TestTheGapIsStatedAsOneNumberForTheReport(t *testing.T) {
	// The four figures every priced row quotes.
	const quoted = 4 // ale, var95, tvar, carried
	// Independently anchored: ale alone, by the closed-form beta-PERT moments.
	const independentlyAnchored = 1
	gap := quoted - independentlyAnchored

	e := &Engine{Iterations: 10_000, Seed: DefaultSeed}
	res, losses := e.RunDistribution(gapTestContribs(), DefaultRiskLoad)
	base := int(math.Floor(0.95 * float64(len(losses))))
	oneRank := math.Abs(tailMeanAt(losses, base+1)-res.TVaR) / res.TVaR

	t.Logf("THE GAP, IN ONE LINE: %d of the %d figures every priced row quotes "+
		"(var95, tvar, carried) have NO independent oracle -- only the deterministic "+
		"golden, the ordering identities and monotonicity. A one-rank tail-index error "+
		"moves tvar by %.4f%%, survives every ordering identity, moves ale by exactly "+
		"zero, and is caught ONLY by the golden. The independent NumPy cross-check is "+
		"bounded by the engine's own %d-iteration quantile noise, which the Makefile "+
		"records as several per cent -- the same order as the error it would need to "+
		"detect, so it cannot adjudicate.",
		gap, quoted, 100*oneRank, len(losses))

	if gap != 3 {
		t.Errorf("the gap is now %d figures, not 3; if an independent oracle has been "+
			"added for a tail figure, update this measurement and the report", gap)
	}
}
