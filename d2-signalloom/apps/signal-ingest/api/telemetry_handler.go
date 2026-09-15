// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
)

var (
	defaultCodingAgentStoreOnce sync.Once
	defaultCodingAgentStore     codingagent.TelemetryStore
)

func getDefaultCodingAgentStore() codingagent.TelemetryStore {
	defaultCodingAgentStoreOnce.Do(func() {
		defaultCodingAgentStore = codingagent.NewMemoryStore()
	})
	return defaultCodingAgentStore
}

func (h *Handlers) getCodingAgentStore() codingagent.TelemetryStore {
	if h != nil && h.CodingAgentStore != nil {
		return h.CodingAgentStore
	}
	return getDefaultCodingAgentStore()
}

// handleCodingAgentTelemetry processes incoming CodingAgentTelemetry POST requests.
// Enforces:
// 1. Authenticated tenant context via ProtectedRouter/tenant_bridge (unauthenticated or forged headers rejected).
// 2. Closed-world JSON decoding conforming strictly to the frozen P1-3 wire contract.
// 3. Monotonic deduplication (session_id + sequence) preventing duplicate metric accumulation.
// 4. Server-side clock skew calculation alongside untouched original timestamp.
func (h *Handlers) handleCodingAgentTelemetry(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// 1. ENFORCE TENANT ISOLATION: Must derive verified tenant context from JWT-SVID principal
	claim, ok := TenantClaimFromRequestContext(r.Context())
	if !ok || claim.TenantID == "" {
		writeError(w, http.StatusUnauthorized, "missing or unverified tenant context")
		return
	}

	// Limit request payload to 128KB to prevent memory exhaustion
	r.Body = http.MaxBytesReader(w, r.Body, 128*1024)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to read request body: "+err.Error())
		return
	}

	// 2. CLOSED-WORLD WIRE VALIDATION: Reject any extra/unlisted keys, missing fields, or bound violations
	wireEnvelope, err := codingagent.DecodeWire(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "closed-world validation failed: "+err.Error())
		return
	}

	// Also validate through typed domain model
	telemetryEvent, err := codingagent.UnmarshalJSON(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "domain validation failed: "+err.Error())
		return
	}

	// Ensure tenant ID is stamped strictly from verified JWT claim (never trusting wire body or header)
	_ = wireEnvelope
	telemetryEvent.TenantID = claim.TenantID
	if telemetryEvent.AgentID == "" && claim.PrincipalSubject != "" {
		telemetryEvent.AgentID = claim.PrincipalSubject
	}

	// 3. PERSISTENCE, DEDUPLICATION, AND CLOCK-SKEW ESTIMATION
	store := h.getCodingAgentStore()
	result, err := store.Ingest(r.Context(), claim.TenantID, claim.PrincipalSubject, telemetryEvent)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ingestion failed: "+err.Error())
		return
	}

	statusCode := http.StatusCreated
	if result.Duplicate {
		statusCode = http.StatusOK
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	_ = json.NewEncoder(w).Encode(result)
}

// handleQueryCodingAgentTelemetry retrieves stored telemetry records for the authenticated tenant.
func (h *Handlers) handleQueryCodingAgentTelemetry(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	claim, ok := TenantClaimFromRequestContext(r.Context())
	if !ok || claim.TenantID == "" {
		writeError(w, http.StatusUnauthorized, "missing or unverified tenant context")
		return
	}

	filter := parseAggregateFilter(r)
	store := h.getCodingAgentStore()
	records, err := store.Query(r.Context(), claim.TenantID, filter)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "query failed: "+err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(records)
}

// handleAggregateCodingAgentTelemetry returns summary metrics for the authenticated tenant,
// strictly enforcing the k-anonymity minimum group size (k=5) to prevent re-identification.
func (h *Handlers) handleAggregateCodingAgentTelemetry(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	claim, ok := TenantClaimFromRequestContext(r.Context())
	if !ok || claim.TenantID == "" {
		writeError(w, http.StatusUnauthorized, "missing or unverified tenant context")
		return
	}

	filter := parseAggregateFilter(r)
	store := h.getCodingAgentStore()
	result, err := store.Aggregate(r.Context(), claim.TenantID, filter)
	if err != nil {
		if errors.Is(err, codingagent.ErrGroupSizeBelowAnonymityFloor) {
			// HTTP 422 Unprocessable Entity when cohort size is below k-anonymity floor
			writeError(w, http.StatusUnprocessableEntity, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "aggregate failed: "+err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(result)
}

// handleCodingAgentOrdering evaluates causal ordering between two records with clock-skew uncertainty bounds.
func (h *Handlers) handleCodingAgentOrdering(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	claim, ok := TenantClaimFromRequestContext(r.Context())
	if !ok || claim.TenantID == "" {
		writeError(w, http.StatusUnauthorized, "missing or unverified tenant context")
		return
	}

	var req struct {
		EventA codingagent.CodingAgentTelemetry `json:"event_a"`
		EventB codingagent.CodingAgentTelemetry `json:"event_b"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	store := h.getCodingAgentStore()

	// Ingest or wrap records to obtain skew calculations
	resA, errA := store.Ingest(r.Context(), claim.TenantID, claim.PrincipalSubject, &req.EventA)
	resB, errB := store.Ingest(r.Context(), claim.TenantID, claim.PrincipalSubject, &req.EventB)
	if errA != nil || errB != nil {
		writeError(w, http.StatusBadRequest, "failed to ingest events for ordering evaluation")
		return
	}

	recA := codingagent.StoredRecord{
		Event:       req.EventA,
		ClockSkewMs: resA.ClockSkewMs,
	}
	recB := codingagent.StoredRecord{
		Event:       req.EventB,
		ClockSkewMs: resB.ClockSkewMs,
	}

	ordering, err := store.ResolveOrdering(r.Context(), claim.TenantID, &recA, &recB)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ordering resolution failed: "+err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(ordering)
}

func parseAggregateFilter(r *http.Request) codingagent.AggregateFilter {
	q := r.URL.Query()
	filter := codingagent.AggregateFilter{
		Harness:   codingagent.Harness(q.Get("harness")),
		TaskID:    q.Get("task_id"),
		Shortcode: q.Get("shortcode"),
	}
	if afterStr := q.Get("after"); afterStr != "" {
		if t, err := time.Parse(time.RFC3339, afterStr); err == nil {
			filter.After = t
		}
	}
	if beforeStr := q.Get("before"); beforeStr != "" {
		if t, err := time.Parse(time.RFC3339, beforeStr); err == nil {
			filter.Before = t
		}
	}
	return filter
}
