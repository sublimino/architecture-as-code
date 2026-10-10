package main

// Money conformance: the four figures a scan reports per check (ale, var95,
// tvar, carriedGbp) are pinned by a committed golden file per pack and held to
// an independent analytic oracle plus a handful of structural properties.
//
// WHY THIS FILE EXISTS. Before it, every monetary figure the product reported
// was unproven. compliance_fixture_scan_test.go summed `r.CarriedGBP` over the
// scan's own rows and compared it to the summary's `TotalExposure` — but both
// sides came from the same fair.Simulate call in compliance.go, so the
// arithmetic was self-consistent and anchored to nothing. Nothing anywhere
// declared an expected monetary value for any check. The product sells PRICED
// risk, and a figure nobody checked is worse than no figure at all.
//
// WHY A GOLDEN FILE PER PACK AND NOT PER-FIXTURE EXPECTATIONS. The money is a
// pure function of (check ID, riskTriple, freqTriple) — compliance.go seeds the
// simulation from the check ID and reads the triples from the pack; nothing
// from the scanned object enters it. So the figure is a per-check constant.
// Writing it into fixtures would duplicate one constant across every fixture
// naming that check, make a single triple edit an N-fixture edit, and leave
// every check outside the chosen sample silent. One golden file per pack covers
// ALL checks, regenerates with `make verify-cel-money-golden`, and turns a
// triple change or an algorithm change into a reviewable diff.
//
// Golden comparison is EXACT. fair.Simulate is a seeded Monte Carlo over a PCG
// generator consumed in a fixed order, so for a given (triple, triple, seed) it
// is deterministic to the bit; there is no sampling tolerance to allow for and
// allowing one would hide exactly the drift the golden exists to catch. The
// only stated tolerance is on the ANALYTIC comparison, where it is a standard
// error rather than a guess (see compliance_money_oracle_test.go).

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

const moneyGoldenDir = "testdata/money-golden"

// moneyGoldenNote is embedded in every golden file so a reader who finds one in
// a diff knows what it is and how to regenerate it.
const moneyGoldenNote = "Engine-reported risk figures for every check in this pack. " +
	"ale/var95/tvar/carried are compared EXACTLY (see compliance_money_test.go); " +
	"analyticAle is the closed-form E[freq]*E[loss] from the beta-PERT triples and " +
	"aleSigma is the deviation of ale from it in standard errors (see compliance_money_oracle_test.go). " +
	"Regenerate with: make verify-cel-money-golden"

type moneyGolden struct {
	Framework  string           `json:"framework"`
	Version    string           `json:"version"`
	Currency   money.Currency   `json:"currency"`
	Iterations int              `json:"iterations"`
	Note       string           `json:"note"`
	Checks     []moneyGoldenRow `json:"checks"`
}

type moneyGoldenRow struct {
	Check string          `json:"check"`
	Seed  uint64          `json:"seed"`
	Risk  fair.RiskTriple `json:"riskTriple"`
	Freq  fair.RiskTriple `json:"freqTriple"`

	ALE     float64 `json:"ale"`
	VaR95   float64 `json:"var95"`
	TVaR    float64 `json:"tvar"`
	Carried float64 `json:"carried"`

	// TailDominated is the engine's own flag for VaR95 < ALE. It is recorded
	// because it changes the risk-financing reading of the figures (transfer
	// starts to beat further control spend), so a check joining or leaving the
	// set must be visible in review. See fair.RiskResult.TailDominated.
	TailDominated bool `json:"tailDominated"`

	// The analytic anchor, carried in the file so the diff shows whether a
	// figure moved toward or away from the closed form.
	AnalyticALE float64 `json:"analyticAle"`
	ALESigma    float64 `json:"aleSigma"`
}

// moneyFigures is a resolved set of figures, denominated.
type moneyFigures struct {
	ALE      float64
	VaR95    float64
	TVaR     float64
	Carried  float64
	Currency money.Currency
}

func (f moneyFigures) String() string {
	return fmt.Sprintf("ale=%.2f var95=%.2f tvar=%.2f carried=%.2f %s", f.ALE, f.VaR95, f.TVaR, f.Carried, f.Currency)
}

// engineFigures is the ONE place this harness derives a check's figures, and it
// derives them exactly the way handleScan does: same simulation, same seed
// derivation, same currency rounding. A second copy of that arithmetic in a
// test is a way for the harness and the service to drift apart silently.
func engineFigures(chk frameworks.Check) moneyFigures {
	r := fair.Simulate(chk.RiskTriple, chk.FreqTriple, checkSeed(chk.ID))
	return moneyFigures{
		ALE:      roundMoney(r.ALE, reportingCurrency),
		VaR95:    roundMoney(r.VaR95, reportingCurrency),
		TVaR:     roundMoney(r.TVaR, reportingCurrency),
		Carried:  roundMoney(r.CarriedGBP, reportingCurrency),
		Currency: reportingCurrency,
	}
}

func goldenRowFor(chk frameworks.Check) moneyGoldenRow {
	raw := fair.Simulate(chk.RiskTriple, chk.FreqTriple, checkSeed(chk.ID))
	f := engineFigures(chk)
	ana := analyticALE(chk.RiskTriple, chk.FreqTriple)
	se := analyticALEStdErr(chk.RiskTriple, chk.FreqTriple)
	sigma := 0.0
	if se > 0 {
		sigma = (f.ALE - ana) / se
	}
	return moneyGoldenRow{
		Check: chk.ID, Seed: checkSeed(chk.ID), Risk: chk.RiskTriple, Freq: chk.FreqTriple,
		ALE: f.ALE, VaR95: f.VaR95, TVaR: f.TVaR, Carried: f.Carried,
		TailDominated: raw.TailDominated,
		AnalyticALE:   round2(ana), ALESigma: round3(sigma),
	}
}

func goldenFor(p *conformancePack) moneyGolden {
	g := moneyGolden{
		Framework: p.fw.ID, Version: p.fw.Version, Currency: reportingCurrency,
		Iterations: simulateIterations, Note: moneyGoldenNote,
	}
	ids := append([]string(nil), p.order...)
	sort.Strings(ids) // stable file order, independent of pack layout
	for _, id := range ids {
		g.Checks = append(g.Checks, goldenRowFor(p.checks[id]))
	}
	return g
}

func moneyGoldenPath(p *conformancePack) string {
	return filepath.Join(moneyGoldenDir, p.fw.ID+"@"+p.fw.Version+".json")
}

func readMoneyGolden(path string) (moneyGolden, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return moneyGolden{}, err
	}
	var g moneyGolden
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&g); err != nil {
		return moneyGolden{}, fmt.Errorf("%s: %w", path, err)
	}
	return g, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// The golden files.
// ─────────────────────────────────────────────────────────────────────────────

// Every pack has a golden file; it covers exactly that pack's checks; and every
// figure in it equals what the engine computes, exactly.
func TestConformance_MoneyGoldenMatchesEngine(t *testing.T) {
	packs := loadConformancePacks(t, conformancePolicyRoot(t))
	rows := 0
	for _, p := range packs {
		path := moneyGoldenPath(p)
		g, err := readMoneyGolden(path)
		if err != nil {
			t.Errorf("%s: %v\nthe pack's figures are unproven; regenerate with: make verify-cel-money-golden", p.label(), err)
			continue
		}
		if g.Framework != p.fw.ID || g.Version != p.fw.Version {
			t.Errorf("%s: golden names %s@%s", path, g.Framework, g.Version)
		}
		if g.Currency != reportingCurrency {
			t.Errorf("%s: golden currency %q, want %q", path, g.Currency, reportingCurrency)
		}
		if g.Iterations != simulateIterations {
			t.Errorf("%s: golden iterations %d, want %d", path, g.Iterations, simulateIterations)
		}

		have := map[string]moneyGoldenRow{}
		for _, r := range g.Checks {
			if _, dup := have[r.Check]; dup {
				t.Errorf("%s: check %q appears twice", path, r.Check)
			}
			have[r.Check] = r
			if _, ok := p.checks[r.Check]; !ok {
				t.Errorf("%s: golden pins check %q which the pack does not have", path, r.Check)
			}
		}
		for _, id := range p.order {
			got, ok := have[id]
			if !ok {
				t.Errorf("%s: check %q has no pinned figures: its money is unproven", path, id)
				continue
			}
			rows++
			if want := goldenRowFor(p.checks[id]); got != want {
				t.Errorf("%s: check %q drifted\n golden %+v\n engine %+v", path, id, got, want)
			}
		}
	}
	if rows == 0 {
		t.Fatal("no golden rows checked: the money is unproven")
	}
	t.Logf("%d packs, %d pinned checks", len(packs), rows)
}

// The pins hold through the real handleScan and over the wire, not just against
// a direct fair.Simulate call.
func TestConformance_MoneyGoldenMatchesScan(t *testing.T) {
	root := conformancePolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	tr := handlerTransport{h}
	for _, p := range loadConformancePacks(t, root) {
		g, err := readMoneyGolden(moneyGoldenPath(p))
		if err != nil {
			continue // reported by TestConformance_MoneyGoldenMatchesEngine
		}
		body, err := json.Marshal(map[string]any{
			"namespace": "conformance", "frameworks": []string{p.fw.ID}, "policyVersion": p.fw.Version,
		})
		if err != nil {
			t.Fatal(err)
		}
		results, err := tr.scan(body)
		if err != nil {
			t.Errorf("%s: %v", p.label(), err)
			continue
		}
		rows := map[string]ComplianceScanResult{}
		for _, r := range results {
			rows[r.Check] = r
		}
		for _, want := range g.Checks {
			r, ok := rows[want.Check]
			if !ok {
				continue // version selection: not every pinned check carries this version
			}
			got := moneyFigures{ALE: r.ALE, VaR95: r.VaR95, TVaR: r.TVaR, Carried: r.CarriedGBP, Currency: r.Currency}
			pinned := moneyFigures{ALE: want.ALE, VaR95: want.VaR95, TVaR: want.TVaR, Carried: want.Carried, Currency: reportingCurrency}
			if got != pinned {
				t.Errorf("%s: check %q over the wire: pinned %s, scan reports %s", p.label(), want.Check, pinned, got)
			}
			if (r.Carried != money.Money{Amount: r.CarriedGBP, Currency: reportingCurrency}) {
				t.Errorf("%s: check %q: carried %v disagrees with carriedGbp %.2f/%s", p.label(), want.Check, r.Carried, r.CarriedGBP, reportingCurrency)
			}
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// The independent analytic anchor.
// ─────────────────────────────────────────────────────────────────────────────

// maxALESigma is how far the engine's ALE may sit from the closed-form mean,
// in standard errors of its own estimator. 5 sigma is a two-sided p of about
// 6e-7; across ~60 priced checks that is a false-alarm rate of roughly 1 in
// 30,000 runs, and the suite is deterministic so a pass today is a pass
// forever. Anything that moves a figure for a real reason — a different
// sampler, a lost scale factor, frequency and magnitude transposed, the wrong
// triple bound — moves it by far more than 5 sigma.
const maxALESigma = 5.0

// Every ALE the engine reports agrees with the closed-form beta-PERT product
// mean, and every figure lies inside the closed-form support. This is the one
// check in the suite that does not consult fair.go's implementation at all.
func TestConformance_MoneyAnalyticAnchor(t *testing.T) {
	var worstSigma, worstRel float64
	var worstCheck, worstRelCheck string
	priced, zero := 0, 0
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, id := range p.order {
			chk := p.checks[id]
			f := engineFigures(chk)
			ana := analyticALE(chk.RiskTriple, chk.FreqTriple)
			se := analyticALEStdErr(chk.RiskTriple, chk.FreqTriple)
			where := p.label() + " check " + id

			if zeroFrequency(chk.FreqTriple) {
				zero++
				if f != (moneyFigures{Currency: reportingCurrency}) {
					t.Errorf("%s: zero frequency must price at zero, got %s", where, f)
				}
				continue
			}
			priced++

			if se <= 0 {
				t.Errorf("%s: analytic standard error is %g for a priced check", where, se)
				continue
			}
			sigma := math.Abs(f.ALE-ana) / se
			rel := math.Abs(f.ALE-ana) / ana
			if sigma > worstSigma {
				worstSigma, worstCheck = sigma, where
			}
			if rel > worstRel {
				worstRel, worstRelCheck = rel, where
			}
			if sigma > maxALESigma {
				t.Errorf("%s: ale %.2f is %.2f sigma from the closed-form mean %.2f (se %.2f, rel %.4f%%); max %.1f sigma",
					where, f.ALE, sigma, ana, se, rel*100, maxALESigma)
			}

			lo, hi := analyticSupport(chk.RiskTriple, chk.FreqTriple)
			for _, v := range []struct {
				n string
				v float64
			}{{"ale", f.ALE}, {"var95", f.VaR95}, {"tvar", f.TVaR}} {
				if v.v < lo || v.v > hi {
					t.Errorf("%s: %s %.2f is outside the closed-form support [%.2f, %.2f]", where, v.n, v.v, lo, hi)
				}
			}
			// carried is tvar plus a 10% risk load, so it may exceed hi by up
			// to that load and no more.
			if f.Carried > hi*1.10+0.01 {
				t.Errorf("%s: carried %.2f exceeds the support ceiling plus the risk load (%.2f)", where, f.Carried, hi*1.10)
			}
		}
	}
	if priced == 0 {
		t.Fatal("no priced check reached the analytic oracle")
	}
	t.Logf("analytic anchor: %d priced checks, %d zero-frequency; worst %.2f sigma (%s), worst relative error %.4f%% (%s)",
		priced, zero, worstSigma, worstCheck, worstRel*100, worstRelCheck)
}

// The oracle's own arithmetic, against values derivable by hand. If these are
// wrong the anchor above is worthless, so they are pinned separately.
func TestConformance_MoneyAnalyticOracleSelfCheck(t *testing.T) {
	// The PERT mean is (min + 4*mode + max)/6 for any triple.
	for _, tr := range []fair.RiskTriple{
		{Min: 0, Mode: 1, Max: 2}, {Min: 5000, Mode: 25000, Max: 100000},
		{Min: 0.1, Mode: 0.5, Max: 0.9}, {Min: 500, Mode: 3000, Max: 20000},
	} {
		want := (tr.Min + 4*tr.Mode + tr.Max) / 6
		if got, _ := pertMoments(tr); math.Abs(got-want) > 1e-9 {
			t.Errorf("pertMoments(%v) mean = %g, want %g", tr, got, want)
		}
	}
	// A symmetric triple: alpha == beta == 3, so the variance is
	// span^2 * 9/252 = span^2/28. (0,1,2) -> 4/28.
	if _, v := pertMoments(fair.RiskTriple{Min: 0, Mode: 1, Max: 2}); math.Abs(v-4.0/28.0) > 1e-12 {
		t.Errorf("symmetric variance = %g, want %g", v, 4.0/28.0)
	}
	// A degenerate triple is the sampler's min branch: mean min, no variance.
	if m, v := pertMoments(fair.RiskTriple{Min: 7, Mode: 7, Max: 7}); m != 7 || v != 0 {
		t.Errorf("degenerate moments = (%g, %g), want (7, 0)", m, v)
	}
	// The product mean is the product of the means.
	loss := fair.RiskTriple{Min: 0, Mode: 6, Max: 6}   // mean 5
	freq := fair.RiskTriple{Min: 0, Mode: 0.5, Max: 4} // mean 1
	if got := analyticALE(loss, freq); math.Abs(got-5) > 1e-9 {
		t.Errorf("analyticALE = %g, want 5", got)
	}
	// Zero frequency prices at zero and has no standard error.
	if got := analyticALE(loss, fair.RiskTriple{}); got != 0 {
		t.Errorf("analyticALE with zero frequency = %g, want 0", got)
	}
	if got := analyticALEStdErr(loss, fair.RiskTriple{}); got != 0 {
		t.Errorf("analyticALEStdErr with zero frequency = %g, want 0", got)
	}
	// The standard error must shrink as sqrt(n): a sanity check that it is a
	// standard error of a mean and not a standard deviation.
	se := analyticALEStdErr(loss, freq)
	_, vf := pertMoments(freq)
	_, vl := pertMoments(loss)
	mf, _ := pertMoments(freq)
	ml, _ := pertMoments(loss)
	want := math.Sqrt(((vf+mf*mf)*(vl+ml*ml) - (mf*ml)*(mf*ml)) / float64(simulateIterations))
	if math.Abs(se-want) > 1e-12 {
		t.Errorf("analyticALEStdErr = %g, want %g", se, want)
	}
	// Support bounds.
	if lo, hi := analyticSupport(fair.RiskTriple{Min: 2, Mode: 3, Max: 4}, fair.RiskTriple{Min: 1, Mode: 2, Max: 5}); lo != 2 || hi != 20 {
		t.Errorf("analyticSupport = (%g, %g), want (2, 20)", lo, hi)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Properties.
// ─────────────────────────────────────────────────────────────────────────────

// TVaR >= VaR95 and TVaR >= ALE are genuine identities of a loss distribution
// and fair.Simulate corrects float noise against them; carried is TVaR plus a
// non-negative load.
//
// `VaR95 >= ALE` is NOT asserted, and the omission is deliberate. An earlier
// revision of fair.Simulate clamped VaR95 up to ALE; the clamp was removed
// because for a low-frequency/high-severity risk most simulated years cost
// nothing, so the 95th percentile legitimately sits below the mean and the
// clamp "silently reported a bad year equal to the average year" — a fabricated
// figure, in precisely the well-governed case a client most wants to see (see
// the note on fair.Simulate and fair/regression_test.go). The inversion is
// surfaced through TailDominated instead, and the test below holds the engine
// to that flag being exact rather than to an ordering that is not a property.
func TestConformance_MoneyFigureOrdering(t *testing.T) {
	checked := 0
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, id := range p.order {
			chk := p.checks[id]
			f := engineFigures(chk)
			where := p.label() + " check " + id
			checked++
			// The risk load is exactly 10% of the UNROUNDED tail mean (the
			// rounding happens once, at the reporting boundary). Pinned here
			// because "carried" is the figure the product actually bills, and a
			// load that silently moved would move every price in the estate.
			raw := fair.Simulate(chk.RiskTriple, chk.FreqTriple, checkSeed(id))
			if want := roundMoney(raw.TVaR*1.10, reportingCurrency); want != f.Carried {
				t.Errorf("%s: carried %.2f, want tvar+10%% = %.2f", where, f.Carried, want)
			}
			for _, v := range []struct {
				n string
				v float64
			}{{"ale", f.ALE}, {"var95", f.VaR95}, {"tvar", f.TVaR}, {"carried", f.Carried}} {
				if math.IsNaN(v.v) || math.IsInf(v.v, 0) || v.v < 0 {
					t.Errorf("%s: %s is %g; must be a finite non-negative amount", where, v.n, v.v)
				}
			}
			if f.TVaR < f.VaR95 {
				t.Errorf("%s: tvar %.2f < var95 %.2f; a tail mean cannot sit below its own threshold", where, f.TVaR, f.VaR95)
			}
			if f.TVaR < f.ALE {
				t.Errorf("%s: tvar %.2f < ale %.2f", where, f.TVaR, f.ALE)
			}
			if f.Carried < f.TVaR {
				t.Errorf("%s: carried %.2f < tvar %.2f; the risk load is non-negative", where, f.Carried, f.TVaR)
			}
		}
	}
	if checked == 0 {
		t.Fatal("no check examined")
	}
	t.Logf("ordering held for %d checks", checked)
}

// TailDominated is exactly VaR95 < ALE — in both directions. A flag that can be
// set when the ordering is conventional, or clear when it is inverted, is worse
// than no flag: it is how a fabricated "bad year equal to the average year"
// gets past review.
//
// FINDING, recorded here rather than asserted away. On the single-scenario
// Simulate path the flag appears to be UNREACHABLE for any triple, so
// `ALE <= VaR95` does hold across the whole estate today — but by accident of
// this path's construction, not as a property of loss distributions. Two
// structural reasons, both independent of fair.go's implementation:
//
//   - the beta-PERT parameterisation fixes alpha+beta = 6 for EVERY triple
//     (lambda=4 on the mode), which bounds how skewed one factor can be: the
//     most skewed attainable shape is Beta(1,5), at min == mode;
//   - Simulate multiplies a CONTINUOUS frequency draw by a magnitude draw, so
//     there are no zero-loss years. The zero-loss years are what push a mean
//     above its own 95th percentile, and they only appear on the aggregate
//     Engine.Run path, which draws Poisson event counts (see the comment on
//     Run, and fair/aggregate_test.go:TestEngineTailDominatedIsNotAnError).
//
// An independent numeric derivation (2e6-sample NumPy Beta draws, no Go code
// involved) puts P(Z <= E[Z]) at about 0.63-0.69 for the extremes of the
// attainable family — nowhere near the 0.95 needed to invert. So the sweep
// below pins reachability: if a sampler change, a different lambda, or Poisson
// counts on this path ever make inversion attainable, `extremesInverting`
// stops being 0, this test goes red, and the figures and the flag both have to
// be re-read before anyone ships.
func TestConformance_MoneyTailDominatedFlagIsExact(t *testing.T) {
	assertExact := func(where string, r fair.RiskResult) bool {
		inverted := r.VaR95 < r.ALE
		if r.TailDominated != inverted {
			t.Errorf("%s: tailDominated=%v but var95 %.2f vs ale %.2f", where, r.TailDominated, r.VaR95, r.ALE)
		}
		return inverted
	}

	shippedInverting, shipped := 0, 0
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, id := range p.order {
			chk := p.checks[id]
			shipped++
			if assertExact(p.label()+" check "+id, fair.Simulate(chk.RiskTriple, chk.FreqTriple, checkSeed(id))) {
				shippedInverting++
			}
		}
	}

	// A sweep over the extremes of the attainable beta-PERT family: maximum
	// skew (min == mode), maximum reverse skew (mode == max), symmetric,
	// degenerate, very wide spread, and a rare-but-severe risk. Several seeds
	// each, so the result is not one lucky draw.
	extremes := []struct {
		name string
		loss fair.RiskTriple
		freq fair.RiskTriple
	}{
		{"max skew both", fair.RiskTriple{Min: 0, Mode: 0, Max: 1_000_000}, fair.RiskTriple{Min: 0, Mode: 0, Max: 10}},
		{"max skew freq, symmetric loss", fair.RiskTriple{Min: 0, Mode: 500_000, Max: 1_000_000}, fair.RiskTriple{Min: 0, Mode: 0, Max: 10}},
		{"reverse skew both", fair.RiskTriple{Min: 0, Mode: 1_000_000, Max: 1_000_000}, fair.RiskTriple{Min: 0, Mode: 10, Max: 10}},
		{"rare and severe", fair.RiskTriple{Min: 1_000_000, Mode: 5_000_000, Max: 20_000_000}, fair.RiskTriple{Min: 0, Mode: 0.0001, Max: 0.02}},
		{"very wide spread", fair.RiskTriple{Min: 1, Mode: 1_000, Max: 100_000_000}, fair.RiskTriple{Min: 0.001, Mode: 0.01, Max: 5}},
		{"symmetric unit", fair.RiskTriple{Min: 0.1, Mode: 0.5, Max: 0.9}, fair.RiskTriple{Min: 0.1, Mode: 0.5, Max: 0.9}},
		{"degenerate loss", fair.RiskTriple{Min: 7, Mode: 7, Max: 7}, fair.RiskTriple{Min: 0, Mode: 1, Max: 3}},
	}
	extremesInverting := 0
	for _, e := range extremes {
		for _, seed := range []uint64{1, 2, 0xdeadbeef, checkSeed(e.name)} {
			if assertExact(fmt.Sprintf("extreme %q seed %d", e.name, seed), fair.Simulate(e.loss, e.freq, seed)) {
				extremesInverting++
			}
		}
	}
	if extremesInverting != 0 {
		t.Errorf("tail dominance has become reachable on the Simulate path (%d of %d extreme cases inverted): "+
			"ALE <= VaR95 can no longer be read as holding across the estate, and the flag is now load-bearing",
			extremesInverting, len(extremes)*4)
	}
	if shippedInverting != 0 {
		t.Errorf("%d shipped checks now invert (var95 < ale): the risk-financing reading of those packs has changed", shippedInverting)
	}
	t.Logf("tail dominance unreachable: %d of %d shipped checks and %d of %d extreme synthetic cases invert",
		shippedInverting, shipped, extremesInverting, len(extremes)*4)
}

// Exposure is monotonic in the risk triple: raise the mode, the carried figure
// does not fall. Checked over every priced check along a ladder of modes
// spanning its own min..max.
//
// Not covered by fair/aggregate_test.go, which pins monotonicity in FREQUENCY
// on the aggregate Engine path (TestEngineLoweringFrequencyLowersLoss); this is
// magnitude-mode monotonicity on the single-scenario Simulate path the policy
// engine actually calls.
//
// The simulation is a fixed-seed Monte Carlo, so monotonicity holds in
// expectation rather than pathwise: raising the mode changes the beta shape
// parameters, the rejection sampler consumes a different number of draws, and
// the sample path diverges. The ladder uses coarse steps so the signal is far
// larger than the sampling noise.
func TestConformance_MoneyExposureMonotoneInRiskMode(t *testing.T) {
	const steps = 10
	checked := 0
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, id := range p.order {
			chk := p.checks[id]
			if zeroFrequency(chk.FreqTriple) || chk.RiskTriple.Max <= chk.RiskTriple.Min {
				continue // identically zero, or no ladder to walk
			}
			checked++
			prev, prevMode := math.Inf(-1), 0.0
			for i := 0; i <= steps; i++ {
				mode := chk.RiskTriple.Min + (chk.RiskTriple.Max-chk.RiskTriple.Min)*float64(i)/steps
				got := fair.Simulate(fair.RiskTriple{Min: chk.RiskTriple.Min, Mode: mode, Max: chk.RiskTriple.Max}, chk.FreqTriple, checkSeed(id)).CarriedGBP
				if got < prev {
					t.Errorf("%s check %q: raising mode %.0f -> %.0f lowered carried %.2f -> %.2f", p.label(), id, prevMode, mode, prev, got)
				}
				prev, prevMode = got, mode
			}
		}
	}
	if checked == 0 {
		t.Fatal("no check exercised the monotonicity ladder")
	}
	t.Logf("ladder of %d modes over %d priced checks", steps+1, checked)
}

// The seed is derived from the check ID and nothing else, so the same check
// prices identically across packs and across process restarts (the golden files
// are the cross-restart half of that claim).
//
// fair's own suites pin that Simulate is deterministic for a fixed seed; what
// is pinned here is the policy engine's seed DERIVATION, which lives in
// compliance.go and nowhere in fair.
func TestConformance_MoneySeedDerivedFromCheckID(t *testing.T) {
	type seen struct {
		where string
		fig   moneyFigures
	}
	byKey := map[string]seen{}
	crossPack := 0
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, id := range p.order {
			chk := p.checks[id]
			key := fmt.Sprintf("%s|risk(%g,%g,%g)|freq(%g,%g,%g)", id,
				chk.RiskTriple.Min, chk.RiskTriple.Mode, chk.RiskTriple.Max,
				chk.FreqTriple.Min, chk.FreqTriple.Mode, chk.FreqTriple.Max)
			f := engineFigures(chk)
			if prev, dup := byKey[key]; dup {
				crossPack++
				if prev.fig != f {
					t.Errorf("check %q with identical triples prices %s in %s and %s in %s", id, prev.fig, prev.where, f, p.label())
				}
				continue
			}
			byKey[key] = seen{where: p.label(), fig: f}
		}
	}
	if crossPack == 0 {
		t.Error("no check ID is shared between packs with identical triples: cross-pack stability proved nothing")
	}

	// The ID is load-bearing: rename it and the figures move.
	base := frameworks.Check{ID: "no-privileged-containers",
		RiskTriple: fair.RiskTriple{Min: 25000, Mode: 120000, Max: 600000},
		FreqTriple: fair.RiskTriple{Min: 0.2, Mode: 0.8, Max: 2}}
	renamed := base
	renamed.ID = "no-privileged-containers-x"
	if checkSeed(base.ID) == checkSeed(renamed.ID) {
		t.Error("checkSeed collided on two distinct IDs")
	}
	if engineFigures(base) == engineFigures(renamed) {
		t.Error("renaming a check left every figure identical: the seed is not derived from the check ID")
	}
	// And the triples are load-bearing independently of the ID.
	wider := base
	wider.RiskTriple.Mode *= 1.5
	if engineFigures(base) == engineFigures(wider) {
		t.Error("raising the risk mode left every figure identical")
	}
}

// A not_evaluated row may carry a figure of its own; the summary counts none of
// it. TestScanContract_PlaceholderIsNotEvaluated pins the exclusion too, but
// every placeholder check shipped today has an all-zero frequency triple and so
// carries 0.00 — which makes that assertion vacuous on the exposure point. This
// drives the summary with a NON-ZERO figure on the not_evaluated row, which is
// the only way to see the exclusion actually happen.
func TestConformance_MoneyNotEvaluatedFigureExcludedFromExposure(t *testing.T) {
	row := func(v Verdict, carried float64) ComplianceScanResult {
		return ComplianceScanResult{
			Check: "synthetic", Status: v, Passed: v == VerdictPass,
			CarriedGBP: carried, Currency: reportingCurrency,
			Carried: money.Money{Amount: carried, Currency: reportingCurrency},
		}
	}
	h := &complianceHandler{lastResults: []ComplianceScanResult{
		row(VerdictNotEvaluated, 12_345.67),
		row(VerdictPass, 98_765.43),
		row(VerdictFail, 1_000),
	}}
	s, err := handlerTransport{h}.summary()
	if err != nil {
		t.Fatal(err)
	}
	if s.TotalExposure != 1_000 {
		t.Errorf("exposure %.2f, want 1000.00: the not_evaluated row's 12345.67 and the pass row's 98765.43 must not be counted", s.TotalExposure)
	}
	if s.NotEvaluated != 1 || s.Passed != 1 || s.Failed != 1 || s.Errored != 0 || s.TotalControls != 3 {
		t.Errorf("notEvaluated/passed/failed/errored/total = %d/%d/%d/%d/%d, want 1/1/1/0/3",
			s.NotEvaluated, s.Passed, s.Failed, s.Errored, s.TotalControls)
	}
	// The row keeps its own figure: it is reported, just not aggregated. This
	// is the honest statement of the "pass carries zero exposure" property —
	// the money is input-independent, so a passing ROW still carries a real
	// figure; it is the SUMMARY that excludes it.
	if h.lastResults[0].CarriedGBP != 12_345.67 || h.lastResults[1].CarriedGBP != 98_765.43 {
		t.Error("summarising mutated a row's figure")
	}
}

// Currency honesty. The reporting currency is a hardcoded package constant;
// pin that it is one, so a future multi-currency change cannot pass silently,
// and pin that money still refuses to add across denominations so the guard
// handleSummary would need is there to inherit. Row-level currency fields are
// already pinned by compliance_adversarial_scan_test.go; the summary side is
// not, so it is covered here.
func TestConformance_MoneyReportingCurrencyIsPinned(t *testing.T) {
	if reportingCurrency != "GBP" {
		t.Fatalf("reportingCurrency is %q, want GBP: every golden figure and the carriedGbp wire field assume GBP", reportingCurrency)
	}
	if err := reportingCurrency.Validate(); err != nil {
		t.Fatalf("reportingCurrency does not validate: %v", err)
	}
	if reportingCurrency.MinorUnits() != 2 {
		t.Fatalf("reportingCurrency minor units = %d, want 2: the golden figures are written to 2dp", reportingCurrency.MinorUnits())
	}
	if _, err := money.Add(money.Money{Amount: 1, Currency: "GBP"}, money.Money{Amount: 1, Currency: "USD"}); err == nil {
		t.Error("money.Add accepted GBP + USD: the cross-currency guard the summary would inherit is gone")
	}
	if _, err := money.Sum(money.Money{Amount: 1, Currency: "GBP"}, money.Money{Amount: 1, Currency: "EUR"}); err == nil {
		t.Error("money.Sum accepted GBP + EUR")
	}

	root := conformancePolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	tr := handlerTransport{h}
	for _, p := range loadConformancePacks(t, root) {
		body, err := json.Marshal(map[string]any{"frameworks": []string{p.fw.ID}, "policyVersion": p.fw.Version})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tr.scan(body); err != nil {
			t.Errorf("%s: %v", p.label(), err)
			continue
		}
		s, err := tr.summary()
		if err != nil {
			t.Errorf("%s: %v", p.label(), err)
			continue
		}
		if s.Currency != reportingCurrency {
			t.Errorf("%s: summary currency %q, want %q", p.label(), s.Currency, reportingCurrency)
		}
		if s.Exposure != (money.Money{Amount: s.TotalExposure, Currency: reportingCurrency}) {
			t.Errorf("%s: summary exposure %v disagrees with totalExposureGbp %.2f", p.label(), s.Exposure, s.TotalExposure)
		}
	}
}

// FINDING, pinned so it stays visible: four shipped packs declare a riskTriple
// but NO freqTriple at all. fair.Simulate short-circuits an all-zero frequency
// to a zero result, so every check in those packs prices at 0.00 and a scan of
// them reports ZERO total exposure however many controls fail — for 64 of the
// estate's 127 checks. This is not a test failure, because the engine does what
// it says; it is the packs that are incomplete. Pinning the set means the
// moment a freqTriple is added the golden goes red and the new figures have to
// be re-proved, and it means nobody can quietly ship another silent-zero pack.
func TestConformance_MoneyPacksWithoutFreqTriplePriceAtZero(t *testing.T) {
	// Two groups, deliberately separated. dora and nis2 are all-placeholder
	// packs: their single check is never evaluated and carries an explicit
	// all-zero triple, so pricing at zero is correct. The other four are the
	// finding: real, evaluated checks with a loss magnitude and no frequency.
	wantPlaceholder := map[string]bool{
		"dora/v1.0": true,
		"nis2/v1.0": true,
	}
	wantFinding := map[string]bool{
		"eu-ai-act/v1.0":   true,
		"eu-ai-act/v2.0":   true,
		"nist-800-53/v1.0": true,
		"nist-800-53/v2.0": true,
	}
	want := map[string]bool{}
	for k := range wantPlaceholder {
		want[k] = true
	}
	for k := range wantFinding {
		want[k] = true
	}
	got := map[string]bool{}
	allPlaceholder := map[string]bool{}
	zeroChecks, allChecks := 0, 0
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		zero := 0
		for _, id := range p.order {
			chk := p.checks[id]
			allChecks++
			if !zeroFrequency(chk.FreqTriple) {
				continue
			}
			zero++
			zeroChecks++
			if f := engineFigures(chk); f != (moneyFigures{Currency: reportingCurrency}) {
				t.Errorf("%s: check %q has no frequency triple but prices at %s", p.label(), id, f)
			}
		}
		if zero > 0 && zero == len(p.order) {
			got[p.label()] = true
			ph := 0
			for _, id := range p.order {
				if p.placeholder(id) {
					ph++
				}
			}
			if ph == len(p.order) {
				allPlaceholder[p.label()] = true
			}
		}
	}
	if !equalStringSets(want, got) {
		t.Errorf("the set of packs that price every check at zero changed:\n have %v\n want %v\n"+
			"a pack leaving this set must have its golden regenerated and its new figures proved; a pack joining it has lost its frequency data",
			sortedSetKeys(got), sortedSetKeys(want))
	}
	// And the split has to stay honest: a pack in the finding group must NOT be
	// all-placeholder (otherwise the zero is correct and the finding evaporates),
	// and a pack in the placeholder group must be.
	if !equalStringSets(wantPlaceholder, allPlaceholder) {
		t.Errorf("the all-placeholder packs among the zero-priced ones changed:\n have %v\n want %v\n"+
			"a finding-group pack that became all-placeholder prices at zero legitimately; a placeholder-group pack that gained a real check does not",
			sortedSetKeys(allPlaceholder), sortedSetKeys(wantPlaceholder))
	}
	t.Logf("%d of %d checks across the estate price at zero for want of a frequency triple; %d of those packs are all-placeholder (zero is correct), %d are not (finding)",
		zeroChecks, allChecks, len(wantPlaceholder), len(wantFinding))
}

// ─────────────────────────────────────────────────────────────────────────────
// Golden updater. Writes the files; asserts nothing. Run via the make target.
// ─────────────────────────────────────────────────────────────────────────────

func TestWriteMoneyGolden(t *testing.T) {
	if os.Getenv("MONEY_GOLDEN") != "update" {
		t.Skip("set MONEY_GOLDEN=update (or run `make verify-cel-money-golden`) to rewrite the golden files")
	}
	if err := os.MkdirAll(moneyGoldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		path := moneyGoldenPath(p)
		raw, err := json.MarshalIndent(goldenFor(p), "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s (%d checks)", path, len(p.order))
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// helpers
// ─────────────────────────────────────────────────────────────────────────────

func round2(v float64) float64 { return math.Round(v*100) / 100 }
func round3(v float64) float64 { return math.Round(v*1000) / 1000 }

func sortedSetKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func equalStringSets(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}
