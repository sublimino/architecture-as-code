package model

// Adversarial tests for the model loader's input validation.
//
// Round 6 adversarial testing — currency, locale, and financial edge cases.
// These target the gap where YAML accepts a value the loader's validation misses,
// so a structurally valid but semantically corrupt number reaches the FAIR engine.

import (
	"strings"
	"testing"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// RiskLoad validation.
//
// risk_load is the percentage markup on TVaR that produces the Carried figure. The computation
// is `tvar * (1 + riskLoad)`, so:
//   - NaN  → Carried = NaN   (passes all IEEE 754 comparisons, reaches the report)
//   - +Inf → Carried = +Inf  (a meaningless number with a currency code)
//   - -1   → Carried = 0     (tail risk vanishes, which is not a coherent posture)
//   - -2   → Carried < 0     (negative carried risk, violates a distribution identity)
//
// YAML parses `.nan`, `.inf`, `-.inf` as valid float64 tokens, so the check belongs here at
// the input boundary.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestRiskLoadNaNIsRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "risk_load: 0.15", "risk_load: .nan", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("risk_load: .nan loaded silently; it would produce NaN Carried in every simulation " +
			"and NaN passes all IEEE 754 comparisons, so SelfCheck cannot reliably catch it on every path")
	}
	if !strings.Contains(err.Error(), "risk_load") {
		t.Errorf("error does not name the field: %v", err)
	}
	if !strings.Contains(err.Error(), "finite") {
		t.Errorf("error does not explain the constraint: %v", err)
	}
}

func TestRiskLoadInfIsRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "risk_load: 0.15", "risk_load: .inf", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("risk_load: .inf loaded silently; it would produce +Inf Carried in every simulation")
	}
	if !strings.Contains(err.Error(), "risk_load") {
		t.Errorf("error does not name the field: %v", err)
	}
}

func TestRiskLoadNegInfIsRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "risk_load: 0.15", "risk_load: -.inf", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("risk_load: -.inf loaded silently")
	}
}

func TestRiskLoadNegativeIsRejected(t *testing.T) {
	body := strings.Replace(minimalOrg, "risk_load: 0.15", "risk_load: -0.5", 1)
	_, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err == nil {
		t.Fatal("risk_load: -0.5 loaded silently; a negative load makes Carried < TVaR, " +
			"which violates a distribution identity")
	}
	if !strings.Contains(err.Error(), "risk_load") {
		t.Errorf("error does not name the field: %v", err)
	}
	if !strings.Contains(err.Error(), "negative") || !strings.Contains(err.Error(), "carried") {
		t.Errorf("error does not explain WHY a negative load is wrong: %v", err)
	}
}

func TestRiskLoadZeroIsAccepted(t *testing.T) {
	// Zero risk load is valid: "no margin for model uncertainty". Carried == TVaR.
	body := strings.Replace(minimalOrg, "risk_load: 0.15", "risk_load: 0", 1)
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err != nil {
		t.Fatalf("risk_load: 0 rejected: %v", err)
	}
	if o.RiskLoad != 0 {
		t.Fatalf("RiskLoad = %g, want 0", o.RiskLoad)
	}
}

func TestRiskLoadOmittedDefaultsToZero(t *testing.T) {
	// An omitted risk_load is valid: Go's zero value for float64 is 0.0.
	body := strings.Replace(minimalOrg, "risk_load: 0.15\n", "", 1)
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err != nil {
		t.Fatalf("omitted risk_load rejected: %v", err)
	}
	if o.RiskLoad != 0 {
		t.Fatalf("RiskLoad = %g, want 0 (the Go zero value)", o.RiskLoad)
	}
}

func TestRiskLoadLargeButFiniteIsAccepted(t *testing.T) {
	// A risk load of 1.0 (100% markup) is aggressive but defensible — it doubles the carried
	// figure. The constraint is finiteness and non-negativity, not a range opinion.
	body := strings.Replace(minimalOrg, "risk_load: 0.15", "risk_load: 1.0", 1)
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", body))
	if err != nil {
		t.Fatalf("risk_load: 1.0 rejected: %v; a large but finite load is the institution's call", err)
	}
	if o.RiskLoad != 1.0 {
		t.Fatalf("RiskLoad = %g, want 1.0", o.RiskLoad)
	}
}

func TestRiskLoadNormalValueIsAccepted(t *testing.T) {
	o, err := LoadOrgRiskPosture(write(t, "org.yaml", minimalOrg))
	if err != nil {
		t.Fatalf("minimal org rejected: %v", err)
	}
	if o.RiskLoad != 0.15 {
		t.Fatalf("RiskLoad = %g, want 0.15", o.RiskLoad)
	}
}
