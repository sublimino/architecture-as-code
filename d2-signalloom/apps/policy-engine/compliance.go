package main

import (
	"encoding/json"
	"hash/fnv"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/cel-go/cel"

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
}

// reportingCurrency denominates every figure this service reports.
//
// It is a constant rather than a config knob for now, and that is a deliberate, temporary choice:
// the loss magnitudes baked into policy/frameworks/ are GBP-calibrated, so making the OUTPUT
// currency configurable without also redenominating those inputs would relabel figures rather than
// convert them -- the precise failure this change exists to prevent. Point this at a real per-tenant
// setting only together with per-tenant calibration data.
const reportingCurrency money.Currency = "GBP"

type ComplianceScanResult struct {
	Framework         string  `json:"framework"`
	ControlSet        string  `json:"controlSet"`
	Control           string  `json:"control"`
	Check             string  `json:"check"`
	Passed            bool    `json:"passed"`
	PolicyVersion     string  `json:"policyVersion"`
	ALE               float64 `json:"ale"`
	VaR95             float64 `json:"var95"`
	TVaR              float64 `json:"tvar"`
	CarriedGBP        float64 `json:"carriedGbp"`
	ScanTimestamp     string  `json:"scanTimestamp"`
	CalibrationSource string  `json:"calibrationSource"`

	// Currency denominates ale, var95, tvar and carriedGbp above.
	//
	// The four numeric fields are retained under their existing names so the dashboard keeps
	// working while it migrates; `carriedGbp` in particular is now a MISNOMER whenever this
	// service is configured for another currency, which is exactly why the denomination has to
	// travel as data rather than in a field name. New consumers should read `carried` and
	// `currency` and treat the *Gbp field as deprecated.
	Currency money.Currency `json:"currency"`
	// Carried is CarriedGBP with its denomination attached. Same number, self-describing.
	Carried money.Money `json:"carried"`
}

type ComplianceSummary struct {
	TotalControls int     `json:"totalControls"`
	Passed        int     `json:"passed"`
	Failed        int     `json:"failed"`
	TotalExposure float64 `json:"totalExposureGbp"`
	ScanTimestamp string  `json:"scanTimestamp,omitempty"`

	// Currency denominates totalExposureGbp. See the note on ComplianceScanResult.
	Currency money.Currency `json:"currency"`
	// Exposure is totalExposureGbp with its denomination attached.
	Exposure money.Money `json:"exposure"`
}

// complianceHandler holds framework data and scan state.
type complianceHandler struct {
	policyRoot string

	mu          sync.RWMutex
	lastResults []ComplianceScanResult
}

func newComplianceHandler(policyRoot string) (*complianceHandler, error) {
	// Verify the frameworks directory exists.
	if _, err := frameworks.ListFrameworks(policyRoot); err != nil {
		return nil, err
	}
	return &complianceHandler{policyRoot: policyRoot}, nil
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

	if len(req.Frameworks) == 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "at least one framework is required"})
		return
	}

	// Pre-flight: reject unknown frameworks before doing any work. A scan that
	// silently ignores every requested framework and returns an empty 200 is the
	// exact "two things that must agree, with nothing checking that they do"
	// pattern: the caller believes it asked for a SOC-2 scan, the server believes
	// it ran one, and neither has any results to show for it.
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
		// ALL requested frameworks are unknown — this is always an error.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "none of the requested frameworks exist: " + strings.Join(unknown, ", "),
		})
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	var results []ComplianceScanResult

	for _, fwID := range req.Frameworks {
		versions, ok := available[fwID]
		if !ok || len(versions) == 0 {
			slog.Warn("framework not found, skipping", "framework", fwID)
			continue
		}

		// Load each version of the framework and collect applicable checks.
		for _, ver := range versions {
			fw, err := frameworks.Load(ch.policyRoot, fwID, ver)
			if err != nil {
				slog.Error("loading framework", "framework", fwID, "version", ver, "error", err)
				continue
			}

			checks := frameworks.ChecksForVersion(fw, req.PolicyVersion)
			for _, cwc := range checks {
				passed := evaluateCEL(cwc.Check.CELExpression, req.Manifest)

				// Deterministic seed from check ID for reproducible FAIR results.
				seed := checkSeed(cwc.Check.ID)
				risk := fair.Simulate(cwc.Check.RiskTriple, cwc.Check.FreqTriple, seed)

				results = append(results, ComplianceScanResult{
					Framework:         cwc.Framework,
					ControlSet:        cwc.ControlSet,
					Control:           cwc.Control,
					Check:             cwc.Check.ID,
					Passed:            passed,
					PolicyVersion:     req.PolicyVersion,
					ALE:               roundTo2(risk.ALE),
					VaR95:             roundTo2(risk.VaR95),
					TVaR:              roundTo2(risk.TVaR),
					CarriedGBP:        roundTo2(risk.CarriedGBP),
					Currency:          reportingCurrency,
					Carried:           money.Money{Amount: roundTo2(risk.CarriedGBP), Currency: reportingCurrency},
					ScanTimestamp:     now,
					CalibrationSource: "industry-indicative",
				})
			}
		}
	}

	// Cache for summary endpoint.
	ch.mu.Lock()
	ch.lastResults = results
	ch.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(results)
}

// handleFrameworks returns available frameworks and their versions.
func (ch *complianceHandler) handleFrameworks(w http.ResponseWriter, r *http.Request) {
	fws, err := frameworks.ListFrameworks(ch.policyRoot)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
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

	summary := ComplianceSummary{Currency: reportingCurrency}
	if len(results) > 0 {
		summary.ScanTimestamp = results[0].ScanTimestamp
		for _, r := range results {
			summary.TotalControls++
			if r.Passed {
				summary.Passed++
			} else {
				summary.Failed++
				summary.TotalExposure += r.CarriedGBP
			}
		}
	}
	summary.Exposure = money.Money{Amount: summary.TotalExposure, Currency: reportingCurrency}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(summary)
}

// evaluateCEL compiles and evaluates a CEL expression against a manifest.
// Returns true if the expression evaluates to true, false otherwise (including
// on compilation or evaluation errors).
func evaluateCEL(expr string, manifest map[string]any) bool {
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType),
	)
	if err != nil {
		slog.Error("creating CEL env", "error", err)
		return false
	}

	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		slog.Warn("CEL compile error", "expression", expr, "error", issues.Err())
		return false
	}

	prg, err := env.Program(ast)
	if err != nil {
		slog.Error("CEL program error", "error", err)
		return false
	}

	out, _, err := prg.Eval(map[string]any{"object": manifest})
	if err != nil {
		slog.Debug("CEL eval error", "expression", expr, "error", err)
		return false
	}

	result, ok := out.Value().(bool)
	return ok && result
}

func checkSeed(id string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(id))
	return h.Sum64()
}

// roundTo2 quantises v to two decimal places, rounding halves away from zero.
//
// The previous implementation, `float64(int(v*100+0.5))/100`, had three defects:
//
//  1. For negative values, int() truncates toward zero, giving the wrong answer at every
//     rounding boundary (e.g. -2.675 → -2.67 instead of -2.68).
//  2. NaN silently became -9.22e16 (MinInt64/100) — a plausible-looking number.
//  3. ±Inf became the same -9.22e16 — also a plausible-looking number.
//
// The fix: pass non-finite values through unchanged (so they surface downstream rather than
// being silently fabricated), and use math.Abs + sign restoration to round negative values
// correctly.
func roundTo2(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return v
	}
	sign := 1.0
	abs := v
	if v < 0 {
		sign = -1.0
		abs = -v
	}
	return sign * math.Floor(abs*100+0.5) / 100
}
