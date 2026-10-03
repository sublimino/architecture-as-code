package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
)

func (h *Handlers) handlePromoteActor(w http.ResponseWriter, r *http.Request) {
	id, err := actorIDFromPath(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "actor id is required")
		return
	}

	// Another tenant's actor is answered exactly like an absent one, before anything changes.
	if visible, err := h.scopedActor(r, id); err != nil {
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	} else if visible == nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("actor %q not found", id))
		return
	}

	actor, err := h.Engine.PromoteActor(id)
	if err != nil {
		slog.Warn("promote failed", "id", id, "error", err)
		if errors.Is(err, correlation.ErrAlreadyPromoted) {
			writeError(w, http.StatusConflict, err.Error())
		} else {
			writeError(w, http.StatusNotFound, err.Error())
		}
		return
	}

	slog.Info("actor promoted", "id", id, "confidence", actor.Confidence)

	// Audit: actor_promoted — the highest-stakes event.
	detail, _ := json.Marshal(map[string]any{
		"confidence":     actor.Confidence,
		"evidence_count": len(actor.EvidenceChain),
		"status":         actor.Status,
	})
	if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
		TenantID:  "tenant-demo",
		EventType: audit.EventActorPromoted,
		ActorID:   actor.ID,
		Detail:    detail,
	}); auditErr != nil {
		slog.Error("audit write failed (actor_promoted); refusing promotion due to fail-closed audit policy", "actor", id, "error", auditErr)
		writeError(w, http.StatusServiceUnavailable, "actor promotion refused: audit trail persistence failed: "+auditErr.Error())
		return
	}

	// In a production deployment, this would call the fe-signalloom API
	// at /api/agents to register in the agent_registry PostgreSQL table.
	// For PoC, the in-memory actor store holds the promoted state.

	writeJSON(w, http.StatusOK, map[string]any{
		"promoted": true,
		"actor":    actor,
		"provenance": map[string]any{
			"evidence_count": len(actor.EvidenceChain),
			"confidence":     actor.Confidence,
		},
	})
}
