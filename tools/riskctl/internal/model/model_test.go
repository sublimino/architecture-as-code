package model

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

const minimalOrg = `apiVersion: osramp.controlplane.io/v1alpha1
kind: OrgRiskPosture
metadata:
  name: t
  jurisdiction: UK
currency: GBP
appetite:
  tolerance: 25000
risk_load: 0.15
transfer:
  annual_premium: 48000
  retention: 100000
  limit: 5000000
magnitude:
  SCN-A:
    triple: { min: 1000, mode: 5000, max: 20000 }
    provenance: test
`

// ─────────────────────────────────────────────────────────────────────────────────────────────
// The legacy-key guard. This is the highest-value test in the package.
//
// yaml.v3 silently ignores keys the target struct does not declare. Without this guard an
// unmigrated file carrying `annual_cost_gbp: 4000` loads cleanly with the cost at ZERO — every
// control silently free, Total Cost of Risk understated, no error anywhere. A wrong number with no
// warning is strictly worse than a failure to load.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestLegacyCurrencySuffixedKeysAreRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "tolerance: 25000", "tolerance_gbp: 25000", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("a legacy `tolerance_gbp` key loaded silently; it would have zeroed the tolerance band")
	}
	for _, want := range []string{"tolerance_gbp", "currency:", "understate"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %q:\n%v", want, err)
		}
	}
}

func TestLegacyKeyErrorNamesTheLine(t *testing.T) {
	body := strings.Replace(minimalOrg, "annual_premium: 48000", "annual_premium_gbp: 48000", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("expected rejection")
	}
	if !strings.Contains(err.Error(), "line ") {
		t.Errorf("error does not name the offending line, so an operator cannot find it: %v", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// A document that declares money must declare its denomination.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestOrgWithoutCurrencyIsRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "currency: GBP\n", "", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("an institution with no reporting currency loaded; every figure in its report would be unlabelled")
	}
	if !strings.Contains(err.Error(), "currency") {
		t.Errorf("unhelpful error: %v", err)
	}
}

func TestBareAmountsInheritTheDocumentCurrency(t *testing.T) {
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", minimalOrg))
	if err != nil {
		t.Fatal(err)
	}
	if o.Appetite.Tolerance.Currency != "GBP" || o.Appetite.Tolerance.Amount != 25000 {
		t.Fatalf("tolerance = %v, want 25000 GBP", o.Appetite.Tolerance)
	}
	if o.Transfer.Limit.Currency != "GBP" {
		t.Fatalf("transfer.limit = %v, want a GBP denomination", o.Transfer.Limit)
	}
	if o.Magnitude["SCN-A"].Currency != "GBP" {
		t.Fatalf("magnitude currency = %q, want the document default", o.Magnitude["SCN-A"].Currency)
	}
}

func TestExplicitlyDenominatedAmountOverridesTheDocumentDefault(t *testing.T) {
	body := strings.Replace(minimalOrg, "annual_premium: 48000",
		"annual_premium: { amount: 60000, currency: EUR }", 1)
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err != nil {
		t.Fatal(err)
	}
	if o.Transfer.AnnualPremium.Currency != "EUR" || o.Transfer.AnnualPremium.Amount != 60000 {
		t.Fatalf("premium = %v, want 60000 EUR; an explicit denomination must survive the file default",
			o.Transfer.AnnualPremium)
	}
	// ...while its neighbours still inherit.
	if o.Transfer.Retention.Currency != "GBP" {
		t.Fatalf("retention = %v, want GBP", o.Transfer.Retention)
	}
}

func TestPerScenarioMagnitudeCurrencyOverride(t *testing.T) {
	body := strings.Replace(minimalOrg,
		"    triple: { min: 1000, mode: 5000, max: 20000 }",
		"    triple: { min: 1000, mode: 5000, max: 20000 }\n    currency: USD", 1)
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err != nil {
		t.Fatal(err)
	}
	if o.Magnitude["SCN-A"].Currency != "USD" {
		t.Fatalf("magnitude currency = %q, want USD", o.Magnitude["SCN-A"].Currency)
	}
}

func TestMalformedCurrencyCodeIsRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "currency: GBP", "currency: pounds", 1)
	if _, err := LoadOrgRiskPosture(write(t, "org.yaml", body)); err == nil {
		t.Fatal("`currency: pounds` was accepted; only ISO 4217 codes are meaningful to a converter")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Territory scoping on the Scenario type.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestScenarioTerritoryMatching(t *testing.T) {
	cases := []struct {
		name         string
		territories  []string
		jurisdiction string
		want         bool
	}{
		{"absent means global", nil, "US", true},
		{"explicit wildcard", []string{Global}, "US", true},
		{"wildcard among others still global", []string{"UK", Global}, "JP", true},
		{"exact match", []string{"UK"}, "UK", true},
		{"no match", []string{"UK"}, "US", false},
		{"one of several", []string{"UK", "DE", "FR"}, "DE", true},
		{"case insensitive territory", []string{"uk"}, "UK", true},
		{"case insensitive jurisdiction", []string{"UK"}, "uk", true},
		{"whitespace tolerated", []string{" UK "}, "UK", true},
		{"empty jurisdiction never matches a scoped scenario", []string{"UK"}, "", false},
		{"empty jurisdiction still matches global", []string{Global}, "", true},
	}
	for _, c := range cases {
		s := Scenario{ID: "S", Territories: c.territories}
		if got := s.AppliesTo(c.jurisdiction); got != c.want {
			t.Errorf("%s: Scenario{%v}.AppliesTo(%q) = %v, want %v",
				c.name, c.territories, c.jurisdiction, got, c.want)
		}
	}
}

func TestLoadPackNormalisesAbsentTerritoriesToWildcard(t *testing.T) {
	body := `apiVersion: v1
kind: PolicyPack
metadata:
  name: p
  version: 1.0.0
currency: GBP
scenarios:
  - id: SCN-A
    title: t
controls:
  - id: C-1
    title: t
    scenario: SCN-A
    action: audit
    rationale: r
    evidence: { artifact: a }
    lef_audit: { min: 0.1, mode: 0.5, max: 1.0 }
    lef_enforced: { min: 0.01, mode: 0.05, max: 0.1 }
    annual_cost: 1000
`
	p, err := LoadPack(write(t, "pack.yaml", body))
	if err != nil {
		t.Fatal(err)
	}
	// Normalised to the explicit wildcard so every consumer sees one shape and nobody has to
	// remember that "empty means global".
	if len(p.Scenarios[0].Territories) != 1 || p.Scenarios[0].Territories[0] != Global {
		t.Fatalf("territories = %v, want [%q]", p.Scenarios[0].Territories, Global)
	}
	if !p.Scenarios[0].IsGlobal() {
		t.Fatal("normalised scenario does not report as global")
	}
	if p.Controls[0].AnnualCost.Currency != "GBP" {
		t.Fatalf("control cost = %v, want the document currency", p.Controls[0].AnnualCost)
	}
	if p.Friction.PerDenyControl.Currency != "GBP" {
		t.Fatalf("friction = %v, want a denomination even when zero", p.Friction.PerDenyControl)
	}
}

func TestPackWithMoneyButNoCurrencyIsRejected(t *testing.T) {
	body := `apiVersion: v1
kind: PolicyPack
metadata:
  name: p
  version: 1.0.0
scenarios:
  - id: SCN-A
    title: t
controls:
  - id: C-1
    title: t
    scenario: SCN-A
    action: audit
    rationale: r
    evidence: { artifact: a }
    lef_audit: { min: 0.1, mode: 0.5, max: 1.0 }
    lef_enforced: { min: 0.01, mode: 0.05, max: 0.1 }
    annual_cost: 1000
`
	_, err := LoadPack(write(t, "pack.yaml", body))
	if err == nil {
		t.Fatal("a pack with bare amounts and no document currency loaded; the costs would be unlabelled")
	}
	if !strings.Contains(err.Error(), "C-1") {
		t.Errorf("error does not name the offending control: %v", err)
	}
}

func TestEmptyTerritoryStringIsRejected(t *testing.T) {
	body := `apiVersion: v1
kind: PolicyPack
metadata: { name: p, version: 1.0.0 }
currency: GBP
scenarios:
  - id: SCN-A
    title: t
    territories: ["UK", ""]
controls:
  - id: C-1
    title: t
    scenario: SCN-A
    action: audit
    rationale: r
    evidence: { artifact: a }
    lef_audit: { min: 0.1, mode: 0.5, max: 1.0 }
    lef_enforced: { min: 0.01, mode: 0.05, max: 0.1 }
    annual_cost: 1000
`
	if _, err := LoadPack(write(t, "pack.yaml", body)); err == nil {
		t.Fatal(`an empty territory string was accepted; it matches nothing and reads like an oversight`)
	}
}

// The shipped files must load. This is the schema gate for the migration itself.
func TestShippedRiskDataLoads(t *testing.T) {
	root := filepath.Join("..", "..", "..", "..")
	for _, v := range []string{"2.0.0", "2.1.0"} {
		if _, err := LoadPack(filepath.Join(root, "risk", "packs", "agent-policy", v, "pack.yaml")); err != nil {
			t.Errorf("pack %s: %v", v, err)
		}
	}
	for _, o := range []string{"acme", "ludlow-health"} {
		if _, err := LoadOrgRiskPosture(filepath.Join(root, "risk", "org", o+".yaml")); err != nil {
			t.Errorf("org %s: %v", o, err)
		}
	}
}
