package money

// Adversarial tests for Money.UnmarshalYAML — non-finite values that slip through
// the YAML → ParseFloat → Money boundary.
//
// Round 6 adversarial testing. The bug class is an input validation gap at a
// serialisation boundary: YAML and ParseFloat both accept tokens that represent
// valid IEEE 754 values but are not money (NaN, Inf). The custom UnmarshalYAML
// must reject them at the boundary rather than carrying them into arithmetic
// where IEEE 754 comparison semantics produce wrong verdicts.

import (
	"testing"

	"gopkg.in/yaml.v3"
)

// unmarshalMoney is a helper that unmarshals a YAML string into a Money value
// via the full YAML pipeline (including tag resolution and custom UnmarshalYAML).
func unmarshalMoney(t *testing.T, yamlStr string) (Money, error) {
	t.Helper()
	// Wrap in a struct so the Money's custom UnmarshalYAML is invoked.
	type wrapper struct {
		Value Money `yaml:"value"`
	}
	var w wrapper
	err := yaml.Unmarshal([]byte(yamlStr), &w)
	return w.Value, err
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Scalar form: `value: NaN`
//
// yaml.v3 resolves `.nan` and `.NaN` with tag !!float, but `NaN` and `nan` with tag !!str.
// ParseFloat accepts the !!str forms ("NaN", "nan") and returns math.NaN(). Without a guard
// in UnmarshalYAML, a NaN amount enters the model as a structurally valid Money.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestUnmarshalScalarNaN(t *testing.T) {
	// The YAML !!str tokens that ParseFloat silently accepts as NaN.
	for _, token := range []string{"NaN", "nan"} {
		t.Run(token, func(t *testing.T) {
			_, err := unmarshalMoney(t, "value: "+token)
			if err == nil {
				t.Fatalf("value: %s loaded silently; NaN is not money and must be rejected at the "+
					"YAML boundary before it enters arithmetic", token)
			}
		})
	}
}

func TestUnmarshalScalarDotNaN(t *testing.T) {
	// The YAML !!float tokens — these are rejected by ParseFloat because of the leading dot,
	// but verify that the rejection is an error, not a silent zero.
	for _, token := range []string{".nan", ".NaN", ".NAN"} {
		t.Run(token, func(t *testing.T) {
			_, err := unmarshalMoney(t, "value: "+token)
			if err == nil {
				t.Fatalf("value: %s loaded silently", token)
			}
		})
	}
}

func TestUnmarshalScalarInf(t *testing.T) {
	// ParseFloat accepts "Inf" and "+Inf" and "-Inf" but not ".Inf".
	for _, token := range []string{"Inf", "+Inf", "-Inf"} {
		t.Run(token, func(t *testing.T) {
			_, err := unmarshalMoney(t, "value: "+token)
			if err == nil {
				t.Fatalf("value: %s loaded silently; Inf is not money", token)
			}
		})
	}
}

func TestUnmarshalScalarDotInf(t *testing.T) {
	for _, token := range []string{".inf", ".Inf", ".INF", "-.inf", "-.Inf"} {
		t.Run(token, func(t *testing.T) {
			_, err := unmarshalMoney(t, "value: "+token)
			if err == nil {
				t.Fatalf("value: %s loaded silently", token)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Mapping form: `value: { amount: .nan, currency: GBP }`
//
// In the mapping form, yaml.v3 decodes `amount: .nan` via its own float parser into NaN
// directly into the float64 field. The custom UnmarshalYAML must check the decoded value.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestUnmarshalMappingNaN(t *testing.T) {
	_, err := unmarshalMoney(t, "value: { amount: .nan, currency: GBP }")
	if err == nil {
		t.Fatal("amount: .nan in mapping form loaded silently; NaN is not money")
	}
}

func TestUnmarshalMappingInf(t *testing.T) {
	_, err := unmarshalMoney(t, "value: { amount: .inf, currency: GBP }")
	if err == nil {
		t.Fatal("amount: .inf in mapping form loaded silently; Inf is not money")
	}
}

func TestUnmarshalMappingNegInf(t *testing.T) {
	_, err := unmarshalMoney(t, "value: { amount: -.inf, currency: GBP }")
	if err == nil {
		t.Fatal("amount: -.inf in mapping form loaded silently")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Valid amounts must still unmarshal correctly.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func TestUnmarshalValidScalar(t *testing.T) {
	m, err := unmarshalMoney(t, "value: 25000")
	if err != nil {
		t.Fatalf("value: 25000 rejected: %v", err)
	}
	if m.Amount != 25000 {
		t.Fatalf("Amount = %g, want 25000", m.Amount)
	}
}

func TestUnmarshalValidMapping(t *testing.T) {
	m, err := unmarshalMoney(t, "value: { amount: 25000, currency: GBP }")
	if err != nil {
		t.Fatalf("valid mapping rejected: %v", err)
	}
	if m.Amount != 25000 || m.Currency != "GBP" {
		t.Fatalf("got %v, want 25000 GBP", m)
	}
}

func TestUnmarshalZeroIsValid(t *testing.T) {
	m, err := unmarshalMoney(t, "value: 0")
	if err != nil {
		t.Fatalf("value: 0 rejected: %v", err)
	}
	if m.Amount != 0 {
		t.Fatalf("Amount = %g, want 0", m.Amount)
	}
}

func TestUnmarshalNegativeIsValid(t *testing.T) {
	// Negative amounts are structurally valid — whether they're semantically valid depends on
	// the field (e.g. a negative tolerance is caught by the loader, not the unmarshaler).
	m, err := unmarshalMoney(t, "value: -500")
	if err != nil {
		t.Fatalf("value: -500 rejected: %v", err)
	}
	if m.Amount != -500 {
		t.Fatalf("Amount = %g, want -500", m.Amount)
	}
}
