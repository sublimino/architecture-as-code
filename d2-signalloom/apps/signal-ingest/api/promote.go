package api

import (
	"log/slog"
	"net/http"
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
