// Package oracle holds the external-oracle tier for the policy packs. It is a
// separate Go module on purpose: it depends on k8s.io/pod-security-admission,
// which drags in 17 modules and moves google.golang.org/protobuf onto an
// unreleased pseudo-version. The policy engine ships as a signed image in a
// supply-chain security product, so a test-only dependency must not touch its
// production module graph. `d2-signalloom/apps/policy-engine/go.mod` is
// byte-identical to what it was before this tier existed.
//
// The cost of that isolation is this file: the engine's CEL construction and
// verdict vocabulary are MIRRORED here rather than imported, because they live
// in `package main`. Every mirrored value is pinned against its source by
// drift_test.go, which reads the engine's own .go files and fails if they
// change. Do not edit the constants here without reading that test.
//
//	source of truth: ../cel_eval.go  (CEL env, cost limit, eval timeout)
//	source of truth: ../bindings.go  (activation keys, Verdict vocabulary)
//	source of truth: ../../../../policy/frameworks/CONFORMANCE.md (fixture contract)
package oracle

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/cel-go/cel"
)

// --- mirrored from ../bindings.go -------------------------------------------

// Verdict is the outcome of one check. Mirrors ../bindings.go; pinned by
// TestDrift_VerdictVocabulary.
type Verdict string

const (
	VerdictPass         Verdict = "pass"
	VerdictFail         Verdict = "fail"
	VerdictError        Verdict = "error"
	VerdictNotEvaluated Verdict = "not_evaluated"
)

// statusPlaceholder marks a pack or check that is not yet evaluable.
const statusPlaceholder = "placeholder"

func verdictOf(passed bool, err error) Verdict {
	switch {
	case err != nil:
		return VerdictError
	case passed:
		return VerdictPass
	default:
		return VerdictFail
	}
}

// celBindings builds the activation every framework check is evaluated with.
// Mirrors ../bindings.go; the key set is pinned by TestDrift_ActivationKeys.
func celBindings(object, agent, request map[string]any) map[string]any {
	orEmpty := func(m map[string]any) map[string]any {
		if m == nil {
			return map[string]any{}
		}
		return m
	}
	return map[string]any{
		"object":   orEmpty(object),
		"manifest": orEmpty(object),
		"agent":    orEmpty(agent),
		"request":  orEmpty(request),
	}
}

// --- mirrored from ../cel_eval.go -------------------------------------------

// The engine's CEL limits. Pinned by TestDrift_CELEnvironment: if ../cel_eval.go
// changes any of these, that test fails and names the new value.
const (
	celMaxExpressionBytes = 4096
	celCostLimit          = 10000
	celEvalTimeout        = 50 * time.Millisecond
)

// celVariables is the engine's variable list, in the engine's order. Pinned by
// TestDrift_CELEnvironment. An oracle evaluating expressions in a different
// environment from production is not an oracle.
var celVariables = []string{"agent", "request", "object", "manifest"}

// CELEngine mirrors ../cel_eval.go's engine closely enough that an expression
// compiled and evaluated here behaves as it does in the service.
type CELEngine struct {
	env   *cel.Env
	mu    sync.RWMutex
	cache map[string]cel.Program
}

func NewCELEngine() (*CELEngine, error) {
	opts := make([]cel.EnvOption, 0, len(celVariables))
	for _, v := range celVariables {
		opts = append(opts, cel.Variable(v, cel.DynType))
	}
	env, err := cel.NewEnv(opts...)
	if err != nil {
		return nil, fmt.Errorf("creating CEL env: %w", err)
	}
	return &CELEngine{env: env, cache: map[string]cel.Program{}}, nil
}

func (e *CELEngine) CompileRule(expr string) (cel.Program, error) {
	expr = strings.TrimSpace(expr)
	if expr == "" {
		return nil, fmt.Errorf("empty CEL expression")
	}
	if len(expr) > celMaxExpressionBytes {
		return nil, fmt.Errorf("CEL expression exceeds maximum allowed length of %d bytes", celMaxExpressionBytes)
	}
	sum := sha256.Sum256([]byte(expr))
	key := hex.EncodeToString(sum[:])

	e.mu.RLock()
	prg, ok := e.cache[key]
	e.mu.RUnlock()
	if ok {
		return prg, nil
	}
	ast, issues := e.env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		return nil, fmt.Errorf("CEL compile error: %w", issues.Err())
	}
	prg, err := e.env.Program(ast, cel.CostLimit(celCostLimit))
	if err != nil {
		return nil, fmt.Errorf("CEL program creation error: %w", err)
	}
	e.mu.Lock()
	e.cache[key] = prg
	e.mu.Unlock()
	return prg, nil
}

func (e *CELEngine) Evaluate(ctx context.Context, expr string, input map[string]any) (bool, error) {
	prg, err := e.CompileRule(expr)
	if err != nil {
		return false, err
	}
	evalCtx, cancel := context.WithTimeout(ctx, celEvalTimeout)
	defer cancel()
	out, _, err := prg.ContextEval(evalCtx, input)
	if err != nil {
		return false, fmt.Errorf("CEL evaluation error: %w", err)
	}
	result, ok := out.Value().(bool)
	if !ok {
		return false, fmt.Errorf("CEL expression evaluated to non-boolean type %T", out.Value())
	}
	return result, nil
}

// --- pack and fixture loading (JSON from disk, no engine import) ------------

// Check is the subset of a pack check this tier needs. The pack JSON carries
// more (severity, risk triples, policy versions); unknown fields are tolerated
// here because the engine's own loader is the authority on the full shape.
type Check struct {
	ID            string
	CELExpression string
	Status        string
	Description   string
}

// Pack is one framework version's checks, in file order.
type Pack struct {
	ID      string
	Version string
	Status  string
	Dir     string
	Order   []string
	Checks  map[string]Check
}

func (p *Pack) Placeholder(id string) bool {
	return p.Status == statusPlaceholder || p.Checks[id].Status == statusPlaceholder
}

type rawFramework struct {
	ID          string `json:"id"`
	Version     string `json:"version"`
	Status      string `json:"status"`
	ControlSets []struct {
		Controls []struct {
			Checks []struct {
				ID            string `json:"id"`
				CELExpression string `json:"celExpression"`
				Status        string `json:"status"`
				Description   string `json:"description"`
			} `json:"checks"`
		} `json:"controls"`
	} `json:"controlSets"`
}

// LoadPack reads a pack's framework.json straight from the policy tree.
func LoadPack(policyRoot, id, version string) (*Pack, error) {
	dir := filepath.Join(policyRoot, "frameworks", id, version)
	raw, err := os.ReadFile(filepath.Join(dir, "framework.json"))
	if err != nil {
		return nil, err
	}
	var fw rawFramework
	if err := json.Unmarshal(raw, &fw); err != nil {
		return nil, fmt.Errorf("%s/%s framework.json: %w", id, version, err)
	}
	p := &Pack{ID: fw.ID, Version: fw.Version, Status: fw.Status, Dir: dir, Checks: map[string]Check{}}
	for _, cs := range fw.ControlSets {
		for _, c := range cs.Controls {
			for _, chk := range c.Checks {
				if _, dup := p.Checks[chk.ID]; !dup {
					p.Order = append(p.Order, chk.ID)
				}
				p.Checks[chk.ID] = Check{ID: chk.ID, CELExpression: chk.CELExpression, Status: chk.Status, Description: chk.Description}
			}
		}
	}
	return p, nil
}

// Fixture mirrors the conformance fixture contract. Unknown fields are
// rejected so a fixture that grows a field this tier does not understand fails
// loudly rather than being judged on a partial reading.
type Fixture struct {
	Name        string             `json:"name"`
	Level       string             `json:"level"`
	Description string             `json:"description"`
	Input       FixtureInput       `json:"input"`
	Expect      map[string]Verdict `json:"expect"`

	Path string `json:"-"`
}

type FixtureInput struct {
	Object  map[string]any `json:"object"`
	Agent   map[string]any `json:"agent"`
	Request map[string]any `json:"request"`
}

// LoadFixtures reads every fixture under a pack's fixtures/ directory.
func LoadFixtures(p *Pack) ([]Fixture, error) {
	dir := filepath.Join(p.Dir, "fixtures")
	var out []Fixture
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".json") {
			return err
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		var f Fixture
		if err := dec.Decode(&f); err != nil {
			return fmt.Errorf("fixture %s: %w", path, err)
		}
		f.Path = path
		out = append(out, f)
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, err
}

// PolicyRoot walks up from the working directory to the repo's policy/ tree.
func PolicyRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(dir, "policy", "frameworks")
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return filepath.Join(dir, "policy"), nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not find policy/frameworks above the working directory")
		}
		dir = parent
	}
}

// EngineSourceDir is the engine package this module mirrors. drift_test.go
// reads its files; everything else here treats it as documentation.
const EngineSourceDir = ".."
