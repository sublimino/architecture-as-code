package oracle

// This module mirrors the engine's CEL environment and verdict vocabulary
// instead of importing them, because they live in `package main`. A mirror
// nobody checks is worse than no mirror: the tier would keep passing while
// judging expressions in an environment production does not use.
//
// So every mirrored value is read back out of the engine's own source here. If
// ../cel_eval.go or ../bindings.go changes, these tests fail and name the new
// value. They are deliberately crude text reads — a parser that silently
// matched nothing would defeat the purpose, so each pattern also asserts it
// found something.

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func engineSource(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(EngineSourceDir, name))
	if err != nil {
		t.Fatalf("cannot read the engine source this module mirrors (%s): %v", name, err)
	}
	return string(raw)
}

// mustFindAll returns every capture of the first group, failing if there are
// none: an empty result would otherwise read as agreement.
func mustFindAll(t *testing.T, src, pattern, what string) []string {
	t.Helper()
	re := regexp.MustCompile(pattern)
	ms := re.FindAllStringSubmatch(src, -1)
	if len(ms) == 0 {
		t.Fatalf("found no %s in the engine source with /%s/: the engine was restructured, "+
			"so this drift check is no longer reading what it thinks it is", what, pattern)
	}
	out := make([]string, 0, len(ms))
	for _, m := range ms {
		out = append(out, m[1])
	}
	return out
}

// TestDrift_CELEnvironment pins the variable list, cost limit, eval timeout and
// expression-length cap against ../cel_eval.go.
func TestDrift_CELEnvironment(t *testing.T) {
	src := engineSource(t, "cel_eval.go")

	vars := mustFindAll(t, src, `cel\.Variable\("([a-zA-Z_]+)",\s*cel\.DynType\)`, "cel.Variable declarations")
	if strings.Join(vars, ",") != strings.Join(celVariables, ",") {
		t.Errorf("CEL variable list drifted.\n  ../cel_eval.go: %v\n  oracle mirror:  %v\n"+
			"Update celVariables in engine.go. An oracle in a different CEL environment from "+
			"production proves nothing.", vars, celVariables)
	}

	for _, c := range []struct {
		what    string
		pattern string
		want    int
	}{
		{"cost limit", `cel\.CostLimit\((\d+)\)`, celCostLimit},
		{"expression length cap", `len\(expr\) > (\d+)`, celMaxExpressionBytes},
		{"eval timeout (ms)", `(\d+)\s*\*\s*time\.Millisecond`, int(celEvalTimeout.Milliseconds())},
	} {
		got := mustFindAll(t, src, c.pattern, c.what)
		n, err := strconv.Atoi(got[0])
		if err != nil {
			t.Fatalf("%s: %v", c.what, err)
		}
		if n != c.want {
			t.Errorf("%s drifted: ../cel_eval.go has %d, oracle mirror has %d", c.what, n, c.want)
		}
	}
}

// TestDrift_ActivationKeys pins the activation key set against ../bindings.go.
// A missing key makes every check that reads it error, which this tier would
// then report as "not comparable" across the board rather than as a fault.
func TestDrift_ActivationKeys(t *testing.T) {
	src := engineSource(t, "bindings.go")
	keys := mustFindAll(t, src, `(?m)^\s*"([a-z]+)":\s*orEmpty\(`, "activation keys")
	want := celBindings(nil, nil, nil)
	if len(keys) != len(want) {
		t.Fatalf("../bindings.go binds %v, the oracle mirror binds %d keys", keys, len(want))
	}
	for _, k := range keys {
		if _, ok := want[k]; !ok {
			t.Errorf("../bindings.go binds %q, which the oracle mirror does not", k)
		}
	}
}

// TestDrift_VerdictVocabulary pins the Verdict constants: if the engine renames
// a verdict string, comparisons here would silently stop matching.
func TestDrift_VerdictVocabulary(t *testing.T) {
	src := engineSource(t, "bindings.go")
	values := mustFindAll(t, src, `Verdict\w+\s+Verdict\s*=\s*"([a-z_]+)"`, "Verdict constants")
	mirror := map[string]bool{
		string(VerdictPass): true, string(VerdictFail): true,
		string(VerdictError): true, string(VerdictNotEvaluated): true,
		string(VerdictNotInForce): true,
	}
	if len(values) != len(mirror) {
		t.Errorf("../bindings.go declares %d verdicts %v, the oracle mirror has %d", len(values), values, len(mirror))
	}
	for _, v := range values {
		if !mirror[v] {
			t.Errorf("../bindings.go declares verdict %q, which the oracle mirror does not", v)
		}
	}
	placeholder := mustFindAll(t, src, `statusPlaceholder = "(\w+)"`, "statusPlaceholder")
	if placeholder[0] != statusPlaceholder {
		t.Errorf("statusPlaceholder drifted: engine %q, mirror %q", placeholder[0], statusPlaceholder)
	}
}

// TestDrift_MirrorCheckerCanFail proves the drift checks are capable of failing:
// the same reads against a doctored source must not match the mirror. Without
// this, a regexp that matched the wrong thing would look like perpetual
// agreement.
func TestDrift_MirrorCheckerCanFail(t *testing.T) {
	doctored := `cel.Variable("agent", cel.DynType)
	cel.Variable("object", cel.DynType)
	cel.CostLimit(99)`
	vars := regexp.MustCompile(`cel\.Variable\("([a-zA-Z_]+)",\s*cel\.DynType\)`).FindAllStringSubmatch(doctored, -1)
	var got []string
	for _, m := range vars {
		got = append(got, m[1])
	}
	if strings.Join(got, ",") == strings.Join(celVariables, ",") {
		t.Fatal("a two-variable source matched the four-variable mirror: the drift check is vacuous")
	}
	cost := regexp.MustCompile(`cel\.CostLimit\((\d+)\)`).FindStringSubmatch(doctored)
	if cost == nil || cost[1] == strconv.Itoa(celCostLimit) {
		t.Fatal("a doctored cost limit matched the mirror: the drift check is vacuous")
	}
}

// TestDrift_PackLoaderSeesTheWholePack guards the other mirrored thing: the
// pack reader here is not the engine's loader, so it must at least agree on the
// check inventory and find a non-empty expression for every check.
func TestDrift_PackLoaderSeesTheWholePack(t *testing.T) {
	p := cisPack(t)
	if len(p.Order) == 0 {
		t.Fatal("pack loader found no checks")
	}
	for _, id := range p.Order {
		c := p.Checks[id]
		if strings.TrimSpace(c.CELExpression) == "" && !p.Placeholder(id) {
			t.Errorf("check %q has no CEL expression: the pack reader is misreading framework.json", id)
		}
		if p.Placeholder(id) {
			t.Errorf("check %q is a placeholder; this tier has never been run against one, "+
				"so confirm placeholder handling before trusting the result", id)
		}
	}
	// The engine's own conformance suite asserts the same pack loads with the
	// same checks; a mismatch in either direction shows up as a mapping gap in
	// TestPSAOracle_MappingCoversEveryPackCheck.
	t.Logf("pack %s@%s: %d checks", p.ID, p.Version, len(p.Order))
}
