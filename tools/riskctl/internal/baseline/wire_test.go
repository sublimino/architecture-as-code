package baseline

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"

	"github.com/acme-co/osramp/tools/riskctl/internal/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// moneyish matches key names that denote an amount of money. If a key like this maps to a bare
// number rather than an {amount, currency} object, a consumer gets a figure with no denomination.
var moneyish = regexp.MustCompile(`(?i)(^|[^a-z])(ale|var95|tvar|carried|cost|spend|tcor|tolerance|buys|net|swing|premium|exposure|magnitude|cage)([^a-z]|$)`)

// dimensionless are the keys that LOOK monetary but genuinely are not, each with a reason. Every
// entry here is a deliberate exemption, not a convenience: a ratio or a percentage has no
// denomination, and giving one a currency would be as wrong as omitting one from an amount.
var dimensionless = map[string]string{
	"PremiumRatio":   "ALE / premium -- both in the reporting currency, so the ratio is dimensionless",
	"SharePct":       "a percentage share of total swing",
	"RiskLoad":       "a multiplier (0.15 = 15%), not an amount",
	"riskLoad":       "a multiplier, not an amount",
	"CageMultiplier": "a frequency multiplier, not an amount",
	"NetGBP":         "legacy key name; must not appear -- asserted absent below",
}

// walk descends the decoded JSON and reports every money-ish key that is not a denominated object.
func walk(t *testing.T, path string, v any, bad *[]string) {
	t.Helper()
	switch n := v.(type) {
	case map[string]any:
		// A denominated amount: exactly {amount, currency}. Stop -- its `amount` is legitimately bare.
		if amt, hasAmt := n["amount"]; hasAmt {
			if cur, hasCur := n["currency"]; hasCur {
				if s, ok := cur.(string); !ok || money.Currency(s).Validate() != nil {
					*bad = append(*bad, path+": currency is not a valid ISO 4217 code: "+strings.TrimSpace(path))
				}
				if _, ok := amt.(float64); !ok {
					*bad = append(*bad, path+".amount is not a number")
				}
				return
			}
		}
		for k, child := range n {
			p := path + "." + k
			if _, exempt := dimensionless[k]; !exempt && moneyish.MatchString(k) {
				if _, isNum := child.(float64); isNum {
					*bad = append(*bad, p+" is a BARE NUMBER that means money")
				}
			}
			walk(t, p, child, bad)
		}
	case []any:
		for i, child := range n {
			walk(t, path+"[", child, bad)
			_ = i
		}
	}
}

// The load-bearing wire invariant: nothing that means money crosses the boundary as a bare number.
//
// This is asserted on the SERIALISED document rather than on the Go types, because that is what a
// consumer actually receives. A struct field can be a money.Money and still reach the wire
// undenominated if something upstream flattens it, and the failure is invisible from the Go side.
//
// It caught a real defect: Report.Risk (fair.Result) was serialising ALE, VaR95, TVaR and Carried
// as bare float64s directly beside the denominated Exposure -- an undenominated figure under the
// most obvious key in the document.
func TestNoBareMoneyCrossesTheWire(t *testing.T) {
	rep := run(t, testPack("GBP", []string{model.Global}), testOrg("uk-co", "UK", "GBP"), rates())

	b, err := json.Marshal(rep)
	if err != nil {
		t.Fatal(err)
	}
	var doc any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}

	var bad []string
	walk(t, "$", doc, &bad)
	if len(bad) > 0 {
		t.Fatalf("undenominated money reached the wire:\n  %s\n\nEvery amount must serialise as "+
			"{\"amount\": N, \"currency\": \"XXX\"}. A bare number here is a figure a consumer will "+
			"render with whatever symbol it happens to default to.", strings.Join(bad, "\n  "))
	}

	// And the legacy suffixed key names must be gone from the wire entirely, not merely deprecated.
	for _, legacy := range []string{"BuysGBP", "CostGBP", "NetGBP", "SwingGBP", "ToleranceGBP", "CarriedGBP"} {
		if strings.Contains(string(b), `"`+legacy+`"`) {
			t.Errorf("legacy key %q still on the wire; the currency must live in the value, not the name", legacy)
		}
	}
}

// The reporting currency must appear once, at the top, so a consumer can label the whole document
// without inspecting every figure.
func TestReportDeclaresItsCurrencyAtTheTop(t *testing.T) {
	rep := run(t, testPack("GBP", []string{model.Global}), testOrg("uk-co", "UK", "GBP"), rates())
	b, _ := json.Marshal(rep)
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["Currency"] != "GBP" {
		t.Fatalf("top-level Currency = %v, want GBP", doc["Currency"])
	}
	// Simulation provenance survives even though the money moved out of fair.Result.
	sim, ok := doc["Simulation"].(map[string]any)
	if !ok {
		t.Fatal("Simulation block missing; reproducibility provenance was lost with the money fields")
	}
	for _, k := range []string{"iterations", "seed", "riskLoad", "tailDominated"} {
		if _, ok := sim[k]; !ok {
			t.Errorf("Simulation.%s missing", k)
		}
	}
	if sim["seed"].(float64) == 0 {
		t.Error("Simulation.seed is zero; the number is not reproducible without it")
	}
}
