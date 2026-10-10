package main

// Handler-level tests for the scan contract in policy/frameworks/CONFORMANCE.md:
// every check is evaluated with celBindings(object, agent, request) and each
// result reports a three-valued status. Results are decoded as generic JSON so
// the wire names themselves are asserted, not just the Go fields.

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

const contractPackID = "contract-pack"
const contractPackVersion = "v9.9.9"

// contractChecks is one control per check so controlId is attributable.
var contractChecks = map[string]string{
	"agent-registered": "has(agent.registry) && agent.registry.model_registered == true",
	"agent-strict":     "agent.registry.model_registered == true",
	"agent-non-bool":   "agent.registry",
	"object-name":      `object.metadata.name == "from-object"`,
	"manifest-name":    `manifest.metadata.name == "from-object"`,
	"request-peer":     `has(request.peer) && request.peer == "spiffe://cluster.local/ns/a/sa/b"`,
}

// writePack writes a framework.json pack under root/frameworks/<id>/<dir>/.
func writePack(t *testing.T, root, id, dir string, fw frameworks.Framework) {
	t.Helper()
	path := filepath.Join(root, "frameworks", id, dir)
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(fw)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "framework.json"), raw, 0o644); err != nil {
		t.Fatal(err)
	}
}

func packCheck(id, expr string) frameworks.Check {
	return frameworks.Check{
		ID: id, Name: "Name of " + id, CELExpression: expr,
		RiskTriple: fair.RiskTriple{Min: 1000, Mode: 5000, Max: 20000},
		FreqTriple: fair.RiskTriple{Min: 0.5, Mode: 1, Max: 2},
	}
}

func contractHandler(t *testing.T) *complianceHandler {
	t.Helper()
	root := t.TempDir()
	var controls []frameworks.Control
	for _, id := range []string{"agent-registered", "agent-strict", "agent-non-bool", "object-name", "manifest-name", "request-peer"} {
		controls = append(controls, frameworks.Control{ID: "CTRL-" + id, Name: "Control " + id, Checks: []frameworks.Check{packCheck(id, contractChecks[id])}})
	}
	writePack(t, root, contractPackID, "v9.9", frameworks.Framework{
		ID: contractPackID, Name: "Contract", Version: contractPackVersion,
		ControlSets: []frameworks.ControlSet{{ID: "CS", Name: "Set", Controls: controls}},
	})
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// postScan sends body to handleScan and returns results keyed by check ID.
func postScan(t *testing.T, h *complianceHandler, body map[string]any) map[string]map[string]any {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	h.handleScan(w, httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan", bytes.NewReader(raw)))
	if w.Code != http.StatusOK {
		t.Fatalf("scan: got %d: %s", w.Code, w.Body.String())
	}
	var results []map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &results); err != nil {
		t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, r := range results {
		out[r["check"].(string)] = r
	}
	return out
}

func getSummary(t *testing.T, h *complianceHandler) map[string]any {
	t.Helper()
	w := httptest.NewRecorder()
	h.handleSummary(w, httptest.NewRequest(http.MethodGet, "/api/v1/compliance/summary", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("summary: got %d: %s", w.Code, w.Body.String())
	}
	var s map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func contractScan(extra map[string]any) map[string]any {
	body := map[string]any{"namespace": "ns", "frameworks": []string{contractPackID}}
	for k, v := range extra {
		body[k] = v
	}
	return body
}

var compliantAgent = map[string]any{"registry": map[string]any{"model_registered": true}}

func assertStatus(t *testing.T, results map[string]map[string]any, check, want string) {
	t.Helper()
	r, ok := results[check]
	if !ok {
		t.Fatalf("no result for check %q", check)
	}
	if got := r["status"]; got != want {
		t.Errorf("check %q: status %v, want %s (error=%v)", check, got, want, r["error"])
	}
	if got, wantPassed := r["passed"], want == "pass"; got != wantPassed {
		t.Errorf("check %q: passed %v, want %v", check, got, wantPassed)
	}
}

func TestScanContract_AgentCheckPassesWithCompliantAgent(t *testing.T) {
	res := postScan(t, contractHandler(t), contractScan(map[string]any{"agent": compliantAgent}))
	assertStatus(t, res, "agent-registered", "pass")
	assertStatus(t, res, "agent-strict", "pass")
	r := res["agent-registered"]
	if _, present := r["error"]; present {
		t.Errorf("passing result carries an error field: %v", r["error"])
	}
	if r["controlId"] != "CTRL-agent-registered" {
		t.Errorf("controlId = %v, want CTRL-agent-registered", r["controlId"])
	}
	if r["frameworkVersion"] != contractPackVersion {
		t.Errorf("frameworkVersion = %v, want %s", r["frameworkVersion"], contractPackVersion)
	}
	if r["checkName"] != "Name of agent-registered" {
		t.Errorf("checkName = %v, want %q", r["checkName"], "Name of agent-registered")
	}
	if r["control"] != "Control agent-registered" || r["framework"] != contractPackID {
		t.Errorf("existing fields changed: control=%v framework=%v", r["control"], r["framework"])
	}
}

func TestScanContract_AgentCheckFailsWithNonCompliantAgent(t *testing.T) {
	agent := map[string]any{"registry": map[string]any{"model_registered": false}}
	res := postScan(t, contractHandler(t), contractScan(map[string]any{"agent": agent}))
	assertStatus(t, res, "agent-registered", "fail")
	assertStatus(t, res, "agent-strict", "fail")
	if _, present := res["agent-registered"]["error"]; present {
		t.Errorf("failing result carries an error field: %v", res["agent-registered"]["error"])
	}
}

// An expression that cannot evaluate is error, carries the CEL error text, and
// is never reported as fail.
func TestScanContract_UnevaluableCheckIsErrorNotFail(t *testing.T) {
	res := postScan(t, contractHandler(t), contractScan(map[string]any{"agent": map[string]any{"name": "x"}}))
	assertStatus(t, res, "agent-strict", "error")
	if msg, _ := res["agent-strict"]["error"].(string); !strings.Contains(msg, "no such key: registry") {
		t.Errorf("agent-strict error = %q, want the CEL missing-key text", msg)
	}

	res = postScan(t, contractHandler(t), contractScan(map[string]any{"agent": compliantAgent}))
	assertStatus(t, res, "agent-non-bool", "error")
	if msg, _ := res["agent-non-bool"]["error"].(string); !strings.Contains(msg, "non-boolean") {
		t.Errorf("agent-non-bool error = %q, want the non-boolean text", msg)
	}
}

// No agent in the request: agent is bound to {} so a has()-guarded check fails
// rather than erroring on an undeclared variable.
func TestScanContract_AbsentAgentGuardedCheckIsFail(t *testing.T) {
	res := postScan(t, contractHandler(t), contractScan(nil))
	assertStatus(t, res, "agent-registered", "fail")
	assertStatus(t, res, "request-peer", "fail")
	assertStatus(t, res, "agent-strict", "error")
}

func TestScanContract_RequestIsBound(t *testing.T) {
	req := map[string]any{"peer": "spiffe://cluster.local/ns/a/sa/b"}
	res := postScan(t, contractHandler(t), contractScan(map[string]any{"request": req}))
	assertStatus(t, res, "request-peer", "pass")
}

func TestScanContract_ObjectWinsOverManifest(t *testing.T) {
	obj := map[string]any{"metadata": map[string]any{"name": "from-object"}}
	man := map[string]any{"metadata": map[string]any{"name": "from-manifest"}}

	both := postScan(t, contractHandler(t), contractScan(map[string]any{"object": obj, "manifest": man}))
	assertStatus(t, both, "object-name", "pass")
	assertStatus(t, both, "manifest-name", "pass") // manifest aliases the winning object

	onlyManifest := postScan(t, contractHandler(t), contractScan(map[string]any{"manifest": obj}))
	assertStatus(t, onlyManifest, "object-name", "pass")

	onlyObject := postScan(t, contractHandler(t), contractScan(map[string]any{"object": obj}))
	assertStatus(t, onlyObject, "manifest-name", "pass")

	// An explicit empty object is absent: it must not mask a non-empty manifest.
	emptyObject := postScan(t, contractHandler(t), contractScan(map[string]any{"object": map[string]any{}, "manifest": obj}))
	assertStatus(t, emptyObject, "object-name", "pass")
	assertStatus(t, emptyObject, "manifest-name", "pass")
}

// Summary: failed counts fail only, errored counts error, exposure sums every
// non-pass result.
func TestScanContract_SummaryCountsErroredSeparately(t *testing.T) {
	h := contractHandler(t)
	res := postScan(t, h, contractScan(map[string]any{"agent": map[string]any{"name": "x"}}))
	// agent-registered fail, agent-strict error, agent-non-bool error,
	// object-name error, manifest-name error, request-peer fail.
	want := map[string]float64{"pass": 0, "fail": 2, "error": 4}
	var exposure float64
	got := map[string]float64{}
	for _, r := range res {
		st, _ := r["status"].(string)
		got[st]++
		if r["status"] != "pass" {
			exposure += r["carriedGbp"].(float64)
		}
	}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("scan tally %s = %v, want %v (all: %v)", k, got[k], v, got)
		}
	}
	s := getSummary(t, h)
	if s["totalControls"] != 6.0 || s["passed"] != 0.0 || s["failed"] != 2.0 || s["errored"] != 4.0 {
		t.Errorf("summary = total %v passed %v failed %v errored %v, want 6/0/2/4",
			s["totalControls"], s["passed"], s["failed"], s["errored"])
	}
	if e := s["totalExposureGbp"].(float64); math.Abs(e-exposure) > 0.005 || exposure == 0 {
		t.Errorf("totalExposureGbp = %v, want %v (sum of non-pass carried)", e, exposure)
	}
}

// Audit M4: a placeholder check (or any check of a placeholder framework) is
// not evaluated. It reports status not_evaluated, passed false, no error; the
// summary counts it in totalControls and notEvaluated only, never in failed,
// errored or exposure.
func TestScanContract_PlaceholderIsNotEvaluated(t *testing.T) {
	root := t.TempDir()
	placeholder := packCheck("ph-check", "false")
	placeholder.Status = "placeholder"
	writePack(t, root, "mixed", "v1.0", frameworks.Framework{ID: "mixed", Version: "v1.0.0",
		ControlSets: []frameworks.ControlSet{{ID: "CS", Name: "Set", Controls: []frameworks.Control{
			{ID: "C1", Name: "C1", Checks: []frameworks.Check{placeholder}},
			{ID: "C2", Name: "C2", Checks: []frameworks.Check{packCheck("real-fail", "false")}},
			{ID: "C3", Name: "C3", Checks: []frameworks.Check{packCheck("real-pass", "true")}},
		}}}})
	writePack(t, root, "phfw", "v1.0", frameworks.Framework{ID: "phfw", Version: "v1.0.0", Status: "placeholder",
		ControlSets: []frameworks.ControlSet{{ID: "CS", Name: "Set", Controls: []frameworks.Control{
			{ID: "C1", Name: "C1", Checks: []frameworks.Check{packCheck("fw-ph-check", "agent.registry")}},
		}}}})
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	res := postScan(t, h, map[string]any{"frameworks": []string{"mixed", "phfw"}})
	for _, id := range []string{"ph-check", "fw-ph-check"} {
		assertStatus(t, res, id, "not_evaluated")
		if _, present := res[id]["error"]; present {
			t.Errorf("%s: not_evaluated result carries an error: %v", id, res[id]["error"])
		}
	}
	assertStatus(t, res, "real-fail", "fail")
	assertStatus(t, res, "real-pass", "pass")

	s := getSummary(t, h)
	if s["totalControls"] != 4.0 || s["passed"] != 1.0 || s["failed"] != 1.0 || s["errored"] != 0.0 || s["notEvaluated"] != 2.0 {
		t.Errorf("summary = total %v passed %v failed %v errored %v notEvaluated %v, want 4/1/1/0/2",
			s["totalControls"], s["passed"], s["failed"], s["errored"], s["notEvaluated"])
	}
	if e, want := s["totalExposureGbp"].(float64), res["real-fail"]["carriedGbp"].(float64); math.Abs(e-want) > 0.005 {
		t.Errorf("totalExposureGbp = %v, want %v (real-fail only)", e, want)
	}
}

// The headline bug: the shipped FINOS AIGF pack reads agent.*, which was never
// bound, so every check reported passed:false. A compliant agent must pass.
func TestScanContract_FinosAIGFAgentChecksEvaluate(t *testing.T) {
	h := testComplianceHandler(t)
	agent := map[string]any{
		"registry":   map[string]any{"model_registered": true},
		"guardrails": map[string]any{"prompt_injection_filter": true},
		"governance": map[string]any{"decision_explainability": true},
	}
	res := postScan(t, h, map[string]any{"frameworks": []string{"finos-aigf"}, "agent": agent})
	for _, id := range []string{"registered-model-registry-entry", "prompt-injection-guardrail-active", "decision-explainability-metadata"} {
		assertStatus(t, res, id, "pass")
	}
}
