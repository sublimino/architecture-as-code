package main

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/money"
)

// Wire format types

type ComplianceScanRequest struct {
	Namespace     string         `json:"namespace"`
	PolicyVersion string         `json:"policyVersion"`
	Frameworks    []string       `json:"frameworks"`
	Manifest      map[string]any `json:"manifest"`
	// Object is the Pod-shaped workload; it wins over Manifest when both are
	// sent. Agent and Request are the other two CEL inputs. The binding
	// contract is policy/frameworks/CONFORMANCE.md.
	Object  map[string]any `json:"object"`
	Agent   map[string]any `json:"agent"`
	Request map[string]any `json:"request"`

	// ── The institution's declared risk posture (migration 062) ─────────────
	//
	// Both are OPTIONAL and both omitted is the overwhelmingly common case. The
	// caller that fills them is the fe gateway, which holds the tenant's
	// tenant_settings row; the engine has no database and never looks one up.
	//
	// ReportingCurrency is empty when undeclared. RiskLoad is a POINTER on
	// purpose: 0 is a coherent declared posture ("carry the tail with no load on
	// top") and a plain float64 could not tell it apart from absent, which would
	// silently price a declared zero as the 0.10 default.
	ReportingCurrency money.Currency `json:"reportingCurrency,omitempty"`
	RiskLoad          *float64       `json:"riskLoad,omitempty"`
}

// workload returns the object every check reads as `object` (and `manifest`).
// An empty object is treated as absent so `"object": {}` cannot mask a
// non-empty manifest.
func (req ComplianceScanRequest) workload() map[string]any {
	if len(req.Object) > 0 {
		return req.Object
	}
	return req.Manifest
}

// defaultReportingCurrency denominates every figure this service reports when
// the institution has NOT declared a reporting currency of its own.
//
// It was `const reportingCurrency = "GBP"`, applied to every tenant
// unconditionally. Renaming it is the honest description of what it now is: a
// fallback, not a fact about the product. A tenant that declares nothing is
// still reported in GBP, so no existing figure moves -- which is asserted, not
// assumed, by TestAnUndeclaredTenantIsPricedExactlyAsBefore.
const defaultReportingCurrency money.Currency = "GBP"

// effectiveRiskProfile is the institution's half of the pricing split as it
// applies to ONE scan: what a figure is denominated in, and the load carried on
// top of tail risk.
//
// Both fields are always populated -- resolution happens once, at the top of
// handleScan, so no code further down has to remember a fallback. The zero
// value is deliberately NOT usable: resolve it through riskProfileFor.
type effectiveRiskProfile struct {
	Currency money.Currency
	RiskLoad float64
	// Declared records whether the institution stated any of this. It exists so
	// the engine can say which figures reflect a declared posture and which
	// reflect its own defaults; a figure priced by a default must never be
	// presented as one the institution chose.
	Declared bool
}

// riskProfileFor resolves the profile a scan request should be priced with.
//
// An absent or blank field means UNDECLARED and falls back to the engine's own
// constant. That is what guarantees no existing figure moves: a request that
// says nothing is priced byte-for-byte as it was before these fields existed.
//
// Invalid is NOT the same as absent and is not silently defaulted -- an
// unparseable currency or a non-finite load is a caller error, because pricing
// a figure with a value the caller did not mean is the failure this whole
// change exists to prevent.
func riskProfileFor(req ComplianceScanRequest) (effectiveRiskProfile, error) {
	p := effectiveRiskProfile{Currency: defaultReportingCurrency, RiskLoad: fair.DefaultRiskLoad}

	if declared := money.Currency(strings.TrimSpace(string(req.ReportingCurrency))); declared != "" {
		if err := declared.Validate(); err != nil {
			return effectiveRiskProfile{}, fmt.Errorf("reportingCurrency: %w", err)
		}
		p.Currency = declared
		p.Declared = true
	}

	if req.RiskLoad != nil {
		load := *req.RiskLoad
		if math.IsNaN(load) || math.IsInf(load, 0) {
			return effectiveRiskProfile{}, fmt.Errorf("riskLoad must be a finite number, got %g", load)
		}
		if load < 0 {
			return effectiveRiskProfile{}, fmt.Errorf(
				"riskLoad must be >= 0, got %g; a negative load would make carried risk "+
					"less than tail risk, which is not a coherent risk posture", load)
		}
		p.RiskLoad = load
		p.Declared = true
	}

	return p, nil
}

type ComplianceScanResult struct {
	Framework  string `json:"framework"`
	ControlSet string `json:"controlSet"`
	Control    string `json:"control"`
	Check      string `json:"check"`
	// Passed is true iff Status is pass. Kept for clients that predate Status.
	Passed            bool    `json:"passed"`
	PolicyVersion     string  `json:"policyVersion"`
	ALE               float64 `json:"ale"`
	VaR95             float64 `json:"var95"`
	TVaR              float64 `json:"tvar"`
	CarriedGBP        float64 `json:"carriedGbp"`
	ScanTimestamp     string  `json:"scanTimestamp"`
	CalibrationSource string  `json:"calibrationSource"`

	// Currency denominates ale, var95, tvar and carriedGbp above.
	Currency money.Currency `json:"currency"`
	// Carried is CarriedGBP with its denomination attached. Same number, self-describing.
	Carried money.Money `json:"carried"`

	// Status is the verdict: pass, fail, error or not_evaluated. An expression
	// that cannot evaluate is error, never fail; a placeholder check is
	// not_evaluated and is never evaluated.
	Status Verdict `json:"status"`
	// Error is the CEL error text when Status is error.
	Error            string `json:"error,omitempty"`
	ControlID        string `json:"controlId"`
	FrameworkVersion string `json:"frameworkVersion"`
	CheckName        string `json:"checkName"`
}

type ComplianceSummary struct {
	TotalControls int `json:"totalControls"`
	Passed        int `json:"passed"`
	Failed        int `json:"failed"`
	Errored       int `json:"errored"`
	// NotEvaluated counts placeholder checks; they are in TotalControls only.
	NotEvaluated  int     `json:"notEvaluated"`
	TotalExposure float64 `json:"totalExposureGbp"`
	ScanTimestamp string  `json:"scanTimestamp,omitempty"`

	// Currency denominates totalExposureGbp. See the note on ComplianceScanResult.
	Currency money.Currency `json:"currency"`
	// Exposure is totalExposureGbp with its denomination attached.
	Exposure money.Money `json:"exposure"`
}

// complianceHandler holds framework data and scan state.
type complianceHandler struct {
	policyRoot  string
	celEngine   *CELEngine
	mu          sync.RWMutex
	lastResults []ComplianceScanResult
}

func newComplianceHandler(policyRoot string, optEngine ...*CELEngine) (*complianceHandler, error) {
	// Verify the frameworks directory exists.
	if _, err := frameworks.ListFrameworks(policyRoot); err != nil {
		return nil, err
	}
	var celEngine *CELEngine
	if len(optEngine) > 0 && optEngine[0] != nil {
		celEngine = optEngine[0]
	} else {
		var err error
		celEngine, err = NewCELEngine()
		if err != nil {
			return nil, err
		}
	}
	return &complianceHandler{
		policyRoot: policyRoot,
		celEngine:  celEngine,
	}, nil
}

// handleScan evaluates CEL checks from requested frameworks against a manifest.
func (ch *complianceHandler) handleScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req ComplianceScanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid request body: " + err.Error()})
		return
	}

	// Which institution this scan is priced for. extractTenant has existed since
	// the handler package was written and nothing on this path ever called it,
	// so until now a scan carried no notion of whose money it was reporting.
	//
	// The tenant id is NOT a lookup key here -- the engine has no database. It
	// is used to refuse an incoherent request: a declared risk posture with no
	// tenant to attribute it to is a caller bug, and pricing it anyway would
	// produce a figure attributed to nobody.
	tenantID := extractTenant(r)

	profile, err := riskProfileFor(req)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid risk profile: " + err.Error()})
		return
	}
	if profile.Declared && tenantID == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "a declared risk profile requires a tenant: send X-Tenant-ID " +
				"(or ?tenant=), because a priced figure has to belong to someone",
		})
		return
	}

	if len(req.Frameworks) == 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "at least one framework is required"})
		return
	}

	available, err := frameworks.ListFrameworks(ch.policyRoot)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": "failed to list frameworks: " + err.Error()})
		return
	}

	var unknown []string
	for _, fwID := range req.Frameworks {
		if _, ok := available[fwID]; !ok {
			unknown = append(unknown, fwID)
		}
	}
	if len(unknown) == len(req.Frameworks) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "none of the requested frameworks exist: " + strings.Join(unknown, ", "),
		})
		return
	}

	// Select every requested framework's pack before evaluating anything: a
	// framework that fails to load, or yields no checks, fails the whole scan
	// rather than being silently omitted from a 200.
	type selected struct {
		fw     *frameworks.Framework
		checks []scanCheck
	}
	var (
		packs               []selected
		loadFailed, noCheck []string
		loadErrs            []string
	)
	for _, fwID := range req.Frameworks {
		versions, ok := available[fwID]
		if !ok {
			// Unknown IDs beside known ones are skipped (all-unknown is a 400
			// above); TestScanMixedKnownUnknown_Succeeds pins this.
			slog.Warn("framework not found, skipping", "framework", fwID)
			continue
		}
		fw, err := selectPack(ch.policyRoot, fwID, versions, req.PolicyVersion)
		if err != nil {
			slog.Error("loading framework", "framework", fwID, "error", err)
			loadFailed = append(loadFailed, fwID)
			loadErrs = append(loadErrs, err.Error())
			continue
		}
		checks := checksWithControlIDs(fw, req.PolicyVersion)
		if len(checks) == 0 {
			noCheck = append(noCheck, fwID)
			continue
		}
		packs = append(packs, selected{fw: fw, checks: checks})
	}
	if len(loadFailed) > 0 {
		writeFrameworkError(w, http.StatusInternalServerError, "framework_load_failed", loadFailed, req.PolicyVersion, strings.Join(loadErrs, "; "))
		return
	}
	if len(noCheck) > 0 {
		writeFrameworkError(w, http.StatusBadRequest, "no_checks_for_framework", noCheck, req.PolicyVersion, "")
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	var results []ComplianceScanResult

	// An object the engine cannot judge must not yield a pass. workload_shape.go
	// normalises supported controller kinds and refuses the rest; checks that do
	// not read the workload are unaffected.
	shaped := shapeWorkload(req.workload())
	if shaped.err != nil {
		slog.Warn("scan object is not pod-shaped: object-reading checks report error", "error", shaped.err)
	}
	inputMap := celBindings(shaped.object, req.Agent, req.Request)

	for _, sel := range packs {
		fw := sel.fw
		for _, cwc := range sel.checks {
			status := VerdictNotEvaluated
			var errText string
			if !isPlaceholder(fw.Status, cwc.Check.Status) {
				if v, msg, guarded := shaped.verdictFor(cwc.Check.CELExpression); guarded {
					status, errText = v, msg
				} else {
					passed, _, err := ch.celEngine.Evaluate(r.Context(), cwc.Check.CELExpression, inputMap)
					status = verdictOf(passed, err)
					if err != nil {
						errText = err.Error()
					}
				}
			}

			seed := checkSeed(cwc.Check.ID)
			// SimulateWithLoad, not Simulate: the load is the institution's, and
			// profile.RiskLoad is fair.DefaultRiskLoad unless this tenant
			// declared otherwise -- so an undeclared tenant takes the identical
			// code path with the identical value it always did.
			risk := fair.SimulateWithLoad(cwc.Check.RiskTriple, cwc.Check.FreqTriple, seed, profile.RiskLoad)

			results = append(results, ComplianceScanResult{
				Framework:         cwc.Framework,
				ControlSet:        cwc.ControlSet,
				Control:           cwc.Control,
				Check:             cwc.Check.ID,
				Passed:            status == VerdictPass,
				Status:            status,
				Error:             errText,
				ControlID:         cwc.controlID,
				FrameworkVersion:  fw.Version,
				CheckName:         cwc.Check.Name,
				PolicyVersion:     req.PolicyVersion,
				ALE:               roundMoney(risk.ALE, profile.Currency),
				VaR95:             roundMoney(risk.VaR95, profile.Currency),
				TVaR:              roundMoney(risk.TVaR, profile.Currency),
				CarriedGBP:        roundMoney(risk.CarriedGBP, profile.Currency),
				Currency:          profile.Currency,
				Carried:           money.Money{Amount: roundMoney(risk.CarriedGBP, profile.Currency), Currency: profile.Currency},
				ScanTimestamp:     now,
				// "industry-indicative" until 2026-10-11. It asserted an industry
				// anchor that does not exist: no public or commercial loss dataset
				// prices these controls, the 127 shipped triples carry no provenance
				// field, author, date or anchor class, and this tag is applied by the
				// engine rather than by the author of a triple. The replacement states
				// what is true of every row -- a declared expert estimate, anchored to
				// nothing outside the pack. It still reads the same on a row that
				// prices at zero, which is a known imprecision; per-triple provenance
				// is an open decision in docs/fair-methodology-open-decisions.md.
				// The calibration statement: policy/frameworks/README.md.
				CalibrationSource: "declared-estimate-unanchored",
			})
		}
	}

	ch.mu.Lock()
	ch.lastResults = results
	ch.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(results)
}

// handleFrameworks returns available frameworks and their versions, or 404 for non-existent framework ID.
func (ch *complianceHandler) handleFrameworks(w http.ResponseWriter, r *http.Request) {
	subpath := strings.TrimPrefix(r.URL.Path, "/api/v1/compliance/frameworks")
	subpath = strings.TrimPrefix(subpath, "/")

	fws, err := frameworks.ListFrameworks(ch.policyRoot)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	if subpath != "" {
		versions, ok := fws[subpath]
		if !ok {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]any{
				"error":        "framework_not_found",
				"message":      fmt.Sprintf("Regulatory framework %q not found", subpath),
				"framework_id": subpath,
			})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]any{
			"id":       subpath,
			"versions": versions,
		})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(fws)
}

// handleSummary returns aggregate posture from the last scan.
func (ch *complianceHandler) handleSummary(w http.ResponseWriter, r *http.Request) {
	ch.mu.RLock()
	results := ch.lastResults
	ch.mu.RUnlock()

	// The summary is denominated by the scan it summarises, not by a constant.
	// Results carry their own currency now, so reading it from them is what
	// stops a declared-currency scan being totalled under the default's label --
	// a sum whose figures and whose label disagree is the worst of the three
	// possible outcomes, because it reads as authoritative.
	summary := ComplianceSummary{Currency: defaultReportingCurrency}
	if len(results) > 0 {
		summary.ScanTimestamp = results[0].ScanTimestamp
		summary.Currency = results[0].Currency
		for _, r := range results {
			summary.TotalControls++
			switch r.Status {
			case VerdictPass:
				summary.Passed++
				continue
			case VerdictNotEvaluated:
				// A placeholder has no verdict: neither failed, errored nor exposure.
				summary.NotEvaluated++
				continue
			case VerdictError:
				summary.Errored++
			default:
				summary.Failed++
			}
			// Exposure is conservative: an errored control is not assumed safe.
			summary.TotalExposure += r.CarriedGBP
		}
	}
	summary.Exposure = money.Money{Amount: summary.TotalExposure, Currency: summary.Currency}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(summary)
}

// evaluateCEL compiles and evaluates a CEL expression against a manifest.
func evaluateCEL(expr string, manifest map[string]any) bool {
	engine, err := NewCELEngine()
	if err != nil {
		slog.Error("creating CEL env", "error", err)
		return false
	}

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	passed, _, err := engine.Evaluate(ctx, expr, map[string]any{
		"object":   manifest,
		"manifest": manifest,
	})
	if err != nil {
		slog.Debug("CEL eval error", "expression", expr, "error", err)
		return false
	}
	return passed
}

type scanCheck struct {
	frameworks.CheckWithContext
	controlID string
}

// checksWithControlIDs is frameworks.ChecksForVersion with each check's control
// ID attached, which CheckWithContext does not carry. Filtering is delegated
// control by control so version semantics stay in one place.
func checksWithControlIDs(fw *frameworks.Framework, policyVersion string) []scanCheck {
	var out []scanCheck
	for _, cs := range fw.ControlSets {
		for _, ctrl := range cs.Controls {
			one := &frameworks.Framework{ID: fw.ID, ControlSets: []frameworks.ControlSet{{Name: cs.Name, Controls: []frameworks.Control{ctrl}}}}
			for _, cwc := range frameworks.ChecksForVersion(one, policyVersion) {
				out = append(out, scanCheck{CheckWithContext: cwc, controlID: ctrl.ID})
			}
		}
	}
	return out
}

func checkSeed(id string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(id))
	return h.Sum64()
}

func roundMoney(v float64, c money.Currency) float64 {
	return money.Money{Amount: v, Currency: c}.Round().Amount
}

// writeFrameworkError reports frameworks a scan could not evaluate.
// `framework` names them all (", "-joined); `frameworks` lists them.
func writeFrameworkError(w http.ResponseWriter, code int, kind string, fws []string, policyVersion, detail string) {
	body := map[string]any{
		"error":         kind,
		"framework":     strings.Join(fws, ", "),
		"frameworks":    fws,
		"policyVersion": policyVersion,
	}
	if detail != "" {
		body["detail"] = detail
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(body)
}

// selectPack loads every version directory of a framework and returns the ONE
// a scan evaluates: the pack whose version equals policyVersion, otherwise the
// newest pack by version order. Every directory is loaded, so a pack that
// fails to load fails the selection rather than being silently skipped.
func selectPack(policyRoot, fwID string, dirs []string, policyVersion string) (*frameworks.Framework, error) {
	var newest *frameworks.Framework
	var newestDir string
	for _, dir := range dirs {
		fw, err := frameworks.Load(policyRoot, fwID, dir)
		if err != nil {
			return nil, err
		}
		if policyVersion != "" && fw.Version == policyVersion {
			return fw, nil
		}
		if newest == nil {
			newest, newestDir = fw, dir
			continue
		}
		c := compareVersions(fw.Version, newest.Version)
		if c > 0 || (c == 0 && dir > newestDir) {
			newest, newestDir = fw, dir
		}
	}
	if newest == nil {
		return nil, fmt.Errorf("framework %s has no version directories", fwID)
	}
	return newest, nil
}

// compareVersions orders semver-ish strings ("v2.10.0" > "v2.9.0"): an
// optional leading v, dot-separated segments compared numerically when both
// are integers and lexically otherwise; a shorter prefix sorts first.
func compareVersions(a, b string) int {
	as := strings.Split(strings.TrimPrefix(a, "v"), ".")
	bs := strings.Split(strings.TrimPrefix(b, "v"), ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		an, aerr := strconv.Atoi(as[i])
		bn, berr := strconv.Atoi(bs[i])
		var c int
		if aerr == nil && berr == nil {
			c = cmp.Compare(an, bn)
		} else {
			c = strings.Compare(as[i], bs[i])
		}
		if c != 0 {
			return c
		}
	}
	return cmp.Compare(len(as), len(bs))
}
