package obscel

import (
	"context"
	"strings"
	"testing"
	"time"
)

func testObservation() Observation {
	return Observation{
		ID:         "obs-1",
		Timestamp:  time.Date(2026, 10, 4, 8, 0, 0, 0, time.UTC),
		Layer:      "cloud_control_plane",
		Source:     "aws:cloudtrail",
		Fidelity:   "high",
		Confidence: 0.91,
		TenantID:   "kusari",
		Actor:      "arn:aws:iam::123456789012:user/dev",
		Labels: map[string]string{
			"event_source": "iam.amazonaws.com",
			"event_name":   "AttachUserPolicy",
			"aws_region":   "eu-west-2",
		},
	}
}

// evalExpr compiles and evaluates one expression against obs/vars.
func evalExpr(t *testing.T, expr string, obs Observation, vars map[string][]string) (any, error) {
	t.Helper()
	c, err := NewCompiler()
	if err != nil {
		t.Fatalf("NewCompiler: %v", err)
	}
	prg, err := c.Compile(expr)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), EvalTimeout)
	defer cancel()
	out, _, err := prg.ContextEval(ctx, Activation(obs, vars))
	if err != nil {
		return nil, err
	}
	return out.Value(), nil
}

// TestEnvExportsEveryObservationField pins the vocabulary: every field the
// proposal §4.1 names must be readable, under the json-tag spelling. A rename
// in types.go that drops one of these breaks every shipped bundle, so the whole
// set is asserted in one place.
func TestEnvExportsEveryObservationField(t *testing.T) {
	obs := testObservation()
	cases := map[string]string{
		"id":         `obs.id == "obs-1"`,
		"timestamp":  `obs.timestamp == timestamp("2026-10-04T08:00:00Z")`,
		"layer":      `obs.layer == "cloud_control_plane"`,
		"source":     `obs.source == "aws:cloudtrail"`,
		"fidelity":   `obs.fidelity == "high"`,
		"confidence": `obs.confidence > 0.9`,
		"tenant_id":  `obs.tenant_id == "kusari"`,
		"actor":      `obs.actor.startsWith("arn:aws:iam::")`,
		"labels":     `obs.labels.aws_region == "eu-west-2"`,
	}
	for field, expr := range cases {
		got, err := evalExpr(t, expr, obs, nil)
		if err != nil {
			t.Errorf("field %q: %v", field, err)
			continue
		}
		if got != true {
			t.Errorf("field %q: expected true, got %v", field, got)
		}
	}
}

// TestHasOnAbsentLabelIsFalseAndNeverErrors is the binding missing-key
// semantics from doc.go. An unlabelled record must not become a finding by
// accident, and it must not become an evaluator fault either.
func TestHasOnAbsentLabelIsFalseAndNeverErrors(t *testing.T) {
	obs := testObservation()

	got, err := evalExpr(t, `has(obs.labels.error_code)`, obs, nil)
	if err != nil {
		t.Fatalf("has() on an absent label key must never error, got: %v", err)
	}
	if got != false {
		t.Fatalf("has() on an absent label key must be false, got %v", got)
	}

	// And on an observation with no labels at all.
	obs.Labels = nil
	got, err = evalExpr(t, `has(obs.labels.event_name)`, obs, nil)
	if err != nil {
		t.Fatalf("has() against a nil label map must never error, got: %v", err)
	}
	if got != false {
		t.Fatalf("has() against a nil label map must be false, got %v", got)
	}

	// The guarded form is therefore safe on an unlabelled record.
	got, err = evalExpr(t, `has(obs.labels.event_name) && obs.labels.event_name == "CreateAccessKey"`, obs, nil)
	if err != nil {
		t.Fatalf("guarded label access must never error, got: %v", err)
	}
	if got != false {
		t.Fatalf("guarded label access on an unlabelled record must be false, got %v", got)
	}
}

// TestMisspelledObservationFieldIsACompileError is why obs is a native type
// rather than a dyn map: a typo is caught by Conform at load time instead of
// becoming a per-observation runtime fault that silently detects nothing.
func TestMisspelledObservationFieldIsACompileError(t *testing.T) {
	if _, err := evalExpr(t, `obs.evemt_name == "x"`, testObservation(), nil); err == nil {
		t.Fatal("a misspelled obs field must be a compile error, not a silent false")
	}
}

// TestVarsAndBundleVarsAreEquivalent covers both spellings of the allowlist
// lookup, including the §4.2 `bundle.vars.X` form operators copy from.
func TestVarsAndBundleVarsAreEquivalent(t *testing.T) {
	obs := testObservation()
	obs.Actor = "arn:aws:iam::123456789012:user/break-glass"
	vars := map[string][]string{"break_glass_actors": {"arn:aws:iam::123456789012:user/break-glass"}}

	for _, expr := range []string{
		`obs.actor in vars.break_glass_actors`,
		`obs.actor in bundle.vars.break_glass_actors`,
		`obs.actor in vars["break_glass_actors"]`,
		`obs.actor in bundle.vars["break_glass_actors"]`,
	} {
		got, err := evalExpr(t, expr, obs, vars)
		if err != nil {
			t.Errorf("%s: %v", expr, err)
			continue
		}
		if got != true {
			t.Errorf("%s: expected true, got %v", expr, got)
		}
	}
}

// TestNonBooleanExpressionRejected keeps a predicate a predicate. Without this
// an expression yielding a string would compile and then fault once per
// observation forever.
func TestNonBooleanExpressionRejected(t *testing.T) {
	c, err := NewCompiler()
	if err != nil {
		t.Fatalf("NewCompiler: %v", err)
	}
	if _, err := c.Compile(`obs.layer`); err == nil {
		t.Fatal("a non-boolean rule expression must be rejected at compile time")
	} else if !strings.Contains(err.Error(), "must yield bool") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCompilerRejectsEmptyAndOversizeExpressions(t *testing.T) {
	c, err := NewCompiler()
	if err != nil {
		t.Fatalf("NewCompiler: %v", err)
	}
	if _, err := c.Compile("   "); err == nil {
		t.Fatal("empty expression must be rejected")
	}
	huge := `obs.layer == "` + strings.Repeat("x", MaxExpressionBytes) + `"`
	if _, err := c.Compile(huge); err == nil {
		t.Fatalf("expression over %d bytes must be rejected", MaxExpressionBytes)
	}
}

// TestProgramCacheKeyedByExpressionHash proves the cache is keyed by the
// expression and not by call count: whitespace-equivalent sources share one
// program, distinct sources do not.
func TestProgramCacheKeyedByExpressionHash(t *testing.T) {
	c, err := NewCompiler()
	if err != nil {
		t.Fatalf("NewCompiler: %v", err)
	}
	if _, err := c.Compile(`obs.layer == "a"`); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Compile(`  obs.layer == "a"  `); err != nil {
		t.Fatal(err)
	}
	if got := c.cachedPrograms(); got != 1 {
		t.Fatalf("whitespace-equivalent expressions must share one cached program, got %d", got)
	}
	if _, err := c.Compile(`obs.layer == "b"`); err != nil {
		t.Fatal(err)
	}
	if got := c.cachedPrograms(); got != 2 {
		t.Fatalf("distinct expressions must cache separately, got %d", got)
	}
	if ExpressionKey(`obs.layer == "a"`) == ExpressionKey(`obs.layer == "b"`) {
		t.Fatal("distinct expressions must not share a cache key")
	}
}

// TestCostLimitRejectsExpensiveEvaluation proves the cost envelope is live: a
// comprehension over a large synthetic list must be cut off rather than burn
// CPU per observation.
func TestCostLimitRejectsExpensiveEvaluation(t *testing.T) {
	obs := testObservation()
	expr := `size(obs.labels) >= 0 && [1,2,3,4,5,6,7,8,9,10].all(a, [1,2,3,4,5,6,7,8,9,10].all(b, [1,2,3,4,5,6,7,8,9,10].all(c, [1,2,3,4,5,6,7,8,9,10].all(d, a + b + c + d >= 0))))`
	if _, err := evalExpr(t, expr, obs, nil); err == nil {
		t.Fatalf("an evaluation beyond the %d cost limit must fail", EvalCostLimit)
	}
}
