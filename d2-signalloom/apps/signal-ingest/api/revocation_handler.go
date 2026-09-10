package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// RevokeDelegationRequest defines payload for POST /api/v1/delegations/revoke.
type RevokeDelegationRequest struct {
	DelegationID string     `json:"delegation_id,omitempty"`
	ActorID      string     `json:"actor_id,omitempty"`
	DelegateID   string     `json:"delegate_id,omitempty"`
	AuthzRef     string     `json:"authz_ref,omitempty"`
	AgentIP      string     `json:"agent_ip,omitempty"`
	Reason       string     `json:"reason,omitempty"`
	RevokedAt    *time.Time `json:"revoked_at,omitempty"`
}

// handleRevokeDelegations handles POST /api/v1/delegations/revoke.
func (h *Handlers) handleRevokeDelegations(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req RevokeDelegationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	target := req.DelegationID
	if target == "" {
		target = req.ActorID
	}
	if target == "" {
		target = req.DelegateID
	}
	if target == "" {
		target = req.AuthzRef
	}
	if target == "" {
		writeError(w, http.StatusBadRequest, "delegation_id, actor_id, delegate_id, or authz_ref is required")
		return
	}

	repo := h.resolveRepository()
	if repo == nil {
		writeError(w, http.StatusServiceUnavailable, "identity repository not configured")
		return
	}

	start := time.Now()
	revokedAt := time.Now().UTC()
	if req.RevokedAt != nil && !req.RevokedAt.IsZero() {
		revokedAt = req.RevokedAt.UTC()
	}

	if err := repo.RevokeActiveDelegations(r.Context(), target, revokedAt); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to revoke delegations: %v", err))
		return
	}

	// Also update provisional actor in correlation engine if present
	if h.Engine != nil {
		for _, a := range h.Engine.GetActors() {
			matches := a.ID == target || a.CanonicalID == target
			if !matches {
				for _, alias := range a.Aliases {
					if alias == target {
						matches = true
						break
					}
				}
			}
			if matches {
				a.Status = model.ActorRevoked
				a.UpdatedAt = revokedAt
			}
		}
	}

	// Dispatch stun-tcctl drop command to Stun Sentinel if IP provided
	stunDispatched := false
	if req.AgentIP != "" {
		if stunClient, ok := h.StunClient.(identity.StunSentinelClient); ok && stunClient != nil {
			_, err := identity.DispatchDropWithRetry(r.Context(), stunClient, identity.DropEgressRequest{
				AgentID:   target,
				IP:        req.AgentIP,
				Reason:    req.Reason,
				Timestamp: revokedAt,
			}, 3)
			if err == nil {
				stunDispatched = true
			}
		}
	}

	// Broadcast revocation and cache flush over event bus if configured
	if bus, ok := h.EventBus.(identity.EventBus); ok && bus != nil {
		_ = bus.Publish(r.Context(), identity.TopicDelegationRevoked, identity.DelegationRevokedEvent{
			ActorID:   target,
			RevokedAt: revokedAt,
			AgentIP:   req.AgentIP,
			Reason:    req.Reason,
		})
		_ = bus.Publish(r.Context(), identity.TopicCacheFlush, target)
	}

	elapsed := time.Since(start)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":               "revoked",
		"identifier":           target,
		"revoked_at":           revokedAt,
		"latency_ms":           float64(elapsed.Microseconds()) / 1000.0,
		"stun_drop_dispatched": stunDispatched,
	})
}

// handleRevokeDelegation is an alias for handleRevokeDelegations.
func (h *Handlers) handleRevokeDelegation(w http.ResponseWriter, r *http.Request) {
	h.handleRevokeDelegations(w, r)
}
