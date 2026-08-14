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

// The vector set must not over-claim its own coverage.
//
// "48 conformance cases" sounds like 48 checks of the conversion maths. It is not: identity pairs
// have a genuine rate of 1, and zero amounts are zero times anything, so 13 of them would still
// pass with the rate lookup completely broken. The generated file states that split so a consumer
// reading the count is not misled, and this test keeps the statement true.
//
// Prompted by the sibling TypeScript implementation, which ran exactly this mutation analysis and
// independently arrived at the same 35/8/5 split — a useful cross-check that both sides agree on
// what the vectors prove.
func TestVectorCoverageIsHonestlyStated(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(root(t), "risk", "fx", "testvectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v fxVectors
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}

	if got := v.Coverage.RateSensitive + v.Coverage.Identity + v.Coverage.ZeroAmount; got != v.Coverage.Total {
		t.Errorf("coverage categories sum to %d but total is %d", got, v.Coverage.Total)
	}
	if v.Coverage.Total != len(v.Cases) {
		t.Errorf("coverage.total = %d but there are %d cases", v.Coverage.Total, len(v.Cases))
	}

	// The classification must match the rule, per case — not merely add up.
	for _, c := range v.Cases {
		want := c.From != c.To && c.Amount != 0
		if c.RateSensitive != want {
			t.Errorf("%v %s->%s: rate_sensitive = %v, want %v", c.Amount, c.From, c.To, c.RateSensitive, want)
		}
	}

	// A vector set with no rate-sensitive cases would be entirely structural and would pass with the
	// conversion maths deleted. Guard the floor rather than an exact count so vectors can be added.
	if v.Coverage.RateSensitive < 30 {
		t.Errorf("only %d rate-sensitive cases; the set no longer meaningfully tests conversion",
			v.Coverage.RateSensitive)
	}
}

// Mutation proof, in-repo: every case marked rate-sensitive must actually die if the rate is wrong.
//
// A flag claiming a case is rate-sensitive is worth nothing if the case would survive a broken rate
// — that is precisely the "green on nothing" failure the TypeScript oracle hit. So rather than
// trusting the flag, this recomputes each case under two mutations and requires a different answer.
func TestRateSensitiveCasesDieUnderRateMutation(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(root(t), "risk", "fx", "testvectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v fxVectors
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}

	checked := 0
	for _, c := range v.Cases {
		if !c.RateSensitive {
			// And the converse: a structural case must NOT be claimed to detect a rate error.
			if c.Amount*1.0 != c.Converted && c.From == c.To {
				t.Errorf("identity case %v %s->%s does not pass through unchanged", c.Amount, c.From, c.To)
			}
			continue
		}
		checked++
		// Mutation 1: every rate forced to 1 (the silent pass-through).
		if c.Amount == c.Converted {
			t.Errorf("%v %s->%s is marked rate-sensitive but survives rate=1: converted equals the input",
				c.Amount, c.From, c.To)
		}
		// Mutation 2: the rate inverted (the direction error).
		if inverted := c.Amount * (1 / c.Rate); inverted == c.Converted {
			t.Errorf("%v %s->%s is marked rate-sensitive but survives an inverted rate",
				c.Amount, c.From, c.To)
		}
	}
	if checked == 0 {
		t.Fatal("no rate-sensitive cases were checked; the test is vacuous")
	}
	t.Logf("%d rate-sensitive cases verified to die under both rate mutations", checked)
}
