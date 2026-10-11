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
	"sort"
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

	// AssessmentDate is the AS-OF DATE the scan is run for, YYYY-MM-DD. It is
	// the only input that lets an applicability window gate anything, and the
	// reason the engine never reads the clock: the caller states the day it is
	// asking about, so the same request replays to identical verdicts forever.
	// Same convention as `as_of` on risk/fx/rates.yaml.
	//
	// ABSENT IS A DELIBERATE DEFAULT, not an oversight -- see
	// TestScan_NoAssessmentDateLeavesEveryCheckEvaluatedAndSaysSo. A scan with
	// no assessmentDate applies no window at all, behaves exactly as it did
	// before windows existed, and reports that fact on the summary via
	// applicabilityGated and ungatedFrameworks. Substituting today here would
	// make a stored scan irreproducible; refusing the request outright would
	// break every caller outside this change.
	AssessmentDate string `json:"assessmentDate,omitempty"`
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

// ApplicabilityReport is the row-level audit record of the window that governed
// a check. It is emitted whenever a window governs the check, even when it did
// not fire, so a reader can tell "no window" from "a window the engine declined
// to act on" from "a window that gated this verdict" without reading the pack.
type ApplicabilityReport struct {
	// Status is what the declared dates say about AssessmentDate. "unknown"
	// when no as-of date was supplied.
	Status frameworks.WindowStatus `json:"status"`
	// Gated is true iff this window actually forced the verdict. A window with
	// verified:false always reports gated:false, which is how an unverified
	// date is proved inert from the response alone.
	Gated          bool   `json:"gated"`
	InForceFrom    string `json:"inForceFrom,omitempty"`
	SupersededFrom string `json:"supersededFrom,omitempty"`
	Basis          string `json:"basis,omitempty"`
	Source         string `json:"source,omitempty"`
	Jurisdiction   string `json:"jurisdiction,omitempty"`
	Verified       bool   `json:"verified"`
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

	// Status is the verdict: pass, fail, error, not_evaluated or not_in_force.
	// An expression that cannot evaluate is error, never fail; a placeholder
	// check is not_evaluated and is never evaluated; a check whose regime's
	// obligations do not exist on AssessmentDate is not_in_force and is never
	// evaluated. A placeholder of a future regime is not_evaluated: having no
	// expression outranks having no obligation.
	Status Verdict `json:"status"`
	// Error is the CEL error text when Status is error.
	Error            string `json:"error,omitempty"`
	ControlID        string `json:"controlId"`
	FrameworkVersion string `json:"frameworkVersion"`
	CheckName        string `json:"checkName"`

	// AssessmentDate echoes the as-of date this verdict is for, empty when the
	// caller supplied none. Carried on the ROW and not only the summary so a
	// single row lifted into an evidence bundle still states the day it is
	// evidence for.
	AssessmentDate string `json:"assessmentDate,omitempty"`
	// Applicability is the window that governed this check, if any.
	Applicability *ApplicabilityReport `json:"applicability,omitempty"`
}

type ComplianceSummary struct {
	TotalControls int `json:"totalControls"`
	Passed        int `json:"passed"`
	Failed        int `json:"failed"`
	Errored       int `json:"errored"`
	// NotEvaluated counts placeholder checks; they are in TotalControls only.
	NotEvaluated int `json:"notEvaluated"`
	// NotInForce counts checks whose regime's obligations do not exist on
	// AssessmentDate. Like NotEvaluated they are in TotalControls only: not
	// passed, not failed, not errored and contributing no exposure. A regime
	// that has not started cannot be breached, so pricing it would be wrong by
	// statute rather than by opinion.
	NotInForce    int     `json:"notInForce"`
	TotalExposure float64 `json:"totalExposureGbp"`
	ScanTimestamp string  `json:"scanTimestamp,omitempty"`

	// AssessmentDate echoes the as-of date the scan was run with, empty when
	// the caller supplied none. It is on the summary as well as every row
	// because it is the one input that makes the verdicts reproducible: a
	// reader cannot re-derive these counts without knowing which day they are
	// counts for.
	AssessmentDate string `json:"assessmentDate,omitempty"`
	// ApplicabilityGated is true when an assessmentDate was supplied, so the
	// declared windows were actually applied. False means every check
	// evaluated regardless of its regime's dates -- see UngatedFrameworks.
	ApplicabilityGated bool `json:"applicabilityGated"`
	// UngatedFrameworks names the frameworks in this scan that declare a
	// VERIFIED applicability window which was NOT applied, because no
	// assessmentDate was supplied. This is the honest report of the default:
	// the gate did not fire, these are the regimes where that mattered, and a
	// reader is told rather than left to assume the dates were checked.
	UngatedFrameworks []string `json:"ungatedFrameworks,omitempty"`

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
	// lastUngated names frameworks of the last scan that declared a verified
	// window which was not applied because no assessmentDate was supplied. Kept
	// beside lastResults because it is a property of the scan, not of a row.
	lastUngated []string
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

	// The as-of date, parsed strictly. A date the engine cannot read is a 400:
	// the caller asserted a day, and silently falling back to today (or to no
	// gate at all) would answer a question nobody asked. A ZERO asOf means the
	// caller supplied none, which is the documented default and gates nothing.
	var asOf frameworks.Date
	if req.AssessmentDate != "" {
		parsed, err := frameworks.ParseDate(req.AssessmentDate)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]any{
				"error":          "invalid_assessment_date",
				"assessmentDate": req.AssessmentDate,
				"detail":         err.Error(),
				"message":        "assessmentDate must be a calendar day in YYYY-MM-DD form; omit it to apply no applicability window",
			})
			return
		}
		asOf = parsed
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

	// Frameworks whose verified window went unapplied because the caller sent
	// no assessmentDate. Reported on the summary so the default is visible.
	ungated := map[string]bool{}

	for _, sel := range packs {
		fw := sel.fw
		for _, cwc := range sel.checks {
			// The window is resolved and REPORTED regardless of whether it
			// fires, so a response always says what the pack declares.
			window, gateStatus, gated := applicabilityOf(cwc.applicability, asOf)
			if window != nil && !gated && window.Verified && asOf.IsZero() {
				ungated[cwc.Framework] = true
			}

			status := VerdictNotEvaluated
			var errText string
			switch {
			// Placeholder outranks the window: having no expression at all is
			// the primary, pack-intrinsic reason a check is not evaluated, and
			// it is true at every as-of date.
			case isPlaceholder(fw.Status, cwc.Check.Status):
			case gated:
				status, errText = gateVerdict(gateStatus)
			default:
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
				Framework:        cwc.Framework,
				ControlSet:       cwc.ControlSet,
				Control:          cwc.Control,
				Check:            cwc.Check.ID,
				Passed:           status == VerdictPass,
				Status:           status,
				Error:            errText,
				ControlID:        cwc.controlID,
				FrameworkVersion: fw.Version,
				CheckName:        cwc.Check.Name,
				PolicyVersion:    req.PolicyVersion,
				ALE:              roundMoney(risk.ALE, profile.Currency),
				VaR95:            roundMoney(risk.VaR95, profile.Currency),
				TVaR:             roundMoney(risk.TVaR, profile.Currency),
				CarriedGBP:       roundMoney(risk.CarriedGBP, profile.Currency),
				Currency:         profile.Currency,
				Carried:          money.Money{Amount: roundMoney(risk.CarriedGBP, profile.Currency), Currency: profile.Currency},
				ScanTimestamp:    now,
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
				AssessmentDate:    req.AssessmentDate,
				Applicability:     window,
			})
		}
	}

	ungatedList := make([]string, 0, len(ungated))
	for id := range ungated {
		ungatedList = append(ungatedList, id)
	}
	sort.Strings(ungatedList)
	if len(ungatedList) > 0 {
		slog.Warn("applicability windows not applied: no assessmentDate supplied",
			"frameworks", strings.Join(ungatedList, ","))
	}

	ch.mu.Lock()
	ch.lastResults = results
	ch.lastUngated = ungatedList
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
	ungated := ch.lastUngated
	ch.mu.RUnlock()

	// The summary is denominated by the scan it summarises, not by a constant.
	// Results carry their own currency now, so reading it from them is what
	// stops a declared-currency scan being totalled under the default's label --
	// a sum whose figures and whose label disagree is the worst of the three
	// possible outcomes, because it reads as authoritative.
	summary := ComplianceSummary{Currency: defaultReportingCurrency, UngatedFrameworks: ungated}
	if len(results) > 0 {
		summary.ScanTimestamp = results[0].ScanTimestamp
		summary.Currency = results[0].Currency
		// Every row of a scan carries the same as-of date, so row 0 is the
		// scan's. Read from the rows rather than kept as separate state so the
		// summary can never claim a date the rows were not evaluated at.
		summary.AssessmentDate = results[0].AssessmentDate
		summary.ApplicabilityGated = summary.AssessmentDate != ""
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
			case VerdictNotInForce:
				// An obligation that does not exist on the assessmentDate cannot
				// be breached: no failure, no error, no exposure. The row keeps
				// its own priced figure; the summary declines to add it up.
				summary.NotInForce++
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
	// applicability is the ONE window governing this check, resolved
	// check > control > control set > framework at selection time so the
	// evaluation loop never has to walk the hierarchy again.
	applicability *frameworks.Applicability
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
				out = append(out, scanCheck{
					CheckWithContext: cwc,
					controlID:        ctrl.ID,
					applicability:    frameworks.ResolveApplicability(fw, cs, ctrl, cwc.Check),
				})
			}
		}
	}
	return out
}

// applicabilityOf turns a resolved window and an as-of date into the row's
// audit record, the status to act on and whether the engine may act on it.
//
// It is the single place the gate decision is made, so there is exactly one
// answer to "did this window change the verdict?" and the response carries it.
// A window is reported even when it does nothing, which is what lets a reader
// distinguish a pack with no declared date from one whose date is unverified.
func applicabilityOf(a *frameworks.Applicability, asOf frameworks.Date) (*ApplicabilityReport, frameworks.WindowStatus, bool) {
	if a == nil {
		return nil, frameworks.WindowUnknown, false
	}
	st, gates := a.Gates(asOf)
	return &ApplicabilityReport{
		Status:         a.StatusAt(asOf),
		Gated:          gates,
		InForceFrom:    a.InForceFrom,
		SupersededFrom: a.SupersededFrom,
		Basis:          a.Basis,
		Source:         a.Source,
		Jurisdiction:   a.Jurisdiction,
		Verified:       a.Verified,
	}, st, gates
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
