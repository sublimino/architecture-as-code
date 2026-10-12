package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
	"testing"
)

// auditRiskMoneyFloor is the magnitude above which a numeric literal assigned to
// an AuditEvent risk field is treated as a money figure rather than a plausible
// small constant.
//
// 1000 is an order of magnitude below the smallest fabrication this guard
// exists to catch (12,400) and far below the largest (847,000), while sitting
// above anything this package legitimately spells small. It is the same floor
// the policy-engine's source invariant uses, deliberately, so a reader meets one
// number and not two.
const auditRiskMoneyFloor = 1000.0

// TestAuditEventsCarryNoCalibratedRiskLiteral asserts that no non-test source
// file in this package assigns a money-magnitude numeric literal to an
// AuditEvent's RiskBefore, RiskAfter or RiskDelta field.
//
// WHY THIS EXISTS, and it is not hypothetical. The manual-stun and recover
// handlers wrote RiskBefore 847000.0 / RiskAfter 12400.0 / RiskDelta -834600.0
// into EVERY audit event, unconditionally, with no comment. Those are the same
// literals this service's own read path refuses to report: aggregateRisk answers
// AUTHORED_NOT_COMPUTED because fleet.yaml's figure is authored configuration
// and not a measurement. So the refusal sat on the read path while the audit
// trail asserted the figures as fact -- and an audit trail is the worst place
// for a fabrication, because it is the record somebody later cites as evidence.
//
// WHY A SOURCE GUARD AND NOT A BEHAVIOURAL ONE. A behavioural test was tried
// first and the mutant SURVIVED: reinstating the literal on the manual-stun
// event left every test in the package green, because no assertion read that
// field on that path. Narrowing the required-field set (which previously
// asserted `RiskBefore == 0` on every event, and so silently depended on the
// fabrication) was necessary but not sufficient. The property worth asserting
// is about the SOURCE: this package must not contain a money literal bound to a
// risk field at all, whatever the surrounding control flow does.
//
// It walks the AST rather than grepping text, because a *ast.BasicLit is a
// literal by construction and therefore cannot match digits inside an
// identifier, a string or a comment -- the three false-positive sources that
// push a text matcher toward an exemption list that then rots.
//
// WHAT IT DELIBERATELY ALLOWS. policy_engine.go computes these figures from real
// inputs and takes their addresses; a variable reference is not a literal, so it
// passes untouched. That is the distinction the guard is built on: the fields
// are legitimate, only hardcoding them is not.
func TestAuditEventsCarryNoCalibratedRiskLiteral(t *testing.T) {
	riskFields := map[string]bool{"RiskBefore": true, "RiskAfter": true, "RiskDelta": true}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("reading package dir: %v", err)
	}

	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, name, nil, parser.ParseComments)
		if err != nil {
			t.Fatalf("parsing %s: %v", name, err)
		}
		scanned++

		ast.Inspect(file, func(n ast.Node) bool {
			kv, ok := n.(*ast.KeyValueExpr)
			if !ok {
				return true
			}
			key, ok := kv.Key.(*ast.Ident)
			if !ok || !riskFields[key.Name] {
				return true
			}
			// Walk the WHOLE assigned expression, not just its root node.
			//
			// The first version of this guard checked only whether kv.Value was
			// itself a *ast.BasicLit, and it could never fire. Because the risk
			// fields are now POINTERS, a literal can only reach one through a
			// helper or a closure -- `func() *float64 { v := 847000.0; return &v }()`
			// -- so the root node is a CallExpr and the literal sits two levels
			// down. The mutation that motivated this whole guard therefore
			// survived it. An instrument that cannot see the shape its target
			// actually takes is worse than none, because it reports clean.
			//
			// So: descend. Any money-magnitude literal anywhere inside the
			// expression bound to a risk field is a finding, whether written
			// directly, wrapped in a closure, negated, or built with separators.
			ast.Inspect(kv.Value, func(inner ast.Node) bool {
				lit, ok := inner.(*ast.BasicLit)
				if !ok || (lit.Kind != token.FLOAT && lit.Kind != token.INT) {
					return true
				}
				parsed, err := strconv.ParseFloat(strings.ReplaceAll(lit.Value, "_", ""), 64)
				if err != nil {
					return true
				}
				if abs(parsed) >= auditRiskMoneyFloor {
					pos := fset.Position(lit.Pos())
					t.Errorf("%s:%d assigns the money literal %s to AuditEvent.%s. "+
						"An audit event must carry a figure something measured, or none at all: "+
						"this service's read path refuses to report authored risk as a "+
						"measurement, and the audit trail must not contradict it. Compute the "+
						"value, or omit the field (it is an omitempty pointer).",
						pos.Filename, pos.Line, lit.Value, key.Name)
				}
				return true
			})
			return true
		})
	}

	// A guard that scanned nothing reports "no findings" identically to a clean
	// one, so the scan is itself asserted.
	if scanned == 0 {
		t.Fatal("scanned 0 non-test Go files; the guard cannot have checked anything")
	}
	t.Logf("scanned %d non-test Go files in this package", scanned)
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}
