// Package baseline evaluates an agent's compliance posture against a versioned policy pack and an
// institution's risk posture, and turns the result into a cash value.
//
// The chain, end to end:
//
//	agent posture  x  policy pack   ->  per-control verdict (PASS / FAIL-audited / FAIL-gated)
//	                                ->  graded enforcement tier (trusted..denied), selected by the £
//	     x  org risk posture        ->  territory scoping (which scenarios can be incurred HERE)
//	                                ->  aggregate annual-loss distribution (FAIR)
//	                                ->  ALE / VaR95 / TVaR / carried
//	                                ->  Total Cost of Risk = residual + controls + transfer
//	                                ->  per-control "what tightening this buys", in money
//
// WHERE CURRENCY CONVERSION HAPPENS, AND WHY IT HAPPENS THERE.
//
// The report has ONE reporting currency: the institution's own, from its `currency:` field. Every
// figure in the report is expressed in it, and every comparison and sum is performed in it. That is
// not a presentation detail — it is what makes the verdicts sound. Two of the terms in Total Cost of
// Risk come from different files that may be denominated differently (control run-costs from the
// PACK, loss magnitudes and the tolerance band from the ORG), and both the tolerance test and the
// tier selection are threshold comparisons. Comparing 30,000 USD against a 25,000 GBP band answers
// "yes" when the truth is "no": a wrong VERDICT, not merely a wrong number.
//
// So conversion happens at exactly two places, both as early as possible and both exactly once:
//
//   - loss magnitude triples are converted into the reporting currency BEFORE they reach the
//     sampler, so the Monte Carlo runs in a single denomination throughout;
//   - pack-sourced costs are converted as they are read, before they are summed.
//
// Converting the magnitude triple once (three multiplications) rather than each drawn sample
// (200,000 iterations x N scenarios x Poisson event count) is the difference between three rounding
// opportunities and hundreds of millions of them. Conversion is a scalar multiply and every FAIR
// output statistic — mean, percentile, tail mean — is positively homogeneous of degree one in the
// magnitude, so scaling the inputs and scaling the outputs are the same operation in exact
// arithmetic. Doing it on the inputs, once, is the version with no accumulation.
//
// Nothing is rounded anywhere in this package. Rounding is presentation-only and belongs to the
// caller. See the money package for that decision and its justification.
//
// THE REGRESSION ANCHOR. When the magnitude currency equals the reporting currency the conversion
// rate is the literal 1.0 and `x * 1.0 == x` bit-exactly in IEEE-754, so the entire GBP->GBP path
// is byte-identical to the behaviour before currency existed. That is deliberate: it is what makes
// the existing FAIR expectations a genuine regression test of this change rather than a rewrite.
package baseline

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/acme-co/osramp/tools/riskctl/internal/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// Verdict is the per-control outcome of the baseline.
type Verdict string

const (
	// VerdictPass — the agent asserts the control, with evidence.
	VerdictPass Verdict = "PASS"
	// VerdictAudited — the control is unmet, but the pack only lane-keeps it. The agent runs and
	// carries a priced residual.
	VerdictAudited Verdict = "FAIL-AUDITED"
	// VerdictGated — the control is unmet and the pack gates on it. Under strict admission the
	// agent would not be admitted; under the graded envelope it is caged instead of denied.
	VerdictGated Verdict = "FAIL-GATED"
	// VerdictUnclaimed — the posture says nothing about this control at all. Treated exactly as
	// unmet: silence is not compliance.
	VerdictUnclaimed Verdict = "UNCLAIMED"
)

// ControlResult is one line of the compliance baseline.
type ControlResult struct {
	Control  model.Control
	Verdict  Verdict
	Met      bool
	Evidence string
	Note     string
	// EffectiveLEF is the frequency actually fed to the simulation for this control, after
	// posture, enforcement action and drift are applied (before the cage multiplier).
	EffectiveLEF model.Triple
	// InScope is false when this control's loss scenario cannot be incurred in this institution's
	// jurisdiction. The control is still evaluated and still reported — an out-of-territory control
	// can still be satisfied or unsatisfied — but it contributes nothing to the exposure.
	InScope bool
	// AnnualCost is the control's run cost, converted into the report's currency.
	AnnualCost money.Money
}

// ScenarioScope records whether a loss scenario counted toward this institution's exposure, and
// why. It exists so that territory filtering is VISIBLE rather than merely applied.
//
// A total that silently omits scenarios is unexplainable: a reader who knows the pack has five
// scenarios and sees a number built from three has no way to tell a deliberate jurisdictional
// exclusion from a bug, a typo in a scenario ID, or a missing magnitude. Every scenario the pack
// references appears here with its verdict and its reason, included and excluded alike.
type ScenarioScope struct {
	Scenario    string
	Title       string
	Territories []string
	Included    bool
	Reason      string
	// Controls names the controls that defend this scenario, so an excluded scenario also explains
	// which controls stopped contributing.
	Controls []string
}

// Exposure is the aggregate loss distribution expressed in the report's currency.
//
// fair.Result deliberately holds bare float64s: the FAIR engine is currency-agnostic maths that
// operates on whatever denomination its inputs carried, and giving a distribution sampler opinions
// about currency would be the wrong place for them. Exposure is the boundary where those numbers
// acquire the denomination the caller must see, and it is what serialises to JSON.
type Exposure struct {
	ALE     money.Money `json:"ale"`
	VaR95   money.Money `json:"var95"`
	TVaR    money.Money `json:"tvar"`
	Carried money.Money `json:"carried"`
}

// Report is the complete output of a baseline run.
type Report struct {
	AgentName     string
	AgentDisplay  string
	OrgName       string
	OrgDisplay    string
	Jurisdiction  string
	PackName      string
	PackClaimed   string
	PackEvaluated string
	// Stale is true when the agent claims an older pack version than the one it is evaluated
	// against — the laggard case.
	Stale bool

	// Currency is the reporting denomination. Every money figure below is expressed in it.
	Currency money.Currency
	// RatesAsOf is the effective date of the rate table consulted, empty if no conversion was
	// needed. It travels with the report so a reader can tell which table produced the figures.
	RatesAsOf string
	// Conversions lists each distinct currency pair converted, with its rate — the working, shown.
	Conversions []money.Converted

	Results []ControlResult

	// Scope explains which loss scenarios counted for this institution and which did not.
	Scope []ScenarioScope
	// NoApplicableScenarios is true when territory scoping excluded EVERY scenario. The exposure is
	// then genuinely zero, but a bare zero reads as a verdict ("no risk") when it actually means
	// "this pack prices nothing that can happen here". Callers must say which.
	NoApplicableScenarios bool

	Tier           string
	TierReason     string
	CageMultiplier float64
	CageCost       money.Money

	// Risk is the raw, undenominated simulation output. Prefer Exposure for anything a human reads.
	Risk fair.Result
	// Exposure is Risk expressed in the reporting currency.
	Exposure Exposure

	ControlSpend  money.Money // annual cost of the controls actually in place, plus the cage
	FrictionSpend money.Money // operational cost of gating: blocked deploys, false positives, unblocking
	TransferSpend money.Money // insurance premium
	TCoR          money.Money // residual (carried) + control spend + friction + transfer

	// PremiumRatio is modelled ALE divided by the annual cyber premium. The premium is a third
	// party's priced view of substantially the same controls, so this is the one genuinely
	// EXTERNAL calibration anchor available for free. A ratio near 1 means the model agrees with
	// the market; far from 1 means one of the two is wrong, and saying which is the interesting
	// conversation.
	//
	// Dimensionless by construction: both terms are in the reporting currency, so the ratio is
	// currency-invariant and means the same thing whichever denomination the report is read in.
	PremiumRatio float64

	Deltas  []Delta
	Tornado []Sensitivity

	Tolerance   money.Money
	Escalations []string
}

// Sensitivity is one row of a one-way tornado analysis: how far the headline number swings when a
// single scenario's loss magnitude is driven to the bottom and top of its calibrated range, with
// everything else held still.
//
// This matters more than the fixed seed. Determinism proves the implementation is reproducible; it
// says nothing about whether the inputs are right. A seeded generator returns the same wrong number
// every time. The tornado converts "trust my triples" into "the answer is dominated by this one
// assumption — argue with that one", which is a far better defence of the number and a far more
// honest invitation to disagree.
type Sensitivity struct {
	Scenario string
	LowALE   money.Money
	HighALE  money.Money
	Swing    money.Money
	// SharePct is this scenario's share of the total swing across all scenarios.
	SharePct float64
}

// Delta answers "what would tightening this control buy?", per year.
type Delta struct {
	ControlID string
	Title     string
	// Buys is ALE_now - ALE_if_this_control_were_met. The hub's "£ a control buys".
	Buys money.Money
	// Cost is the control's annual run cost, in the reporting currency.
	Cost money.Money
	// Net is Buys - Cost. Positive means implementing it is cheaper than carrying it.
	Net money.Money
	// AboveTolerance is true when Buys exceeds the institution's tolerance band, which is the
	// quantitative trigger for promoting the control to the gate. Both sides of that comparison are
	// in the reporting currency; a cross-currency comparison here would produce a wrong verdict and
	// is refused by money.GreaterThan rather than silently performed.
	AboveTolerance bool
}

// driftWeight controls how much credit an unenforced-but-implemented control receives.
//
// A control that is implemented but only lane-kept (action: audit) can silently regress — nothing
// stops a workload that has stopped satisfying it. We therefore do not award it the full enforced
// frequency. The effective frequency is the geometric mean of the audit and enforced triples,
// i.e. the midpoint in log space. Geometric rather than arithmetic because frequencies span orders
// of magnitude and the arithmetic mean would be dominated by the unmitigated value.
const driftWeight = 0.5

func geoBlend(a, b model.Triple, w float64) model.Triple {
	g := func(x, y float64) float64 {
		if x <= 0 || y <= 0 {
			return (1-w)*x + w*y
		}
		return pow(x, 1-w) * pow(y, w)
	}
	return model.Triple{
		Min:  g(a.Min, b.Min),
		Mode: g(a.Mode, b.Mode),
		Max:  g(a.Max, b.Max),
	}
}

func scale(t model.Triple, m float64) model.Triple {
	return model.Triple{Min: t.Min * m, Mode: t.Mode * m, Max: t.Max * m}
}

// effectiveLEF resolves the frequency actually used for a control.
//
//	unmet                  -> lef_audit     (the control is simply absent)
//	met and action=deny    -> lef_enforced  (in place and guaranteed to stay in place)
//	met and action=audit   -> geometric blend (in place, but free to drift)
func effectiveLEF(c model.Control, met bool) model.Triple {
	if !met {
		return c.LEFAudit
	}
	if c.Action == model.ActionDeny {
		return c.LEFEnforced
	}
	return geoBlend(c.LEFAudit, c.LEFEnforced, driftWeight)
}

// Options tune a run.
type Options struct {
	Iterations int
	Seed       int64
	// Rates is the checked-in FX table. It may be nil, in which case any conversion between two
	// different currencies is an error naming the pair — never a silent 1.0. A run whose inputs are
	// all in one currency needs no table, because same-currency is an identity rather than a
	// conversion.
	Rates *money.RateTable
}

// converter resolves amounts into the report's single reporting currency, recording each distinct
// pair it touches so the report can show its working.
type converter struct {
	target money.Currency
	rates  *money.RateTable
	seen   map[string]bool
	log    []money.Converted
}

func newConverter(target money.Currency, rates *money.RateTable) *converter {
	return &converter{target: target, rates: rates, seen: map[string]bool{}}
}

// rate returns the multiplier from `from` into the reporting currency.
//
// Same-currency returns the literal 1.0 without consulting the table at all, which is both correct
// (it is an identity, not a conversion) and the reason a single-currency estate needs no rate table
// and reproduces its previous figures bit for bit.
func (c *converter) rate(from money.Currency, context string) (float64, error) {
	if from == c.target {
		return 1.0, nil
	}
	if c.rates == nil {
		return 0, fmt.Errorf("%s: cannot convert %s -> %s because no FX rate table was supplied. "+
			"A conversion is never silently assumed to be 1.0; load risk/fx/rates.yaml and pass it in",
			context, from, c.target)
	}
	conv, err := c.rates.Convert(money.Money{Amount: 1, Currency: from}, c.target)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", context, err)
	}
	if key := string(from) + "->" + string(c.target); !c.seen[key] {
		c.seen[key] = true
		c.log = append(c.log, conv)
	}
	return conv.Rate, nil
}

// money converts a single amount into the reporting currency.
func (c *converter) money(m money.Money, context string) (money.Money, error) {
	if err := m.Validate(context); err != nil {
		return money.Money{}, err
	}
	r, err := c.rate(m.Currency, context)
	if err != nil {
		return money.Money{}, err
	}
	if r == 1.0 {
		return money.Money{Amount: m.Amount, Currency: c.target}, nil
	}
	return money.Money{Amount: m.Amount * r, Currency: c.target}, nil
}

// triple converts all three points of a magnitude triple with a SINGLE rate lookup, so the three
// points cannot end up scaled by three different numbers and the ordering invariant min <= mode <=
// max is preserved by construction (a positive scalar is monotone).
func (c *converter) triple(t model.Triple, from money.Currency, context string) (model.Triple, error) {
	r, err := c.rate(from, context)
	if err != nil {
		return model.Triple{}, err
	}
	if r == 1.0 {
		return t, nil // bit-exact identity: the regression anchor
	}
	return model.Triple{Min: t.Min * r, Mode: t.Mode * r, Max: t.Max * r}, nil
}

// zero returns a zero amount in the reporting currency — never a bare 0.0, which has no
// denomination and would be silently addable to anything.
func (c *converter) zero() money.Money { return money.Money{Amount: 0, Currency: c.target} }

// Run produces the complete baseline report.
func Run(pack *model.Pack, agent *model.AgentPosture, org *model.OrgRiskPosture, opt Options) (*Report, error) {
	conv := newConverter(org.Currency, opt.Rates)

	rep := &Report{
		AgentName:     agent.Metadata.Name,
		AgentDisplay:  agent.Metadata.DisplayName,
		OrgName:       org.Metadata.Name,
		OrgDisplay:    org.Metadata.DisplayName,
		Jurisdiction:  org.Metadata.Jurisdiction,
		PackName:      pack.Metadata.Name,
		PackClaimed:   agent.Claims.Version,
		PackEvaluated: pack.Metadata.Version,
		Stale:         agent.Claims.Version != pack.Metadata.Version,
		Currency:      org.Currency,
		Tolerance:     org.Appetite.Tolerance,
	}

	// 0. Territory scoping. Decide which loss scenarios this institution can actually incur, before
	//    anything is priced. A scenario scoped to the UK is not a loss a US provider can suffer, and
	//    pricing it into their exposure inflates the number in a way an informed reader will catch.
	inScope, scope, err := scopeScenarios(pack, org)
	if err != nil {
		return nil, err
	}
	rep.Scope = scope

	// 1. Per-control verdicts, in pack order so output is deterministic.
	//    Controls are evaluated regardless of territory: an out-of-scope control can still be
	//    satisfied or unsatisfied, and hiding it would misreport the compliance baseline. Only its
	//    contribution to the EXPOSURE is suppressed.
	unmetGated := 0
	for _, c := range pack.Controls {
		s, claimed := agent.Met(c.ID)
		met := claimed && s.Met

		v := VerdictPass
		switch {
		case !claimed:
			v = VerdictUnclaimed
		case !met && c.Action == model.ActionDeny:
			v = VerdictGated
		case !met:
			v = VerdictAudited
		}
		if !met && c.Action == model.ActionDeny {
			unmetGated++
		}

		cost, err := conv.money(c.AnnualCost, fmt.Sprintf("control %s annual_cost", c.ID))
		if err != nil {
			return nil, err
		}

		rep.Results = append(rep.Results, ControlResult{
			Control:      c,
			Verdict:      v,
			Met:          met,
			Evidence:     s.Evidence,
			Note:         s.Note,
			EffectiveLEF: effectiveLEF(c, met),
			InScope:      inScope[c.Scenario],
			AnnualCost:   cost,
		})
	}

	// 2. Conditional branches the agent has elected replace the relaxed control's frequency with
	//    the branch's own priced residual. Choosing autonomy is allowed; it is not free.
	for _, cd := range pack.Conditional {
		if !agent.Elected(cd.ID) {
			continue
		}
		for i := range rep.Results {
			if rep.Results[i].Control.ID == cd.Relaxes {
				rep.Results[i].EffectiveLEF = cd.LEFResidual
				rep.Results[i].Note = fmt.Sprintf("%s [conditional %s elected: %s]",
					rep.Results[i].Note, cd.ID, cd.Title)
			}
		}
	}

	eng := &fair.Engine{Iterations: opt.Iterations, Seed: opt.Seed}
	if eng.Iterations == 0 {
		eng.Iterations = fair.DefaultIterations
	}
	if eng.Seed == 0 {
		eng.Seed = fair.DefaultSeed
	}

	// Magnitudes, converted into the reporting currency ONCE, up front. Everything downstream of
	// here — every simulation, every hypothetical, every tornado leg — reads this map, so the
	// conversion cannot be applied twice or inconsistently between two legs of the same comparison.
	magnitude := map[string]model.Triple{}
	for id, m := range org.Magnitude {
		t, err := conv.triple(m.Triple, m.Currency, fmt.Sprintf("magnitude %s", id))
		if err != nil {
			return nil, err
		}
		magnitude[id] = t
	}

	// build assembles the simulation inputs, aggregating PER SCENARIO rather than per control.
	//
	// This is the weakest-link rule, and it matters. Several controls defend the same loss
	// scenario: AGT-001, AGT-002, AGT-007 and AGT-010 all bear on secret exfiltration. Summing
	// their frequencies would count one incident four times and inflate the £ into fantasy.
	//
	// An attacker needs one way in, so the scenario's loss event frequency is set by its WEAKEST
	// remaining control — the maximum effective LEF across the controls guarding it. Magnitude is
	// then drawn once per event, from the institution's triple for that scenario.
	//
	// The consequence for the deltas is deliberate and honest: tightening a control that is not
	// the weakest link in its scenario buys nothing until the weakest link is fixed. That is a
	// true statement about defence in depth, and a report that hid it would be flattering rather
	// than useful.
	build := func(mult float64, override map[string]model.Triple) ([]fair.Contribution, error) {
		type acc struct {
			lef     model.Triple
			driverA string
		}
		byScenario := map[string]*acc{}
		var order []string

		for _, r := range rep.Results {
			// Out-of-territory scenarios contribute nothing. Their magnitude is not even required
			// to be declared: an institution should not have to price a loss it cannot incur.
			if !inScope[r.Control.Scenario] {
				continue
			}
			if _, ok := magnitude[r.Control.Scenario]; !ok {
				return nil, fmt.Errorf("org %s declares no loss magnitude for scenario %s (needed by control %s)",
					org.Metadata.Name, r.Control.Scenario, r.Control.ID)
			}
			lef := r.EffectiveLEF
			if o, ok := override[r.Control.ID]; ok {
				lef = o
			}
			cur, seen := byScenario[r.Control.Scenario]
			if !seen {
				byScenario[r.Control.Scenario] = &acc{lef: lef, driverA: r.Control.ID}
				order = append(order, r.Control.Scenario)
				continue
			}
			// Weakest link: the control leaving the highest residual frequency sets the scenario.
			if lef.Mode > cur.lef.Mode {
				cur.lef = lef
				cur.driverA = r.Control.ID
			}
		}

		out := make([]fair.Contribution, 0, len(order))
		for _, sc := range order { // pack order — deterministic
			a := byScenario[sc]
			out = append(out, fair.Contribution{
				ControlID: a.driverA,
				Scenario:  sc,
				LEF:       scale(a.lef, mult),
				Magnitude: magnitude[sc],
			})
		}
		return out, nil
	}

	// 3. Uncaged residual first — the £ is what selects the cage tier, per the graded-enforcement
	//    design. Enforcement severity is justified by a number, not by a timer or an opinion.
	uncaged, err := build(1.0, nil)
	if err != nil {
		return nil, err
	}
	rep.NoApplicableScenarios = len(uncaged) == 0
	pre := eng.Run(uncaged, org.RiskLoad)

	tierName, reason := selectTier(pack, unmetGated, pre.ALE, org.Appetite.Tolerance.Amount)
	if rep.NoApplicableScenarios {
		reason += "; NOTE: territory scoping excluded every loss scenario in this pack, so the residual " +
			"is zero because nothing here is priced, not because the estate is safe"
	}
	cage := pack.Cages[tierName]
	rep.Tier = tierName
	rep.TierReason = reason
	rep.CageMultiplier = cage.Multiplier
	cageCost, err := conv.money(cage.AnnualCost, fmt.Sprintf("cage %s annual_cost", tierName))
	if err != nil {
		return nil, err
	}
	rep.CageCost = cageCost

	// 4. Final residual with the cage applied.
	caged, err := build(cage.Multiplier, nil)
	if err != nil {
		return nil, err
	}
	rep.Risk = eng.Run(caged, org.RiskLoad)
	if err := rep.Risk.SelfCheck(); err != nil {
		return nil, err
	}
	rep.Exposure = Exposure{
		ALE:     money.Money{Amount: rep.Risk.ALE, Currency: conv.target},
		VaR95:   money.Money{Amount: rep.Risk.VaR95, Currency: conv.target},
		TVaR:    money.Money{Amount: rep.Risk.TVaR, Currency: conv.target},
		Carried: money.Money{Amount: rep.Risk.Carried, Currency: conv.target},
	}

	// 5. Total Cost of Risk = residual you keep + what the controls cost + what gating costs
	//    operationally + what you transferred.
	//
	//    Every term is added through money.Add, which refuses to sum two denominations. The control
	//    terms originate in the PACK and the residual and transfer terms in the ORG, so this sum is
	//    precisely where a currency mismatch would otherwise have produced a plausible, wrong, and
	//    entirely unremarkable-looking board figure.
	rep.ControlSpend = conv.zero()
	rep.FrictionSpend = conv.zero()
	friction, err := conv.money(pack.Friction.PerDenyControl, "enforcement_friction.per_deny_control")
	if err != nil {
		return nil, err
	}
	for _, r := range rep.Results {
		if r.Met {
			if rep.ControlSpend, err = money.Add(rep.ControlSpend, r.AnnualCost); err != nil {
				return nil, fmt.Errorf("control spend, at %s: %w", r.Control.ID, err)
			}
		}
		// Friction is incurred by every control that GATES, whether or not the agent passes it:
		// the deploy is blocked, someone investigates, someone unblocks it.
		if r.Control.Action == model.ActionDeny {
			if rep.FrictionSpend, err = money.Add(rep.FrictionSpend, friction); err != nil {
				return nil, fmt.Errorf("friction spend, at %s: %w", r.Control.ID, err)
			}
		}
	}
	if rep.ControlSpend, err = money.Add(rep.ControlSpend, rep.CageCost); err != nil {
		return nil, fmt.Errorf("control spend, adding the cage: %w", err)
	}
	if rep.TransferSpend, err = conv.money(org.Transfer.AnnualPremium, "transfer.annual_premium"); err != nil {
		return nil, err
	}
	if rep.TCoR, err = money.Sum(rep.Exposure.Carried, rep.ControlSpend, rep.FrictionSpend, rep.TransferSpend); err != nil {
		return nil, fmt.Errorf("total cost of risk: %w", err)
	}
	if rep.TransferSpend.Amount > 0 {
		// Both terms are in the reporting currency, so the ratio is dimensionless and reads the
		// same whichever denomination the report is rendered in.
		rep.PremiumRatio = rep.Exposure.ALE.Amount / rep.TransferSpend.Amount
	}

	// 6. Per-control deltas: what would tightening each unmet control buy?
	for _, r := range rep.Results {
		if r.Met {
			continue
		}
		// A control defending a scenario this institution cannot incur buys nothing here, by
		// construction. Reporting a delta for it would invite spending money to remove a risk that
		// does not exist in this jurisdiction.
		if !r.InScope {
			continue
		}
		override := map[string]model.Triple{
			r.Control.ID: effectiveLEF(r.Control, true),
		}
		hyp, err := build(cage.Multiplier, override)
		if err != nil {
			return nil, err
		}
		res := eng.Run(hyp, org.RiskLoad)
		buys := money.Money{Amount: rep.Risk.ALE - res.ALE, Currency: conv.target}
		net, err := buys.Sub(r.AnnualCost)
		if err != nil {
			return nil, fmt.Errorf("delta for %s: %w", r.Control.ID, err)
		}
		above, err := buys.GreaterThan(org.Appetite.Tolerance)
		if err != nil {
			return nil, fmt.Errorf("tolerance test for %s: %w", r.Control.ID, err)
		}
		d := Delta{
			ControlID:      r.Control.ID,
			Title:          r.Control.Title,
			Buys:           buys,
			Cost:           r.AnnualCost,
			Net:            net,
			AboveTolerance: above,
		}
		rep.Deltas = append(rep.Deltas, d)
		if d.AboveTolerance && r.Control.Action == model.ActionAudit {
			rep.Escalations = append(rep.Escalations, fmt.Sprintf(
				"%s: enforcing buys %s/yr against a tolerance band of %s — promote audit -> deny",
				r.Control.ID, buys.Round(), org.Appetite.Tolerance.Round()))
		}
	}
	sort.SliceStable(rep.Deltas, func(i, j int) bool { return rep.Deltas[i].Buys.Amount > rep.Deltas[j].Buys.Amount })

	// 7. One-way sensitivity. For each scenario, drive its loss magnitude to the bottom and the top
	//    of the calibrated range while holding every other input still, and record the swing.
	//    Whichever scenario swings the number most is the assumption the whole answer rests on.
	var scenarios []string
	seenScn := map[string]bool{}
	for _, r := range rep.Results {
		if !inScope[r.Control.Scenario] {
			continue
		}
		if !seenScn[r.Control.Scenario] {
			seenScn[r.Control.Scenario] = true
			scenarios = append(scenarios, r.Control.Scenario)
		}
	}
	buildWithMagnitude := func(sc string, pick func(model.Triple) model.Triple) ([]fair.Contribution, error) {
		base, err := build(cage.Multiplier, nil)
		if err != nil {
			return nil, err
		}
		for i := range base {
			if base[i].Scenario == sc {
				base[i].Magnitude = pick(magnitude[sc])
			}
		}
		return base, nil
	}
	flat := func(v float64) model.Triple { return model.Triple{Min: v, Mode: v, Max: v} }

	var totalSwing float64
	for _, sc := range scenarios {
		lo, err := buildWithMagnitude(sc, func(t model.Triple) model.Triple { return flat(t.Min) })
		if err != nil {
			return nil, err
		}
		hi, err := buildWithMagnitude(sc, func(t model.Triple) model.Triple { return flat(t.Max) })
		if err != nil {
			return nil, err
		}
		l := eng.Run(lo, org.RiskLoad)
		h := eng.Run(hi, org.RiskLoad)
		s := Sensitivity{
			Scenario: sc,
			LowALE:   money.Money{Amount: l.ALE, Currency: conv.target},
			HighALE:  money.Money{Amount: h.ALE, Currency: conv.target},
			Swing:    money.Money{Amount: h.ALE - l.ALE, Currency: conv.target},
		}
		totalSwing += s.Swing.Amount
		rep.Tornado = append(rep.Tornado, s)
	}
	for i := range rep.Tornado {
		if totalSwing > 0 {
			rep.Tornado[i].SharePct = 100 * rep.Tornado[i].Swing.Amount / totalSwing
		}
	}
	sort.SliceStable(rep.Tornado, func(i, j int) bool { return rep.Tornado[i].Swing.Amount > rep.Tornado[j].Swing.Amount })

	rep.Conversions = conv.log
	if len(conv.log) > 0 && opt.Rates != nil {
		rep.RatesAsOf = opt.Rates.AsOf
	}
	return rep, nil
}

// scopeScenarios decides which of the pack's loss scenarios this institution can incur, and records
// the reasoning for every one of them.
//
// Only scenarios actually referenced by a control are reported: a scenario nothing defends
// contributes nothing either way, and listing it would pad the table with noise.
func scopeScenarios(pack *model.Pack, org *model.OrgRiskPosture) (map[string]bool, []ScenarioScope, error) {
	jurisdiction := strings.TrimSpace(org.Metadata.Jurisdiction)

	byScenario := map[string][]string{}
	var order []string
	for _, c := range pack.Controls {
		if _, seen := byScenario[c.Scenario]; !seen {
			order = append(order, c.Scenario)
		}
		byScenario[c.Scenario] = append(byScenario[c.Scenario], c.ID)
	}

	in := map[string]bool{}
	scope := make([]ScenarioScope, 0, len(order))
	for _, id := range order {
		s, ok := pack.Scenario(id)
		if !ok {
			// LoadPack already rejects a control referencing an unknown scenario, so this is
			// unreachable via the loaders. Fail loudly anyway rather than silently treating an
			// unknown scenario as global and pricing it.
			return nil, nil, fmt.Errorf("pack %s: control(s) %s reference scenario %q which the pack does not declare",
				pack.Metadata.Version, strings.Join(byScenario[id], ", "), id)
		}
		included := s.AppliesTo(jurisdiction)
		in[id] = included

		var reason string
		switch {
		case s.IsGlobal():
			reason = "global: applies in every jurisdiction"
		case included:
			reason = fmt.Sprintf("institution jurisdiction %s is within the scenario's territories [%s]",
				jurisdiction, strings.Join(s.Territories, ", "))
		case jurisdiction == "":
			reason = fmt.Sprintf("EXCLUDED: scenario is scoped to [%s] and the institution declares no "+
				"metadata.jurisdiction; an unstated jurisdiction is never assumed to match",
				strings.Join(s.Territories, ", "))
		default:
			reason = fmt.Sprintf("EXCLUDED: institution jurisdiction %s is not within the scenario's "+
				"territories [%s]", jurisdiction, strings.Join(s.Territories, ", "))
		}
		if s.TerritoryNote != "" {
			reason += " — " + strings.Join(strings.Fields(s.TerritoryNote), " ")
		}

		scope = append(scope, ScenarioScope{
			Scenario:    id,
			Title:       s.Title,
			Territories: s.Territories,
			Included:    included,
			Reason:      reason,
			Controls:    byScenario[id],
		})
	}
	return in, scope, nil
}

// ExcludedScenarios returns the scenarios territory scoping removed from the exposure. Callers use
// it to state the omission explicitly rather than leaving a reader to infer it from a total.
func (r *Report) ExcludedScenarios() []ScenarioScope {
	var out []ScenarioScope
	for _, s := range r.Scope {
		if !s.Included {
			out = append(out, s)
		}
	}
	return out
}

// selectTier picks the graded-enforcement rung. Unmet gate-controls are the trigger; the £ against
// the institution's tolerance band chooses how far down the agent drops. Deny is the bottom rung,
// not the only rung: "least trusted, most expensive to run".
//
// Both arguments are amounts in the reporting currency, so the ratio is dimensionless and the tier
// an agent lands in does not depend on which currency the report is rendered in. That invariance is
// the point: an enforcement verdict that changed when you switched the display currency would be
// indefensible.
func selectTier(pack *model.Pack, unmetGated int, residualALE, tolerance float64) (string, string) {
	if unmetGated == 0 {
		return "trusted", "all gate-action controls satisfied"
	}
	ratio := residualALE / tolerance
	switch {
	case ratio <= 2:
		return "constrained", fmt.Sprintf("%d unmet gate control(s); residual ALE is %.1fx tolerance", unmetGated, ratio)
	case ratio <= 8:
		return "caged", fmt.Sprintf("%d unmet gate control(s); residual ALE is %.1fx tolerance", unmetGated, ratio)
	default:
		return "denied", fmt.Sprintf("%d unmet gate control(s); residual ALE is %.1fx tolerance", unmetGated, ratio)
	}
}

// pow is math.Pow guarded for the non-positive case, which geoBlend must not feed to a logarithm.
func pow(x, y float64) float64 {
	if x <= 0 {
		return 0
	}
	return math.Pow(x, y)
}
