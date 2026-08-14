package baseline

import (
	"math"
	"strings"
	"testing"

	"github.com/acme-co/osramp/tools/riskctl/internal/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Fixtures.
//
// These are built in code rather than loaded from risk/, deliberately. The shipped packs are all
// globally scoped and all GBP, which is the correct default and the reason this change moved no
// existing figure — but it means the shipped data cannot exercise either new axis. Synthetic
// fixtures let the tests drive territory and currency to their edges without perturbing the demo
// estate's numbers.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func rates() *money.RateTable {
	return &money.RateTable{
		AsOf: "2026-08-01",
		Base: "USD",
		Rates: map[money.Currency]float64{
			"USD": 1.0,
			"GBP": 0.79,
			"EUR": 0.92,
		},
	}
}

// testPack builds a two-scenario pack: one global, one scoped to the given territories.
func testPack(cur money.Currency, scopedTerritories []string) *model.Pack {
	p := &model.Pack{
		Currency: cur,
		Scenarios: []model.Scenario{
			{ID: "SCN-GLOBAL", Title: "Happens anywhere", Territories: []string{model.Global}},
			{ID: "SCN-SCOPED", Title: "Happens only in named jurisdictions", Territories: scopedTerritories},
		},
		Controls: []model.Control{
			{
				ID: "C-GLOBAL", Title: "Guards the global scenario", Scenario: "SCN-GLOBAL",
				Action: model.ActionAudit, Rationale: "x",
				Evidence:    model.Evidence{Artifact: "a"},
				LEFAudit:    model.Triple{Min: 0.2, Mode: 0.8, Max: 2.0},
				LEFEnforced: model.Triple{Min: 0.01, Mode: 0.05, Max: 0.2},
				AnnualCost:  money.Money{Amount: 1000, Currency: cur},
			},
			{
				ID: "C-SCOPED", Title: "Guards the scoped scenario", Scenario: "SCN-SCOPED",
				Action: model.ActionAudit, Rationale: "x",
				Evidence:    model.Evidence{Artifact: "a"},
				LEFAudit:    model.Triple{Min: 0.3, Mode: 1.0, Max: 3.0},
				LEFEnforced: model.Triple{Min: 0.01, Mode: 0.05, Max: 0.2},
				AnnualCost:  money.Money{Amount: 2000, Currency: cur},
			},
		},
		Cages: map[string]model.Cage{
			"trusted":     {Multiplier: 1.0, AnnualCost: money.Money{Amount: 0, Currency: cur}},
			"constrained": {Multiplier: 0.55, AnnualCost: money.Money{Amount: 8000, Currency: cur}},
			"caged":       {Multiplier: 0.25, AnnualCost: money.Money{Amount: 26000, Currency: cur}},
			"denied":      {Multiplier: 0.02, AnnualCost: money.Money{Amount: 0, Currency: cur}},
		},
		Friction: model.EnforcementFriction{PerDenyControl: money.Money{Amount: 3500, Currency: cur}},
	}
	p.Metadata.Name = "test-pack"
	p.Metadata.Version = "1.0.0"
	return p
}

// testOrg builds an institution in the given jurisdiction, reporting in the given currency.
func testOrg(name, jurisdiction string, cur money.Currency) *model.OrgRiskPosture {
	o := &model.OrgRiskPosture{
		Currency: cur,
		Magnitude: map[string]model.Magnitude{
			"SCN-GLOBAL": {Triple: model.Triple{Min: 10000, Mode: 50000, Max: 300000}, Currency: cur, Provenance: "test"},
			"SCN-SCOPED": {Triple: model.Triple{Min: 20000, Mode: 90000, Max: 500000}, Currency: cur, Provenance: "test"},
		},
		RiskLoad: 0.15,
	}
	o.Metadata.Name = name
	o.Metadata.DisplayName = name
	o.Metadata.Jurisdiction = jurisdiction
	o.Appetite.Tolerance = money.Money{Amount: 25000, Currency: cur}
	o.Transfer.AnnualPremium = money.Money{Amount: 48000, Currency: cur}
	return o
}

// testAgent asserts nothing, so every control is unmet and every scenario contributes.
func testAgent() *model.AgentPosture {
	a := &model.AgentPosture{}
	a.Metadata.Name = "test-agent"
	a.Claims.Version = "1.0.0"
	return a
}

var opts = Options{Iterations: 40000, Seed: 20260801}

func run(t *testing.T, p *model.Pack, o *model.OrgRiskPosture, tbl *money.RateTable) *Report {
	t.Helper()
	op := opts
	op.Rates = tbl
	rep, err := Run(p, testAgent(), o, op)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	return rep
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Territory scoping, asserted on the TOTAL rather than on a filter function.
//
// A filter that returns the right booleans while the total ignores it is the bug worth catching,
// so these tests read the aggregate exposure, which is what a reader actually sees.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestScenarioScopedToUKCountsForUKOrgAndNotForUSOrg(t *testing.T) {
	pack := testPack("GBP", []string{"UK"})

	uk := run(t, pack, testOrg("uk-co", "UK", "GBP"), rates())
	us := run(t, pack, testOrg("us-co", "US", "GBP"), rates())

	if !(uk.Exposure.ALE.Amount > us.Exposure.ALE.Amount) {
		t.Fatalf("a UK-scoped scenario did not raise the UK institution's total above the US one: "+
			"UK ALE %.2f, US ALE %.2f", uk.Exposure.ALE.Amount, us.Exposure.ALE.Amount)
	}

	// And the US total must be exactly the total of a pack containing ONLY the global scenario —
	// not merely smaller. "Smaller" would also be satisfied by a scaling bug.
	globalOnly := testPack("GBP", []string{"UK"})
	globalOnly.Scenarios = globalOnly.Scenarios[:1]
	globalOnly.Controls = globalOnly.Controls[:1]
	baselineUS := run(t, globalOnly, testOrg("us-co", "US", "GBP"), rates())

	if us.Exposure.ALE.Amount != baselineUS.Exposure.ALE.Amount {
		t.Fatalf("excluding a scenario is not equivalent to removing it: with-exclusion ALE %.6f, "+
			"pack-without-it ALE %.6f", us.Exposure.ALE.Amount, baselineUS.Exposure.ALE.Amount)
	}
}

func TestGlobalScenarioCountsForBoth(t *testing.T) {
	pack := testPack("GBP", []string{model.Global})

	uk := run(t, pack, testOrg("uk-co", "UK", "GBP"), rates())
	us := run(t, pack, testOrg("us-co", "US", "GBP"), rates())

	if uk.Exposure.ALE != us.Exposure.ALE {
		t.Fatalf("two globally-scoped institutions with identical magnitudes produced different totals: "+
			"%v vs %v", uk.Exposure.ALE, us.Exposure.ALE)
	}
	for _, rep := range []*Report{uk, us} {
		for _, s := range rep.Scope {
			if !s.Included {
				t.Fatalf("%s: scenario %s excluded under a global pack", rep.OrgName, s.Scenario)
			}
		}
	}
}

func TestMultipleTerritoriesMatchAnyOne(t *testing.T) {
	pack := testPack("GBP", []string{"UK", "DE", "FR"})
	de := run(t, pack, testOrg("de-co", "DE", "GBP"), rates())
	jp := run(t, pack, testOrg("jp-co", "JP", "GBP"), rates())

	if !(de.Exposure.ALE.Amount > jp.Exposure.ALE.Amount) {
		t.Fatalf("DE is named in the territories and must count: DE %.2f, JP %.2f",
			de.Exposure.ALE.Amount, jp.Exposure.ALE.Amount)
	}
}

func TestTerritoryMatchIsCaseInsensitive(t *testing.T) {
	pack := testPack("GBP", []string{"uk"})
	upper := run(t, pack, testOrg("a", "UK", "GBP"), rates())
	lower := run(t, pack, testOrg("b", " uk ", "GBP"), rates())

	if upper.Exposure.ALE != lower.Exposure.ALE {
		t.Fatalf("case or whitespace changed the answer: %v vs %v", upper.Exposure.ALE, lower.Exposure.ALE)
	}
	for _, s := range upper.Scope {
		if s.Scenario == "SCN-SCOPED" && !s.Included {
			t.Fatal(`territories ["uk"] did not match jurisdiction "UK"`)
		}
	}
}

// An institution matching nothing must still produce a coherent report: real spend, real transfer,
// a stated reason, and an exposure that is explicitly labelled as "nothing here is priced" rather
// than silently reading as "no risk".
func TestOrgMatchingNoScenarioProducesACoherentTotalNotACrash(t *testing.T) {
	pack := testPack("GBP", []string{"UK"})
	pack.Scenarios[0].Territories = []string{"UK"} // scope BOTH scenarios away
	org := testOrg("jp-co", "JP", "GBP")

	rep := run(t, pack, org, rates())

	if !rep.NoApplicableScenarios {
		t.Fatal("every scenario was excluded but NoApplicableScenarios is false; a bare zero would read as a verdict")
	}
	if rep.Exposure.ALE.Amount != 0 {
		t.Fatalf("no applicable scenarios should price to zero exposure, got %v", rep.Exposure.ALE)
	}
	// Coherent, not empty: the institution still pays for its controls and its insurance.
	if rep.TCoR.Amount <= 0 {
		t.Fatalf("TCoR collapsed to %v; control spend and premium are still real costs", rep.TCoR)
	}
	if rep.TCoR.Currency != "GBP" {
		t.Fatalf("TCoR lost its denomination: %v", rep.TCoR)
	}
	if !strings.Contains(rep.TierReason, "territory scoping excluded every loss scenario") {
		t.Fatalf("the tier reason does not explain the zero: %q", rep.TierReason)
	}
	// No deltas: recommending spend to remove a risk that cannot occur here would be worse than
	// saying nothing.
	if len(rep.Deltas) != 0 {
		t.Fatalf("expected no deltas when nothing is in scope, got %d", len(rep.Deltas))
	}
}

// An institution that declares no jurisdiction must not silently match a scoped scenario.
func TestUnstatedJurisdictionDoesNotMatchAScopedScenario(t *testing.T) {
	pack := testPack("GBP", []string{"UK"})
	rep := run(t, pack, testOrg("anon", "", "GBP"), rates())

	for _, s := range rep.Scope {
		if s.Scenario != "SCN-SCOPED" {
			continue
		}
		if s.Included {
			t.Fatal("an institution with no declared jurisdiction matched a UK-scoped scenario; silence must not read as a match")
		}
		if !strings.Contains(s.Reason, "declares no metadata.jurisdiction") {
			t.Fatalf("the exclusion reason does not explain itself: %q", s.Reason)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Territory filtering must be VISIBLE, not merely applied.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestScopeIsReportedForEveryScenarioIncludedAndExcluded(t *testing.T) {
	pack := testPack("GBP", []string{"UK"})
	rep := run(t, pack, testOrg("us-co", "US", "GBP"), rates())

	if len(rep.Scope) != 2 {
		t.Fatalf("expected both scenarios in the scope table, got %d", len(rep.Scope))
	}
	byID := map[string]ScenarioScope{}
	for _, s := range rep.Scope {
		byID[s.Scenario] = s
	}
	if !byID["SCN-GLOBAL"].Included {
		t.Error("global scenario reported as excluded")
	}
	if byID["SCN-SCOPED"].Included {
		t.Error("UK-scoped scenario reported as included for a US institution")
	}
	// The reason must name the jurisdiction AND the territories, or a reader cannot tell a
	// deliberate exclusion from a typo in a scenario ID.
	reason := byID["SCN-SCOPED"].Reason
	for _, want := range []string{"US", "UK", "EXCLUDED"} {
		if !strings.Contains(reason, want) {
			t.Errorf("exclusion reason %q does not mention %q", reason, want)
		}
	}
	// The excluded scenario must also name the controls that stopped contributing.
	if len(byID["SCN-SCOPED"].Controls) == 0 {
		t.Error("excluded scenario does not say which controls it took out of play")
	}
	if got := rep.ExcludedScenarios(); len(got) != 1 || got[0].Scenario != "SCN-SCOPED" {
		t.Fatalf("ExcludedScenarios() = %+v, want just SCN-SCOPED", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Currency.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// A missing rate must fail loudly and name the pair, not silently pass the number through.
func TestMissingRateFailsNamingThePair(t *testing.T) {
	pack := testPack("CHF", []string{model.Global}) // control costs in CHF...
	org := testOrg("uk-co", "UK", "GBP")            // ...institution reports in GBP
	tbl := rates()                                  // ...and the table has no CHF

	op := opts
	op.Rates = tbl
	_, err := Run(pack, testAgent(), org, op)
	if err == nil {
		t.Fatal("a pack denominated in a currency absent from the rate table converted silently")
	}
	for _, want := range []string{"CHF", "GBP"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not name %s", err, want)
		}
	}
}

// With no rate table at all, a single-currency estate must still run — but a cross-currency one
// must fail rather than assume 1.0.
func TestNoRateTableIsFineUntilAConversionIsNeeded(t *testing.T) {
	op := opts
	op.Rates = nil

	if _, err := Run(testPack("GBP", []string{model.Global}), testAgent(), testOrg("uk", "UK", "GBP"), op); err != nil {
		t.Fatalf("a single-currency run should not require an FX table: %v", err)
	}

	_, err := Run(testPack("USD", []string{model.Global}), testAgent(), testOrg("uk", "UK", "GBP"), op)
	if err == nil {
		t.Fatal("a cross-currency run with no rate table succeeded; that is a silent 1.0")
	}
	if !strings.Contains(err.Error(), "never silently assumed to be 1.0") {
		t.Fatalf("error does not explain the refusal: %v", err)
	}
}

// Converting the whole model into another currency must scale every figure by exactly the rate and
// must NOT change any verdict. Ratios are dimensionless; a tier that moved when the denomination
// changed would be indefensible.
func TestConvertingTheEstateScalesFiguresAndPreservesVerdicts(t *testing.T) {
	tbl := rates()
	pack := testPack("GBP", []string{model.Global})

	gbp := run(t, pack, testOrg("uk-co", "UK", "GBP"), tbl)

	// The same institution, every input redenominated into USD at the table rate.
	rate, err := tbl.Rate("GBP", "USD")
	if err != nil {
		t.Fatal(err)
	}
	usdOrg := testOrg("uk-co", "UK", "USD")
	for id, m := range usdOrg.Magnitude {
		m.Triple = model.Triple{Min: m.Triple.Min * rate, Mode: m.Triple.Mode * rate, Max: m.Triple.Max * rate}
		usdOrg.Magnitude[id] = m
	}
	usdOrg.Appetite.Tolerance = money.Money{Amount: 25000 * rate, Currency: "USD"}
	usdOrg.Transfer.AnnualPremium = money.Money{Amount: 48000 * rate, Currency: "USD"}
	usd := run(t, pack, usdOrg, tbl) // pack still GBP: the conversion is exercised, not bypassed

	if usd.Exposure.ALE.Currency != "USD" {
		t.Fatalf("report currency = %s, want USD", usd.Exposure.ALE.Currency)
	}
	// Scaled by the rate, to within Monte Carlo determinism (same seed, same draw order, so the
	// only difference is float rounding on the scaled magnitudes).
	want := gbp.Exposure.ALE.Amount * rate
	if rel := math.Abs(usd.Exposure.ALE.Amount-want) / want; rel > 1e-9 {
		t.Fatalf("ALE did not scale with the rate: GBP %.4f x %.6f = %.4f, got %.4f (rel err %.2e)",
			gbp.Exposure.ALE.Amount, rate, want, usd.Exposure.ALE.Amount, rel)
	}
	// The verdict is currency-invariant.
	if usd.Tier != gbp.Tier {
		t.Fatalf("enforcement tier changed with the display denomination: %s (GBP) vs %s (USD)", gbp.Tier, usd.Tier)
	}
	if len(usd.Deltas) != len(gbp.Deltas) {
		t.Fatalf("delta count changed with currency: %d vs %d", len(gbp.Deltas), len(usd.Deltas))
	}
	for i := range usd.Deltas {
		if usd.Deltas[i].AboveTolerance != gbp.Deltas[i].AboveTolerance {
			t.Fatalf("%s: tolerance verdict flipped with the denomination", usd.Deltas[i].ControlID)
		}
	}
	// PremiumRatio is dimensionless and must be identical, not merely close in spirit.
	if rel := math.Abs(usd.PremiumRatio-gbp.PremiumRatio) / gbp.PremiumRatio; rel > 1e-9 {
		t.Fatalf("PremiumRatio is dimensionless but moved: %.9f vs %.9f", gbp.PremiumRatio, usd.PremiumRatio)
	}
}

// Every money figure in a report must carry the reporting currency. A figure that lost its
// denomination on the way out is exactly the bug this change exists to prevent.
func TestEveryReportedFigureIsDenominated(t *testing.T) {
	rep := run(t, testPack("GBP", []string{model.Global}), testOrg("uk-co", "UK", "GBP"), rates())

	check := func(name string, m money.Money) {
		t.Helper()
		if m.Currency != rep.Currency {
			t.Errorf("%s = %v, want denomination %s", name, m, rep.Currency)
		}
	}
	check("Exposure.ALE", rep.Exposure.ALE)
	check("Exposure.VaR95", rep.Exposure.VaR95)
	check("Exposure.TVaR", rep.Exposure.TVaR)
	check("Exposure.Carried", rep.Exposure.Carried)
	check("ControlSpend", rep.ControlSpend)
	check("FrictionSpend", rep.FrictionSpend)
	check("TransferSpend", rep.TransferSpend)
	check("TCoR", rep.TCoR)
	check("CageCost", rep.CageCost)
	check("Tolerance", rep.Tolerance)
	for _, d := range rep.Deltas {
		check(d.ControlID+".Buys", d.Buys)
		check(d.ControlID+".Cost", d.Cost)
		check(d.ControlID+".Net", d.Net)
	}
	for _, s := range rep.Tornado {
		check(s.Scenario+".LowALE", s.LowALE)
		check(s.Scenario+".HighALE", s.HighALE)
		check(s.Scenario+".Swing", s.Swing)
	}
	for _, r := range rep.Results {
		check(r.Control.ID+".AnnualCost", r.AnnualCost)
	}
}

// A cross-currency run must record the rate it used, so the figure can be re-derived.
func TestConversionsAreRecordedForAudit(t *testing.T) {
	rep := run(t, testPack("USD", []string{model.Global}), testOrg("uk-co", "UK", "GBP"), rates())

	if len(rep.Conversions) == 0 {
		t.Fatal("a USD pack priced into a GBP report recorded no conversion; the working is not shown")
	}
	c := rep.Conversions[0]
	if c.Source.Currency != "USD" || c.Currency != "GBP" {
		t.Fatalf("recorded conversion is %s->%s, want USD->GBP", c.Source.Currency, c.Currency)
	}
	if c.AsOf == "" || rep.RatesAsOf == "" {
		t.Error("the conversion did not carry the rate table's effective date")
	}
	if c.Rate <= 0 {
		t.Errorf("recorded rate %v is not usable", c.Rate)
	}
	// Same-currency runs must record nothing: an identity is not a conversion, and logging it
	// would bury the real ones.
	same := run(t, testPack("GBP", []string{model.Global}), testOrg("uk-co", "UK", "GBP"), rates())
	if len(same.Conversions) != 0 {
		t.Fatalf("a single-currency run recorded %d conversions", len(same.Conversions))
	}
}

// Determinism across runs, with currency and territory both in play.
func TestReportIsByteIdenticalAcrossRunsWithConversion(t *testing.T) {
	pack := testPack("USD", []string{"UK"})
	org := testOrg("uk-co", "UK", "GBP")

	first := run(t, pack, org, rates())
	for i := 0; i < 5; i++ {
		again := run(t, pack, org, rates())
		if first.Exposure != again.Exposure || first.TCoR != again.TCoR || first.Tier != again.Tier {
			t.Fatalf("run %d diverged:\n first %+v %v %s\n again %+v %v %s",
				i+2, first.Exposure, first.TCoR, first.Tier, again.Exposure, again.TCoR, again.Tier)
		}
		if len(first.Conversions) != len(again.Conversions) || first.Conversions[0] != again.Conversions[0] {
			t.Fatalf("run %d recorded different conversions", i+2)
		}
	}
}

// The shipped estate must remain single-currency and globally scoped. If someone later denominates
// an org differently or scopes a scenario, this fails and forces them to re-baseline the demo
// numbers deliberately rather than discovering the movement on stage.
func TestShippedEstateIsSingleCurrencyAndGlobal(t *testing.T) {
	for _, v := range []string{"2.0.0", "2.1.0"} {
		p, _, _ := loadAll(t, v, "agent-remediation", "acme")
		if p.Currency != "GBP" {
			t.Errorf("pack %s currency = %s, want GBP", v, p.Currency)
		}
		for _, s := range p.Scenarios {
			if !s.IsGlobal() {
				t.Errorf("pack %s scenario %s is territory-scoped to %v; the demo figures were "+
					"baselined with every scenario global", v, s.ID, s.Territories)
			}
		}
	}
	for _, org := range []string{"acme", "ludlow-health"} {
		_, _, o := loadAll(t, "2.1.0", "agent-remediation", org)
		if o.Currency != "GBP" {
			t.Errorf("org %s currency = %s, want GBP", org, o.Currency)
		}
		for id, m := range o.Magnitude {
			if m.Currency != "GBP" {
				t.Errorf("org %s magnitude %s is denominated %s", org, id, m.Currency)
			}
		}
	}
}
