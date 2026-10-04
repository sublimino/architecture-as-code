package obscel

import (
	"strings"
	"testing"
	"time"
)

func conformErrorsFor(t *testing.T, b *Bundle, ruleID string) []RuleError {
	t.Helper()
	var out []RuleError
	for _, e := range Conform(b) {
		if e.RuleID == ruleID {
			out = append(out, e)
		}
	}
	return out
}

// TestConformReportsDefectsAgainstTheOffendingRuleID: a bundle author must be
// told which stanza to edit. A flat list of CEL parser messages is not that.
func TestConformReportsDefectsAgainstTheOffendingRuleID(t *testing.T) {
	b := &Bundle{
		ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
		Vars: map[string][]string{"allowed": {"a"}},
		Rules: []Rule{
			{ID: "healthy", Severity: "low", Expression: `obs.layer == "cloud_control_plane"`},
			{ID: "bad-syntax", Severity: "low", Expression: `obs.layer ===== "x"`},
			{ID: "bad-field", Severity: "low", Expression: `obs.evemt_name == "x"`},
			{ID: "bad-type", Severity: "low", Expression: `obs.layer`},
			{ID: "undeclared-var", Severity: "low", Expression: `obs.actor in vars.not_declared`},
			{ID: "empty-expr", Severity: "low", Expression: ``},
		},
	}

	if got := conformErrorsFor(t, b, "healthy"); len(got) != 0 {
		t.Errorf("the healthy rule must report nothing, got %v", got)
	}
	for _, id := range []string{"bad-syntax", "bad-field", "bad-type", "undeclared-var", "empty-expr"} {
		if got := conformErrorsFor(t, b, id); len(got) == 0 {
			t.Errorf("rule %q must be reported", id)
		} else if got[0].Field != "expression" || got[0].Kind != "rule" {
			t.Errorf("rule %q: expected a rule.expression defect, got %+v", id, got[0])
		}
	}
}

// TestConformCatchesUndeclaredVarsReference is the defect that would otherwise
// be invisible until production: `vars.X` where the bundle declares no X is a
// per-observation "no such key" fault, so the rule detects nothing, forever,
// while the bundle looks healthy.
//
// Killed mutation: deleting the VarsReferences loop in Conform makes the
// undeclared-var case pass conformance, and the bundle ships blind.
func TestConformCatchesUndeclaredVarsReference(t *testing.T) {
	mk := func(expr string) *Bundle {
		return &Bundle{
			ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
			Vars:  map[string][]string{"break_glass_actors": {"a"}},
			Rules: []Rule{{ID: "r", Severity: "low", Expression: expr}},
		}
	}

	// All four spellings of a declared var must pass.
	for _, expr := range []string{
		`obs.actor in vars.break_glass_actors`,
		`obs.actor in bundle.vars.break_glass_actors`,
		`obs.actor in vars["break_glass_actors"]`,
		`obs.actor in bundle.vars["break_glass_actors"]`,
	} {
		if errs := Conform(mk(expr)); len(errs) != 0 {
			t.Errorf("%s must conform, got %v", expr, JoinRuleErrors(errs))
		}
	}

	// All four spellings of an undeclared var must fail.
	for _, expr := range []string{
		`obs.actor in vars.typo_actors`,
		`obs.actor in bundle.vars.typo_actors`,
		`obs.actor in vars["typo_actors"]`,
		`obs.actor in bundle.vars["typo_actors"]`,
	} {
		errs := Conform(mk(expr))
		if len(errs) == 0 {
			t.Errorf("%s must be reported as an undeclared var", expr)
			continue
		}
		if !strings.Contains(errs[0].Message, "typo_actors") {
			t.Errorf("%s: the defect must name the var, got %q", expr, errs[0].Message)
		}
	}

	// A presence test on an undeclared var is legitimate: that is what guarding
	// is for, so it must not be reported.
	if errs := Conform(mk(`has(vars.optional_actors) && obs.actor in vars.break_glass_actors`)); len(errs) != 0 {
		t.Errorf("a guarded optional var must conform, got %v", JoinRuleErrors(errs))
	}
}

func TestVarsReferencesExtraction(t *testing.T) {
	c, err := NewCompiler()
	if err != nil {
		t.Fatalf("NewCompiler: %v", err)
	}
	refs := func(expr string) []string {
		t.Helper()
		ast, _, err := c.CompileAST(expr)
		if err != nil {
			t.Fatalf("%s: %v", expr, err)
		}
		return VarsReferences(ast.NativeRep().Expr())
	}

	got := refs(`obs.actor in vars.b && obs.source in bundle.vars.a && obs.layer in vars["a"]`)
	if strings.Join(got, ",") != "a,b" {
		t.Fatalf("references must be sorted and de-duplicated, got %v", got)
	}
	if got := refs(`obs.layer == "x"`); len(got) != 0 {
		t.Fatalf("an expression with no vars must yield none, got %v", got)
	}
}

// TestConformResolvesWindowReferences: a window over a rule id that does not
// exist can never fire, and nothing at runtime would say so.
func TestConformResolvesWindowReferences(t *testing.T) {
	base := func() *Bundle {
		return &Bundle{
			ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
			Rules: []Rule{{ID: "r1", Severity: "low", Expression: `true`}},
			Windows: []Window{{
				ID: "w1", OverRule: "r1", Key: []string{KeyTenantID, KeyActor},
				Window: 10 * time.Minute, Threshold: 3, Severity: "high",
			}},
		}
	}
	if errs := Conform(base()); len(errs) != 0 {
		t.Fatalf("baseline must conform, got %v", JoinRuleErrors(errs))
	}

	cases := []struct {
		name   string
		mutate func(*Bundle)
		field  string
	}{
		{"dangling over_rule", func(b *Bundle) { b.Windows[0].OverRule = "r2" }, "over_rule"},
		{"empty over_rule", func(b *Bundle) { b.Windows[0].OverRule = "" }, "over_rule"},
		{"no key", func(b *Bundle) { b.Windows[0].Key = nil }, "key"},
		{"unaddressable key", func(b *Bundle) { b.Windows[0].Key = []string{"event_name"} }, "key"},
		{"bare labels prefix", func(b *Bundle) { b.Windows[0].Key = []string{"labels."} }, "key"},
		{"zero window", func(b *Bundle) { b.Windows[0].Window = 0 }, "window"},
		{"negative window", func(b *Bundle) { b.Windows[0].Window = -time.Minute }, "window"},
		{"zero threshold", func(b *Bundle) { b.Windows[0].Threshold = 0 }, "threshold"},
		{"missing severity", func(b *Bundle) { b.Windows[0].Severity = " " }, "severity"},
		{"missing id", func(b *Bundle) { b.Windows[0].ID = "" }, "id"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b := base()
			tc.mutate(b)
			errs := Conform(b)
			if len(errs) == 0 {
				t.Fatalf("%s must be reported", tc.name)
			}
			for _, e := range errs {
				if e.Kind == "window" && e.Field == tc.field {
					return
				}
			}
			t.Fatalf("expected a window.%s defect, got %v", tc.field, errs)
		})
	}

	// A label-keyed window dimension is addressable.
	b := base()
	b.Windows[0].Key = []string{KeyRuleID, KeyLabelPrefix + "event_name"}
	if errs := Conform(b); len(errs) != 0 {
		t.Fatalf("labels.<key> must be an addressable window dimension, got %v", JoinRuleErrors(errs))
	}
}

func TestConformRejectsDuplicateIDs(t *testing.T) {
	b := &Bundle{
		ID: "b", TenantID: "kusari", Version: "1.0.0", Mode: ModeShadow,
		Rules: []Rule{
			{ID: "r1", Severity: "low", Expression: `true`},
			{ID: "r1", Severity: "low", Expression: `false`},
		},
		Windows: []Window{
			{ID: "w1", OverRule: "r1", Key: []string{KeyActor}, Window: time.Minute, Threshold: 1, Severity: "high"},
			{ID: "w1", OverRule: "r1", Key: []string{KeyActor}, Window: time.Minute, Threshold: 1, Severity: "high"},
		},
	}
	errs := Conform(b)
	var dupRule, dupWindow bool
	for _, e := range errs {
		if e.Kind == "rule" && strings.Contains(e.Message, "duplicate") {
			dupRule = true
		}
		if e.Kind == "window" && strings.Contains(e.Message, "duplicate") {
			dupWindow = true
		}
	}
	if !dupRule {
		t.Error("a duplicate rule id must be reported: two rules with one id give one event two identities")
	}
	if !dupWindow {
		t.Error("a duplicate window id must be reported")
	}
}

func TestConformOnNilBundle(t *testing.T) {
	if errs := Conform(nil); len(errs) != 1 {
		t.Fatalf("a nil bundle must report exactly one defect, got %v", errs)
	}
}

func TestJoinRuleErrorsIsNilWhenClean(t *testing.T) {
	if err := JoinRuleErrors(nil); err != nil {
		t.Fatalf("no defects must join to a nil error, got %v", err)
	}
	err := JoinRuleErrors([]RuleError{{RuleID: "r", Kind: "rule", Field: "expression", Message: "boom"}})
	if err == nil || !strings.Contains(err.Error(), "boom") || !strings.Contains(err.Error(), `"r"`) {
		t.Fatalf("joined error must carry rule and message, got %v", err)
	}
}
