package api

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

func (h *Handlers) handlePromoteActor(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	actor, err := h.Engine.PromoteActor(id)
	if err != nil {
		slog.Warn("promote failed", "id", id, "error", err)
		writeError(w, http.StatusNotFound, err.Error())
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
		slog.Error("audit write failed (actor_promoted)", "actor", id, "error", auditErr)
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
