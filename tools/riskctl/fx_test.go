package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func root(t *testing.T) string {
	t.Helper()
	return filepath.Join("..", "..")
}

// The generated JSON is what non-Go consumers read. A stale copy means the dashboard and the risk
// engine quote different rates for the same figure, with nothing to notice — so staleness is a
// failing test rather than a convention.
func TestGeneratedFXArtefactsAreCurrent(t *testing.T) {
	if err := runFX(root(t), true); err != nil {
		t.Fatalf("%v", err)
	}
}

// The cross rates a consumer looks up must equal the ones the engine computes. This is the property
// that lets the frontend implement LOOKUP rather than arithmetic: there is no second implementation
// of the division to get wrong.
func TestGeneratedPairsMatchTheEngine(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(root(t), "risk", "fx", "rates.json"))
	if err != nil {
		t.Fatal(err)
	}
	var gen fxTable
	if err := json.Unmarshal(b, &gen); err != nil {
		t.Fatal(err)
	}
	tbl, err := loadRates(root(t), "")
	if err != nil {
		t.Fatal(err)
	}
	if gen.AsOf != tbl.AsOf {
		t.Fatalf("generated as_of %q != source %q", gen.AsOf, tbl.AsOf)
	}
	for from, row := range gen.Pairs {
		for to, got := range row {
			want, err := tbl.Rate(from, to)
			if err != nil {
				t.Errorf("%s->%s in generated table but not derivable: %v", from, to, err)
				continue
			}
			// Byte-identical, not approximate: both sides came from the same function, and a
			// tolerance here would hide exactly the drift this test exists to catch.
			if got != want {
				t.Errorf("%s->%s: generated %.17g, engine %.17g", from, to, got, want)
			}
		}
	}
	// Every currency must appear in the matrix, or a consumer gets a null for a pair we support.
	if len(gen.Pairs) != len(tbl.Rates) {
		t.Errorf("pairs matrix has %d rows for %d currencies", len(gen.Pairs), len(tbl.Rates))
	}
}

// The conformance vectors must be reproducible from the engine, so a TypeScript implementation
// checked against them is genuinely checked against this code.
func TestGeneratedVectorsAreSelfConsistent(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(root(t), "risk", "fx", "testvectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v fxVectors
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Cases) == 0 {
		t.Fatal("no conformance cases emitted")
	}
	sawIdentity, sawNegative, sawHalf, sawZeroDecimal := false, false, false, false
	for _, c := range v.Cases {
		if c.From == c.To {
			sawIdentity = true
			// The identity must be exact, or every GBP figure in the repo moves.
			if c.Rate != 1.0 || c.Converted != c.Amount {
				t.Errorf("identity case %s->%s is not exact: rate %v, %v -> %v",
					c.From, c.To, c.Rate, c.Amount, c.Converted)
			}
		}
		if c.Amount < 0 {
			sawNegative = true
		}
		if c.Amount == 2.675 || c.Amount == 0.125 {
			sawHalf = true
		}
		if c.MinorUnits == 0 {
			sawZeroDecimal = true
		}
		if c.Rate <= 0 {
			t.Errorf("case %s->%s has unusable rate %v", c.From, c.To, c.Rate)
		}
	}
	// The vectors are only useful if they cover the cases another language gets WRONG.
	for name, ok := range map[string]bool{
		"an identity conversion":        sawIdentity,
		"a negative amount":             sawNegative,
		"a .x5 rounding boundary":       sawHalf,
		"a zero-decimal currency (JPY)": sawZeroDecimal,
	} {
		if !ok {
			t.Errorf("conformance vectors do not cover %s; a consumer could pass them and still be wrong", name)
		}
	}
}
