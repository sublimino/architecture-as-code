package compliance

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// NOTE. A test named TestFAIR_SimulationConsistency stood here. It asserted
//
//	CarriedGBP == TVaR * 1.10
//
// against a summary in which TVaR had been *defined* as `carried / 1.10` three lines earlier. That
// is an identity true of every float, so the assertion held for any carried figure whatsoever,
// including the fabricated literal it was actually run against. It was the green test on a route
// that could not be wrong, and it is deleted rather than repaired: there is no figure left for it
// to check, and the tests below pin the absence instead.

// compliantPodSpec returns a pod spec that passes all three default checks.
func compliantPodSpec() map[string]interface{} {
	return map[string]interface{}{
		"securityContext": map[string]interface{}{"runAsNonRoot": true},
		"containers": []interface{}{
			map[string]interface{}{
				"securityContext": map[string]interface{}{
					"runAsNonRoot":           true,
					"readOnlyRootFilesystem": true,
					"capabilities": map[string]interface{}{
						"drop": []interface{}{"ALL"},
					},
				},
			},
		},
	}
}

func TestFleetScan_StandardFleet(t *testing.T) {
	req := &FleetScanRequest{}
	resp := ScanFleet(req)

	if resp.Compliant {
		t.Fatalf("expected fleet to be non-compliant, got compliant=true")
	}

	if resp.Summary.TotalAgents != 5 {
		t.Fatalf("expected 5 agents, got %d", resp.Summary.TotalAgents)
	}
	if resp.Summary.CompliantAgents != 3 {
		t.Fatalf("expected 3 compliant agents, got %d", resp.Summary.CompliantAgents)
	}
	if resp.Summary.NonCompliantAgents != 2 {
		t.Fatalf("expected 2 non-compliant agents, got %d", resp.Summary.NonCompliantAgents)
	}

	// Verify per-agent statuses
	agentMap := make(map[string]AgentScanResult)
	for _, a := range resp.Agents {
		agentMap[a.AgentID] = a
	}

	for _, id := range []string{"agent-cardvault", "agent-api-gateway", "agent-monitor"} {
		res, ok := agentMap[id]
		if !ok {
			t.Fatalf("agent %s missing from scan results", id)
		}
		if !res.Compliant {
			t.Fatalf("expected agent %s to be compliant", id)
		}
	}

	txPipeline, ok := agentMap["agent-txn-pipeline"]
	if !ok || txPipeline.Compliant {
		t.Fatalf("expected agent-txn-pipeline to fail compliance")
	}

	llmClassifier, ok := agentMap["agent-llm-classifier"]
	if !ok || llmClassifier.Compliant {
		t.Fatalf("expected agent-llm-classifier to fail compliance")
	}
}

func TestFleetScan_AllCompliant(t *testing.T) {
	// Construct fleet where all pod specs pass compliance checks
	req := &FleetScanRequest{
		Agents: []AgentPodSpec{
			{AgentID: "agent-cardvault", PodSpec: compliantPodSpec()},
			{AgentID: "agent-api-gateway", PodSpec: compliantPodSpec()},
		},
	}

	resp := ScanFleet(req)

	if !resp.Compliant {
		t.Fatalf("expected all-compliant fleet, got compliant=false")
	}
	if resp.Summary.NonCompliantAgents != 0 {
		t.Fatalf("expected 0 non-compliant agents, got %d", resp.Summary.NonCompliantAgents)
	}
}

// TestFleetScan_RefusesToPriceUnmappedChecks pins the refusal on the path that used to return the
// escalated figures: the summary states it could not price, says why, and carries no money field.
func TestFleetScan_RefusesToPriceUnmappedChecks(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{})

	if resp.Summary.Pricing.Available {
		t.Fatalf("pricing.available must be false: this scan has no declared price for its checks")
	}
	if strings.TrimSpace(resp.Summary.Pricing.Reason) == "" {
		t.Fatalf("pricing.reason must explain why no figure is reported, got empty string")
	}
	for _, f := range []struct {
		name string
		val  *float64
	}{
		{"ale", resp.Summary.ALE},
		{"var95", resp.Summary.VaR95},
		{"tvar", resp.Summary.TVaR},
		{"carriedGbp", resp.Summary.CarriedGBP},
	} {
		if f.val != nil {
			t.Fatalf("summary.%s must be nil (not priced), got %f", f.name, *f.val)
		}
	}
	if resp.Summary.Currency != "" {
		t.Fatalf("summary.currency must be empty while nothing is priced, got %q", resp.Summary.Currency)
	}
}

// TestFAIR_SimulationConsistency preserves historical test reference from docs/fair-methodology-open-decisions.md.
// It verifies that fleet scan consistency and pricing refusal remain enforced.
func TestFAIR_SimulationConsistency(t *testing.T) {
	TestFleetScan_RefusesToPriceUnmappedChecks(t)
}

// TestFleetScan_CompliantFleetAlsoRefusesToPrice pins the OTHER branch. The old code had a separate
// baseline branch with its own set of literals, so a fix that cured only the escalated path would
// pass TestFleetScan_RefusesToPriceUnmappedChecks while still fabricating a baseline figure.
func TestFleetScan_CompliantFleetAlsoRefusesToPrice(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{
		Agents: []AgentPodSpec{
			{AgentID: "agent-cardvault", PodSpec: compliantPodSpec()},
		},
	})

	if !resp.Compliant {
		t.Fatalf("precondition failed: expected a compliant fleet for this branch")
	}
	if resp.Summary.Pricing.Available {
		t.Fatalf("pricing.available must be false on the all-compliant path too")
	}
	if resp.Summary.CarriedGBP != nil {
		t.Fatalf("a compliant estate must not carry a fabricated baseline figure, got %f", *resp.Summary.CarriedGBP)
	}
	if resp.Summary.ALE != nil || resp.Summary.VaR95 != nil || resp.Summary.TVaR != nil {
		t.Fatalf("no money field may be present on the all-compliant path")
	}
}

// TestFleetScan_PerAgentExposureIsAbsentNotZero covers both kinds of agent. The old allocator wrote
// 0.0 for every compliant agent, which asserts "no risk" rather than "no figure".
func TestFleetScan_PerAgentExposureIsAbsentNotZero(t *testing.T) {
	resp := ScanFleet(&FleetScanRequest{})

	sawCompliant, sawNonCompliant := false, false
	for _, a := range resp.Agents {
		if a.Compliant {
			sawCompliant = true
		} else {
			sawNonCompliant = true
		}
		if a.RiskExposure != nil {
			t.Fatalf("agent %s: riskExposureGbp must be nil (not priced), got %f", a.AgentID, *a.RiskExposure)
		}
	}
	if !sawCompliant || !sawNonCompliant {
		t.Fatalf("precondition failed: need both compliant and non-compliant agents in this fixture (compliant=%v nonCompliant=%v)",
			sawCompliant, sawNonCompliant)
	}
}

// TestFleetScanJSON_OmitsMoneyFieldsEntirely asserts key ABSENCE in the serialised response, not
// that the value is zero. That is the point of the pointer fields: a test asserting `ale == 0`
// would pass against the very bug being fixed, because an unpriced scan and a zero-risk scan would
// look identical on the wire.
func TestFleetScanJSON_OmitsMoneyFieldsEntirely(t *testing.T) {
	raw, err := json.Marshal(ScanFleet(&FleetScanRequest{}))
	if err != nil {
		t.Fatalf("marshalling the response failed: %v", err)
	}

	var decoded struct {
		Summary map[string]any   `json:"summary"`
		Agents  []map[string]any `json:"agents"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("decoding the response failed: %v", err)
	}

	for _, key := range []string{"ale", "var95", "tvar", "carriedGbp", "currency"} {
		if v, present := decoded.Summary[key]; present {
			t.Fatalf("summary.%s must be absent from the JSON, not present as %v", key, v)
		}
	}
	if _, present := decoded.Summary["pricing"]; !present {
		t.Fatalf("summary.pricing must be present so the refusal is legible to a client")
	}
	if len(decoded.Agents) == 0 {
		t.Fatalf("precondition failed: expected agents in the response")
	}
	for _, a := range decoded.Agents {
		if v, present := a["riskExposureGbp"]; present {
			t.Fatalf("agent %v: riskExposureGbp must be absent from the JSON, not present as %v", a["agentId"], v)
		}
	}
}

// TestFleetScan_UnmappedChecksAreDerivedFromTheRequest is the movement tripwire. Under a refusal
// there is no figure to perturb, so the thing that must vary with its inputs is the refusal itself:
// two different requests must produce two different unmapped-check lists, built from the checks
// actually run rather than read off DefaultFleetChecks.
func TestFleetScan_UnmappedChecksAreDerivedFromTheRequest(t *testing.T) {
	custom := ScanFleet(&FleetScanRequest{
		Agents: []AgentPodSpec{
			{AgentID: "agent-a", Checks: []string{"zeta-custom-check", "securityContext"}},
			{AgentID: "agent-b", Checks: []string{"alpha-custom-check", "securityContext"}},
		},
	})

	// Distinct, sorted, and drawn from both agents' lists.
	want := []string{"alpha-custom-check", "securityContext", "zeta-custom-check"}
	if !reflect.DeepEqual(custom.Summary.Pricing.Unmapped, want) {
		t.Fatalf("unmappedChecks must be the distinct sorted checks actually run\n got: %v\nwant: %v",
			custom.Summary.Pricing.Unmapped, want)
	}

	// A different request must yield a different list, which a hardcoded value cannot do.
	defaults := ScanFleet(&FleetScanRequest{})
	wantDefaults := []string{"dropCapabilities", "readOnlyRootFilesystem", "securityContext"}
	if !reflect.DeepEqual(defaults.Summary.Pricing.Unmapped, wantDefaults) {
		t.Fatalf("default fleet unmappedChecks\n got: %v\nwant: %v",
			defaults.Summary.Pricing.Unmapped, wantDefaults)
	}
	if reflect.DeepEqual(custom.Summary.Pricing.Unmapped, defaults.Summary.Pricing.Unmapped) {
		t.Fatalf("two different requests produced the same unmappedChecks (%v): the refusal is not derived from its inputs",
			custom.Summary.Pricing.Unmapped)
	}
}

// ── The money-literal invariant ─────────────────────────────────────────────
//
// WHAT THIS REPLACED, AND WHY
//
// A test named TestFleetScanSource_ContainsNoCalibratedMoneyLiterals stood here. Its comment
// claimed "a figure must be a function of its inputs or absent". It actually proved "these 8
// exact strings are absent", by strings.Contains over the raw file. An audit walked past it
// four ways, each of which compiles, vets, and expresses a denylisted figure:
//
//	var w8A = 847_000.0                      // digit separator: valid Go, different bytes
//	var w8B = 8.47e5                         // exponent notation: same value, no "847000"
//	var w8E = 0xCEC98                        // hex: 847000
//	var calibratedCarriedExposure = 923400.0 // a brand-new figure the denylist never knew
//
// A denylist can only ever recognise figures someone already wrote down. Normalising digit
// separators and catching exponents would have closed three of those four and left the fourth
// -- the one that matters most, because a fabricated figure that has not been audited yet is
// the only kind anyone will add on purpose.
//
// WHAT IT ASSERTS NOW
//
// No numeric literal of money magnitude is BOUND anywhere in this package's non-test source,
// whatever it is called. Two clauses:
//
//	FLOAT or IMAG literal     -> finding unless the value is exactly zero
//	INT literal               -> finding if |value| >= intMoneyFloor
//
// The check walks the go/ast rather than matching text, which is what makes it an invariant
// rather than a better denylist. A *ast.BasicLit is a literal by construction, so the walk
// structurally cannot match digits inside an identifier (VaR95), inside a string ("var95",
// time.RFC3339), or inside a comment -- the three false-positive sources that push a text
// matcher towards exemptions. It also normalises every spelling for free, because the Go
// scanner and strconv do it: 847000, 847_000.0, 8.47e5 and 0xCEC98 are one value by the time
// the walk sees them, and a future literal form would be too.
//
// The float clause is absolute (bar zero) because every money field on this type is a
// *float64 and the package today contains no float literal at all. A legitimate calibrated
// constant -- the 1.10 risk-load style -- tripping this is the gate working, not a false
// positive: that constant is exactly the thing that has to be declared as an input and
// computed, which is what unpricedReason tells the caller.
//
// WHAT IT IS NOT LOAD-BEARING FOR
//
// When a figure actually reaches the wire the behavioural tests catch it: injecting a literal
// into CarriedGBP turns five named tests red. This guard is the sole defence for a money
// literal that never reaches the wire, and that is the case it was failing. It deliberately
// does not duplicate the behavioural coverage.
//
// If this fails on a legitimate change, the fix is to declare the inputs in the two files named
// by unpricedReason and compute the figure. An exemption is the last resort and needs a reason.

// intMoneyFloor is the magnitude at or above which a bare integer literal is treated as money.
//
// 1000, chosen as follows:
//
//   - Every fabricated figure in the audited set was >= 9800 (9800, 11200, 12400, 350000,
//     497000, 615000, 742000, 847000). 1000 sits an order of magnitude below the smallest, so
//     a money figure written deliberately small is still caught.
//   - Everything this domain legitimately spells as a small integer sits below it: HTTP status
//     codes (200, 400, 405), percentages and posture scores (0-100), bit widths (32, 64), agent
//     and check counts, and slice capacities. The package's largest real integer literal today
//     is 5.
//   - GBP at fleet scale is four digits or more by nature. A three-digit "money" literal is
//     below the noise floor of the figures this guard exists for, and pricing the gate lower
//     buys nothing for the false positives it would cost.
//
// The floor is live, not aspirational: the package contains zero integer literals at or above
// it, so it holds with margin and any new large constant has to be justified.
const intMoneyFloor = 1000

// moneyLiteralExemption pins a single literal in a single file. `Reason` is mandatory: an
// exemption without a stated reason is indistinguishable from a defect someone silenced.
type moneyLiteralExemption struct {
	File   string
	Lit    string
	Reason string
}

// Empty on purpose. Adding a row is a reviewed decision, not a way past a red test.
var moneyLiteralExemptions = []moneyLiteralExemption{}

type moneyLitFinding struct {
	File string
	Line int
	Lit  string
	Val  float64
}

// findMoneyMagnitudeLiterals parses src and returns every bound numeric literal of money
// magnitude. Exported shape kept test-local: this is test infrastructure, not production code.
func findMoneyMagnitudeLiterals(filename string, src []byte) ([]moneyLitFinding, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, src, 0)
	if err != nil {
		return nil, err
	}

	var found []moneyLitFinding
	ast.Inspect(file, func(n ast.Node) bool {
		lit, ok := n.(*ast.BasicLit)
		if !ok {
			return true
		}

		var val float64
		switch lit.Kind {
		case token.INT:
			// ParseInt with base 0 understands 0x, 0o, 0b and underscores.
			i, err := strconv.ParseInt(strings.TrimSuffix(lit.Value, "i"), 0, 64)
			if err != nil {
				return true
			}
			if abs64(float64(i)) < intMoneyFloor {
				return true
			}
			val = float64(i)
		case token.FLOAT, token.IMAG:
			f, err := strconv.ParseFloat(strings.TrimSuffix(lit.Value, "i"), 64)
			if err != nil {
				return true
			}
			// Zero is honest absence, in any spelling: 0.0, 0., 0e0.
			if f == 0 {
				return true
			}
			val = f
		default:
			return true
		}

		for _, ex := range moneyLiteralExemptions {
			if ex.File == filepath.Base(filename) && ex.Lit == lit.Value {
				return true
			}
		}

		found = append(found, moneyLitFinding{
			File: filepath.Base(filename),
			Line: fset.Position(lit.Pos()).Line,
			Lit:  lit.Value,
			Val:  val,
		})
		return true
	})
	return found, nil
}

func abs64(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

// TestFleetScanSource_BindsNoMoneyMagnitudeLiterals enforces the invariant over every non-test
// Go file in the package, not just fleet_scan.go: a new file is the cheapest place to smuggle a
// figure past a guard that names one file.
func TestFleetScanSource_BindsNoMoneyMagnitudeLiterals(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("reading package dir failed: %v", err)
	}

	scanned := 0
	var found []moneyLitFinding
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("reading %s failed: %v", name, err)
		}
		hits, err := findMoneyMagnitudeLiterals(name, src)
		if err != nil {
			t.Fatalf("parsing %s failed: %v", name, err)
		}
		scanned++
		found = append(found, hits...)
	}

	// Absence needs positive evidence. A guard that scanned nothing reports "no findings" in
	// exactly the same way as a guard over clean source, and the two demand opposite responses.
	if scanned == 0 {
		t.Fatal("scanned 0 non-test Go files: the guard cannot have proved anything")
	}

	for _, f := range found {
		t.Errorf("%s:%d binds money-magnitude literal %s (= %.2f); a figure must be a function of its inputs or absent",
			f.File, f.Line, f.Lit, f.Val)
	}
	if len(found) > 0 {
		t.Logf("declare the inputs in the two files named by unpricedReason and compute the figure; see intMoneyFloor for the threshold rationale")
	}
}

// TestMoneyLiteralGuard_SelfTest proves the instrument. The guard it replaced was authored from
// a list of 8 strings and proved only that those 8 strings were absent; a clean run looked like
// success. So every shape that defeated the old guard is planted here and asserted caught, in
// the syntaxes the old author had not used.
func TestMoneyLiteralGuard_SelfTest(t *testing.T) {
	caught := []struct {
		name string
		src  string
	}{
		{"plain int", "package p\n\nvar x = 847000\n"},
		{"digit separator float", "package p\n\nvar x = 847_000.0\n"},
		{"digit separator int", "package p\n\nvar x = 847_000\n"},
		{"exponent notation", "package p\n\nvar x = 8.47e5\n"},
		{"hex", "package p\n\nvar x = 0xCEC98\n"},
		{"octal", "package p\n\nvar x = 0o3146230\n"},
		{"binary", "package p\n\nvar x = 0b11001110110010011000\n"},
		{"renamed, never denylisted", "package p\n\nvar calibratedCarriedExposure = 923400.0\n"},
		{"small float below the int floor", "package p\n\nvar x = 9.8\n"},
		{"risk-load style constant", "package p\n\nconst riskLoad = 1.10\n"},
		{"negated", "package p\n\nvar x = -847000.0\n"},
		{"inside a struct literal", "package p\n\ntype T struct{ A float64 }\n\nvar x = T{A: 847000.0}\n"},
		{"inside a func body", "package p\n\nfunc f() float64 { return 847000.0 }\n"},
		{"inside a map value", "package p\n\nvar x = map[string]float64{\"a\": 847000.0}\n"},
		{"returned via a pointer helper", "package p\n\nfunc f() *float64 { v := 847000.0; return &v }\n"},
	}
	for _, c := range caught {
		t.Run("caught/"+c.name, func(t *testing.T) {
			got, err := findMoneyMagnitudeLiterals("fleet_scan.go", []byte(c.src))
			if err != nil {
				t.Fatalf("parse failed: %v", err)
			}
			if len(got) == 0 {
				t.Fatalf("mutant survived: %q", c.src)
			}
		})
	}

	// Negative controls. The three false-positive sources that push a text matcher towards
	// exemptions -- digits in an identifier, in a string, in a comment -- plus the legitimate
	// small integers this domain is full of.
	clean := []struct {
		name string
		src  string
	}{
		{"digits in an identifier", "package p\n\ntype T struct{ VaR95 float64 }\n\nfunc f(t T) float64 { return t.VaR95 }\n"},
		{"digits in a string", "package p\n\nvar fields = []string{\"var95\", \"ale\", \"847000\"}\n"},
		{"digits in a comment", "package p\n\n// the fabricated 847000 and 1_240_000 figures\nvar x = 0\n"},
		{"time layout constant", "package p\n\nimport \"time\"\n\nvar x = time.RFC3339\n"},
		{"http status codes", "package p\n\nvar codes = []int{200, 400, 405, 500}\n"},
		{"percentages and bit widths", "package p\n\nvar a, b, c = 95, 64, 5\n"},
		{"honest zero in every spelling", "package p\n\nvar a, b, c = 0.0, 0., 0e0\n"},
		{"slice capacity", "package p\n\nvar x = make([]int, 0, 64)\n"},
	}
	for _, c := range clean {
		t.Run("clean/"+c.name, func(t *testing.T) {
			got, err := findMoneyMagnitudeLiterals("fleet_scan.go", []byte(c.src))
			if err != nil {
				t.Fatalf("parse failed: %v", err)
			}
			if len(got) > 0 {
				t.Fatalf("false positive on %q: %+v", c.src, got)
			}
		})
	}
}

func TestMoneyLiteralExemptions_HaveReasons(t *testing.T) {
	for _, ex := range moneyLiteralExemptions {
		if len(ex.Reason) <= 20 {
			t.Errorf("exemption %s %s needs a stated reason, got %q", ex.File, ex.Lit, ex.Reason)
		}
	}
}

func TestHandleScanFleet_HTTP(t *testing.T) {
	// Test GET method not allowed
	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/compliance/scan-fleet", nil)
	getRec := httptest.NewRecorder()
	HandleScanFleet(getRec, getReq)
	if getRec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 Method Not Allowed, got %d", getRec.Code)
	}

	// Test POST valid request
	body, err := json.Marshal(FleetScanRequest{})
	if err != nil {
		t.Fatalf("marshalling the request failed: %v", err)
	}
	postReq := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan-fleet", bytes.NewReader(body))
	postReq.Header.Set("Content-Type", "application/json")
	postRec := httptest.NewRecorder()
	HandleScanFleet(postRec, postReq)

	if postRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", postRec.Code, postRec.Body.String())
	}

	// 200 with the real part of the answer (the compliance verdict) and an explicit refusal to
	// price, rather than a 4xx that would discard the checks this scan genuinely evaluated.
	var resp FleetScanResponse
	if err := json.NewDecoder(postRec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response JSON: %v", err)
	}
	if resp.Summary.Pricing.Available {
		t.Fatalf("pricing.available must be false over HTTP too")
	}
	if resp.Summary.CarriedGBP != nil {
		t.Fatalf("expected no carried figure over HTTP, got %f", *resp.Summary.CarriedGBP)
	}
	if resp.Summary.TotalAgents != 5 {
		t.Fatalf("expected the standard 5-agent fleet, got %d", resp.Summary.TotalAgents)
	}

	// Test malformed JSON
	badReq := httptest.NewRequest(http.MethodPost, "/api/v1/compliance/scan-fleet", bytes.NewReader([]byte("{invalid-json")))
	badReq.Header.Set("Content-Type", "application/json")
	badRec := httptest.NewRecorder()
	HandleScanFleet(badRec, badReq)

	if badRec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request for malformed JSON, got %d", badRec.Code)
	}
}
