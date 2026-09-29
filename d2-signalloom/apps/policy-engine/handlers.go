package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

type PolicyEngineHandlers struct {
	store     *PolicyStore
	celEngine *CELEngine
}

func NewPolicyEngineHandlers(store *PolicyStore, celEngine *CELEngine) *PolicyEngineHandlers {
	return &PolicyEngineHandlers{
		store:     store,
		celEngine: celEngine,
	}
}

func extractTenant(r *http.Request) string {
	tenant := r.Header.Get("X-Tenant-ID")
	if tenant == "" {
		tenant = r.URL.Query().Get("tenant")
	}
	return strings.TrimSpace(tenant)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// HandleListPolicies handles GET /api/v1/policies.
func (h *PolicyEngineHandlers) HandleListPolicies(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	tenantID := extractTenant(r)
	summaries := h.store.ListPolicies(tenantID)
	writeJSON(w, http.StatusOK, summaries)
}

// HandleEvaluatePolicies handles POST /api/v1/policies/evaluate.
func (h *PolicyEngineHandlers) HandleEvaluatePolicies(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req EvaluatePoliciesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID := extractTenant(r)
	if req.TenantID == "" {
		req.TenantID = tenantID
	}

	if req.FrameworkID != "" {
		bundle, err := h.store.GetActiveBundle(req.TenantID, req.FrameworkID, req.PolicyVersion)
		if err != nil {
			writeError(w, http.StatusNotFound, err.Error())
			return
		}

		resp, err := h.store.EvaluateBundle(r.Context(), bundle, &req)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "evaluation failed: "+err.Error())
			return
		}
		writeJSON(w, http.StatusOK, resp)
		return
	}

	// If no framework_id specified, evaluate across all active frameworks for tenant
	summaries := h.store.ListPolicies(req.TenantID)
	if len(summaries) == 0 {
		writeError(w, http.StatusBadRequest, "no frameworks registered for evaluation")
		return
	}

	allResults := make([]RuleEvaluationResult, 0)
	compliant := true
	totalPassed := 0
	totalFailed := 0
	var totalExposure float64
	start := time.Now()

	for _, s := range summaries {
		if s.ActiveBundle == nil {
			continue
		}
		resp, err := h.store.EvaluateBundle(r.Context(), s.ActiveBundle, &req)
		if err != nil {
			continue
		}
		if !resp.Compliant {
			compliant = false
		}
		totalPassed += resp.PassedRules
		totalFailed += resp.FailedRules
		totalExposure += resp.TotalExposure
		allResults = append(allResults, resp.Results...)
	}

	totalLatency := float64(time.Since(start).Microseconds()) / 1000.0

	combinedResp := EvaluatePoliciesResponse{
		Compliant:     compliant,
		TenantID:      req.TenantID,
		FrameworkID:   "all",
		PolicyVersion: "latest",
		TotalRules:    len(allResults),
		PassedRules:   totalPassed,
		FailedRules:   totalFailed,
		TotalExposure: totalExposure,
		Results:       allResults,
		EvaluatedAt:   time.Now().UTC().Format(time.RFC3339),
		EvaluationMs:  totalLatency,
	}

	writeJSON(w, http.StatusOK, combinedResp)
}

// HandleRegisterBundle handles POST /api/v1/policies/bundles.
func (h *PolicyEngineHandlers) HandleRegisterBundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var bundle PolicyBundle
	if err := json.NewDecoder(r.Body).Decode(&bundle); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID := extractTenant(r)
	if bundle.TenantID == "" {
		bundle.TenantID = tenantID
	}

	if err := h.store.RegisterBundle(bundle.TenantID, &bundle); err != nil {
		writeError(w, http.StatusBadRequest, "failed to register policy bundle: "+err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, bundle)
}

// HandleRollback handles POST /api/v1/policies/rollback.
func (h *PolicyEngineHandlers) HandleRollback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req RollbackRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID := extractTenant(r)
	if req.TenantID == "" {
		req.TenantID = tenantID
	}
	if req.FrameworkID == "" {
		writeError(w, http.StatusBadRequest, "framework_id is required")
		return
	}
	if req.TargetVersion == "" {
		writeError(w, http.StatusBadRequest, "target_version is required")
		return
	}

	restored, err := h.store.Rollback(req.TenantID, req.FrameworkID, req.TargetVersion)
	if err != nil {
		if strings.Contains(err.Error(), "not found") {
			writeError(w, http.StatusNotFound, err.Error())
		} else {
			writeError(w, http.StatusBadRequest, err.Error())
		}
		return
	}

	writeJSON(w, http.StatusOK, restored)
}
