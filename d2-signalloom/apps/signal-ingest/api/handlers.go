// Package api provides HTTP handlers for the signal-ingest service.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"sort"
	"strconv"
	"time"

	apiaudit "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/agentnono"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// Handlers holds shared state for all HTTP handlers.
type Handlers struct {
	Store     store.SignalStore
	Engine    *correlation.Engine
	Audit     audit.AuditWriter
	Encryptor identity.Encryptor

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

	// AuditReceiver handles APIServer audit webhooks at /api/v1/audit/webhook.
	AuditReceiver *apiaudit.WebhookReceiver

	// CollectorHealth, when non-nil, polls source readiness for live collectors.
	CollectorHealth func(context.Context) error

	// IdentityStore provides access to the persisted identity and delegation graph (SFDP-P3-2).
	IdentityStore any

	// FairService evaluates quantitative OpenFAIR risk (CRKC Phase 2).
	FairService *fair.Service

	// StunClient connects to Stun Sentinel daemon to issue containment drops.
	StunClient any

	// EventBus provides internal pub/sub event dispatching.
	EventBus any

	// Privacy is the GDPR Article 17 erasure gate (SLDP-P3-2). A nil Privacy makes the erasure
	// route answer 503: with no gate configured, no erasure may proceed. That is the fail-closed
	// direction — the alternative, erasing when unconfigured, is the defect the gate exists for.
	Privacy *privacy.Service
}

// Handlers contain application behavior only and do not authenticate requests.
// Production routes must be registered exclusively through NewProtectedRouter.

// readyCheckTimeout bounds the /readyz connectivity check. It must stay under
// the readinessProbe's own timeoutSeconds (3, in
// apps/signal-ingest/base/deployment.yaml) so the handler answers with a
// diagnosable 503 body rather than being cut off mid-check by the kubelet.
//
// Bounding this at all is the same lesson as the boot path: a NetworkPolicy
// drop produces silence, and an unbounded readiness check against silence
// hangs the probe instead of failing it.
const readyCheckTimeout = 2 * time.Second

func (h *Handlers) handleAuditWebhook(w http.ResponseWriter, r *http.Request) {
	if h.AuditReceiver == nil {
		writeError(w, http.StatusServiceUnavailable, "audit webhook receiver not configured")
		return
	}
	h.AuditReceiver.HandleAuditWebhook(w, r)
}

func (h *Handlers) handleNonoAudit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to read request body")
		return
	}
	defer r.Body.Close()

	if len(body) == 0 {
		writeError(w, http.StatusBadRequest, "empty request body")
		return
	}

	var event agentnono.NonoAuditEvent
	if err := json.Unmarshal(body, &event); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid json audit event: %v", err))
		return
	}

	verifier := agentnono.NewAuditVerifier(agentnono.VerifierConfig{
		TrustDomain: agentnono.DefaultTrustDomain,
	})
	res := verifier.VerifyEvent(&event)

	fidelity := model.FidelityDefinitive
	confidence := 1.0
	switch res.Status {
	case agentnono.StatusVerified:
		fidelity = model.FidelityDefinitive
		confidence = 1.0
	case agentnono.StatusTampered:
		fidelity = model.FidelityCircumstantial
		confidence = 0.0
	case agentnono.StatusUnverified, agentnono.StatusUnsigned:
		fidelity = model.FidelityCircumstantial
		confidence = 0.2
	}

	obs := model.Observation{
		ID:             fmt.Sprintf("nono-%s-%d", event.AuditSessionID, event.Seq),
		Timestamp:      event.Timestamp,
		Layer:          model.LayerEndpointHost,
		Fidelity:       fidelity,
		Source:         "agent-nono-evidenced",
		Confidence:     confidence,
		ActorHint:      event.SPIFFEID,
		RawEvidenceRef: fmt.Sprintf("nono://session/%s/event/%d", event.AuditSessionID, event.Seq),
		SessionID:      event.AuditSessionID,
		ActorID:        event.AgentID,
		Description:    fmt.Sprintf("Nono Landlock audit session event #%d (%s) [%s]", event.Seq, event.EventType, res.Status),
		Labels: map[string]string{
			"event_type":          event.EventType,
			"spiffe_id":           event.SPIFFEID,
			"agent_id":            event.AgentID,
			"verification_status": string(res.Status),
			"hash_chain_digest":   res.CalculatedDigest,
			"prev_digest":         event.PrevDigest,
			"signature_gitoid":    res.SignatureGitOID,
			"landlock_status":     event.Landlock.Status,
			"landlock_abi":        fmt.Sprintf("%d", event.Landlock.ABIVersion),
			"nono_available":      fmt.Sprintf("%t", event.NonoCapabilityAvailable),
		},
	}
	if event.DelegationChainID != "" {
		obs.Labels["delegation_chain_id"] = event.DelegationChainID
	}
	if event.Syscall != "" {
		obs.Labels["syscall"] = event.Syscall
	}
	if event.Path != "" {
		obs.Labels["path"] = event.Path
	}
	if event.DenialReason != "" {
		obs.Labels["denial_reason"] = event.DenialReason
	}

	if h.Store != nil {
		if err := h.Store.Append(r.Context(), []model.Observation{obs}); err != nil {
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to append observation: %v", err))
			return
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":              "accepted",
		"verification_status": res.Status,
		"observation_id":      obs.ID,
		"digest":              res.CalculatedDigest,
		"signature_gitoid":    res.SignatureGitOID,
	})
}

func (h *Handlers) handleGKECloudLogging(w http.ResponseWriter, r *http.Request) {
	if h.AuditReceiver == nil {
		writeError(w, http.StatusServiceUnavailable, "audit webhook receiver not configured")
		return
	}
	h.AuditReceiver.HandleGKECloudLogging(w, r)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// HealthResponse reports service liveness and effective protective controls posture.
type HealthResponse struct {
	Status     string                     `json:"status"`
	Encryption identity.EncryptionPosture `json:"encryption"`
	Audit      audit.AuditPosture         `json:"audit"`
}

// handleHealth answers health queries with full visibility into the effective protective controls posture.
// Operators can inspect this endpoint to verify encryption and audit enforcement directly.
func (h *Handlers) handleHealth(w http.ResponseWriter, _ *http.Request) {
	encPosture := identity.GetEncryptionPosture(h.Encryptor)
	auditPosture := audit.GetAuditPosture(h.Audit)

	status := "ok"
	if !encPosture.Healthy || !auditPosture.Healthy {
		status = "degraded"
	}

	resp := HealthResponse{
		Status:     status,
		Encryption: encPosture,
		Audit:      auditPosture,
	}
	writeJSON(w, http.StatusOK, resp)
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
// including recording an audit trail and connecting to live collector sources.
// Readiness failure means "send me no traffic".
func (h *Handlers) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), readyCheckTimeout)
	defer cancel()

	if h.AuditReady != nil {
		if err := h.AuditReady(ctx); err != nil {
			slog.Warn("readiness: audit backend unreachable", "error", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "not_ready",
				"reason": "audit_backend_unreachable",
				"error":  err.Error(),
			})
			return
		}
	}

	if h.CollectorHealth != nil {
		if err := h.CollectorHealth(ctx); err != nil {
			slog.Warn("readiness: collector source unhealthy", "error", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "not_ready",
				"reason": "collector_source_unhealthy",
				"error":  err.Error(),
			})
			return
		}
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

func (h *Handlers) handleListActors(w http.ResponseWriter, r *http.Request) {
	actors := h.Engine.GetActors()
	if limit, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && limit > 0 && len(actors) > limit {
		actors = actors[:limit]
	}
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

	returnedActors := actors
	if limit := requestLimit(r, len(actors)); limit < len(returnedActors) {
		returnedActors = returnedActors[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"actors_discovered": len(actors),
		"actors":            returnedActors,
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

func (h *Handlers) handleStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	// Initial connect frame
	fmt.Fprintf(w, "event: connected\ndata: {\"status\":\"connected\",\"time\":\"%s\"}\n\n", time.Now().UTC().Format(time.RFC3339))
	flusher.Flush()

	// Handle Last-Event-ID replay if provided
	lastEventID := r.Header.Get("Last-Event-ID")
	if lastEventID == "" {
		lastEventID = r.URL.Query().Get("last_event_id")
	}
	if lastEventID != "" {
		if t, err := time.Parse(time.RFC3339, lastEventID); err == nil {
			obs, err := h.Store.QueryRange(r.Context(), store.Query{After: t, Limit: 100})
			if err == nil {
				for _, o := range obs {
					data, _ := json.Marshal(o)
					fmt.Fprintf(w, "id: %s\nevent: observation\ndata: %s\n\n", o.Timestamp.UTC().Format(time.RFC3339), string(data))
				}
				flusher.Flush()
			}
		}
	}

	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			fmt.Fprintf(w, ":keepalive\n\n")
			flusher.Flush()
		}
	}
}

func (h *Handlers) handleGetAgentRisk(w http.ResponseWriter, r *http.Request) {
	if h.FairService == nil {
		writeError(w, http.StatusServiceUnavailable, "fair service not initialized")
		return
	}

	id := r.PathValue("id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "agent id is required")
		return
	}

	opts := fair.Options{}
	if trials := r.URL.Query().Get("trials"); trials != "" {
		if n, err := strconv.Atoi(trials); err == nil && n > 0 {
			opts.Trials = n
		}
	}
	if seed := r.URL.Query().Get("seed"); seed != "" {
		if s, err := strconv.ParseInt(seed, 10, 64); err == nil {
			opts.Seed = s
		}
	}
	if model := r.URL.Query().Get("model"); model != "" {
		opts.Model = fair.MagnitudeModel(model)
	}

	ass, err := h.FairService.Assess(id, opts)
	if err != nil {
		if errors.Is(err, fair.ErrUnknownAgent) {
			writeError(w, http.StatusNotFound, "agent not found")
			return
		}
		slog.Error("risk assessment failed", "agent", id, "error", err)
		writeError(w, http.StatusInternalServerError, "risk assessment failed: "+err.Error())
		return
	}

	tier := "monitored"
	if ass.ALE > 50000 {
		tier = "caged"
	}

	resp := map[string]any{
		"agentId":  ass.AgentID,
		"currency": "GBP",
		"lef": map[string]float64{
			"min":  ass.LEF.Min,
			"mode": ass.LEF.Mode,
			"max":  ass.LEF.Max,
		},
		"lossMagnitude": map[string]any{
			"min":  map[string]any{"amount": ass.LM.Min, "currency": "GBP"},
			"mode": map[string]any{"amount": ass.LM.Mode, "currency": "GBP"},
			"max":  map[string]any{"amount": ass.LM.Max, "currency": "GBP"},
		},
		"exposure": map[string]any{
			"ale":     map[string]any{"amount": ass.ALE, "currency": "GBP"},
			"var95":   map[string]any{"amount": ass.PML, "currency": "GBP"},
			"tvar":    map[string]any{"amount": ass.TVaR, "currency": "GBP"},
			"carried": map[string]any{"amount": ass.Carried, "currency": "GBP"},
		},
		"ale":     ass.ALE,
		"pml":     ass.PML,
		"var95":   ass.PML,
		"tvar":    ass.TVaR,
		"carried": ass.Carried,
		"tier":    tier,
		"simulation": map[string]any{
			"iterations":    ass.Trials,
			"seed":          ass.Seed,
			"riskLoad":      ass.RiskLoad,
			"tailDominated": ass.TailDominated,
			"guards": map[string]int{
				"shapeClamped":        ass.Guards.ShapeClamped,
				"midpointSubstituted": ass.Guards.MidpointSubstituted,
				"gammaNonFinite":      ass.Guards.GammaNonFinite,
				"poissonLoopCapped":   ass.Guards.PoissonLoopCapped,
			},
		},
		"computedAt": time.Now().UTC().Format(time.RFC3339),
		"source":     "riskctl",
	}

	writeJSON(w, http.StatusOK, resp)
}

func (h *Handlers) handleGetFleetRisk(w http.ResponseWriter, r *http.Request) {
	if h.FairService == nil {
		writeError(w, http.StatusServiceUnavailable, "fair service not initialized")
		return
	}

	agentIDs := h.FairService.AgentIDs()
	if len(agentIDs) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{
			"currency":   "GBP",
			"agentCount": 0,
			"exposure": map[string]any{
				"ale":     map[string]any{"amount": 0.0, "currency": "GBP"},
				"var95":   map[string]any{"amount": 0.0, "currency": "GBP"},
				"tvar":    map[string]any{"amount": 0.0, "currency": "GBP"},
				"carried": map[string]any{"amount": 0.0, "currency": "GBP"},
			},
			"topAgents":  []any{},
			"computedAt": time.Now().UTC().Format(time.RFC3339),
			"source":     "riskctl",
		})
		return
	}

	type topAgent struct {
		AgentID string         `json:"agentId"`
		ALE     map[string]any `json:"ale"`
		aleVal  float64
	}

	var totalALE, totalPML, totalTVaR, totalCarried float64
	var scoredAgents []topAgent

	for _, id := range agentIDs {
		ass, err := h.FairService.Assess(id, fair.Options{})
		if err != nil {
			continue
		}
		totalALE += ass.ALE
		totalPML += ass.PML
		totalTVaR += ass.TVaR
		totalCarried += ass.Carried
		scoredAgents = append(scoredAgents, topAgent{
			AgentID: id,
			ALE:     map[string]any{"amount": ass.ALE, "currency": "GBP"},
			aleVal:  ass.ALE,
		})
	}

	sort.Slice(scoredAgents, func(i, j int) bool {
		return scoredAgents[i].aleVal > scoredAgents[j].aleVal
	})

	topLimit := requestLimit(r, 5)
	if len(scoredAgents) < topLimit {
		topLimit = len(scoredAgents)
	}
	top := make([]map[string]any, topLimit)
	for i := 0; i < topLimit; i++ {
		top[i] = map[string]any{
			"agentId": scoredAgents[i].AgentID,
			"ale":     scoredAgents[i].ALE,
		}
	}

	resp := map[string]any{
		"currency":   "GBP",
		"agentCount": len(agentIDs),
		"exposure": map[string]any{
			"ale":     map[string]any{"amount": totalALE, "currency": "GBP"},
			"var95":   map[string]any{"amount": totalPML, "currency": "GBP"},
			"tvar":    map[string]any{"amount": totalTVaR, "currency": "GBP"},
			"carried": map[string]any{"amount": totalCarried, "currency": "GBP"},
		},
		"topAgents":  top,
		"computedAt": time.Now().UTC().Format(time.RFC3339),
		"source":     "riskctl",
	}

	writeJSON(w, http.StatusOK, resp)
}

func requestLimit(r *http.Request, fallback int) int {
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 {
		return n
	}
	return fallback
}
