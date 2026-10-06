package obscel

import (
	"fmt"
	"sort"
	"strings"

	celast "github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/operators"
)

// Window key fields that are not label lookups. Anything else must be written
// as "labels.<key>".
const (
	KeyTenantID = "tenant_id"
	KeyActor    = "actor"
	KeyRuleID   = "rule_id"
	// KeyLabelPrefix introduces a label-keyed window dimension, e.g.
	// "labels.event_name".
	KeyLabelPrefix = "labels."
)

// RuleError localises a bundle defect to the rule (or window) that carries it,
// so an operator fixing a bundle is told which stanza to edit rather than being
// handed a bare CEL parser message.
type RuleError struct {
	// RuleID is the offending rule or window id. It is empty only for defects in
	// the bundle header itself (id, tenant_id, version, mode).
	RuleID string `json:"rule_id,omitempty"`
	// Kind is "bundle", "rule" or "window".
	Kind string `json:"kind"`
	// Field is the offending field name, e.g. "expression", "over_rule", "mode".
	Field string `json:"field"`
	// Message is the human-readable defect.
	Message string `json:"message"`
}

// Error implements error so a single RuleError can be returned on its own.
func (e RuleError) Error() string {
	if e.RuleID == "" {
		return fmt.Sprintf("%s.%s: %s", e.Kind, e.Field, e.Message)
	}
	return fmt.Sprintf("%s %q field %q: %s", e.Kind, e.RuleID, e.Field, e.Message)
}

// JoinRuleErrors renders a slice of RuleError as one error, or nil when the
// slice is empty. Used wherever an `error` return is the contract.
func JoinRuleErrors(errs []RuleError) error {
	if len(errs) == 0 {
		return nil
	}
	parts := make([]string, 0, len(errs))
	for _, e := range errs {
		parts = append(parts, e.Error())
	}
	return fmt.Errorf("%d bundle conformance error(s): %s", len(errs), strings.Join(parts, "; "))
}

// Conform compiles every rule expression in the bundle and resolves every
// window and vars reference, reporting defects per rule id (ISC-39).
//
// This is the gate that keeps a broken bundle out of the boot-loaded set. Three
// classes of defect are all compile-time here and would otherwise only appear
// once real traffic hit the rule:
//
//   - a rule that does not compile, or that yields a non-boolean;
//   - a misspelled observation field (obs is a native type, so obs.evemt_name
//     is a type-check error, not a silent false);
//   - a reference to vars.X where the bundle declares no X, which would be a
//     per-observation "no such key" fault in production.
//
// Window references are resolved against the rule ids actually present.
// Conform does not mutate the bundle.
func Conform(b *Bundle) []RuleError {
	if b == nil {
		return []RuleError{{Kind: "bundle", Field: "", Message: "bundle is nil"}}
	}

	compiler, err := NewCompiler()
	if err != nil {
		return []RuleError{{Kind: "bundle", Field: "", Message: err.Error()}}
	}

	var errs []RuleError

	actorVars := make(map[string]bool, len(b.ActorVars))
	for _, name := range b.ActorVars {
		actorVars[name] = true
	}

	ruleIDs := make(map[string]bool, len(b.Rules))
	for _, r := range SortedRules(b) {
		if strings.TrimSpace(r.ID) == "" {
			errs = append(errs, RuleError{Kind: "rule", Field: "id", Message: "rule id is required"})
			continue
		}
		if ruleIDs[r.ID] {
			errs = append(errs, RuleError{RuleID: r.ID, Kind: "rule", Field: "id", Message: "duplicate rule id"})
			continue
		}
		ruleIDs[r.ID] = true

		ast, _, cerr := compiler.CompileAST(r.Expression)
		if cerr != nil {
			errs = append(errs, RuleError{RuleID: r.ID, Kind: "rule", Field: "expression", Message: cerr.Error()})
			continue
		}
		for _, name := range VarsReferences(ast.NativeRep().Expr()) {
			if _, ok := b.Vars[name]; !ok {
				errs = append(errs, RuleError{
					RuleID:  r.ID,
					Kind:    "rule",
					Field:   "expression",
					Message: fmt.Sprintf("references vars.%s, which the bundle does not declare", name),
				})
			}
		}
		// Every var this rule compares obs.actor against must be declared as an
		// actor list, so it is pseudonymised at load with the key obs.actor is
		// pseudonymised with.
		//
		// This is the gate that turns the worst available failure into a refusal.
		// Undeclared, the list keeps its cleartext values; obs.actor is a
		// pseudonym; `obs.actor in vars.X` is never true; and the negative form
		// every shipped rule is written in is therefore ALWAYS true, so the
		// allowlisted identity fires on every record. Live and replay agree on
		// that wrong answer, so the replay oracle reports parity and nothing
		// downstream can see it. Load time is the only place it is visible.
		for _, name := range ActorComparedVars(ast.NativeRep().Expr()) {
			if !actorVars[name] {
				errs = append(errs, RuleError{
					RuleID: r.ID,
					Kind:   "rule",
					Field:  "expression",
					Message: fmt.Sprintf(
						"compares obs.actor against vars.%s, which is not listed in the bundle's actor_vars; "+
							"obs.actor is a keyed pseudonym, so an unpseudonymised list can never match it and "+
							"a negative allowlist test becomes always-true. Add %q to actor_vars", name, name),
				})
			}
		}
	}

	windowIDs := make(map[string]bool, len(b.Windows))
	for _, w := range sortedWindows(b) {
		if strings.TrimSpace(w.ID) == "" {
			errs = append(errs, RuleError{Kind: "window", Field: "id", Message: "window id is required"})
			continue
		}
		if windowIDs[w.ID] {
			errs = append(errs, RuleError{RuleID: w.ID, Kind: "window", Field: "id", Message: "duplicate window id"})
			continue
		}
		windowIDs[w.ID] = true

		if !ruleIDs[w.OverRule] {
			errs = append(errs, RuleError{
				RuleID:  w.ID,
				Kind:    "window",
				Field:   "over_rule",
				Message: fmt.Sprintf("references rule %q, which the bundle does not define", w.OverRule),
			})
		}
		if len(w.Key) == 0 {
			errs = append(errs, RuleError{RuleID: w.ID, Kind: "window", Field: "key", Message: "at least one key field is required"})
		}
		for _, k := range w.Key {
			if !validWindowKeyField(k) {
				errs = append(errs, RuleError{
					RuleID:  w.ID,
					Kind:    "window",
					Field:   "key",
					Message: fmt.Sprintf("key field %q must be one of %s, %s, %s or %s<label>", k, KeyTenantID, KeyActor, KeyRuleID, KeyLabelPrefix),
				})
			}
		}
		if w.Window <= 0 {
			errs = append(errs, RuleError{RuleID: w.ID, Kind: "window", Field: "window", Message: "window duration must be positive"})
		}
		if w.Threshold < 1 {
			errs = append(errs, RuleError{RuleID: w.ID, Kind: "window", Field: "threshold", Message: "threshold must be at least 1"})
		}
		if strings.TrimSpace(w.Severity) == "" {
			errs = append(errs, RuleError{RuleID: w.ID, Kind: "window", Field: "severity", Message: "severity is required"})
		}
	}

	return errs
}

// validWindowKeyField reports whether a window key dimension is addressable.
func validWindowKeyField(k string) bool {
	switch k {
	case KeyTenantID, KeyActor, KeyRuleID:
		return true
	}
	return strings.HasPrefix(k, KeyLabelPrefix) && len(k) > len(KeyLabelPrefix)
}

// sortedWindows returns windows in canonical (sorted window ID) order, for the
// same reason SortedRules exists: diagnostics must not depend on file order.
func sortedWindows(b *Bundle) []Window {
	if b == nil {
		return nil
	}
	ws := append([]Window(nil), b.Windows...)
	sort.Slice(ws, func(i, j int) bool { return ws[i].ID < ws[j].ID })
	return ws
}

// VarsReferences returns the sorted, de-duplicated set of bundle var names an
// expression reads. All four spellings the vocabulary accepts are covered:
//
//	vars.name          bundle.vars.name
//	vars["name"]       bundle.vars["name"]
//
// Presence tests (`has(vars.name)`) are deliberately excluded: guarding on a
// var is how a rule copes with a var it does not require, so demanding that the
// guarded var exist would defeat the guard.
func VarsReferences(expr celast.Expr) []string {
	seen := map[string]bool{}

	celast.PostOrderVisit(expr, celast.NewExprVisitor(func(e celast.Expr) {
		switch e.Kind() {
		case celast.SelectKind:
			sel := e.AsSelect()
			if sel.IsTestOnly() {
				return
			}
			if isVarsRoot(sel.Operand()) {
				seen[sel.FieldName()] = true
			}
		case celast.CallKind:
			call := e.AsCall()
			if call.FunctionName() != operators.Index {
				return
			}
			args := call.Args()
			if len(args) != 2 || !isVarsRoot(args[0]) {
				return
			}
			if args[1].Kind() != celast.LiteralKind {
				return
			}
			if name, ok := args[1].AsLiteral().Value().(string); ok {
				seen[name] = true
			}
		}
	}))

	names := make([]string, 0, len(seen))
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// ActorComparedVars returns the sorted, de-duplicated set of bundle var names
// an expression compares obs.actor against, in any of the four spellings the
// vocabulary accepts:
//
//	obs.actor in vars.name          obs.actor in bundle.vars.name
//	obs.actor in vars["name"]       obs.actor in bundle.vars["name"]
//
// Membership (`in`) is the only form recognised, and that is a deliberate
// bound rather than an oversight. It is the form every shipped rule uses and the
// only one an allowlist can be written in: `vars.X` is a list, so the other
// comparisons CEL would permit against it are not identity tests. A rule that
// found some other way to compare an actor to a var would not be caught here --
// which is why PseudonymiseActorVars is driven by the explicit declaration and
// this walk only enforces that the declaration was not forgotten.
func ActorComparedVars(expr celast.Expr) []string {
	seen := map[string]bool{}

	celast.PostOrderVisit(expr, celast.NewExprVisitor(func(e celast.Expr) {
		if e.Kind() != celast.CallKind {
			return
		}
		call := e.AsCall()
		if call.FunctionName() != operators.In {
			return
		}
		args := call.Args()
		if len(args) != 2 || !isObsActor(args[0]) {
			return
		}
		if name, ok := varsListName(args[1]); ok {
			seen[name] = true
		}
	}))

	names := make([]string, 0, len(seen))
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// isObsActor reports whether e is the `obs.actor` selection.
func isObsActor(e celast.Expr) bool {
	if e == nil || e.Kind() != celast.SelectKind {
		return false
	}
	sel := e.AsSelect()
	if sel.IsTestOnly() || sel.FieldName() != actorFieldName {
		return false
	}
	op := sel.Operand()
	return op != nil && op.Kind() == celast.IdentKind && op.AsIdent() == ObsVar
}

// actorFieldName is the json tag of Observation.Actor, which is the field name
// the native-type provider exposes to CEL.
const actorFieldName = "actor"

// varsListName returns the bundle var name e denotes, for either spelling.
func varsListName(e celast.Expr) (string, bool) {
	if e == nil {
		return "", false
	}
	switch e.Kind() {
	case celast.SelectKind:
		sel := e.AsSelect()
		if sel.IsTestOnly() || !isVarsRoot(sel.Operand()) {
			return "", false
		}
		return sel.FieldName(), true
	case celast.CallKind:
		call := e.AsCall()
		if call.FunctionName() != operators.Index {
			return "", false
		}
		args := call.Args()
		if len(args) != 2 || !isVarsRoot(args[0]) || args[1].Kind() != celast.LiteralKind {
			return "", false
		}
		name, ok := args[1].AsLiteral().Value().(string)
		return name, ok
	}
	return "", false
}

// isVarsRoot reports whether e is the map that holds the bundle vars, i.e.
// either the `vars` ident or the `bundle.vars` selection.
func isVarsRoot(e celast.Expr) bool {
	if e == nil {
		return false
	}
	switch e.Kind() {
	case celast.IdentKind:
		return e.AsIdent() == VarsVar
	case celast.SelectKind:
		sel := e.AsSelect()
		if sel.IsTestOnly() || sel.FieldName() != BundleVarsField {
			return false
		}
		op := sel.Operand()
		return op != nil && op.Kind() == celast.IdentKind && op.AsIdent() == BundleVar
	}
	return false
}
