package obscel

import (
	"errors"
	"strings"
	"testing"
)

// upper is a stand-in pseudonymiser: deterministic, total, and visibly not the
// identity function, which is all this package needs. The real key ring lives in
// apps/signal-ingest/store and this module must not depend on it.
func upper(v string) (string, error) { return "P(" + v + ")", nil }

func actorVarsBundle() *Bundle {
	return &Bundle{
		ID: "b", TenantID: "t", Version: "1.0.0", Mode: ModeShadow,
		ActorVars: []string{"break_glass_actors"},
		Vars: map[string][]string{
			"break_glass_actors": {"arn:aws:iam::1:user/break-glass"},
			"tenant_accounts":    {"123456789012"},
		},
		Rules: []Rule{{
			ID: "r", Name: "n", Severity: "high",
			Expression: `obs.layer == "cloud_control_plane" && !(obs.actor in vars.break_glass_actors)`,
		}},
	}
}

// Declared actor vars are rewritten; everything else is left alone.
//
// Both halves matter. obs.actor is a pseudonym by the time a rule runs, so an
// allowlist still holding cleartext ARNs can never match it -- the allowlisted
// identity would fire on every path, live and replay alike. And tenant_accounts
// holds AWS account numbers compared against a LABEL, so pseudonymising it would
// break the comparison in the opposite direction.
func TestPseudonymiseActorVars_RewritesOnlyDeclaredLists(t *testing.T) {
	b := actorVarsBundle()
	if err := PseudonymiseActorVars(b, upper); err != nil {
		t.Fatalf("PseudonymiseActorVars: %v", err)
	}
	if got := b.Vars["break_glass_actors"][0]; got != "P(arn:aws:iam::1:user/break-glass)" {
		t.Errorf("break_glass_actors[0] = %q, want it pseudonymised", got)
	}
	if got := b.Vars["tenant_accounts"][0]; got != "123456789012" {
		t.Errorf("tenant_accounts[0] = %q, want it untouched: it is compared against a label, not an actor", got)
	}
}

// A nil function is a no-op, not an error: a MemoryStore development binary with
// no key material runs cleartext end to end, and the vars must stay cleartext
// with it or the allowlists stop matching.
func TestPseudonymiseActorVars_NilFuncLeavesTheBundleAlone(t *testing.T) {
	b := actorVarsBundle()
	if err := PseudonymiseActorVars(b, nil); err != nil {
		t.Fatalf("PseudonymiseActorVars: %v", err)
	}
	if got := b.Vars["break_glass_actors"][0]; got != "arn:aws:iam::1:user/break-glass" {
		t.Errorf("break_glass_actors[0] = %q, want it untouched", got)
	}
}

// Declaring a var that does not exist is a load-time error. Silently ignoring it
// is how a typo in actor_vars becomes an allowlist that is never pseudonymised.
func TestValidateBundle_ActorVarMustBeDeclared(t *testing.T) {
	b := actorVarsBundle()
	b.ActorVars = []string{"no_such_var"}
	errs := ValidateBundle(b)
	if len(errs) == 0 {
		t.Fatal("an actor_vars entry naming an undeclared var was accepted")
	}
	if !strings.Contains(JoinRuleErrors(errs).Error(), "no_such_var") {
		t.Errorf("the error does not name the offending var: %v", JoinRuleErrors(errs))
	}
}

// THE MUTATION THE CARD NAMES. A rule that compares obs.actor against a var the
// bundle has not declared as an actor list must be REFUSED AT LOAD.
//
// Without this gate the failure is silent and it is the worst shape available:
// the var stays cleartext, obs.actor is a pseudonym, `obs.actor in vars.X` is
// never true, and so a NEGATIVE allowlist test (`!(obs.actor in vars.X)`) is
// always true -- the allowlisted operator fires on every record, live and
// replay. Counts agree between the two sides, so the replay oracle reports
// parity while the detection is inverted. A load-time refusal is the only point
// at which that is visible.
func TestConform_RejectsActorComparisonAgainstUndeclaredActorVar(t *testing.T) {
	b := actorVarsBundle()
	b.ActorVars = nil // the rule still compares obs.actor against break_glass_actors

	errs := Conform(b)
	if len(errs) == 0 {
		t.Fatal("a rule comparing obs.actor against an undeclared actor var was conformant")
	}
	msg := JoinRuleErrors(errs).Error()
	if !strings.Contains(msg, "break_glass_actors") || !strings.Contains(msg, "actor_vars") {
		t.Errorf("the error must name the var and the remedy, got: %v", msg)
	}
}

// Declared, so conformant. The positive case has to be asserted too, or the gate
// above could be satisfied by refusing everything.
func TestConform_AcceptsDeclaredActorVar(t *testing.T) {
	if errs := Conform(actorVarsBundle()); len(errs) > 0 {
		t.Fatalf("a correctly declared actor var was refused: %v", JoinRuleErrors(errs))
	}
}

// Every spelling the vocabulary accepts is detected, because a rule author who
// writes bundle.vars["x"] must not get a silently unpseudonymised allowlist.
func TestActorComparedVars_CoversEverySpelling(t *testing.T) {
	for _, tc := range []struct{ name, expr string }{
		{"vars.x", `!(obs.actor in vars.x)`},
		{"vars index", `!(obs.actor in vars["x"])`},
		{"bundle.vars.x", `!(obs.actor in bundle.vars.x)`},
		{"bundle.vars index", `!(obs.actor in bundle.vars["x"])`},
		{"positive form", `obs.actor in vars.x`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := &Bundle{
				ID: "b", TenantID: "t", Version: "1.0.0", Mode: ModeShadow,
				Vars:  map[string][]string{"x": {"a"}},
				Rules: []Rule{{ID: "r", Name: "n", Severity: "high", Expression: tc.expr}},
			}
			errs := Conform(b)
			if len(errs) == 0 {
				t.Fatalf("%s was not detected as an actor comparison", tc.expr)
			}
			if !strings.Contains(JoinRuleErrors(errs).Error(), "actor_vars") {
				t.Errorf("wrong error for %s: %v", tc.expr, JoinRuleErrors(errs))
			}
		})
	}
}

// A var compared against something that is NOT obs.actor needs no declaration.
// tenant_accounts is the live example: it is compared against a label.
func TestActorComparedVars_IgnoresNonActorComparisons(t *testing.T) {
	b := &Bundle{
		ID: "b", TenantID: "t", Version: "1.0.0", Mode: ModeShadow,
		Vars: map[string][]string{"tenant_accounts": {"1"}},
		Rules: []Rule{{ID: "r", Name: "n", Severity: "high",
			Expression: `has(obs.labels.aws_account_id) && obs.labels.aws_account_id in vars.tenant_accounts`}},
	}
	if errs := Conform(b); len(errs) > 0 {
		t.Fatalf("a label comparison was treated as an actor comparison: %v", JoinRuleErrors(errs))
	}
}

// A pseudonymiser fault aborts the whole bundle rather than leaving half an
// allowlist rewritten. A half-pseudonymised allowlist matches some identities
// and not others, which is indistinguishable from a deliberately shorter list.
func TestPseudonymiseActorVars_FaultAbortsWholeBundle(t *testing.T) {
	b := actorVarsBundle()
	b.Vars["break_glass_actors"] = []string{"ok", "boom", "also-ok"}
	boom := errors.New("key ring unavailable")
	err := PseudonymiseActorVars(b, func(v string) (string, error) {
		if v == "boom" {
			return "", boom
		}
		return "P(" + v + ")", nil
	})
	if !errors.Is(err, boom) {
		t.Fatalf("want the pseudonymiser fault returned, got %v", err)
	}
	if got := b.Vars["break_glass_actors"][0]; got != "ok" {
		t.Errorf("the bundle was partially rewritten: break_glass_actors[0] = %q", got)
	}
}
