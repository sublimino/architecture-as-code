package main

// Conformance harness for policy/frameworks/*. Contract: policy/frameworks/CONFORMANCE.md.
//
// Every pack that has a fixtures/ directory is held to the contract: each
// fixture's expectations must match the verdict the real CELEngine produces,
// fixtures must be well-formed, and every non-placeholder check needs at least
// one passing and one failing fixture.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

type conformanceFixture struct {
	Name        string             `json:"name"`
	Level       string             `json:"level"`
	Description string             `json:"description"`
	Input       conformanceInput   `json:"input"`
	Expect      map[string]Verdict `json:"expect"`

	path string
}

type conformanceInput struct {
	Object  map[string]any `json:"object"`
	Agent   map[string]any `json:"agent"`
	Request map[string]any `json:"request"`
}

type conformancePack struct {
	dir      string
	fw       *frameworks.Framework
	checks   map[string]frameworks.Check
	order    []string
	fixtures []conformanceFixture
}

func (p *conformancePack) label() string { return p.fw.ID + "/" + filepath.Base(p.dir) }

func (p *conformancePack) placeholder(id string) bool {
	return isPlaceholder(p.fw.Status, p.checks[id].Status)
}

func conformancePolicyRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "policy", "frameworks")
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return filepath.Join(dir, "policy")
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find policy/frameworks")
		}
		dir = parent
	}
}

// loadConformancePacks loads every framework version the engine would load,
// with its fixtures (if any).
func loadConformancePacks(t *testing.T, root string) []*conformancePack {
	t.Helper()
	avail, err := frameworks.ListFrameworks(root)
	if err != nil {
		t.Fatal(err)
	}
	var packs []*conformancePack
	ids := make([]string, 0, len(avail))
	for id := range avail {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		for _, ver := range avail[id] {
			fw, err := frameworks.Load(root, id, ver)
			if err != nil {
				t.Errorf("%s/%s does not load: %v", id, ver, err)
				continue
			}
			p := newConformancePack(filepath.Join(root, "frameworks", id, ver), fw)
			fixtures, err := readFixtures(filepath.Join(p.dir, "fixtures"))
			if err != nil {
				t.Errorf("%s: %v", p.label(), err)
			}
			p.fixtures = fixtures
			packs = append(packs, p)
		}
	}
	return packs
}

func newConformancePack(dir string, fw *frameworks.Framework) *conformancePack {
	p := &conformancePack{dir: dir, fw: fw, checks: map[string]frameworks.Check{}}
	for _, cs := range fw.ControlSets {
		for _, c := range cs.Controls {
			for _, chk := range c.Checks {
				if _, dup := p.checks[chk.ID]; !dup {
					p.order = append(p.order, chk.ID)
				}
				p.checks[chk.ID] = chk
			}
		}
	}
	return p
}

func readFixtures(dir string) ([]conformanceFixture, error) {
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return nil, nil
	}
	var out []conformanceFixture
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
		var f conformanceFixture
		if err := dec.Decode(&f); err != nil {
			return fmt.Errorf("fixture %s: %w", path, err)
		}
		f.path = path
		out = append(out, f)
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].path < out[j].path })
	return out, err
}

// validatePack returns every contract violation in a pack's fixtures. It does
// not evaluate CEL; see evaluateFixture for that.
func validatePack(p *conformancePack) []string {
	var problems []string
	seen := map[string]string{}
	for _, f := range p.fixtures {
		where := f.path
		base := strings.TrimSuffix(filepath.Base(f.path), ".json")
		if f.Name != base {
			problems = append(problems, fmt.Sprintf("%s: name %q must equal file basename %q", where, f.Name, base))
		}
		if prev, dup := seen[f.Name]; dup {
			problems = append(problems, fmt.Sprintf("%s: duplicate fixture name %q (also %s)", where, f.Name, prev))
		}
		seen[f.Name] = where
		if f.Level != "unit" && f.Level != "integration" {
			problems = append(problems, fmt.Sprintf("%s: level %q must be unit or integration", where, f.Level))
		}
		if len(f.Expect) == 0 {
			problems = append(problems, fmt.Sprintf("%s: expect is empty", where))
		}
		for id, v := range f.Expect {
			if _, ok := p.checks[id]; !ok {
				problems = append(problems, fmt.Sprintf("%s: expects unknown check %q", where, id))
				continue
			}
			placeholder := p.placeholder(id)
			if placeholder && v != VerdictNotEvaluated {
				problems = append(problems, fmt.Sprintf("%s: placeholder check %q must expect not_evaluated, not %q", where, id, v))
				continue
			}
			switch v {
			case VerdictNotEvaluated:
				if !placeholder {
					problems = append(problems, fmt.Sprintf("%s: check %q is not a placeholder: not_evaluated is not a valid expectation", where, id))
				}
			case VerdictPass, VerdictFail:
			case VerdictError:
				if strings.TrimSpace(f.Description) == "" {
					problems = append(problems, fmt.Sprintf("%s: error expectation for %q needs a description saying why", where, id))
				}
			default:
				problems = append(problems, fmt.Sprintf("%s: verdict %q for %q must be pass, fail, error or not_evaluated", where, v, id))
			}
		}
		if f.Level == "integration" {
			for _, id := range p.order {
				if _, ok := f.Expect[id]; !ok {
					problems = append(problems, fmt.Sprintf("%s: integration fixture missing expectation for check %q", where, id))
				}
			}
		}
	}
	return problems
}

// coverageGaps lists non-placeholder checks lacking a pass or a fail fixture.
func coverageGaps(p *conformancePack) []string {
	var gaps []string
	if len(p.fixtures) == 0 {
		for _, id := range p.order {
			if !p.placeholder(id) {
				gaps = append(gaps, fmt.Sprintf("%s: pack has no fixtures but has non-placeholder check %q", p.label(), id))
				break
			}
		}
	}
	for _, id := range p.order {
		if p.placeholder(id) {
			continue
		}
		var pass, fail bool
		for _, f := range p.fixtures {
			switch f.Expect[id] {
			case VerdictPass:
				pass = true
			case VerdictFail:
				fail = true
			}
		}
		if !pass {
			gaps = append(gaps, fmt.Sprintf("%s: check %q has no passing fixture", p.label(), id))
		}
		if !fail {
			gaps = append(gaps, fmt.Sprintf("%s: check %q has no failing fixture", p.label(), id))
		}
	}
	return gaps
}

type checkOutcome struct {
	verdict Verdict
	err     error
}

func evaluateFixture(eng *CELEngine, p *conformancePack, f conformanceFixture) map[string]checkOutcome {
	in := celBindings(f.Input.Object, f.Input.Agent, f.Input.Request)
	out := map[string]checkOutcome{}
	for id := range f.Expect {
		chk, ok := p.checks[id]
		if !ok {
			continue
		}
		if p.placeholder(id) {
			out[id] = checkOutcome{verdict: VerdictNotEvaluated}
			continue
		}
		passed, _, err := eng.Evaluate(context.Background(), chk.CELExpression, in)
		out[id] = checkOutcome{verdict: verdictOf(passed, err), err: err}
	}
	return out
}

// roundTripFixtureInput re-decodes a fixture's input exactly the way handleScan
// decodes a request body, so numbers reach CEL as float64 like in production.
func roundTripFixtureInput(t *testing.T, f conformanceFixture) conformanceFixture {
	t.Helper()
	raw, err := json.Marshal(f.Input)
	if err != nil {
		t.Fatal(err)
	}
	var in conformanceInput
	if err := json.NewDecoder(bytes.NewReader(raw)).Decode(&in); err != nil {
		t.Fatal(err)
	}
	f.Input = in
	return f
}

func TestConformance_ChecksCompile(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, id := range p.order {
			if _, err := eng.CompileRule(p.checks[id].CELExpression); err != nil {
				t.Errorf("%s: check %q does not compile: %v", p.label(), id, err)
			}
		}
	}
}

func TestConformance_FixturesWellFormed(t *testing.T) {
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, problem := range validatePack(p) {
			t.Error(problem)
		}
	}
}

func TestConformance_Coverage(t *testing.T) {
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, gap := range coverageGaps(p) {
			t.Error(gap)
		}
	}
}

// versionSelectionProblems runs, for every pack, a scan of its framework at
// policyVersion = the pack's version, and requires the rows to be exactly that
// directory's checks carrying that version: no foreign directory, no
// duplicate, none missing.
func versionSelectionProblems(packs []*conformancePack, scan func(fwID, policyVersion string) ([]ComplianceScanResult, error)) []string {
	var problems []string
	for _, p := range packs {
		where := p.fw.ID + "@" + p.fw.Version
		results, err := scan(p.fw.ID, p.fw.Version)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: %v", where, err))
			continue
		}
		want := map[string]bool{}
		for _, id := range p.order {
			for _, v := range p.checks[id].PolicyVersions {
				if v == p.fw.Version {
					want[id] = true
				}
			}
		}
		count := map[string]int{}
		for _, r := range results {
			if r.Framework != p.fw.ID || r.FrameworkVersion != p.fw.Version {
				problems = append(problems, fmt.Sprintf("%s: row %q from %s", where, r.Check, r.FrameworkVersion))
				continue
			}
			count[r.Check]++
		}
		for id, n := range count {
			if n > 1 {
				problems = append(problems, fmt.Sprintf("%s: check %q reported %d times", where, id, n))
			}
			if !want[id] {
				problems = append(problems, fmt.Sprintf("%s: check %q does not carry %s", where, id, p.fw.Version))
			}
		}
		for id := range want {
			if count[id] == 0 {
				problems = append(problems, fmt.Sprintf("%s: check %q missing", where, id))
			}
		}
	}
	sort.Strings(problems)
	return problems
}

// Audit H1/H2 through the real handleScan: each framework × each pack version
// present selects exactly that pack's directory.
func TestConformance_VersionSelection(t *testing.T) {
	root := conformancePolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	scan := func(fwID, pv string) ([]ComplianceScanResult, error) {
		raw, _ := json.Marshal(map[string]any{"frameworks": []string{fwID}, "policyVersion": pv})
		return handlerTransport{h}.scan(raw)
	}
	for _, problem := range versionSelectionProblems(loadConformancePacks(t, root), scan) {
		t.Error(problem)
	}
}

func TestConformance_Verdicts(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range loadConformancePacks(t, conformancePolicyRoot(t)) {
		for _, f := range p.fixtures {
			f := roundTripFixtureInput(t, f)
			t.Run(p.label()+"/"+f.Name, func(t *testing.T) {
				got := evaluateFixture(eng, p, f)
				ids := make([]string, 0, len(f.Expect))
				for id := range f.Expect {
					ids = append(ids, id)
				}
				sort.Strings(ids)
				for _, id := range ids {
					want, o := f.Expect[id], got[id]
					if o.verdict != want {
						t.Errorf("check %q: got %s, want %s (err=%v)", id, o.verdict, want, o.err)
					}
				}
			})
		}
	}
}

// --- harness self-tests: the harness must refuse the fake greens it exists to stop.

func syntheticPack() *conformancePack {
	fw := &frameworks.Framework{ID: "synthetic", ControlSets: []frameworks.ControlSet{{
		Controls: []frameworks.Control{{Checks: []frameworks.Check{
			{ID: "non-root", CELExpression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)"},
			{ID: "strict-read", CELExpression: "object.spec.mustExist == true"},
		}}},
	}}}
	return newConformancePack("/x/frameworks/synthetic/v1.0", fw)
}

func fixture(name, level string, expect map[string]Verdict) conformanceFixture {
	return conformanceFixture{Name: name, Level: level, Expect: expect, path: "/x/fixtures/" + name + ".json"}
}

func TestConformanceHarness_RejectsMalformedFixtures(t *testing.T) {
	cases := map[string]struct {
		f    conformanceFixture
		want string
	}{
		"unknown check":      {fixture("a", "unit", map[string]Verdict{"typo": VerdictPass}), `unknown check "typo"`},
		"empty expect":       {fixture("a", "unit", nil), "expect is empty"},
		"bad level":          {fixture("a", "e2e", map[string]Verdict{"non-root": VerdictPass}), `level "e2e"`},
		"bad verdict":        {fixture("a", "unit", map[string]Verdict{"non-root": "ok"}), `verdict "ok"`},
		"undocumented error": {fixture("a", "unit", map[string]Verdict{"non-root": VerdictError}), "needs a description"},
		"incomplete integ":   {fixture("a", "integration", map[string]Verdict{"non-root": VerdictPass}), `missing expectation for check "strict-read"`},
		"name != basename":   {conformanceFixture{Name: "a", Level: "unit", Expect: map[string]Verdict{"non-root": VerdictPass}, path: "/x/b.json"}, "must equal file basename"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			p := syntheticPack()
			p.fixtures = []conformanceFixture{tc.f}
			problems := strings.Join(validatePack(p), "\n")
			if !strings.Contains(problems, tc.want) {
				t.Fatalf("want a problem containing %q, got:\n%s", tc.want, problems)
			}
		})
	}
	t.Run("duplicate names", func(t *testing.T) {
		p := syntheticPack()
		a := fixture("a", "unit", map[string]Verdict{"non-root": VerdictPass})
		b := a
		b.path = "/x/fixtures/sub/a.json"
		p.fixtures = []conformanceFixture{a, b}
		if !strings.Contains(strings.Join(validatePack(p), "\n"), "duplicate fixture name") {
			t.Fatal("duplicate fixture names accepted")
		}
	})
	t.Run("well-formed accepted", func(t *testing.T) {
		p := syntheticPack()
		p.fixtures = []conformanceFixture{fixture("a", "integration", map[string]Verdict{"non-root": VerdictPass, "strict-read": VerdictFail})}
		if problems := validatePack(p); len(problems) != 0 {
			t.Fatalf("valid fixture rejected: %v", problems)
		}
	})
}

func TestConformanceHarness_CoverageNeedsPassAndFail(t *testing.T) {
	p := syntheticPack()
	p.fixtures = []conformanceFixture{fixture("a", "unit", map[string]Verdict{"non-root": VerdictPass})}
	gaps := strings.Join(coverageGaps(p), "\n")
	for _, want := range []string{`"non-root" has no failing`, `"strict-read" has no passing`, `"strict-read" has no failing`} {
		if !strings.Contains(gaps, want) {
			t.Errorf("coverage gate missed %q:\n%s", want, gaps)
		}
	}
	p.fw.Status = "placeholder"
	if gaps := coverageGaps(p); len(gaps) != 0 {
		t.Errorf("placeholder pack still gated: %v", gaps)
	}
}

// CONFORMANCE rule 5: a pack with any non-placeholder check and no fixtures at
// all fails coverage; an all-placeholder pack with no fixtures does not.
func TestConformanceHarness_PackWithoutFixturesFailsCoverage(t *testing.T) {
	p := syntheticPack()
	if gaps := strings.Join(coverageGaps(p), "\n"); !strings.Contains(gaps, "synthetic/v1.0: pack has no fixtures") {
		t.Errorf("fixture-less pack passed coverage:\n%s", gaps)
	}
	p.fw.Status = "placeholder"
	if gaps := coverageGaps(p); len(gaps) != 0 {
		t.Errorf("fixture-less placeholder pack gated: %v", gaps)
	}
}

// versionSelectionProblems must catch a scanner that evaluates more than the
// one selected directory (the audit H1/H2 defect).
func TestConformanceHarness_VersionSelectionDetectsMultiDirectoryScan(t *testing.T) {
	packs := loadConformancePacks(t, throwawayRoot(t))
	allDirs := func(fwID, _ string) ([]ComplianceScanResult, error) {
		var out []ComplianceScanResult
		for _, p := range packs {
			for _, id := range p.order {
				out = append(out, ComplianceScanResult{Framework: fwID, Check: id, FrameworkVersion: p.fw.Version})
			}
		}
		return out, nil
	}
	problems := strings.Join(versionSelectionProblems(packs, allDirs), "\n")
	if want := `throwaway@v1.0.0: row "agent-registered" from v2.0.0`; !strings.Contains(problems, want) {
		t.Errorf("missed %q in:\n%s", want, problems)
	}

	// Right directory, but a check reported twice and one missing.
	dupAndMissing := func(fwID, pv string) ([]ComplianceScanResult, error) {
		r := ComplianceScanResult{Framework: fwID, Check: "agent-registered", FrameworkVersion: pv}
		return []ComplianceScanResult{r, r}, nil
	}
	problems = strings.Join(versionSelectionProblems(packs, dupAndMissing), "\n")
	for _, want := range []string{
		`throwaway@v1.0.0: check "agent-registered" reported 2 times`,
		`throwaway@v1.0.0: check "object-non-root" missing`,
	} {
		if !strings.Contains(problems, want) {
			t.Errorf("missed %q in:\n%s", want, problems)
		}
	}
	if got := versionSelectionProblems(packs, func(fwID, pv string) ([]ComplianceScanResult, error) {
		var out []ComplianceScanResult
		for _, p := range packs {
			if p.fw.Version == pv {
				for _, id := range p.order {
					out = append(out, ComplianceScanResult{Framework: fwID, Check: id, FrameworkVersion: pv})
				}
			}
		}
		return out, nil
	}); len(got) != 0 {
		t.Errorf("correct scanner flagged: %v", got)
	}
}

// A placeholder check is expected not_evaluated, and only a placeholder check
// may be: pass/fail/error for a placeholder, or not_evaluated for a real
// check, are both rejected.
func TestConformanceHarness_PlaceholderVerdicts(t *testing.T) {
	p := syntheticPack()
	ph := p.checks["strict-read"]
	ph.Status = "placeholder"
	p.checks["strict-read"] = ph

	for _, v := range []Verdict{VerdictPass, VerdictFail, VerdictError} {
		p.fixtures = []conformanceFixture{fixture("a", "unit", map[string]Verdict{"strict-read": v})}
		p.fixtures[0].Description = "why"
		if !strings.Contains(strings.Join(validatePack(p), "\n"), `placeholder check "strict-read" must expect not_evaluated`) {
			t.Errorf("placeholder expecting %s accepted", v)
		}
	}
	p.fixtures = []conformanceFixture{fixture("a", "unit", map[string]Verdict{"non-root": VerdictNotEvaluated})}
	if !strings.Contains(strings.Join(validatePack(p), "\n"), `check "non-root" is not a placeholder: not_evaluated`) {
		t.Error("not_evaluated accepted for a non-placeholder check")
	}
	p.fixtures = []conformanceFixture{fixture("a", "unit", map[string]Verdict{"strict-read": VerdictNotEvaluated})}
	if problems := validatePack(p); len(problems) != 0 {
		t.Errorf("not_evaluated for a placeholder rejected: %v", problems)
	}

	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	// strict-read would error on this input; as a placeholder it is not evaluated.
	f := fixture("a", "unit", map[string]Verdict{"strict-read": VerdictNotEvaluated})
	f.Input.Object = map[string]any{"spec": map[string]any{}}
	if got := evaluateFixture(eng, p, f)["strict-read"]; got.verdict != VerdictNotEvaluated || got.err != nil {
		t.Errorf("placeholder evaluated: got %s (err=%v), want not_evaluated", got.verdict, got.err)
	}
}

// An evaluation error must surface as error, never satisfy a fail expectation.
func TestConformanceHarness_ErrorIsNotFail(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	p := syntheticPack()
	f := fixture("a", "unit", map[string]Verdict{"strict-read": VerdictFail, "non-root": VerdictFail})
	f.Input.Object = map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"name": "c"}}}}
	got := evaluateFixture(eng, p, roundTripFixtureInput(t, f))
	if got["strict-read"].verdict != VerdictError {
		t.Errorf("missing key: got %s, want error", got["strict-read"].verdict)
	}
	if got["non-root"].verdict != VerdictFail {
		t.Errorf("guarded absent field: got %s, want fail (err=%v)", got["non-root"].verdict, got["non-root"].err)
	}
}

// Absent inputs are bound to empty maps: a has()-guarded agent check fails
// instead of erroring on an undeclared variable.
func TestConformanceHarness_AbsentInputsBoundEmpty(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	passed, _, err := eng.Evaluate(context.Background(), "has(agent.registry) && agent.registry.model_registered == true", celBindings(nil, nil, nil))
	if v := verdictOf(passed, err); v != VerdictFail {
		t.Fatalf("got %s, want fail (err=%v)", v, err)
	}
}
