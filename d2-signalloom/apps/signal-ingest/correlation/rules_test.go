package correlation

import (
	"testing"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
)

// TestRules_Compile verifies every default rule compiles.
func TestRules_Compile(t *testing.T) {
	for _, r := range DefaultRules() {
		_, err := compileRule(r.CEL)
		if err != nil {
			t.Errorf("rule %q failed to compile: %v", r.Name, err)
		}
	}
}

func evalRule(t *testing.T, expr string, a, b map[string]any) bool {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("a", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("b", cel.MapType(cel.StringType, cel.DynType)),
		cel.Function("abs",
			cel.Overload("abs_int", []*cel.Type{cel.IntType}, cel.IntType,
				cel.UnaryBinding(func(val ref.Val) ref.Val {
					v := val.Value().(int64)
					if v < 0 {
						return types.Int(-v)
					}
					return types.Int(v)
				}),
			),
		),
	)
	if err != nil {
		t.Fatal(err)
	}
	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		t.Fatal(issues.Err())
	}
	prg, err := env.Program(ast)
	if err != nil {
		t.Fatal(err)
	}
	out, _, err := prg.Eval(map[string]any{"a": a, "b": b})
	if err != nil {
		t.Fatal(err)
	}
	return out.Value() == true
}

func TestRule_CrossLayerIdentity_Match(t *testing.T) {
	rules := DefaultRules()
	r := rules[0] // cross_layer_identity
	a := map[string]any{"layer": "network_egress", "actor_hint": "sa-bot", "source": "x", "timestamp": int64(100)}
	b := map[string]any{"layer": "behavioural", "actor_hint": "sa-bot", "source": "y", "timestamp": int64(200)}
	if !evalRule(t, r.CEL, a, b) {
		t.Error("cross_layer_identity should match")
	}
}

func TestRule_CrossLayerIdentity_SameLayer(t *testing.T) {
	rules := DefaultRules()
	r := rules[0]
	a := map[string]any{"layer": "behavioural", "actor_hint": "sa-bot", "source": "x", "timestamp": int64(100)}
	b := map[string]any{"layer": "behavioural", "actor_hint": "sa-bot", "source": "y", "timestamp": int64(200)}
	if evalRule(t, r.CEL, a, b) {
		t.Error("same layer should not match cross_layer_identity")
	}
}

func TestRule_CrossLayerIdentity_NoHint(t *testing.T) {
	rules := DefaultRules()
	r := rules[0]
	a := map[string]any{"layer": "network_egress", "actor_hint": "", "source": "x", "timestamp": int64(100)}
	b := map[string]any{"layer": "behavioural", "actor_hint": "", "source": "y", "timestamp": int64(200)}
	if evalRule(t, r.CEL, a, b) {
		t.Error("empty actor_hint should not match")
	}
}

func TestRule_TimingCorrelation_Match(t *testing.T) {
	rules := DefaultRules()
	r := rules[1] // timing_correlation
	a := map[string]any{"layer": "network_egress", "source": "workload-x", "timestamp": int64(1000), "actor_hint": ""}
	b := map[string]any{"layer": "behavioural", "source": "workload-x", "timestamp": int64(1200), "actor_hint": ""}
	if !evalRule(t, r.CEL, a, b) {
		t.Error("timing_correlation should match within 5 min window")
	}
}

func TestRule_TimingCorrelation_TooFarApart(t *testing.T) {
	rules := DefaultRules()
	r := rules[1]
	a := map[string]any{"layer": "network_egress", "source": "workload-x", "timestamp": int64(1000), "actor_hint": ""}
	b := map[string]any{"layer": "behavioural", "source": "workload-x", "timestamp": int64(1400), "actor_hint": ""}
	if evalRule(t, r.CEL, a, b) {
		t.Error("timing_correlation should not match beyond 5 min")
	}
}

func TestRule_ScheduledJobExclusion(t *testing.T) {
	rules := DefaultRules()
	r := rules[3] // scheduled_job_exclusion
	a := map[string]any{"layer": "behavioural", "fidelity": "suggestive", "actor_hint": "", "source": "cron", "timestamp": int64(100)}
	if !evalRule(t, r.CEL, a, a) {
		t.Error("scheduled_job_exclusion should match cron pattern")
	}
}

func TestRule_ScheduledJobExclusion_WithHint(t *testing.T) {
	rules := DefaultRules()
	r := rules[3]
	a := map[string]any{"layer": "behavioural", "fidelity": "suggestive", "actor_hint": "sa-bot", "source": "cron", "timestamp": int64(100)}
	if evalRule(t, r.CEL, a, a) {
		t.Error("scheduled_job with actor_hint should NOT be excluded")
	}
}
