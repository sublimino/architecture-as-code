package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// BundlesDirEnv names the directory Flux reconciles tenant observation bundles
// into (SLAWS v2 §4.4, D6).
const BundlesDirEnv = "POLICY_BUNDLES_DIR"

// DefaultBundlesDir is the in-container mount point for that ConfigMap.
const DefaultBundlesDir = "/etc/policy-engine/bundles"

// EvaluateObservationRequest is the body of POST /api/v1/observations/evaluate.
type EvaluateObservationRequest struct {
	TenantID         string             `json:"tenant_id"`
	Observation      obscel.Observation `json:"observation"`
	ActorIsPseudonym bool               `json:"actor_is_pseudonym"`
}

// EvaluateObservationResponse is the dry-run result for one observation.
//
// DryRun is always true on this route. The route exists so the dashboard can
// ask "what would this bundle have said", and nothing it returns is stored or
// alerted on; the authoritative stage-1 path is in-process at the ingest sink.
type EvaluateObservationResponse struct {
	TenantID    string            `json:"tenant_id"`
	DryRun      bool              `json:"dry_run"`
	Bundles     []string          `json:"bundles"`
	Findings    []obscel.Finding  `json:"findings"`
	Faults      []string          `json:"faults,omitempty"`
	EvaluatedAt string            `json:"evaluated_at"`
	Modes       map[string]string `json:"modes"`
}

// ObservationHandlers serves the observation dry-run surface over the bundles
// the store loaded at boot.
type ObservationHandlers struct {
	store     *PolicyStore
	evaluator obscel.Evaluator
}

// NewObservationHandlers wires the in-process evaluator to the boot-loaded set.
func NewObservationHandlers(store *PolicyStore, evaluator obscel.Evaluator) *ObservationHandlers {
	return &ObservationHandlers{store: store, evaluator: evaluator}
}

// HandleEvaluateObservation handles POST /api/v1/observations/evaluate.
//
// It evaluates the observation against every bundle loaded for the named tenant
// and returns the findings. Evaluator faults are reported alongside the
// findings rather than replacing them: a broken rule in one bundle must not
// hide what the other rules found. Fail-closed behaviour belongs to the ingest
// drain loop, not to a read-only dry-run surface.
func (h *ObservationHandlers) HandleEvaluateObservation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req EvaluateObservationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	tenantID, err := extractTenant(r)
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	if req.TenantID != "" {
		if tenantID != "" && req.TenantID != tenantID {
			writeError(w, http.StatusForbidden, fmt.Sprintf("cross-tenant mismatch: authenticated tenant %q does not match request tenant %q", tenantID, req.TenantID))
			return
		}
		tenantID = req.TenantID
	}
	if tenantID == "" {
		writeError(w, http.StatusBadRequest, "tenant_id is required")
		return
	}

	// Tenant binding (D7): the request tenant is authoritative. A mismatch is a
	// caller defect, so it is refused rather than silently rebound — a finding
	// attributed to the wrong tenant is worse than no finding.
	if req.Observation.TenantID != "" && req.Observation.TenantID != tenantID {
		writeError(w, http.StatusBadRequest, fmt.Sprintf(
			"observation.tenant_id %q does not match tenant_id %q", req.Observation.TenantID, tenantID))
		return
	}
	req.Observation.TenantID = tenantID

	// SLAWS-P5-4: when ActorIsPseudonym is false and Actor is non-empty, pseudonymise
	// the actor using the same HMAC derivation the store uses before CEL evaluation.
	if !req.ActorIsPseudonym && req.Observation.Actor != "" {
		if h.store.HasPseudonymConfig() {
			ps, err := h.store.PseudonymiserFor(tenantID)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "pseudonymiser error: "+err.Error())
				return
			}
			pseudonym, err := ps.Pseudonym(req.Observation.Actor)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "pseudonymisation error: "+err.Error())
				return
			}
			req.Observation.Actor = pseudonym
		}
	}

	bundles := h.store.ObservationBundles(tenantID)

	resp := EvaluateObservationResponse{
		TenantID:    tenantID,
		DryRun:      true,
		Bundles:     make([]string, 0, len(bundles)),
		Findings:    make([]obscel.Finding, 0),
		Modes:       make(map[string]string, len(bundles)),
		EvaluatedAt: time.Now().UTC().Format(time.RFC3339),
	}

	for _, b := range bundles {
		resp.Bundles = append(resp.Bundles, b.ID+"@"+b.Version)
		resp.Modes[b.ID] = string(b.Mode)

		findings, err := h.evaluator.EvaluateObservation(req.Observation, b)
		resp.Findings = append(resp.Findings, findings...)
		if err != nil {
			resp.Faults = append(resp.Faults, fmt.Sprintf("bundle %s@%s: %v", b.ID, b.Version, err))
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

// LoadObservationBundles replaces the durable observation-bundle set from disk,
// keyed by tenant (SLAWS v2 §4.4). It returns the number of bundles loaded.
//
// Replace, not merge, is the whole point: the directory is the source of truth,
// so a bundle deleted from git must disappear on the next boot. Merging would
// make a removed rule keep firing until the pod was recreated with an empty
// cache, which is the kind of divergence between git and behaviour that policy
// as versioned code exists to eliminate.
//
// An unset or missing dir loads nothing and is not an error: policy-engine must
// boot in an estate that has not shipped a bundle yet. A malformed bundle IS an
// error, surfaced to the caller, because a half-loaded policy set is
// indistinguishable at runtime from one that chose to detect nothing.
func (s *PolicyStore) LoadObservationBundles(dir string) (int, error) {
	bundles, err := obscel.LoadBundleDir(dir)
	if err != nil {
		return 0, err
	}

	// SLAWS-P5-4: rewrite declared actor_vars with HMAC pseudonyms.
	// Fail closed if any bundle declares actor_vars but no pseudonym key is configured.
	for _, b := range bundles {
		if len(b.ActorVars) > 0 {
			if !s.HasPseudonymConfig() {
				return 0, fmt.Errorf("obscel: bundle %s declares actor_vars but SIGNAL_SEGMENT_PSEUDONYM_KEY is not configured", b.ID)
			}
			ps, err := s.PseudonymiserFor(b.TenantID)
			if err != nil {
				return 0, fmt.Errorf("obscel: creating pseudonymiser for bundle %s tenant %s: %w", b.ID, b.TenantID, err)
			}
			if err := obscel.PseudonymiseActorVars(b, ps.Pseudonym); err != nil {
				return 0, fmt.Errorf("obscel: pseudonymising actor vars for bundle %s: %w", b.ID, err)
			}
		}
	}

	byTenant := make(map[string][]*obscel.Bundle, len(bundles))
	for _, b := range bundles {
		byTenant[b.TenantID] = append(byTenant[b.TenantID], b)
	}
	// Canonical order per tenant so two boots over the same tree evaluate in the
	// same order, which the determinism contract requires of boot as well as of
	// replay. LoadBundleDir already returns sorted paths; this makes the
	// invariant independent of the file layout.
	for tenant := range byTenant {
		sort.Slice(byTenant[tenant], func(i, j int) bool {
			a, b := byTenant[tenant][i], byTenant[tenant][j]
			if a.ID != b.ID {
				return a.ID < b.ID
			}
			return a.Version < b.Version
		})
	}

	s.mu.Lock()
	s.obsBundles = byTenant
	s.mu.Unlock()

	return len(bundles), nil
}

// ObservationBundles returns the boot-loaded bundles for a tenant, in canonical
// order. The slice is a copy: a caller cannot reorder or extend the durable set
// through the value it was handed.
//
// Bundles registered over POST /api/v1/policies/bundles are deliberately absent
// from this set. That route is a dry-run surface (§4.4) and nothing it accepts
// survives a restart.
func (s *PolicyStore) ObservationBundles(tenantID string) []*obscel.Bundle {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]*obscel.Bundle(nil), s.obsBundles[tenantID]...)
}

// ObservationBundleTenants returns the tenants with at least one boot-loaded
// bundle, sorted. Used for the boot log line and by tests asserting the set.
func (s *PolicyStore) ObservationBundleTenants() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	tenants := make([]string, 0, len(s.obsBundles))
	for t := range s.obsBundles {
		tenants = append(tenants, t)
	}
	sort.Strings(tenants)
	return tenants
}
