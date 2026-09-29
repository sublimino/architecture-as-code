package main

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"log/slog"
	"net/http"
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
}

// reportingCurrency denominates every figure this service reports.
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

	now := time.Now().UTC().Format(time.RFC3339)
	var results []ComplianceScanResult

	inputMap := map[string]any{
		"object":   req.Manifest,
		"manifest": req.Manifest,
	}

	for _, fwID := range req.Frameworks {
		versions, ok := available[fwID]
		if !ok || len(versions) == 0 {
			slog.Warn("framework not found, skipping", "framework", fwID)
			continue
		}

		for _, ver := range versions {
			fw, err := frameworks.Load(ch.policyRoot, fwID, ver)
			if err != nil {
				slog.Error("loading framework", "framework", fwID, "version", ver, "error", err)
				continue
			}

			checks := frameworks.ChecksForVersion(fw, req.PolicyVersion)
			for _, cwc := range checks {
				passed, _, err := ch.celEngine.Evaluate(r.Context(), cwc.Check.CELExpression, inputMap)
				if err != nil {
					passed = false
				}

				seed := checkSeed(cwc.Check.ID)
				risk := fair.Simulate(cwc.Check.RiskTriple, cwc.Check.FreqTriple, seed)

				results = append(results, ComplianceScanResult{
					Framework:         cwc.Framework,
					ControlSet:        cwc.ControlSet,
					Control:           cwc.Control,
					Check:             cwc.Check.ID,
					Passed:            passed,
					PolicyVersion:     req.PolicyVersion,
					ALE:               roundMoney(risk.ALE, reportingCurrency),
					VaR95:             roundMoney(risk.VaR95, reportingCurrency),
					TVaR:              roundMoney(risk.TVaR, reportingCurrency),
					CarriedGBP:        roundMoney(risk.CarriedGBP, reportingCurrency),
					Currency:          reportingCurrency,
					Carried:           money.Money{Amount: roundMoney(risk.CarriedGBP, reportingCurrency), Currency: reportingCurrency},
					ScanTimestamp:     now,
					CalibrationSource: "industry-indicative",
				})
			}
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

func checkSeed(id string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(id))
	return h.Sum64()
}

func roundMoney(v float64, c money.Currency) float64 {
	return money.Money{Amount: v, Currency: c}.Round().Amount
}
