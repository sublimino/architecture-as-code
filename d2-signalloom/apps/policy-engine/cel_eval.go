package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/google/cel-go/cel"
)

// CELEngine handles CEL environment initialization, compilation, caching, and execution.
type CELEngine struct {
	env   *cel.Env
	mu    sync.RWMutex
	cache map[string]cel.Program
}

// NewCELEngine initializes a new CEL execution environment with standard type declarations.
func NewCELEngine() (*CELEngine, error) {
	env, err := cel.NewEnv(
		cel.Variable("agent", cel.DynType),
		cel.Variable("request", cel.DynType),
		cel.Variable("object", cel.DynType),
		cel.Variable("manifest", cel.DynType),
	)
	if err != nil {
		return nil, fmt.Errorf("creating CEL env: %w", err)
	}

	return &CELEngine{
		env:   env,
		cache: make(map[string]cel.Program),
	}, nil
}

func (e *CELEngine) cacheKey(expr string) string {
	h := sha256.Sum256([]byte(expr))
	return hex.EncodeToString(h[:])
}

// CompileRule parses and compiles a CEL expression with strict cost limits.
func (e *CELEngine) CompileRule(expr string) (cel.Program, error) {
	expr = strings.TrimSpace(expr)
	if expr == "" {
		return nil, fmt.Errorf("empty CEL expression")
	}
	if len(expr) > 4096 {
		return nil, fmt.Errorf("CEL expression exceeds maximum allowed length of 4096 bytes")
	}

	key := e.cacheKey(expr)
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

	// Enforce strict instruction cost limit of 10,000 to prevent CPU exhaustion.
	prg, err := e.env.Program(ast, cel.CostLimit(10000))
	if err != nil {
		return nil, fmt.Errorf("CEL program creation error: %w", err)
	}

	e.mu.Lock()
	e.cache[key] = prg
	e.mu.Unlock()

	return prg, nil
}

// Evaluate evaluates a compiled expression against agent and request contexts.
func (e *CELEngine) Evaluate(ctx context.Context, expr string, input map[string]any) (bool, uint64, error) {
	prg, err := e.CompileRule(expr)
	if err != nil {
		return false, 0, err
	}

	// Enforce 50ms timeout on evaluation
	evalCtx, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()

	out, evalDetails, err := prg.ContextEval(evalCtx, input)
	if err != nil {
		slog.Debug("CEL eval error", "expression", expr, "error", err)
		return false, 0, fmt.Errorf("CEL evaluation error: %w", err)
	}

	var cost uint64
	if evalDetails != nil && evalDetails.ActualCost() != nil {
		cost = *evalDetails.ActualCost()
	}

	result, ok := out.Value().(bool)
	if !ok {
		return false, cost, fmt.Errorf("CEL expression evaluated to non-boolean type %T", out.Value())
	}

	return result, cost, nil
}
