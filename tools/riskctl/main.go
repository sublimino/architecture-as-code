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
	"github.com/acme-co/osramp/tools/riskctl/internal/fair"
	"github.com/acme-co/osramp/tools/riskctl/internal/model"
)

const usage = `riskctl — price an agent's compliance posture in pounds.

USAGE
  riskctl <command> [flags]

COMMANDS
  baseline   per-control compliance verdicts for an agent, with evidence
  risk       the cash value: ALE / VaR95 / TVaR / Total Cost of Risk, plus what each control buys
  compare    the same agent and the same pack against two institutions

FLAGS
  --root      repository root holding risk/ (default: auto-detected)
  --agent     agent posture name under risk/posture/        (default: agent-remediation)
  --pack      policy pack version under risk/packs/agent-policy/ (default: 2.1.0)
  --org       organisation under risk/org/                  (default: acme)
  --with      second organisation, for compare
  --seed      Monte Carlo seed (default: pinned, for reproducibility)
  --iters     Monte Carlo iterations (default: 200000)
  --json      emit machine-readable JSON instead of a report
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
	asJSON := fs.Bool("json", false, "emit JSON")

	switch cmd {
	case "baseline", "risk", "compare":
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
	opt := baseline.Options{Iterations: *iters, Seed: *seed}

	rep, err := load(r, *agentName, *packVer, *orgName, opt)
	if err != nil {
		fatal(err)
	}

	switch cmd {
	case "baseline":
		if *asJSON {
			emitJSON(rep)
			return
		}
		printBaseline(rep)
	case "risk":
		if *asJSON {
			emitJSON(rep)
			return
		}
		printBaseline(rep)
		printRisk(rep)
	case "compare":
		if *withOrg == "" {
			fatal(fmt.Errorf("compare requires --with <org>"))
		}
		other, err := load(r, *agentName, *packVer, *withOrg, opt)
		if err != nil {
			fatal(err)
		}
		if *asJSON {
			emitJSON([]*baseline.Report{rep, other})
			return
		}
		printCompare(rep, other)
	}
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

func gbp(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	s := fmt.Sprintf("%.0f", v)
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	if neg {
		return "-£" + string(out)
	}
	return "£" + string(out)
}

func printBaseline(r *baseline.Report) {
	fmt.Printf("\n%s\n", rule(96))
	fmt.Printf("AGENT COMPLIANCE BASELINE\n")
	fmt.Printf("%s\n", rule(96))
	fmt.Printf("  agent         %s (%s)\n", r.AgentDisplay, r.AgentName)
	fmt.Printf("  institution   %s\n", r.OrgDisplay)
	fmt.Printf("  pack          %s, evaluated against %s\n", r.PackName, r.PackEvaluated)
	fmt.Printf("  claims        %s", r.PackClaimed)
	if r.Stale {
		fmt.Printf("   ⚠ STALE — agent is pinned behind the evaluated version")
	}
	fmt.Printf("\n\n")

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
		fmt.Printf("  %-9s %-8s %-52s %s %s\n", c.Control.ID, c.Control.Action, title, mark, c.Verdict)
	}

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
		strings.ToUpper(r.Tier), r.CageMultiplier, gbp(r.CageCost))
	fmt.Printf("  reason: %s\n", r.TierReason)
	fmt.Printf("  Deny is the bottom rung, not the only rung — least trusted, most expensive to run.\n")
}

func printRisk(r *baseline.Report) {
	fmt.Printf("\n%s\n", rule(96))
	fmt.Printf("CASH VALUE OF RISK EXPOSURE — %s carrying %s\n", r.OrgDisplay, r.AgentDisplay)
	fmt.Printf("%s\n", rule(96))
	fmt.Printf("  Monte Carlo: %d iterations, seed %d (fixed — rerun reproduces to the pound)\n\n",
		r.Risk.Iterations, r.Risk.Seed)

	fmt.Printf("  ALE     (the average year)          %14s\n", gbp(r.Risk.ALE))
	fmt.Printf("  VaR95   (the bad year)              %14s\n", gbp(r.Risk.VaR95))
	fmt.Printf("  TVaR    (the tail beyond VaR95)     %14s\n", gbp(r.Risk.TVaR))
	fmt.Printf("  carried (TVaR + %.0f%% risk load)      %14s   ← residual risk\n",
		r.Risk.RiskLoad*100, gbp(r.Risk.Carried))

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
	fmt.Printf("    residual (risk you keep)          %14s\n", gbp(r.Risk.Carried))
	fmt.Printf("  + cost of controls (incl. the cage) %14s\n", gbp(r.ControlSpend))
	fmt.Printf("  + enforcement friction (gating)     %14s\n", gbp(r.FrictionSpend))
	fmt.Printf("  + risk transferred (insurance)      %14s\n", gbp(r.TransferSpend))
	fmt.Printf("  %s\n", rule(50))
	fmt.Printf("  = TCoR                              %14s\n", gbp(r.TCoR))

	if len(r.Deltas) > 0 {
		fmt.Printf("\n  WHAT TIGHTENING EACH UNMET CONTROL BUYS  (tolerance band %s/yr)\n  %s\n",
			gbp(r.ToleranceGBP), rule(94))
		fmt.Printf("  %-9s %-46s %12s %11s %11s\n", "CONTROL", "TITLE", "BUYS/yr", "COST/yr", "NET/yr")
		for _, d := range r.Deltas {
			title := d.Title
			if len(title) > 44 {
				title = title[:43] + "…"
			}
			flag := " "
			if d.AboveTolerance {
				flag = "*"
			}
			fmt.Printf("  %-9s %-46s %12s %11s %11s %s\n",
				d.ControlID, title, gbp(d.BuysGBP), gbp(d.CostGBP), gbp(d.NetGBP), flag)
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
				gbp(s.LowALE), gbp(s.HighALE), gbp(s.SwingGBP), s.SharePct)
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

func printCompare(a, b *baseline.Report) {
	fmt.Printf("\n%s\n", rule(96))
	fmt.Printf("SAME AGENT. SAME PACK. SAME CONTROLS. TWO INSTITUTIONS.\n")
	fmt.Printf("%s\n", rule(96))
	fmt.Printf("  agent: %s     pack: %s %s\n\n", a.AgentDisplay, a.PackName, a.PackEvaluated)

	fmt.Printf("  %-34s %22s %22s\n", "", a.OrgDisplay, b.OrgDisplay)
	fmt.Printf("  %s\n", rule(80))
	fmt.Printf("  %-34s %22s %22s\n", "ALE (average year)", gbp(a.Risk.ALE), gbp(b.Risk.ALE))
	fmt.Printf("  %-34s %22s %22s\n", "VaR95 (bad year)", gbp(a.Risk.VaR95), gbp(b.Risk.VaR95))
	fmt.Printf("  %-34s %22s %22s\n", "TVaR (the tail)", gbp(a.Risk.TVaR), gbp(b.Risk.TVaR))
	fmt.Printf("  %-34s %22s %22s\n", "residual carried", gbp(a.Risk.Carried), gbp(b.Risk.Carried))
	fmt.Printf("  %-34s %22s %22s\n", "tolerance band", gbp(a.ToleranceGBP), gbp(b.ToleranceGBP))
	fmt.Printf("  %-34s %22s %22s\n", "Total Cost of Risk", gbp(a.TCoR), gbp(b.TCoR))
	fmt.Printf("  %-34s %22s %22s\n", "enforcement tier", strings.ToUpper(a.Tier), strings.ToUpper(b.Tier))

	fmt.Printf("\n  THE SAME CONTROL, PRICED TWICE\n  %s\n", rule(80))
	fmt.Printf("  %-9s %-30s %18s %18s\n", "CONTROL", "TITLE", a.OrgDisplay, b.OrgDisplay)
	bd := map[string]baseline.Delta{}
	for _, d := range b.Deltas {
		bd[d.ControlID] = d
	}
	for _, d := range a.Deltas {
		o, ok := bd[d.ControlID]
		if !ok {
			continue
		}
		title := d.Title
		if len(title) > 28 {
			title = title[:27] + "…"
		}
		av, bv := "audit", "audit"
		if d.AboveTolerance {
			av = "DENY"
		}
		if o.AboveTolerance {
			bv = "DENY"
		}
		fmt.Printf("  %-9s %-30s %10s %-7s %10s %-7s\n",
			d.ControlID, title, gbp(d.BuysGBP), av, gbp(o.BuysGBP), bv)
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
