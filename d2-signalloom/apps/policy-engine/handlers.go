package main

import (
	"encoding/json"
	"fmt"
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

func extractTenant(r *http.Request) (string, error) {
	headerTenant := strings.TrimSpace(r.Header.Get("X-Tenant-ID"))
	q := r.URL.Query()
	queryTenant := strings.TrimSpace(q.Get("tenant"))
	queryTenantID := strings.TrimSpace(q.Get("tenant_id"))

	if queryTenant != "" && queryTenantID != "" && queryTenant != queryTenantID {
		return "", fmt.Errorf("cross-tenant mismatch: query tenant %q does not match query tenant_id %q", queryTenant, queryTenantID)
	}

	effectiveQuery := queryTenant
	if effectiveQuery == "" {
		effectiveQuery = queryTenantID
	}

	if headerTenant != "" && effectiveQuery != "" && headerTenant != effectiveQuery {
		return "", fmt.Errorf("cross-tenant mismatch: authenticated header %q does not match query tenant %q", headerTenant, effectiveQuery)
	}
	if headerTenant != "" {
		return headerTenant, nil
	}
	return effectiveQuery, nil
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
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	tenantID, err := extractTenant(r)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}
	summaries := h.store.ListPolicies(tenantID)
	writeJSON(w, http.StatusOK, summaries)
}

// HandleEvaluatePolicies handles POST /api/v1/policies/evaluate.
func (h *PolicyEngineHandlers) HandleEvaluatePolicies(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req EvaluatePoliciesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID, err := extractTenant(r)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	if tenantID != "" && req.TenantID != "" && req.TenantID != tenantID {
		writeError(w, http.StatusForbidden, fmt.Sprintf("cross-tenant mismatch: authenticated tenant %q does not match request tenant %q", tenantID, req.TenantID))
		return
	}
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
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var bundle PolicyBundle
	if err := json.NewDecoder(r.Body).Decode(&bundle); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID, err := extractTenant(r)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	if tenantID != "" && bundle.TenantID != "" && bundle.TenantID != tenantID {
		writeError(w, http.StatusForbidden, fmt.Sprintf("cross-tenant mismatch: authenticated tenant %q does not match bundle tenant %q", tenantID, bundle.TenantID))
		return
	}
	if bundle.TenantID == "" {
		bundle.TenantID = tenantID
	}

	// §4.4: this route is a dry-run surface. The flag is set here, not by the
	// caller, so a client cannot register something that claims to be durable.
	bundle.DryRun = true

	if err := h.store.RegisterBundle(bundle.TenantID, &bundle); err != nil {
		writeError(w, http.StatusBadRequest, "failed to register policy bundle: "+err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, bundle)
}

// HandleRollback handles POST /api/v1/policies/rollback.
func (h *PolicyEngineHandlers) HandleRollback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req RollbackRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID, err := extractTenant(r)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	if tenantID != "" && req.TenantID != "" && req.TenantID != tenantID {
		writeError(w, http.StatusForbidden, fmt.Sprintf("cross-tenant mismatch: authenticated tenant %q does not match rollback tenant %q", tenantID, req.TenantID))
		return
	}
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
