package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// CreateDelegationRequest defines payload for POST /api/v1/delegations.
type CreateDelegationRequest struct {
	DelegateActorID   string         `json:"delegate_actor_id"`
	PrincipalActorID  string         `json:"principal_actor_id"`
	AuthzRef          string         `json:"authz_ref"`
	ValidFrom         *time.Time     `json:"valid_from,omitempty"`
	ValidTo           *time.Time     `json:"valid_to,omitempty"`
	Capabilities      []string       `json:"capabilities,omitempty"`
	ContainmentClaims []string       `json:"containment_claims,omitempty"`
	Signature         string         `json:"signature,omitempty"`
	Metadata          map[string]any `json:"metadata,omitempty"`
}

// ClampDelegationRequest defines payload for POST /api/v1/delegations/clamp.
type ClampDelegationRequest struct {
	DelegateActorID string     `json:"delegate_actor_id,omitempty"`
	AuthzRef        string     `json:"authz_ref,omitempty"`
	ClampTime       *time.Time `json:"clamp_time,omitempty"`
}

// handleCreateDelegation handles POST /api/v1/delegations.
func (h *Handlers) handleCreateDelegation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req CreateDelegationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if req.DelegateActorID == "" || req.PrincipalActorID == "" {
		writeError(w, http.StatusBadRequest, "delegate_actor_id and principal_actor_id are required")
		return
	}

	repo := h.resolveRepository()
	if repo == nil {
		writeError(w, http.StatusServiceUnavailable, "identity repository not configured")
		return
	}

	validFrom := time.Now().UTC()
	if req.ValidFrom != nil && !req.ValidFrom.IsZero() {
		validFrom = req.ValidFrom.UTC()
	}

	authzRef := req.AuthzRef
	if authzRef == "" {
		authzRef = fmt.Sprintf("claim-%s-%d", req.DelegateActorID, validFrom.Unix())
	}

	// 1. Verify capability claim boundaries and Landlock containment
	verifier := identity.NewCapabilityClaimVerifier(repo, h.Store)
	res, err := verifier.VerifyClaim(r.Context(), identity.CapabilityClaim{
		ClaimID:           authzRef,
		DelegateActorID:   req.DelegateActorID,
		PrincipalActorID:  req.PrincipalActorID,
		Capabilities:      req.Capabilities,
		ContainmentClaims: req.ContainmentClaims,
		Signature:         req.Signature,
		Metadata:          req.Metadata,
		ValidFrom:         validFrom,
		ValidTo:           req.ValidTo,
	})
	if err != nil {
		var scopeErr *identity.ScopeExceededError
		if errors.As(err, &scopeErr) {
			writeJSON(w, http.StatusForbidden, map[string]any{
				"error":                scopeErr.Error(),
				"violation":            "ScopeExceededError",
				"delegator_id":         scopeErr.DelegatorID,
				"missing_capabilities": scopeErr.MissingCapabilities,
			})
			return
		}
		if errors.Is(err, identity.ErrMissingLandlockClaim) {
			writeJSON(w, http.StatusForbidden, map[string]any{
				"error":     err.Error(),
				"violation": "MissingLandlockContainment",
			})
			return
		}
		if errors.Is(err, identity.ErrForgedClaim) || errors.Is(err, identity.ErrAttestationFailed) {
			writeJSON(w, http.StatusForbidden, map[string]any{
				"error":     err.Error(),
				"violation": "AttestationFailed",
			})
			return
		}
		if errors.Is(err, identity.ErrExpiredLease) {
			writeJSON(w, http.StatusForbidden, map[string]any{
				"error":     err.Error(),
				"violation": "ExpiredLease",
			})
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// 2. Auto-provision actors if not already registered in identity graph
	if _, err := repo.GetActor(r.Context(), req.DelegateActorID); errors.Is(err, identity.ErrActorNotFound) {
		_ = repo.CreateActor(r.Context(), identity.ActorRecord{
			ActorID:   req.DelegateActorID,
			Status:    model.ActorProvisional,
			Metadata:  map[string]any{"type": "agent", "auto_provisioned": true},
			CreatedAt: validFrom,
			UpdatedAt: validFrom,
		})
	}
	if _, err := repo.GetActor(r.Context(), req.PrincipalActorID); errors.Is(err, identity.ErrActorNotFound) {
		_ = repo.CreateActor(r.Context(), identity.ActorRecord{
			ActorID:   req.PrincipalActorID,
			Status:    model.ActorActionable,
			Metadata:  map[string]any{"type": "human", "auto_provisioned": true},
			CreatedAt: validFrom,
			UpdatedAt: validFrom,
		})
	}

	// 3. Persist delegation record into identity spine
	record := identity.DelegationRecord{
		DelegateActorID:  req.DelegateActorID,
		PrincipalActorID: req.PrincipalActorID,
		AuthzRef:         authzRef,
		ValidFrom:        validFrom,
		ValidTo:          req.ValidTo,
		Metadata:         req.Metadata,
		CreatedAt:        validFrom,
	}

	if err := repo.AddDelegation(r.Context(), record); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to persist delegation: %v", err))
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"status":            "created",
		"delegation":        record,
		"verified":          true,
		"landlock_verified": res.LandlockVerified,
		"capabilities":      res.Capabilities,
	})
}

// handleClampDelegation handles POST /api/v1/delegations/clamp.
func (h *Handlers) handleClampDelegation(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req ClampDelegationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	identifier := req.AuthzRef
	if identifier == "" {
		identifier = req.DelegateActorID
	}
	if identifier == "" {
		writeError(w, http.StatusBadRequest, "authz_ref or delegate_actor_id is required")
		return
	}

	repo := h.resolveRepository()
	if repo == nil {
		writeError(w, http.StatusServiceUnavailable, "identity repository not configured")
		return
	}

	clampTime := time.Now().UTC()
	if req.ClampTime != nil && !req.ClampTime.IsZero() {
		clampTime = req.ClampTime.UTC()
	}

	if err := repo.ClampDelegation(r.Context(), identifier, clampTime); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to clamp delegation: %v", err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":     "clamped",
		"identifier": identifier,
		"clamped_at": clampTime,
	})
}

// resolveRepository extracts the underlying identity.Repository from Handlers.IdentityStore.
func (h *Handlers) resolveRepository() identity.Repository {
	if h.IdentityStore == nil {
		return nil
	}
	if repo, ok := h.IdentityStore.(identity.Repository); ok {
		return repo
	}
	if store, ok := h.IdentityStore.(identity.ResolverStore); ok {
		return store.Repository()
	}
	return nil
}
