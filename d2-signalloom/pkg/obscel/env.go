package obscel

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/ext"
)

// VarsVar is the CEL variable holding Bundle.Vars, so a rule can reference a
// named allowlist instead of inlining it:
//
//	obs.actor in vars.break_glass_actors
//
// Its CEL type is map<string, list<string>>. A reference to a key the bundle
// does not declare is an evaluation error, which Conform reports at load time
// rather than leaving to discover in production (see conformance.go).
const VarsVar = "vars"

// BundleVar is the alias form the proposal's §4.2 sample rule is written in:
//
//	!(obs.actor in bundle.vars.break_glass_actors)
//
// It exports exactly one field, `vars`, holding the same map as the top-level
// VarsVar. Both spellings are supported because §4.2 is the text operators will
// copy from and a vocabulary that rejects its own documented example is a
// defect. `vars.X` is the shorter canonical form and is preferred in new rules.
const BundleVar = "bundle"

// BundleVarsField is the only field BundleVar exposes.
const BundleVarsField = "vars"

// ObsTypeName is the CEL object type name the native-type provider derives for
// Observation: simplePkgAlias(reflect PkgPath) + "." + struct name.
const ObsTypeName = "obscel.Observation"

// Limits shared by every observation-rule compilation and evaluation. These
// mirror apps/policy-engine/cel_eval.go deliberately: one vocabulary means one
// cost envelope, so a rule that is affordable in the dashboard dry-run surface
// is affordable in the ingest hot path.
const (
	// MaxExpressionBytes caps rule source length before the parser is reached.
	MaxExpressionBytes = 4096
	// EvalCostLimit caps CEL instruction cost, bounding CPU per observation.
	EvalCostLimit uint64 = 10000
	// EvalTimeout caps wall-clock time for a single rule evaluation.
	EvalTimeout = 50 * time.Millisecond
)

// NewEnv builds the single CEL environment every observation rule compiles
// against (SLAWS §4.1, D2). It exports exactly two variables:
//
//	obs    — the Observation (id, timestamp, layer, source, fidelity, confidence,
//	         tenant_id, actor, labels), field names taken from the json tags,
//	         with labels typed map<string,string>.
//	vars   — the bundle's named lists, typed map<string, list<string>>.
//	bundle — { vars: <the same map> }, the spelling §4.2 of the proposal uses.
//
// Observation is registered as a native type rather than a dyn map so that a
// misspelled field (obs.evemt_name) is a COMPILE error Conform catches at load
// time, instead of a runtime "no such key" fault discovered per observation.
//
// Missing-key semantics (binding, see doc.go): has(obs.labels.k) on an absent
// key evaluates to false and never errors. Bare access to an absent label key
// does error, so rules guard with has() — the first bundle does exactly that.
func NewEnv() (*cel.Env, error) {
	env, err := cel.NewEnv(
		ext.NativeTypes(reflect.TypeOf(Observation{}), ext.ParseStructTag("json")),
		cel.Variable(ObsVar, cel.ObjectType(ObsTypeName)),
		cel.Variable(VarsVar, varsCELType()),
		cel.Variable(BundleVar, cel.MapType(cel.StringType, varsCELType())),
	)
	if err != nil {
		return nil, fmt.Errorf("obscel: creating CEL env: %w", err)
	}
	return env, nil
}

// varsCELType is map<string, list<string>>: a named allowlist per key.
func varsCELType() *cel.Type {
	return cel.MapType(cel.StringType, cel.ListType(cel.StringType))
}

// Activation is the canonical CEL input for one observation under one bundle.
// Both the ingest hot path and the dashboard dry-run surface must build their
// input through this function; a hand-rolled map is how the two environments
// drift apart.
func Activation(obs Observation, vars map[string][]string) map[string]any {
	if vars == nil {
		vars = map[string][]string{}
	}
	return map[string]any{
		ObsVar:    obs,
		VarsVar:   vars,
		BundleVar: map[string]map[string][]string{BundleVarsField: vars},
	}
}

// Compiler compiles observation rules against NewEnv and caches the resulting
// programs by expression hash, so a bundle reloaded with unchanged rules does
// not pay compilation again. Safe for concurrent use.
type Compiler struct {
	env   *cel.Env
	mu    sync.RWMutex
	cache map[string]compiled
}

type compiled struct {
	ast *cel.Ast
	prg cel.Program
}

// NewCompiler returns a Compiler over a fresh env.
func NewCompiler() (*Compiler, error) {
	env, err := NewEnv()
	if err != nil {
		return nil, err
	}
	return &Compiler{env: env, cache: make(map[string]compiled)}, nil
}

// Env exposes the underlying environment for callers that need to inspect an
// AST (Conform does, to resolve vars references).
func (c *Compiler) Env() *cel.Env { return c.env }

// ExpressionKey is the program-cache key: the hash of the trimmed expression.
func ExpressionKey(expr string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(expr)))
	return hex.EncodeToString(sum[:])
}

// Compile parses, type-checks and plans a rule expression. The result must be
// boolean: a rule is a predicate, and an expression that yields a string or an
// int is a authoring defect that would otherwise surface as a per-observation
// fault.
func (c *Compiler) Compile(expr string) (cel.Program, error) {
	_, prg, err := c.CompileAST(expr)
	return prg, err
}

// CompileAST is Compile plus the checked AST, used by Conform to resolve the
// vars references a rule makes.
func (c *Compiler) CompileAST(expr string) (*cel.Ast, cel.Program, error) {
	trimmed := strings.TrimSpace(expr)
	if trimmed == "" {
		return nil, nil, fmt.Errorf("obscel: empty CEL expression")
	}
	if len(trimmed) > MaxExpressionBytes {
		return nil, nil, fmt.Errorf("obscel: CEL expression exceeds maximum allowed length of %d bytes", MaxExpressionBytes)
	}

	key := ExpressionKey(trimmed)
	c.mu.RLock()
	hit, ok := c.cache[key]
	c.mu.RUnlock()
	if ok {
		return hit.ast, hit.prg, nil
	}

	ast, issues := c.env.Compile(trimmed)
	if issues != nil && issues.Err() != nil {
		return nil, nil, fmt.Errorf("obscel: CEL compile error: %w", issues.Err())
	}
	if ast.OutputType() != cel.BoolType {
		return nil, nil, fmt.Errorf("obscel: rule expression must yield bool, got %s", ast.OutputType())
	}

	prg, err := c.env.Program(ast, cel.CostLimit(EvalCostLimit))
	if err != nil {
		return nil, nil, fmt.Errorf("obscel: CEL program creation error: %w", err)
	}

	c.mu.Lock()
	c.cache[key] = compiled{ast: ast, prg: prg}
	c.mu.Unlock()

	return ast, prg, nil
}

// cachedPrograms reports the cache size. Test-only accessor for the cache
// invariant; exported state would invite callers to depend on it.
func (c *Compiler) cachedPrograms() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.cache)
}
