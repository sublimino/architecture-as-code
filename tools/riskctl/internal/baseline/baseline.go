// Package baseline evaluates an agent's compliance posture against a versioned policy pack and an
// institution's risk posture, and turns the result into a cash value.
//
// The chain, end to end:
//
//	agent posture  x  policy pack   ->  per-control verdict (PASS / FAIL-audited / FAIL-gated)
//	                                ->  graded enforcement tier (trusted..denied), selected by the £
//	     x  org risk posture        ->  aggregate annual-loss distribution (FAIR)
//	                                ->  ALE / VaR95 / TVaR / carried
//	                                ->  Total Cost of Risk = residual + controls + transfer
//	                                ->  per-control "what tightening this buys", in pounds
package baseline

import (
	"fmt"
	"math"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/acme-co/osramp/tools/riskctl/internal/model"
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
}

// Report is the complete output of a baseline run.
type Report struct {
	AgentName    string
	AgentDisplay string
	OrgName      string
	OrgDisplay   string
	PackName     string
	PackClaimed  string
	PackEvaluated string
	// Stale is true when the agent claims an older pack version than the one it is evaluated
	// against — the laggard case.
	Stale bool

	Results []ControlResult

	Tier           string
	TierReason     string
	CageMultiplier float64
	CageCost       float64

	Risk fair.Result

	ControlSpend  float64 // annual cost of the controls actually in place, plus the cage
	FrictionSpend float64 // operational cost of gating: blocked deploys, false positives, unblocking
	TransferSpend float64 // insurance premium
	TCoR          float64 // residual (carried) + control spend + friction + transfer

	// PremiumRatio is modelled ALE divided by the annual cyber premium. The premium is a third
	// party's priced view of substantially the same controls, so this is the one genuinely
	// EXTERNAL calibration anchor available for free. A ratio near 1 means the model agrees with
	// the market; far from 1 means one of the two is wrong, and saying which is the interesting
	// conversation.
	PremiumRatio float64

	Deltas   []Delta
	Tornado  []Sensitivity

	ToleranceGBP float64
	Escalations  []string
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
	LowALE   float64
	HighALE  float64
	SwingGBP float64
	// SharePct is this scenario's share of the total swing across all scenarios.
	SharePct float64
}

// Delta answers "what would tightening this control buy?", in pounds per year.
type Delta struct {
	ControlID string
	Title     string
	// BuysGBP is ALE_now - ALE_if_this_control_were_met. The hub's "£ a control buys".
	BuysGBP float64
	// CostGBP is the control's annual run cost.
	CostGBP float64
	// NetGBP is BuysGBP - CostGBP. Positive means implementing it is cheaper than carrying it.
	NetGBP float64
	// AboveTolerance is true when BuysGBP exceeds the institution's tolerance band, which is the
	// quantitative trigger for promoting the control to the gate.
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
}

// Run produces the complete baseline report.
func Run(pack *model.Pack, agent *model.AgentPosture, org *model.OrgRiskPosture, opt Options) (*Report, error) {
	rep := &Report{
		AgentName:     agent.Metadata.Name,
		AgentDisplay:  agent.Metadata.DisplayName,
		OrgName:       org.Metadata.Name,
		OrgDisplay:    org.Metadata.DisplayName,
		PackName:      pack.Metadata.Name,
		PackClaimed:   agent.Claims.Version,
		PackEvaluated: pack.Metadata.Version,
		Stale:         agent.Claims.Version != pack.Metadata.Version,
		ToleranceGBP:  org.Appetite.ToleranceGBP,
	}

	// 1. Per-control verdicts, in pack order so output is deterministic.
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

		rep.Results = append(rep.Results, ControlResult{
			Control:      c,
			Verdict:      v,
			Met:          met,
			Evidence:     s.Evidence,
			Note:         s.Note,
			EffectiveLEF: effectiveLEF(c, met),
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
			if _, ok := org.Magnitude[r.Control.Scenario]; !ok {
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
				Magnitude: org.Magnitude[sc].Triple,
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
	pre := eng.Run(uncaged, org.RiskLoad)

	tierName, reason := selectTier(pack, unmetGated, pre.ALE, org.Appetite.ToleranceGBP)
	cage := pack.Cages[tierName]
	rep.Tier = tierName
	rep.TierReason = reason
	rep.CageMultiplier = cage.Multiplier
	rep.CageCost = cage.AnnualCost

	// 4. Final residual with the cage applied.
	caged, err := build(cage.Multiplier, nil)
	if err != nil {
		return nil, err
	}
	rep.Risk = eng.Run(caged, org.RiskLoad)
	if err := rep.Risk.SelfCheck(); err != nil {
		return nil, err
	}

	// 5. Total Cost of Risk = residual you keep + what the controls cost + what gating costs
	//    operationally + what you transferred.
	for _, r := range rep.Results {
		if r.Met {
			rep.ControlSpend += r.Control.AnnualCost
		}
		// Friction is incurred by every control that GATES, whether or not the agent passes it:
		// the deploy is blocked, someone investigates, someone unblocks it.
		if r.Control.Action == model.ActionDeny {
			rep.FrictionSpend += pack.Friction.PerDenyControlGBP
		}
	}
	rep.ControlSpend += cage.AnnualCost
	rep.TransferSpend = org.Transfer.AnnualPremiumGBP
	rep.TCoR = rep.Risk.Carried + rep.ControlSpend + rep.FrictionSpend + rep.TransferSpend
	if org.Transfer.AnnualPremiumGBP > 0 {
		rep.PremiumRatio = rep.Risk.ALE / org.Transfer.AnnualPremiumGBP
	}

	// 6. Per-control deltas: what would tightening each unmet control buy?
	for _, r := range rep.Results {
		if r.Met {
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
		buys := rep.Risk.ALE - res.ALE
		d := Delta{
			ControlID:      r.Control.ID,
			Title:          r.Control.Title,
			BuysGBP:        buys,
			CostGBP:        r.Control.AnnualCost,
			NetGBP:         buys - r.Control.AnnualCost,
			AboveTolerance: buys > org.Appetite.ToleranceGBP,
		}
		rep.Deltas = append(rep.Deltas, d)
		if d.AboveTolerance && r.Control.Action == model.ActionAudit {
			rep.Escalations = append(rep.Escalations, fmt.Sprintf(
				"%s: enforcing buys GBP %.0f/yr against a tolerance band of GBP %.0f — promote audit -> deny",
				r.Control.ID, buys, org.Appetite.ToleranceGBP))
		}
	}
	sort.SliceStable(rep.Deltas, func(i, j int) bool { return rep.Deltas[i].BuysGBP > rep.Deltas[j].BuysGBP })

	// 7. One-way sensitivity. For each scenario, drive its loss magnitude to the bottom and the top
	//    of the calibrated range while holding every other input still, and record the swing.
	//    Whichever scenario swings the number most is the assumption the whole answer rests on.
	var scenarios []string
	seenScn := map[string]bool{}
	for _, r := range rep.Results {
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
				base[i].Magnitude = pick(org.Magnitude[sc].Triple)
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
		s := Sensitivity{Scenario: sc, LowALE: l.ALE, HighALE: h.ALE, SwingGBP: h.ALE - l.ALE}
		totalSwing += s.SwingGBP
		rep.Tornado = append(rep.Tornado, s)
	}
	for i := range rep.Tornado {
		if totalSwing > 0 {
			rep.Tornado[i].SharePct = 100 * rep.Tornado[i].SwingGBP / totalSwing
		}
	}
	sort.SliceStable(rep.Tornado, func(i, j int) bool { return rep.Tornado[i].SwingGBP > rep.Tornado[j].SwingGBP })

	return rep, nil
}

// selectTier picks the graded-enforcement rung. Unmet gate-controls are the trigger; the £ against
// the institution's tolerance band chooses how far down the agent drops. Deny is the bottom rung,
// not the only rung: "least trusted, most expensive to run".
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
