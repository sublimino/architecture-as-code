package main

import (
	"context"
	"strings"
	"testing"
)

// TestAdversarialMalformation verifies rejection of syntactically invalid, type-mismatched, or oversized CEL expressions.
func TestAdversarialMalformation(t *testing.T) {
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed creating CEL engine: %v", err)
	}

	tests := []struct {
		name string
		expr string
	}{
		{"Empty expression", ""},
		{"Whitespace only", "    \t\n  "},
		{"Syntax error missing closing bracket", `agent.model in ["gpt-4o"`},
		{"Invalid operator", `agent.model === "gpt-4o"`},
		{"Non-existent function", `agent.model.unknownFunction()`},
		{"Oversized expression (> 4096 bytes)", strings.Repeat("agent.model == 'a' && ", 300) + "true"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := engine.CompileRule(tc.expr)
			if err == nil {
				t.Fatalf("expected compilation error for %q, got nil", tc.name)
			}
		})
	}
}

// TestAdversarialTypeMismatch verifies handling of runtime type mismatches in CEL evaluations.
func TestAdversarialTypeMismatch(t *testing.T) {
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed creating CEL engine: %v", err)
	}

	// Expression expecting bool, but returns int or string
	nonBoolExpr := `42`
	_, _, err = engine.Evaluate(context.Background(), nonBoolExpr, map[string]any{})
	if err == nil || !strings.Contains(err.Error(), "non-boolean") {
		t.Fatalf("expected non-boolean type evaluation error, got: %v", err)
	}

	// Expression operating on missing or incorrect field types
	mismatchExpr := `agent.model + 5 == 10`
	_, _, err = engine.Evaluate(context.Background(), mismatchExpr, map[string]any{
		"agent": map[string]any{"model": "gpt-4"},
	})
	if err == nil {
		t.Fatalf("expected runtime evaluation error on invalid type addition, got nil")
	}
}

// TestAdversarialReDoSProtection verifies regex safety under simulated ReDoS payloads.
func TestAdversarialReDoSProtection(t *testing.T) {
	engine, err := NewCELEngine()
	if err != nil {
		t.Fatalf("failed creating CEL engine: %v", err)
	}

	// Classic ReDoS pattern: nested repetitions
	reDosExpr := `agent.id.matches("^(a+)+$")`
	targetInput := strings.Repeat("a", 30) + "!"

	ctx, cancel := context.WithTimeout(context.Background(), 50)
	defer cancel()

	// Go RE2 and CEL cost limits prevent catastrophic backtracking
	pass, _, err := engine.Evaluate(ctx, reDosExpr, map[string]any{
		"agent": map[string]any{"id": targetInput},
	})
	if err == nil && pass {
		t.Fatalf("expected matching to fail for non-matching input, got pass=true")
	}
}
