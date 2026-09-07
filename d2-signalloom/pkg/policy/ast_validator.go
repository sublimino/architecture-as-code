package policy

import (
	"fmt"
	"sort"
	"strings"

	"github.com/google/cel-go/cel"
	celast "github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/operators"
	"github.com/google/cel-go/common/overloads"
)

// Rule SP-4 — Non-Turing Complete CEL Invariant.
//
// "All admission and governance rules must be expressed in standard Google CEL
// without extension libraries that execute external processes or network
// lookups."
//
// This file enforces SP-4 in two independent ways, because a single mechanism
// would be a single point of failure for the constraint the card treats as a
// hard blocker.
//
//  1. CONSTRUCTIVELY. SP4Env builds a cel.NewEnv declaring only the Kubernetes
//     ValidatingAdmissionPolicy variable set, with zero extension libraries and
//     zero custom function bindings. An expression calling ext.http(...),
//     base64.encode(...), or any other out-of-tree function does not merely fail
//     a lint — it fails to compile. A violation cannot be emitted.
//
//  2. BY AUDIT. Validate walks the *checked* AST (not the source text, which a
//     comment or a string literal could fool) and asserts every called function
//     is a member of a closed allowlist. This catches anything that is in the
//     CEL standard library but that we nonetheless refuse.
//
// Non-Turing-completeness itself is a property of CEL: no unbounded recursion,
// no user-defined functions, and comprehensions that iterate a finite range. The
// job here is to keep it that way under generation, which means capping
// expression depth, node count, and — the one that actually bites — *nested*
// comprehension depth, since each level multiplies admission-time cost.

// VAP variable names an admission expression may reference. Anything else is an
// undeclared reference and fails the checker.
var vapVariables = []string{
	"object",
	"oldObject",
	"request",
	"params",
	"namespaceObject",
	"authorizer",
	"variables",
}

// SP4Env builds the constrained CEL environment described above.
//
// cel.NewEnv (as opposed to NewCustomEnv) loads the CEL standard library and
// standard macros and nothing else. No cel.Lib, no ext.*, no cel.Function.
func SP4Env() (*cel.Env, error) {
	opts := make([]cel.EnvOption, 0, len(vapVariables))
	for _, v := range vapVariables {
		opts = append(opts, cel.Variable(v, cel.DynType))
	}
	return cel.NewEnv(opts...)
}

// allowedFunctions is the closed set of function and operator names a generated
// expression may call.
//
// Every entry is a pure, total, side-effect-free operation over values already
// present in the AdmissionReview. Nothing here reads a file, spawns a process,
// resolves a name, or opens a socket — and because the list is a closed
// allowlist rather than a denylist, a future CEL release adding such a function
// does not silently become reachable.
var allowedFunctions = map[string]bool{
	// Boolean and comparison operators.
	operators.LogicalAnd:       true,
	operators.LogicalOr:        true,
	operators.LogicalNot:       true,
	operators.Conditional:      true,
	operators.Equals:           true,
	operators.NotEquals:        true,
	operators.Less:             true,
	operators.LessEquals:       true,
	operators.Greater:          true,
	operators.GreaterEquals:    true,
	operators.In:               true,
	operators.NotStrictlyFalse: true,

	// Arithmetic, needed for string concatenation in prefix tests.
	operators.Add:      true,
	operators.Subtract: true,
	operators.Index:    true,

	// Presence testing. VAP objects are unstructured, so has() is unavoidable.
	operators.Has: true,

	// The bounded-iteration string and collection builtins we actually emit.
	overloads.StartsWith: true,
	overloads.EndsWith:   true,
	overloads.Contains:   true,
	overloads.Size:       true,
}

// FindingSeverity classifies an SP-4 finding.
type FindingSeverity string

// Finding severities.
const (
	FindingError FindingSeverity = "error"
	FindingWarn  FindingSeverity = "warning"
)

// Finding is one SP-4 or complexity violation.
type Finding struct {
	Expression string          `json:"expression"`
	Code       string          `json:"code"`
	Severity   FindingSeverity `json:"severity"`
	Detail     string          `json:"detail"`
}

// SP-4 and complexity finding codes. Stable strings so a CI grep does not
// depend on prose.
const (
	CodeParseError          = "SP4-PARSE"
	CodeCheckError          = "SP4-CHECK"
	CodeForbiddenFunction   = "SP4-FUNC"
	CodeNotBoolean          = "SP4-TYPE"
	CodeDepthExceeded       = "SP4-DEPTH"
	CodeNodeCountExceeded   = "SP4-NODES"
	CodeComprehensionNested = "SP4-COMPREHENSION"
)

// ExprMetrics are the structural measurements taken from one expression.
type ExprMetrics struct {
	Name               string   `json:"name"`
	Nodes              int      `json:"nodes"`
	Depth              int      `json:"depth"`
	ComprehensionDepth int      `json:"comprehensionDepth"`
	Functions          []string `json:"functions"`
}

// SP4Report is the machine-readable result of an SP-4 audit.
//
// It is a struct rather than a bare bool precisely so that "the expression did
// not parse" cannot be mistaken for "the expression is clean" — Parsed is false
// and Findings is non-empty, where an error-as-empty design would report a
// parse failure as a pass.
type SP4Report struct {
	Compliant        bool          `json:"compliant"`
	Checked          int           `json:"checked"`
	Parsed           int           `json:"parsed"`
	Findings         []Finding     `json:"findings"`
	Metrics          []ExprMetrics `json:"metrics"`
	ExtensionLibs    []string      `json:"extensionLibraries"`
	MaxDepth         int           `json:"maxDepthLimit"`
	MaxNodes         int           `json:"maxNodeLimit"`
	MaxComprehension int           `json:"maxComprehensionLimit"`
}

// ValidateExpressions audits every named expression against SP-4 and the
// structural caps in def.
func ValidateExpressions(exprs map[string]string, def Defaults) (*SP4Report, error) {
	def = def.Applied()
	env, err := SP4Env()
	if err != nil {
		return nil, fmt.Errorf("build SP-4 CEL environment: %w", err)
	}

	rep := &SP4Report{
		Checked:          len(exprs),
		MaxDepth:         def.MaxExprDepth,
		MaxNodes:         def.MaxExprNodes,
		MaxComprehension: def.MaxComprehensionDepth,
		Findings:         []Finding{},
		Metrics:          []ExprMetrics{},
	}

	// Record which libraries the environment actually loaded. An `ext` entry here
	// would mean the constructive guarantee had been broken by an edit to
	// SP4Env, so it is surfaced rather than assumed.
	for _, lib := range env.Libraries() {
		if strings.Contains(strings.ToLower(lib), "ext") {
			rep.ExtensionLibs = append(rep.ExtensionLibs, lib)
			rep.Findings = append(rep.Findings, Finding{
				Expression: "<environment>",
				Code:       CodeForbiddenFunction,
				Severity:   FindingError,
				Detail:     fmt.Sprintf("SP-4 environment loaded extension library %q; the constructive guarantee is void", lib),
			})
		}
	}
	sort.Strings(rep.ExtensionLibs)

	names := make([]string, 0, len(exprs))
	for k := range exprs {
		names = append(names, k)
	}
	sort.Strings(names)

	for _, name := range names {
		src := exprs[name]

		ast, iss := env.Compile(src)
		if iss != nil && iss.Err() != nil {
			// A compile failure in this environment is the SP-4 mechanism firing:
			// an extension call literally cannot type-check here.
			rep.Findings = append(rep.Findings, Finding{
				Expression: name,
				Code:       CodeCheckError,
				Severity:   FindingError,
				Detail:     iss.Err().Error(),
			})
			continue
		}
		rep.Parsed++

		if ast.OutputType() != cel.BoolType {
			rep.Findings = append(rep.Findings, Finding{
				Expression: name,
				Code:       CodeNotBoolean,
				Severity:   FindingError,
				Detail:     fmt.Sprintf("admission expression must evaluate to bool, got %s", ast.OutputType()),
			})
		}

		native := ast.NativeRep()
		m := ExprMetrics{
			Name:  name,
			Nodes: celast.NodeCount(native),
			Depth: maxHeight(native),
		}
		fns, compDepth := walk(native)
		m.ComprehensionDepth = compDepth
		m.Functions = fns
		rep.Metrics = append(rep.Metrics, m)

		for _, fn := range fns {
			if !allowedFunctions[fn] {
				rep.Findings = append(rep.Findings, Finding{
					Expression: name,
					Code:       CodeForbiddenFunction,
					Severity:   FindingError,
					Detail: fmt.Sprintf("call to %q is outside the SP-4 allowlist of pure, "+
						"side-effect-free CEL builtins", fn),
				})
			}
		}
		if m.Depth > def.MaxExprDepth {
			rep.Findings = append(rep.Findings, Finding{
				Expression: name, Code: CodeDepthExceeded, Severity: FindingError,
				Detail: fmt.Sprintf("expression depth %d exceeds limit %d; deep operator nesting risks a checker stack overflow", m.Depth, def.MaxExprDepth),
			})
		}
		if m.Nodes > def.MaxExprNodes {
			rep.Findings = append(rep.Findings, Finding{
				Expression: name, Code: CodeNodeCountExceeded, Severity: FindingError,
				Detail: fmt.Sprintf("expression node count %d exceeds limit %d", m.Nodes, def.MaxExprNodes),
			})
		}
		if m.ComprehensionDepth > def.MaxComprehensionDepth {
			rep.Findings = append(rep.Findings, Finding{
				Expression: name, Code: CodeComprehensionNested, Severity: FindingError,
				Detail: fmt.Sprintf("nested comprehension depth %d exceeds limit %d; each level multiplies "+
					"admission-time evaluation cost", m.ComprehensionDepth, def.MaxComprehensionDepth),
			})
		}
	}

	sort.Slice(rep.Findings, func(i, j int) bool {
		if rep.Findings[i].Expression != rep.Findings[j].Expression {
			return rep.Findings[i].Expression < rep.Findings[j].Expression
		}
		return rep.Findings[i].Code < rep.Findings[j].Code
	})
	sort.Slice(rep.Metrics, func(i, j int) bool { return rep.Metrics[i].Name < rep.Metrics[j].Name })

	rep.Compliant = len(rep.Findings) == 0 && rep.Parsed == rep.Checked
	return rep, nil
}

func maxHeight(a *celast.AST) int {
	best := 0
	for _, h := range celast.Heights(a) {
		if h > best {
			best = h
		}
	}
	return best
}

// walk returns the sorted set of called function names and the maximum nesting
// depth of comprehensions.
//
// Comprehension depth is tracked with an explicit recursion rather than
// PostOrderVisit because the visitor interface hands over nodes without the path
// that reached them, and "how many comprehensions am I inside" is exactly a
// property of that path.
func walk(a *celast.AST) ([]string, int) {
	fns := map[string]bool{}
	maxDepth := 0

	var rec func(e celast.Expr, depth int)
	rec = func(e celast.Expr, depth int) {
		if e == nil {
			return
		}
		if depth > maxDepth {
			maxDepth = depth
		}
		switch e.Kind() {
		case celast.CallKind:
			c := e.AsCall()
			fns[c.FunctionName()] = true
			if c.IsMemberFunction() {
				rec(c.Target(), depth)
			}
			for _, arg := range c.Args() {
				rec(arg, depth)
			}
		case celast.ComprehensionKind:
			c := e.AsComprehension()
			rec(c.IterRange(), depth)
			rec(c.AccuInit(), depth+1)
			rec(c.LoopCondition(), depth+1)
			rec(c.LoopStep(), depth+1)
			rec(c.Result(), depth+1)
		case celast.ListKind:
			for _, el := range e.AsList().Elements() {
				rec(el, depth)
			}
		case celast.MapKind:
			for _, entry := range e.AsMap().Entries() {
				me := entry.AsMapEntry()
				rec(me.Key(), depth)
				rec(me.Value(), depth)
			}
		case celast.StructKind:
			for _, f := range e.AsStruct().Fields() {
				rec(f.AsStructField().Value(), depth)
			}
		case celast.SelectKind:
			rec(e.AsSelect().Operand(), depth)
		}
	}
	rec(a.Expr(), 0)

	out := make([]string, 0, len(fns))
	for f := range fns {
		out = append(out, f)
	}
	sort.Strings(out)
	return out, maxDepth
}
