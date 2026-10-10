package main

// ISC-10: every conformance fixture under policy/frameworks/*/*/fixtures is
// POSTed through the scan handler, one scan per fixture restricted to the
// fixture's framework, and each expected check's status must equal the
// fixture's verdict. /summary after each scan must equal that scan's tally.
// The walk is generic: packs gain coverage here as soon as fixtures land.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

// scanTransport performs one scan and one summary read. The handler-level
// test drives the handler in-process; the e2e test drives the real binary.
type scanTransport interface {
	scan(body []byte) ([]ComplianceScanResult, error)
	summary() (ComplianceSummary, error)
}

type handlerTransport struct{ h *complianceHandler }

func (ht handlerTransport) scan(body []byte) ([]ComplianceScanResult, error) {
	w := httptest.NewRecorder()
	ht.h.handleScan(w, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(body)))
	if w.Code != http.StatusOK {
		return nil, fmt.Errorf("scan: HTTP %d: %s", w.Code, w.Body.String())
	}
	var out []ComplianceScanResult
	return out, json.Unmarshal(w.Body.Bytes(), &out)
}

func (ht handlerTransport) summary() (ComplianceSummary, error) {
	w := httptest.NewRecorder()
	ht.h.handleSummary(w, httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil))
	if w.Code != http.StatusOK {
		return ComplianceSummary{}, fmt.Errorf("summary: HTTP %d: %s", w.Code, w.Body.String())
	}
	var s ComplianceSummary
	return s, json.Unmarshal(w.Body.Bytes(), &s)
}

// fixtureScanMismatches scans every fixture of every pack and returns each
// disagreement, plus the number of fixtures scanned.
func fixtureScanMismatches(t *testing.T, tr scanTransport, packs []*conformancePack) ([]string, int) {
	t.Helper()
	var problems []string
	scanned := 0

	// A scan evaluates every version of a framework; results are attributed to
	// a pack by frameworkVersion, which must therefore be unique per framework.
	versionOwner := map[string]string{}
	for _, p := range packs {
		key := p.fw.ID + "@" + p.fw.Version
		if prev, dup := versionOwner[key]; dup {
			problems = append(problems, fmt.Sprintf("%s and %s both declare version %q: scan results cannot be attributed", prev, p.dir, p.fw.Version))
		}
		versionOwner[key] = p.dir
	}

	for _, p := range packs {
		for _, f := range p.fixtures {
			scanned++
			where := p.label() + "/" + f.Name
			body, err := json.Marshal(map[string]any{
				"namespace":  "conformance",
				"frameworks": []string{p.fw.ID},
				"object":     f.Input.Object,
				"agent":      f.Input.Agent,
				"request":    f.Input.Request,
			})
			if err != nil {
				t.Fatal(err)
			}
			results, err := tr.scan(body)
			if err != nil {
				problems = append(problems, fmt.Sprintf("%s: %v", where, err))
				continue
			}

			got := map[string][]ComplianceScanResult{}
			tally := map[Verdict]int{}
			var exposure float64
			for _, r := range results {
				tally[r.Status]++
				if r.Status != VerdictPass {
					exposure += r.CarriedGBP
				}
				if r.Framework == p.fw.ID && r.FrameworkVersion == p.fw.Version {
					got[r.Check] = append(got[r.Check], r)
				}
			}
			for _, id := range sortedKeys(f.Expect) {
				want := f.Expect[id]
				rs := got[id]
				if len(rs) == 0 {
					problems = append(problems, fmt.Sprintf("%s: check %q: no scan result", where, id))
				}
				for _, r := range rs {
					if r.Status != want {
						problems = append(problems, fmt.Sprintf("%s: check %q: got %s, want %s (error=%q)", where, id, r.Status, want, r.Error))
					}
					if r.Passed != (r.Status == VerdictPass) {
						problems = append(problems, fmt.Sprintf("%s: check %q: passed=%v contradicts status %s", where, id, r.Passed, r.Status))
					}
				}
			}

			s, err := tr.summary()
			if err != nil {
				problems = append(problems, fmt.Sprintf("%s: %v", where, err))
				continue
			}
			if s.TotalControls != len(results) || s.Passed != tally[VerdictPass] || s.Failed != tally[VerdictFail] || s.Errored != tally[VerdictError] {
				problems = append(problems, fmt.Sprintf("%s: summary total/passed/failed/errored = %d/%d/%d/%d, scan tally = %d/%d/%d/%d",
					where, s.TotalControls, s.Passed, s.Failed, s.Errored,
					len(results), tally[VerdictPass], tally[VerdictFail], tally[VerdictError]))
			}
			if math.Abs(s.TotalExposure-exposure) > 0.01*float64(len(results)+1) {
				problems = append(problems, fmt.Sprintf("%s: summary exposure %.2f, scan non-pass carried %.2f", where, s.TotalExposure, exposure))
			}
		}
	}
	return problems, scanned
}

func sortedKeys(m map[string]Verdict) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestScanIntegration_ConformanceFixtures(t *testing.T) {
	root := conformancePolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	problems, scanned := fixtureScanMismatches(t, handlerTransport{h}, loadConformancePacks(t, root))
	for _, p := range problems {
		t.Error(p)
	}
	t.Logf("scanned %d conformance fixtures from %s", scanned, filepath.Join(root, "frameworks"))
}

// --- self-test: the integration walk must catch a wrong expectation.

// throwawayRoot builds a pack with two versions (same check ID, different
// expressions) and fixtures, one of which carries a deliberately wrong
// expectation.
func throwawayRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	controls := func(registeredExpr string) []frameworks.ControlSet {
		return []frameworks.ControlSet{{ID: "CS", Name: "Set", Controls: []frameworks.Control{
			{ID: "TA-1", Name: "Registered", Checks: []frameworks.Check{packCheck("agent-registered", registeredExpr)}},
			{ID: "TA-2", Name: "Non-root", Checks: []frameworks.Check{packCheck("object-non-root", "object.spec.securityContext.runAsNonRoot == true")}},
		}}}
	}
	writePack(t, root, "throwaway", "v1.0", frameworks.Framework{ID: "throwaway", Version: "v1.0.0",
		ControlSets: controls("has(agent.registry) && agent.registry.model_registered == true")})
	// v2.0 inverts the check: if results were not attributed by version, the
	// v1.0 fixtures would see these verdicts too.
	writePack(t, root, "throwaway", "v2.0", frameworks.Framework{ID: "throwaway", Version: "v2.0.0",
		ControlSets: controls("!(has(agent.registry) && agent.registry.model_registered == true)")})

	nonRoot := map[string]any{"spec": map[string]any{"securityContext": map[string]any{"runAsNonRoot": true}}}
	registered := map[string]any{"registry": map[string]any{"model_registered": true}}
	write := func(name string, f map[string]any) {
		dir := filepath.Join(root, "frameworks", "throwaway", "v1.0", "fixtures", "unit")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		f["name"] = name
		raw, _ := json.Marshal(f)
		if err := os.WriteFile(filepath.Join(dir, name+".json"), raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("compliant", map[string]any{"level": "unit",
		"input":  map[string]any{"object": nonRoot, "agent": registered},
		"expect": map[string]string{"agent-registered": "pass", "object-non-root": "pass"}})
	write("no-agent", map[string]any{"level": "unit",
		"input":  map[string]any{"object": nonRoot},
		"expect": map[string]string{"agent-registered": "fail"}})
	write("no-security-context", map[string]any{"level": "unit", "description": "spec without securityContext: the unguarded read errors by design",
		"input":  map[string]any{"object": map[string]any{"spec": map[string]any{}}, "agent": registered},
		"expect": map[string]string{"object-non-root": "error", "agent-registered": "pass"}})
	write("wrong-expectation", map[string]any{"level": "unit",
		"input":  map[string]any{"object": nonRoot, "agent": registered},
		"expect": map[string]string{"agent-registered": "fail"}})
	return root
}

func TestScanIntegration_DetectsWrongExpectation(t *testing.T) {
	root := throwawayRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	problems, scanned := fixtureScanMismatches(t, handlerTransport{h}, loadConformancePacks(t, root))
	if scanned != 4 {
		t.Fatalf("scanned %d fixtures, want 4", scanned)
	}
	want := `throwaway/v1.0/wrong-expectation: check "agent-registered": got pass, want fail (error="")`
	if len(problems) != 1 || problems[0] != want {
		t.Fatalf("problems:\n%s\nwant exactly:\n%s", strings.Join(problems, "\n"), want)
	}
}
