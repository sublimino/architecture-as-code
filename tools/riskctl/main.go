// Command riskctl baselines an agent's compliance posture against a versioned policy pack and an
// institution's risk posture, and prices the residual exposure in pounds.
//
//	"Not a red, amber, green dot on a dashboard — a number in pounds."
//
// Runs fully offline. No cluster, no network, no API key. Deterministic under a fixed seed.
//
//	riskctl baseline --agent agent-remediation --pack 2.1.0 --org acme
//	riskctl risk     --agent agent-remediation --pack 2.0.0 --org acme --json
//	riskctl compare  --agent agent-remediation --pack 2.1.0 --org acme --with ludlow-health
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/acme-co/osramp/tools/riskctl/internal/baseline"
	"github.com/acme-co/osramp/tools/riskctl/internal/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

const usage = `riskctl — price an agent's compliance posture in pounds.

USAGE
  riskctl <command> [flags]

COMMANDS
  baseline   per-control compliance verdicts for an agent, with evidence
  risk       the cash value: ALE / VaR95 / TVaR / Total Cost of Risk, plus what each control buys
  compare    the same agent and the same pack against two institutions
  fx         regenerate the JSON FX artefacts non-Go consumers read (--check to verify)

FLAGS
  --root      repository root holding risk/ (default: auto-detected)
  --agent     agent posture name under risk/posture/        (default: agent-remediation)
  --pack      policy pack version under risk/packs/agent-policy/ (default: 2.1.0)
  --org       organisation under risk/org/                  (default: acme)
  --with      second organisation, for compare
  --seed      Monte Carlo seed (default: pinned, for reproducibility)
  --iters     Monte Carlo iterations (default: 200000)
  --currency  ISO 4217 code to DISPLAY figures in (default: the institution's own)
  --rates     FX rate table (default: <root>/risk/fx/rates.yaml)
  --json      emit machine-readable JSON instead of a report

CURRENCY
  Every amount in risk/ carries its own denomination as data. The simulation and every threshold
  test run in the institution's own reporting currency, so an enforcement verdict never depends on
  how the report is displayed. --currency converts at the very last step, for reading only.

  Rates come from a checked-in, dated table -- never a network call -- for the same reason the
  Monte Carlo seed is pinned: a figure quoted today must be the same figure tomorrow. A missing
  rate is an error naming the pair, never a silent 1.0.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd := os.Args[1]

	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	root := fs.String("root", "", "repository root holding risk/")
	agentName := fs.String("agent", "agent-remediation", "agent posture name")
	packVer := fs.String("pack", "2.1.0", "policy pack version")
	orgName := fs.String("org", "acme", "organisation name")
	withOrg := fs.String("with", "", "second organisation for compare")
	seed := fs.Int64("seed", fair.DefaultSeed, "Monte Carlo seed")
	iters := fs.Int("iters", fair.DefaultIterations, "Monte Carlo iterations")
	displayCur := fs.String("currency", "", "ISO 4217 code to display figures in")
	ratesPath := fs.String("rates", "", "FX rate table (default <root>/risk/fx/rates.yaml)")
	fxCheck := fs.Bool("check", false, "fx: verify the generated artefacts are current instead of writing them")
	asJSON := fs.Bool("json", false, "emit JSON")

	switch cmd {
	case "baseline", "risk", "compare", "fx":
		_ = fs.Parse(os.Args[2:])
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}

	r, err := resolveRoot(*root)
	if err != nil {
		fatal(err)
	}
	if cmd == "fx" {
		if err := runFX(r, *fxCheck); err != nil {
			fatal(err)
		}
		return
	}

	// The rate table is loaded up front, always. It is small, it is local, and loading it eagerly
	// means a missing or malformed table is reported before any figure is computed rather than
	// halfway through a report. A table that is simply absent is not fatal on its own: a run whose
	// inputs are all in one currency never needs it, and refusing to run offline without an FX file
	// would be a worse failure than the one it prevents.
	rates, ratesErr := loadRates(r, *ratesPath)

	opt := baseline.Options{Iterations: *iters, Seed: *seed, Rates: rates}

	rep, err := load(r, *agentName, *packVer, *orgName, opt)
	if err != nil {
		if rates == nil && ratesErr != nil && strings.Contains(err.Error(), "rate table") {
			fatal(fmt.Errorf("%w\n  (the FX table also failed to load: %v)", err, ratesErr))
		}
		fatal(err)
	}

	disp, err := newDisplay(money.Currency(*displayCur), rep.Currency, rates)
	if err != nil {
		fatal(err)
	}

	switch cmd {
	case "baseline":
		if *asJSON {
			emitJSON(rep)
			return
		}
		printBaseline(rep, disp)
	case "risk":
		if *asJSON {
			emitJSON(rep)
			return
		}
		printBaseline(rep, disp)
		printRisk(rep, disp)
	case "compare":
		if *withOrg == "" {
			fatal(fmt.Errorf("compare requires --with <org>"))
		}
		other, err := load(r, *agentName, *packVer, *withOrg, opt)
		if err != nil {
			fatal(err)
		}
		// Two institutions can report in two different currencies. Printing them side by side in a
		// single table then invites a reader to compare, subtract, or rank two figures that are not
		// in the same unit -- the comparison the whole change exists to make impossible. Refuse,
		// and name the fix.
		if rep.Currency != other.Currency && *displayCur == "" {
			fatal(fmt.Errorf("cannot compare %s (%s) with %s (%s) side by side: the two institutions report in "+
				"different currencies, and a table that placed them in adjacent columns would invite a "+
				"comparison between two different units.\n  Pass --currency %s (or any code in the rate "+
				"table) to convert both onto one axis",
				rep.OrgDisplay, rep.Currency, other.OrgDisplay, other.Currency, rep.Currency))
		}
		if *asJSON {
			emitJSON([]*baseline.Report{rep, other})
			return
		}
		printCompare(rep, other, disp)
	}
}

// loadRates reads the FX table, defaulting to the one checked in beside the risk data.
func loadRates(root, explicit string) (*money.RateTable, error) {
	path := explicit
	if path == "" {
		path = filepath.Join(root, "risk", "fx", "rates.yaml")
	}
	t, err := money.LoadRateTable(path)
	if err != nil {
		return nil, err
	}
	return t, nil
}

// display renders amounts, converting to a target currency only at the moment of printing.
//
// This is the last step in the pipeline on purpose. Every sum, every threshold test and every tier
// selection has already happened in the institution's own reporting currency, so no verdict in the
// report depends on how it is displayed. Converting here also means each printed figure is
// converted exactly once, directly from the computed value -- nothing is converted, summed, and
// converted again, which is how rounding accumulates and how two views of the same report end up
// disagreeing by a few pounds.
type display struct {
	to    money.Currency
	rates *money.RateTable
	// converted is true when the display currency differs from the report's own, which the report
	// header states explicitly -- a converted figure must never be mistaken for a source figure.
	converted bool
}

func newDisplay(want, reportCur money.Currency, rates *money.RateTable) (*display, error) {
	if want == "" {
		return &display{to: reportCur, rates: rates}, nil
	}
	if err := want.Validate(); err != nil {
		return nil, fmt.Errorf("--currency: %w", err)
	}
	if want == reportCur {
		return &display{to: reportCur, rates: rates}, nil
	}
	if rates == nil {
		return nil, fmt.Errorf("--currency %s requires an FX rate table and none could be loaded", want)
	}
	// Fail here, before a single figure is printed, rather than partway down a report.
	if _, err := rates.Rate(reportCur, want); err != nil {
		return nil, err
	}
	return &display{to: want, rates: rates, converted: true}, nil
}

// s formats an amount for reading, converting it into the display currency first.
func (d *display) s(m money.Money) string {
	if m.Currency == "" {
		// An undenominated amount reaching the printer is a bug upstream, not something to paper
		// over with a plausible-looking figure.
		return "??? " + fmt.Sprintf("%.0f", m.Amount)
	}
	out := m
	if m.Currency != d.to {
		c, err := d.rates.Convert(m, d.to)
		if err != nil {
			return "ERR:" + err.Error()
		}
		out = c.Money()
	}
	return symbolise(out)
}

// symbolise renders an amount with a currency symbol where one is unambiguous, and with the ISO
// code otherwise. "$" is deliberately NOT used: it is shared by USD, CAD, AUD, SGD, HKD and others,
// and an unqualified dollar sign on a risk figure is exactly the ambiguity this change removes.
func symbolise(m money.Money) string {
	v := m.Amount
	neg := v < 0
	if neg {
		v = -v
	}
	digits := group(fmt.Sprintf("%.0f", v))
	var body string
	switch m.Currency {
	case "GBP":
		body = "£" + digits
	case "EUR":
		body = "€" + digits
	case "JPY":
		body = "¥" + digits
	default:
		body = digits + " " + string(m.Currency)
	}
	if neg {
		return "-" + body
	}
	return body
}

// group inserts thousands separators into a plain digit string.
func group(s string) string {
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	return string(out)
}

func load(root, agentName, packVer, orgName string, opt baseline.Options) (*baseline.Report, error) {
	packPath := filepath.Join(root, "risk", "packs", "agent-policy", packVer, "pack.yaml")
	agentPath := filepath.Join(root, "risk", "posture", agentName+".yaml")
	orgPath := filepath.Join(root, "risk", "org", orgName+".yaml")

	pack, err := model.LoadPack(packPath)
	if err != nil {
		return nil, err
	}
	agent, err := model.LoadAgentPosture(agentPath)
	if err != nil {
		return nil, err
	}
	org, err := model.LoadOrgRiskPosture(orgPath)
	if err != nil {
		return nil, err
	}
	return baseline.Run(pack, agent, org, opt)
}

// resolveRoot walks up from the working directory looking for a risk/ directory, so the tool works
// from anywhere in the repo without configuration.
func resolveRoot(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		if st, err := os.Stat(filepath.Join(dir, "risk", "packs")); err == nil && st.IsDir() {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("could not locate a risk/ directory above the working directory; pass --root")
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "riskctl:", err)
	os.Exit(1)
}

func emitJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fatal(err)
	}
}

func rule(w int) string { return strings.Repeat("─", w) }

// printCurrencyProvenance states the denomination of every figure that follows, and — when the
// display currency differs from the institution's own — the rate and date that produced it.
//
// A converted figure that is not labelled as converted is indistinguishable from a source figure,
// and the reader has no way to re-derive it. Stating the rate makes the number checkable with a
// calculator, which is the difference between a number and evidence.
func printCurrencyProvenance(r *baseline.Report, d *display) {
	if d.converted {
		rate, err := d.rates.Rate(r.Currency, d.to)
		if err != nil {
			fmt.Printf("  currency      %s (CONVERSION ERROR: %v)\n", r.Currency, err)
			return
		}
		fmt.Printf("  currency      figures shown in %s, CONVERTED from the institution's reporting\n", d.to)
		fmt.Printf("                currency %s at %.6f %s/%s, rates as of %s (risk/fx/rates.yaml)\n",
			r.Currency, rate, d.to, r.Currency, d.rates.AsOf)
		fmt.Printf("                All arithmetic and every verdict below were computed in %s;\n", r.Currency)
		fmt.Printf("                conversion is the last step and changes no verdict.\n")
		return
	}
	fmt.Printf("  currency      %s (the institution's own reporting currency — no conversion applied)\n", r.Currency)
	for _, c := range r.Conversions {
		fmt.Printf("                ↳ %s converted to %s at %.6f, rates as of %s\n",
			c.Source.Currency, c.Currency, c.Rate, c.AsOf)
	}
}

// printScope makes territory filtering visible. A total that silently omits scenarios is
// unexplainable: a reader who knows the pack has five scenarios and sees a number built from three
// cannot tell a deliberate jurisdictional exclusion from a bug or a typo. Every scenario is listed
// with its verdict and its reason, included and excluded alike.
func printScope(r *baseline.Report) {
	if len(r.Scope) == 0 {
		return
	}
	excluded := r.ExcludedScenarios()
	if len(excluded) == 0 {
		// Distinguish "nothing is scoped" from "everything scoped happens to match here". They are
		// the same total but not the same fact: the second means another institution would get a
		// different number from this identical pack, which is the thing a reader needs to know.
		scoped := 0
		for _, s := range r.Scope {
			if len(s.Territories) != 1 || s.Territories[0] != "*" {
				scoped++
			}
		}
		if scoped == 0 {
			fmt.Printf("\n  TERRITORY SCOPE: all %d loss scenarios are global; none is jurisdiction-scoped\n",
				len(r.Scope))
		} else {
			fmt.Printf("\n  TERRITORY SCOPE: all %d loss scenarios apply in %s (%d jurisdiction-scoped,\n",
				len(r.Scope), orUnstated(r.Jurisdiction), scoped)
			fmt.Printf("  all matching here). An institution elsewhere would be priced against a smaller\n")
			fmt.Printf("  set from this identical pack.\n")
		}
		return
	}

	fmt.Printf("\n  TERRITORY SCOPE — which loss scenarios can be incurred in %s\n  %s\n",
		orUnstated(r.Jurisdiction), rule(94))
	fmt.Printf("  %-22s %-10s %-22s %s\n", "SCENARIO", "COUNTS", "TERRITORIES", "CONTROLS")
	for _, s := range r.Scope {
		mark := "yes"
		if !s.Included {
			mark = "NO"
		}
		fmt.Printf("  %-22s %-10s %-22s %s\n",
			strings.TrimPrefix(s.Scenario, "SCN-"), mark,
			"["+strings.Join(s.Territories, ", ")+"]",
			strings.Join(s.Controls, " "))
	}
	fmt.Printf("\n  %d of %d scenarios excluded from the exposure:\n", len(excluded), len(r.Scope))
	for _, s := range excluded {
		fmt.Printf("    %s — %s\n", s.Scenario, wrap(s.Reason, 84, "      "))
	}
	fmt.Printf("\n  The total below is built from the %d scenarios marked `yes`. Excluded scenarios are\n",
		len(r.Scope)-len(excluded))
	fmt.Printf("  still evaluated for compliance — a control can be unmet whether or not the loss it\n")
	fmt.Printf("  defends can happen here — but they contribute no pounds and generate no deltas.\n")

	if r.NoApplicableScenarios {
		fmt.Printf("\n  ⚠ EVERY scenario was excluded. The exposure below is zero because this pack prices\n")
		fmt.Printf("    nothing that can occur in %s — NOT because the estate is safe. Do not read the\n",
			orUnstated(r.Jurisdiction))
		fmt.Printf("    zero as a verdict.\n")
	}
}

func orUnstated(j string) string {
	if strings.TrimSpace(j) == "" {
		return "an unstated jurisdiction"
	}
	return j
}

func printBaseline(r *baseline.Report, d *display) {
	fmt.Printf("\n%s\n", rule(96))
	fmt.Printf("AGENT COMPLIANCE BASELINE\n")
	fmt.Printf("%s\n", rule(96))
	fmt.Printf("  agent         %s (%s)\n", r.AgentDisplay, r.AgentName)
	fmt.Printf("  institution   %s", r.OrgDisplay)
	if r.Jurisdiction != "" {
		fmt.Printf("   (jurisdiction: %s)", r.Jurisdiction)
	}
	fmt.Printf("\n")
	fmt.Printf("  pack          %s, evaluated against %s\n", r.PackName, r.PackEvaluated)
	fmt.Printf("  claims        %s", r.PackClaimed)
	if r.Stale {
		fmt.Printf("   ⚠ STALE — agent is pinned behind the evaluated version")
	}
	fmt.Printf("\n")
	printCurrencyProvenance(r, d)
	fmt.Printf("\n")

	fmt.Printf("  %-9s %-8s %-52s %s\n", "CONTROL", "ACTION", "TITLE", "VERDICT")
	fmt.Printf("  %s\n", rule(94))
	for _, c := range r.Results {
		mark := "✓"
		switch c.Verdict {
		case baseline.VerdictGated:
			mark = "✗"
		case baseline.VerdictAudited, baseline.VerdictUnclaimed:
			mark = "!"
		}
		title := c.Control.Title
		if len(title) > 50 {
			title = title[:49] + "…"
		}
		// An out-of-territory control is still reported — it can still be satisfied or unsatisfied —
		// but the reader must be able to see that it contributes nothing to the exposure, or the
		// per-control table and the £ table will look inconsistent.
		scope := ""
		if !c.InScope {
			scope = "  ⊘ out of territory"
		}
		fmt.Printf("  %-9s %-8s %-52s %s %s%s\n", c.Control.ID, c.Control.Action, title, mark, c.Verdict, scope)
	}

	printScope(r)

	fmt.Printf("\n  EVIDENCE FOR UNMET CONTROLS\n  %s\n", rule(94))
	any := false
	for _, c := range r.Results {
		if c.Met {
			continue
		}
		any = true
		fmt.Printf("  %s  %s\n", c.Control.ID, c.Control.Title)
		fmt.Printf("       cited artefact: %s\n", c.Evidence)
		fmt.Printf("       %s\n", wrap(c.Note, 88, "       "))
	}
	if !any {
		fmt.Printf("  (none — every control in the pack is satisfied)\n")
	}

	fmt.Printf("\n  ENFORCEMENT TIER: %s  (frequency multiplier %.2f, run cost %s/yr)\n",
		strings.ToUpper(r.Tier), r.CageMultiplier, d.s(r.CageCost))
	fmt.Printf("  reason: %s\n", r.TierReason)
	fmt.Printf("  Deny is the bottom rung, not the only rung — least trusted, most expensive to run.\n")
}

func printRisk(r *baseline.Report, d *display) {
	fmt.Printf("\n%s\n", rule(96))
	fmt.Printf("CASH VALUE OF RISK EXPOSURE — %s carrying %s\n", r.OrgDisplay, r.AgentDisplay)
	fmt.Printf("%s\n", rule(96))
	fmt.Printf("  Monte Carlo: %d iterations, seed %d (fixed — rerun reproduces to the pound)\n\n",
		r.Risk.Iterations, r.Risk.Seed)

	fmt.Printf("  ALE     (the average year)          %14s\n", d.s(r.Exposure.ALE))
	fmt.Printf("  VaR95   (the bad year)              %14s\n", d.s(r.Exposure.VaR95))
	fmt.Printf("  TVaR    (the tail beyond VaR95)     %14s\n", d.s(r.Exposure.TVaR))
	fmt.Printf("  carried (TVaR + %.0f%% risk load)      %14s   ← residual risk\n",
		r.Risk.RiskLoad*100, d.s(r.Exposure.Carried))

	if r.Risk.TailDominated() {
		fmt.Printf("\n  ⓘ TAIL-DOMINATED: VaR95 sits below ALE, so more than 95%% of simulated years cost\n")
		fmt.Printf("    nothing at all and the whole expected loss lives in the tail. This is the regime\n")
		fmt.Printf("    where TRANSFER (insurance) begins to beat further control spend — you are no\n")
		fmt.Printf("    longer buying down a frequency anyone can feel. It is the shape an underwriter\n")
		fmt.Printf("    prices, which is what putting risk on the balance sheet actually means.\n")
	}

	if r.PremiumRatio > 0 {
		fmt.Printf("\n  EXTERNAL ANCHOR — the market's own view of the same controls\n  %s\n", rule(94))
		fmt.Printf("    modelled ALE / annual cyber premium   %.2fx\n", r.PremiumRatio)
		switch {
		case r.PremiumRatio > 3:
			fmt.Printf("    The model is materially more pessimistic than the underwriter. Either our triples\n")
			fmt.Printf("    are hot, or we are carrying risk the policy does not cover. Both are worth knowing.\n")
		case r.PremiumRatio < 0.33:
			fmt.Printf("    The model is materially more optimistic than the underwriter, who prices\n")
			fmt.Printf("    substantially these same controls. Treat our triples as suspect until reconciled.\n")
		default:
			fmt.Printf("    Within the same order as the priced market view — the model and the underwriter\n")
			fmt.Printf("    broadly agree. This is the only external calibration available for free.\n")
		}
	}

	fmt.Printf("\n  TOTAL COST OF RISK\n  %s\n", rule(94))
	fmt.Printf("    residual (risk you keep)          %14s\n", d.s(r.Exposure.Carried))
	fmt.Printf("  + cost of controls (incl. the cage) %14s\n", d.s(r.ControlSpend))
	fmt.Printf("  + enforcement friction (gating)     %14s\n", d.s(r.FrictionSpend))
	fmt.Printf("  + risk transferred (insurance)      %14s\n", d.s(r.TransferSpend))
	fmt.Printf("  %s\n", rule(50))
	fmt.Printf("  = TCoR                              %14s\n", d.s(r.TCoR))

	if len(r.Deltas) > 0 {
		fmt.Printf("\n  WHAT TIGHTENING EACH UNMET CONTROL BUYS  (tolerance band %s/yr)\n  %s\n",
			d.s(r.Tolerance), rule(94))
		fmt.Printf("  %-9s %-46s %12s %11s %11s\n", "CONTROL", "TITLE", "BUYS/yr", "COST/yr", "NET/yr")
		for _, dl := range r.Deltas {
			title := dl.Title
			if len(title) > 44 {
				title = title[:43] + "…"
			}
			flag := " "
			if dl.AboveTolerance {
				flag = "*"
			}
			fmt.Printf("  %-9s %-46s %12s %11s %11s %s\n",
				dl.ControlID, title, d.s(dl.Buys), d.s(dl.Cost), d.s(dl.Net), flag)
		}
		fmt.Printf("\n  * exceeds the institution's tolerance band — the quantitative trigger for the gate\n")
		fmt.Printf("  NOT ADDITIVE: these deltas are marginal, each computed holding the others fixed.\n")
		fmt.Printf("  They defend overlapping loss events, so summing the column overstates the benefit.\n")
		fmt.Printf("  A £0 entry means the control is not the weakest link in its scenario — fixing it\n")
		fmt.Printf("  buys nothing until the dominant control above it is fixed first.\n")
		fmt.Printf("  A negative NET means DO NOT TIGHTEN: the control costs more than the risk it removes.\n")
	}

	if len(r.Tornado) > 0 {
		fmt.Printf("\n  SENSITIVITY — which assumption the answer actually rests on\n  %s\n", rule(94))
		fmt.Printf("  Each scenario's loss magnitude driven to the floor and ceiling of its calibrated\n")
		fmt.Printf("  range, everything else held still. Determinism proves the code reproduces; this\n")
		fmt.Printf("  proves which input to argue about.\n\n")
		fmt.Printf("  %-22s %14s %14s %14s %8s\n", "SCENARIO", "ALE @ floor", "ALE @ ceiling", "SWING", "SHARE")
		for _, s := range r.Tornado {
			fmt.Printf("  %-22s %14s %14s %14s %7.1f%%\n",
				strings.TrimPrefix(s.Scenario, "SCN-"),
				d.s(s.LowALE), d.s(s.HighALE), d.s(s.Swing), s.SharePct)
		}
	}

	if len(r.Escalations) > 0 {
		fmt.Printf("\n  PROPOSED ESCALATIONS  (proposed, never applied — these become a reviewed PR)\n  %s\n", rule(94))
		for _, e := range r.Escalations {
			fmt.Printf("  → %s\n", e)
		}
	}
	fmt.Println()
}

func printCompare(a, b *baseline.Report, d *display) {
	fmt.Printf("\n%s\n", rule(96))
	fmt.Printf("SAME AGENT. SAME PACK. SAME CONTROLS. TWO INSTITUTIONS.\n")
	fmt.Printf("%s\n", rule(96))
	fmt.Printf("  agent: %s     pack: %s %s\n\n", a.AgentDisplay, a.PackName, a.PackEvaluated)

	fmt.Printf("  %-34s %22s %22s\n", "", a.OrgDisplay, b.OrgDisplay)
	fmt.Printf("  %s\n", rule(80))
	fmt.Printf("  %-34s %22s %22s\n", "ALE (average year)", d.s(a.Exposure.ALE), d.s(b.Exposure.ALE))
	fmt.Printf("  %-34s %22s %22s\n", "VaR95 (bad year)", d.s(a.Exposure.VaR95), d.s(b.Exposure.VaR95))
	fmt.Printf("  %-34s %22s %22s\n", "TVaR (the tail)", d.s(a.Exposure.TVaR), d.s(b.Exposure.TVaR))
	fmt.Printf("  %-34s %22s %22s\n", "residual carried", d.s(a.Exposure.Carried), d.s(b.Exposure.Carried))
	fmt.Printf("  %-34s %22s %22s\n", "tolerance band", d.s(a.Tolerance), d.s(b.Tolerance))
	fmt.Printf("  %-34s %22s %22s\n", "Total Cost of Risk", d.s(a.TCoR), d.s(b.TCoR))
	fmt.Printf("  %-34s %22s %22s\n", "enforcement tier", strings.ToUpper(a.Tier), strings.ToUpper(b.Tier))

	fmt.Printf("\n  THE SAME CONTROL, PRICED TWICE\n  %s\n", rule(80))
	fmt.Printf("  %-9s %-30s %18s %18s\n", "CONTROL", "TITLE", a.OrgDisplay, b.OrgDisplay)
	bd := map[string]baseline.Delta{}
	for _, other := range b.Deltas {
		bd[other.ControlID] = other
	}
	for _, dl := range a.Deltas {
		o, ok := bd[dl.ControlID]
		if !ok {
			continue
		}
		title := dl.Title
		if len(title) > 28 {
			title = title[:27] + "…"
		}
		av, bv := "audit", "audit"
		if dl.AboveTolerance {
			av = "DENY"
		}
		if o.AboveTolerance {
			bv = "DENY"
		}
		fmt.Printf("  %-9s %-30s %10s %-7s %10s %-7s\n",
			dl.ControlID, title, d.s(dl.Buys), av, d.s(o.Buys), bv)
	}
	fmt.Printf("\n  One identical rule. Opposite verdicts. Nobody had an opinion — the pounds decided.\n\n")
}

func wrap(s string, width int, indent string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) <= width {
		return s
	}
	var b strings.Builder
	line := 0
	for _, w := range strings.Fields(s) {
		if line+len(w)+1 > width {
			b.WriteString("\n" + indent)
			line = 0
		} else if line > 0 {
			b.WriteString(" ")
			line++
		}
		b.WriteString(w)
		line += len(w)
	}
	return b.String()
}
