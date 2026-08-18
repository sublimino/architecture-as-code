// Package api provides HTTP handlers for the signal-ingest service.
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Handlers holds shared state for all HTTP handlers.
type Handlers struct {
	Store  store.SignalStore
	Engine *correlation.Engine
	Audit  audit.AuditWriter

	// AuditReady, when non-nil, is called on every /readyz probe to verify
	// the audit backend is actually reachable. nil means there is nothing to
	// verify -- no DATABASE_URL was configured, so audit is deliberately off
	// and the pod is ready to serve without it.
	//
	// This is the visible half of the startup fix. Boot no longer blocks on
	// Postgres, so a pod whose audit trail is broken now STARTS; without this
	// hook that pod would report 1/1 Running and look identical to a healthy
	// one while writing nothing durable. Failing readiness takes it out of
	// the Service endpoints instead: `kubectl get pods` shows 0/1, which is
	// the loudest signal available short of crashing, and it stops traffic
	// reaching a replica that cannot record what it does.
	AuditReady func(context.Context) error
}

// readyCheckTimeout bounds the /readyz connectivity check. It must stay under
// the readinessProbe's own timeoutSeconds (3, in
// apps/signal-ingest/base/deployment.yaml) so the handler answers with a
// diagnosable 503 body rather than being cut off mid-check by the kubelet.
//
// Bounding this at all is the same lesson as the boot path: a NetworkPolicy
// drop produces silence, and an unbounded readiness check against silence
// hangs the probe instead of failing it.
const readyCheckTimeout = 2 * time.Second

// RegisterRoutes adds all API routes to the mux.
func (h *Handlers) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /readyz", h.handleReadyz)
	mux.HandleFunc("POST /api/v1/observations", h.handleIngestObservations)
	mux.HandleFunc("GET /api/v1/observations", h.handleQueryObservations)
	mux.HandleFunc("GET /api/v1/actors", h.handleListActors)
	mux.HandleFunc("GET /api/v1/actors/{id}", h.handleGetActor)
	mux.HandleFunc("POST /api/v1/actors/{id}/promote", h.handlePromoteActor)
	mux.HandleFunc("GET /api/v1/coverage", handleCoverage)
	mux.HandleFunc("POST /api/v1/correlate", h.handleCorrelate)
	mux.HandleFunc("POST /api/v1/collectors/seed", h.handleSeed)
	mux.HandleFunc("GET /api/v1/store/stats", h.handleStoreStats)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// handleHealthz answers liveness: the process is up and the mux is serving.
// It deliberately checks NOTHING external. Liveness failure means "restart
// me", and restarting cannot repair an unreachable database -- wiring a
// dependency in here would turn a Postgres outage into a CrashLoopBackOff,
// which is the failure this whole change exists to remove.
func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz answers readiness: the process is up AND can do its job,
// including recording an audit trail. Readiness failure means "send me no
// traffic", which is the correct response to an audit backend this replica
// cannot reach -- for a compliance product, serving requests it cannot record
// is worse than serving none.
//
// The check is live on every probe rather than a boot-time verdict cached in
// a bool. A cached verdict would be wrong in both directions: it would keep
// reporting ready after the database went away, and it would keep reporting
// not-ready long after the database came back, leaving a recovered pod out of
// the endpoints until someone noticed and restarted it.
func (h *Handlers) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if h.AuditReady == nil {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), readyCheckTimeout)
	defer cancel()

	if err := h.AuditReady(ctx); err != nil {
		slog.Warn("readiness: audit backend unreachable", "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "not_ready",
			"reason": "audit_backend_unreachable",
			"error":  err.Error(),
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (h *Handlers) handleIngestObservations(w http.ResponseWriter, r *http.Request) {
	var observations []model.Observation
	if err := json.NewDecoder(r.Body).Decode(&observations); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if len(observations) == 0 {
		writeError(w, http.StatusBadRequest, "at least one observation required")
		return
	}

	// Validate every observation before persisting any (atomic reject).
	for i, o := range observations {
		// Reject +Inf/-Inf that survived JSON decoding (e.g. 1e999).
		if math.IsInf(o.Confidence, 0) || math.IsNaN(o.Confidence) {
			writeError(w, http.StatusBadRequest,
				fmt.Sprintf("observation[%d]: confidence must be a finite number", i))
			return
		}
		if err := o.Validate(); err != nil {
			writeError(w, http.StatusBadRequest,
				fmt.Sprintf("observation[%d]: %s", i, err.Error()))
			return
		}
	}

	if err := h.Store.Append(r.Context(), observations); err != nil {
		slog.Error("append failed", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to store observations")
		return
	}

	slog.Info("observations ingested", "count", len(observations))
	writeJSON(w, http.StatusCreated, map[string]any{
		"ingested": len(observations),
	})
}

func (h *Handlers) handleQueryObservations(w http.ResponseWriter, r *http.Request) {
	q := store.Query{}

	if layers := r.URL.Query()["layer"]; len(layers) > 0 {
		for _, l := range layers {
			q.Layers = append(q.Layers, model.Layer(l))
		}
	}

	if after := r.URL.Query().Get("after"); after != "" {
		t, err := time.Parse(time.RFC3339, after)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid 'after' time: "+err.Error())
			return
		}
		q.After = t
	}

	if before := r.URL.Query().Get("before"); before != "" {
		t, err := time.Parse(time.RFC3339, before)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid 'before' time: "+err.Error())
			return
		}
		q.Before = t
	}

	if actor := r.URL.Query().Get("actor_id"); actor != "" {
		q.ActorID = actor
	}

	if limit := r.URL.Query().Get("limit"); limit != "" {
		n, err := strconv.Atoi(limit)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid 'limit': "+err.Error())
			return
		}
		if n < 0 {
			writeError(w, http.StatusBadRequest, "limit must be non-negative")
			return
		}
		q.Limit = n
	}

	obs, err := h.Store.QueryRange(r.Context(), q)
	if err != nil {
		slog.Error("query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}

	// encoding/json marshals a nil slice as `null`, not `[]`. A caller that
	// declared the field an array then dereferences null and crashes — which is
	// exactly what the dashboard's Weave page did on an empty result:
	//   Uncaught TypeError: Cannot read properties of null (reading 'length')
	// The contract is "a list of observations, possibly empty", so an empty
	// result must serialise as an empty list. handleListActors below already
	// does this; the asymmetry was the bug.
	if obs == nil {
		obs = []model.Observation{}
	}

	writeJSON(w, http.StatusOK, obs)
}

func (h *Handlers) handleListActors(w http.ResponseWriter, _ *http.Request) {
	actors := h.Engine.GetActors()
	if actors == nil {
		actors = []*model.ProvisionalActor{}
	}
	writeJSON(w, http.StatusOK, actors)
}

func (h *Handlers) handleGetActor(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	actor := h.Engine.GetActor(id)
	if actor == nil {
		writeError(w, http.StatusNotFound, "actor not found")
		return
	}
	writeJSON(w, http.StatusOK, actor)
}

func (h *Handlers) handleCorrelate(w http.ResponseWriter, r *http.Request) {
	actors, err := h.Engine.Correlate(r.Context())
	if err != nil {
		slog.Error("correlation failed", "error", err)
		writeError(w, http.StatusInternalServerError, "correlation failed: "+err.Error())
		return
	}

	// Audit: correlation_run
	detail, _ := json.Marshal(map[string]any{"actors_discovered": len(actors)})
	if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
		TenantID:  "tenant-demo",
		EventType: audit.EventCorrelationRun,
		Detail:    detail,
	}); auditErr != nil {
		slog.Error("audit write failed (correlation_run)", "error", auditErr)
	}

	// Audit: actor_created for any newly created actors
	for _, a := range actors {
		actorDetail, _ := json.Marshal(map[string]any{
			"actor_id":   a.ID,
			"confidence": a.Confidence,
			"status":     a.Status,
			"evidence":   len(a.EvidenceChain),
		})
		if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
			TenantID:  "tenant-demo",
			EventType: audit.EventActorCreated,
			ActorID:   a.ID,
			Detail:    actorDetail,
		}); auditErr != nil {
			slog.Error("audit write failed (actor_created)", "actor", a.ID, "error", auditErr)
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"actors_discovered": len(actors),
		"actors":            actors,
	})
}

func (h *Handlers) handleSeed(w http.ResponseWriter, r *http.Request) {
	obs := collectors.SeedAll(time.Now().UTC())
	if err := h.Store.Append(r.Context(), obs); err != nil {
		slog.Error("seed failed", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to seed fixtures")
		return
	}

	slog.Info("fixtures seeded", "count", len(obs))

	// Audit: collector_run
	seedDetail, _ := json.Marshal(map[string]any{"observations_seeded": len(obs)})
	if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
		TenantID:  "tenant-demo",
		EventType: audit.EventCollectorRun,
		Detail:    seedDetail,
	}); auditErr != nil {
		slog.Error("audit write failed (collector_run)", "error", auditErr)
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"seeded": len(obs),
	})
}

// StoreStatsResponse describes the current state of the signal store and engine.
type StoreStatsResponse struct {
	TotalObservations      int            `json:"total_observations"`
	ObservationsByLayer    map[string]int `json:"observations_by_layer"`
	ObservationsByFidelity map[string]int `json:"observations_by_fidelity"`
	ActorCount             int            `json:"actor_count"`
	ActorsByStatus         map[string]int `json:"actors_by_status"`
	LastIngestion          *time.Time     `json:"last_ingestion"`
	StoreType              string         `json:"store_type"`
}

func (h *Handlers) handleStoreStats(w http.ResponseWriter, r *http.Request) {
	// Query all observations from the store.
	obs, err := h.Store.QueryRange(r.Context(), store.Query{})
	if err != nil {
		slog.Error("store stats query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to query store")
		return
	}

	byLayer := make(map[string]int)
	byFidelity := make(map[string]int)
	var lastIngestion *time.Time

	for _, o := range obs {
		byLayer[string(o.Layer)]++
		byFidelity[string(o.Fidelity)]++
		if lastIngestion == nil || o.Timestamp.After(*lastIngestion) {
			t := o.Timestamp
			lastIngestion = &t
		}
	}

	actors := h.Engine.GetActors()
	byStatus := make(map[string]int)
	for _, a := range actors {
		byStatus[string(a.Status)]++
	}

	// Determine store type from the concrete implementation.
	storeType := fmt.Sprintf("%T", h.Store)

	resp := StoreStatsResponse{
		TotalObservations:      len(obs),
		ObservationsByLayer:    byLayer,
		ObservationsByFidelity: byFidelity,
		ActorCount:             len(actors),
		ActorsByStatus:         byStatus,
		LastIngestion:          lastIngestion,
		StoreType:              storeType,
	}

	writeJSON(w, http.StatusOK, resp)
}

// CoverageResponse describes the signal coverage state.
type CoverageResponse struct {
	CoveredLayers       []string    `json:"covered_layers"`
	BlindSpots          []BlindSpot `json:"blind_spots"`
	CloseableByIssuance []string    `json:"closeable_by_issuance"`
	DeploymentCoverage  string      `json:"deployment_coverage"`
}

// BlindSpot is a known gap in signal coverage.
type BlindSpot struct {
	ID          string `json:"id"`
	Layer       string `json:"layer"`
	Description string `json:"description"`
}

func handleCoverage(w http.ResponseWriter, _ *http.Request) {
	resp := CoverageResponse{
		CoveredLayers: []string{
			"network_egress",
			"identity_authorization",
			"application_saas",
			"endpoint_host",
			"behavioural",
		},
		BlindSpots: []BlindSpot{
			{ID: "local_transport", Layer: "network_egress", Description: "Agent communicating via Unix socket or localhost -- invisible at the network layer"},
			{ID: "session_inheritance", Layer: "identity_authorization", Description: "Agent riding a human's existing session -- no distinct identity signal"},
			{ID: "cloud_control_plane", Layer: "cloud_control_plane", Description: "Layer not deployed -- cloud API calls not observed"},
			{ID: "protocol_analysis", Layer: "protocol", Description: "Layer not deployed -- protocol-level signals not observed"},
			{ID: "encrypted_c2", Layer: "network_egress", Description: "Command-and-control over TLS to allowed destinations -- content invisible"},
		},
		CloseableByIssuance: []string{"local_transport", "session_inheritance"},
		DeploymentCoverage:  "5 of 7 layers active",
	}
	writeJSON(w, http.StatusOK, resp)
}
