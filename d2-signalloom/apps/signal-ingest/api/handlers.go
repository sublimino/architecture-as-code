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
	"sync"
	"time"

	apiaudit "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
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

	// CodingAgentStore provides persistence and analysis for CodingAgentTelemetry (SLCD-P5-1).
	CodingAgentStore codingagent.TelemetryStore

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

	// AuditVocabulary, when non-nil, is called on /readyz after AuditReady
	// passes: it reports whether the live signal_audit_trail constraint
	// admits every event type this service writes (audit.CheckVocabulary).
	// Live, 2026-10-03, a pod Ready on a database that rejected batch_chain
	// 503'd every batch; failing readiness instead stalls the rollout while
	// the previous pods keep serving.
	AuditVocabulary func(context.Context) error

	// ReadinessLogInterval bounds how often a failing vocabulary check is
	// logged (default defaultReadinessLogInterval, the readinessProbe
	// period): logged every interval while it fails, never once per probe.
	ReadinessLogInterval time.Duration

	// now is the clock for the readiness log throttle; nil is time.Now.
	now func() time.Time

	vocabLogMu    sync.Mutex
	vocabLoggedAt time.Time

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

	chainTracker *BatchChainTracker
	chainOnce    sync.Once
}

func (h *Handlers) getBatchChainTracker() *BatchChainTracker {
	h.chainOnce.Do(func() {
		if h.chainTracker == nil {
			h.chainTracker = NewBatchChainTracker(DefaultMaxEpochsPerSubject, DefaultWindowSizePerEpoch)
		}
	})
	return h.chainTracker
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
		w.Header().Set("Allow", "POST")
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

type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(b), nil
}

func (w *headResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if _, ok := w.(*headResponseWriter); ok {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
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
func (h *Handlers) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	encPosture := identity.GetEncryptionPosture(h.Encryptor)
	auditPosture := audit.GetAuditPosture(h.Audit)

	status := "ok"
	if !encPosture.Healthy || !auditPosture.Healthy {
		status = "degraded"
	}

	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
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
func handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// defaultReadinessLogInterval is the readinessProbe period
// (apps/signal-ingest/base/deployment.yaml leaves periodSeconds at 10).
const defaultReadinessLogInterval = 10 * time.Second

// vocabLogDue reports whether a failing vocabulary check should be logged
// now: once, then again only after ReadinessLogInterval has passed.
func (h *Handlers) vocabLogDue() bool {
	now := time.Now
	if h.now != nil {
		now = h.now
	}
	interval := h.ReadinessLogInterval
	if interval <= 0 {
		interval = defaultReadinessLogInterval
	}
	h.vocabLogMu.Lock()
	defer h.vocabLogMu.Unlock()
	t := now()
	if !h.vocabLoggedAt.IsZero() && t.Sub(h.vocabLoggedAt) < interval {
		return false
	}
	h.vocabLoggedAt = t
	return true
}

// handleReadyz answers readiness: the process is up AND can do its job,
// including recording an audit trail and connecting to live collector sources.
// Readiness failure means "send me no traffic".
func (h *Handlers) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), readyCheckTimeout)
	defer cancel()

	if h.AuditReady != nil {
		if err := h.AuditReady(ctx); err != nil {
			slog.Warn("readiness: audit backend unreachable", "error", err)
			if r != nil && r.Method == http.MethodHead {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "not_ready",
				"reason": "audit_backend_unreachable",
				"error":  err.Error(),
			})
			return
		}
	}

	if h.AuditVocabulary != nil {
		if err := h.AuditVocabulary(ctx); err != nil {
			body := map[string]string{
				"status": "not_ready",
				"reason": "audit_vocabulary_not_admitted",
				"error":  err.Error(),
			}
			var gap *audit.VocabularyError
			if errors.As(err, &gap) {
				body["missing_event_types"] = gap.MissingNames()
			}
			if h.vocabLogDue() {
				slog.Warn("readiness: audit_vocabulary_not_admitted",
					"missing_event_types", body["missing_event_types"], "error", err)
			}
			if r != nil && r.Method == http.MethodHead {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			writeJSON(w, http.StatusServiceUnavailable, body)
			return
		}
	}

	if h.CollectorHealth != nil {
		if err := h.CollectorHealth(ctx); err != nil {
			slog.Warn("readiness: collector source unhealthy", "error", err)
			if r != nil && r.Method == http.MethodHead {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "not_ready",
				"reason": "collector_source_unhealthy",
				"error":  err.Error(),
			})
			return
		}
	}

	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (h *Handlers) handleIngestObservations(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	chainHeaders, err := parseChainHeaders(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_batch_chain: "+err.Error())
		return
	}

	maxBytes := getMaxBodyBytes()
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "payload too large")
			return
		}
		writeError(w, http.StatusBadRequest, "failed to read request body: "+err.Error())
		return
	}

	digest := computeBodyDigest(body)

	var observations []model.Observation
	if err := json.Unmarshal(body, &observations); err != nil {
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

	if err := bindWriteTenancy(r, observations); err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}

	subject := "anonymous"
	tenantID := "default"
	if p, ok := PrincipalFromContext(r.Context()); ok {
		if p.Subject != "" {
			subject = p.Subject
		}
		if p.TenantID != "" {
			tenantID = p.TenantID
		}
	} else if tc, ok := TenantContextFromContext(r.Context()); ok {
		if tc.Principal != "" {
			subject = tc.Principal
		}
		if tc.TenantID != "" {
			tenantID = tc.TenantID
		}
	}

	tracker := h.getBatchChainTracker()

	if chainHeaders == nil {
		// Unchained sender: count, log, and audit first per subject per hour
		slog.Info("unchained observations received", "subject", subject, "count", len(observations))
		if tracker.ShouldAuditUnchained(subject) {
			detail := BatchChainDetail{
				Outcome: OutcomeUnchained,
				Subject: subject,
			}
			detailJSON, _ := json.Marshal(detail)
			auditEv := audit.Event{
				TenantID:  tenantID,
				EventType: audit.EventBatchChain,
				Detail:    detailJSON,
				CreatedAt: time.Now().UTC(),
			}
			if h.Audit == nil {
				writeError(w, http.StatusServiceUnavailable, "audit trail unavailable")
				return
			}
			if err := h.Audit.WriteAuditEvent(r.Context(), auditEv); err != nil {
				slog.Error("audit write failed for unchained batch", "error", err)
				writeError(w, http.StatusServiceUnavailable, "audit trail unavailable: "+err.Error())
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
		return
	}

	classification := tracker.Classify(subject, chainHeaders, digest)

	if classification.Outcome == OutcomeReplayed {
		// Duplicate batch: write audit event, do not append to store, answer 201 {"ingested":0, "duplicate":true}
		detailJSON, _ := json.Marshal(classification.Detail)
		auditEv := audit.Event{
			TenantID:  tenantID,
			EventType: audit.EventBatchChain,
			Detail:    detailJSON,
			CreatedAt: time.Now().UTC(),
		}
		if h.Audit == nil {
			writeError(w, http.StatusServiceUnavailable, "audit trail unavailable")
			return
		}
		if err := h.Audit.WriteAuditEvent(r.Context(), auditEv); err != nil {
			slog.Error("audit write failed for replayed batch", "error", err)
			writeError(w, http.StatusServiceUnavailable, "audit trail unavailable: "+err.Error())
			return
		}

		slog.Info("replayed batch ignored", "subject", subject, "epoch", chainHeaders.Epoch, "seq", chainHeaders.Seq)
		writeJSON(w, http.StatusCreated, map[string]any{
			"ingested":  0,
			"duplicate": true,
		})
		return
	}

	// For any non-contiguous outcome, write ONE audit event before Append
	if classification.Outcome != OutcomeContiguous {
		detailJSON, _ := json.Marshal(classification.Detail)
		auditEv := audit.Event{
			TenantID:  tenantID,
			EventType: audit.EventBatchChain,
			Detail:    detailJSON,
			CreatedAt: time.Now().UTC(),
		}
		if h.Audit == nil {
			writeError(w, http.StatusServiceUnavailable, "audit trail unavailable")
			return
		}
		if err := h.Audit.WriteAuditEvent(r.Context(), auditEv); err != nil {
			slog.Error("audit write failed for batch chain event", "outcome", classification.Outcome, "error", err)
			writeError(w, http.StatusServiceUnavailable, "audit trail unavailable: "+err.Error())
			return
		}
	}

	if err := h.Store.Append(r.Context(), observations); err != nil {
		slog.Error("append failed", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to store observations")
		return
	}

	// Advance tracker state after successful Append
	tracker.Advance(subject, chainHeaders, digest, classification.Outcome)

	slog.Info("observations ingested", "count", len(observations))
	writeJSON(w, http.StatusCreated, map[string]any{
		"ingested": len(observations),
	})
}

func (h *Handlers) handleQueryObservations(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}

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

	// Tenancy filter runs before the limit; see scopeObservations.
	tenant, all := observationReadScope(r)
	limit := q.Limit
	q.Limit = 0
	obs, err := h.Store.QueryRange(r.Context(), q)
	if err != nil {
		slog.Error("query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	// One row per derived ID. The write-side Deduper stops new duplicates; it
	// cannot repair segments written before it existed, and those are the ones
	// Weave reads. This runs BEFORE the limit is applied, so a page is `limit`
	// distinct observations rather than `limit` rows of which some are copies.
	obs = store.DedupeByID(obs)
	obs = scopeObservations(obs, tenant, all, limit)

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
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}

	actors, err := h.scopedActors(r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	if limit, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && limit > 0 && len(actors) > limit {
		actors = actors[:limit]
	}
	if actors == nil {
		actors = []*model.ProvisionalActor{}
	}
	writeJSON(w, http.StatusOK, actors)
}

func (h *Handlers) handleGetActor(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	id, err := actorIDFromPath(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "actor id is required")
		return
	}
	actor, err := h.scopedActor(r, id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	if actor == nil {
		writeError(w, http.StatusNotFound, "actor not found")
		return
	}
	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, actor)
}

func (h *Handlers) handleCorrelate(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	actors, err := h.Engine.Correlate(r.Context())
	if err != nil {
		slog.Error("correlation failed", "error", err)
		writeError(w, http.StatusInternalServerError, "correlation failed: "+err.Error())
		return
	}

	// Audit: correlation_run
	tenantID := resolveAuditTenant(r)
	detail, _ := json.Marshal(map[string]any{"actors_discovered": len(actors)})
	if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
		TenantID:  tenantID,
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
			TenantID:  tenantID,
			EventType: audit.EventActorCreated,
			ActorID:   a.ID,
			Detail:    actorDetail,
		}); auditErr != nil {
			slog.Error("audit write failed (actor_created)", "actor", a.ID, "error", auditErr)
		}
	}

	// Correlation runs over the whole store; what it reports back is scoped like any read.
	scope, err := h.actorScopeFor(r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "query failed")
		return
	}
	actors = scope.filter(actors)
	returnedActors := actors
	if limit := requestLimit(r, len(actors)); limit < len(returnedActors) {
		returnedActors = returnedActors[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"actors_discovered": len(actors),
		"actors":            returnedActors,
	})
}

// projectSeedLabels drops fixture label keys the backing store's segment allow-list would refuse.
//
// The fixtures predate the FrostDB allow-list and carry keys it deliberately excludes (src_ip,
// principal_email, destination, ...); FrostDBStore.Append refuses a whole batch on the first one,
// which made the /feeds "Seed Fixtures" button a guaranteed 500 on every durable-store pod. The
// allow-list is a privacy control, so the fixtures bend to it rather than the reverse. A store
// without an allow-list (the in-memory store) keeps every label.
func projectSeedLabels(s store.SignalStore, obs []model.Observation) {
	type labelPolicy interface{ AllowsLabelKey(string) bool }
	type unwrapper interface{ Unwrap() store.SignalStore }
	for {
		if p, ok := s.(labelPolicy); ok {
			for i := range obs {
				for k := range obs[i].Labels {
					if !p.AllowsLabelKey(k) {
						delete(obs[i].Labels, k)
					}
				}
			}
			return
		}
		u, ok := s.(unwrapper)
		if !ok {
			return
		}
		s = u.Unwrap()
	}
}

func (h *Handlers) handleSeed(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	obs := collectors.SeedAll(time.Now().UTC())
	projectSeedLabels(h.Store, obs)
	if err := bindWriteTenancy(r, obs); err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	if err := h.Store.Append(r.Context(), obs); err != nil {
		slog.Error("seed failed", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to seed fixtures")
		return
	}

	slog.Info("fixtures seeded", "count", len(obs))

	// Audit: collector_run
	tenantID := resolveAuditTenant(r)
	seedDetail, _ := json.Marshal(map[string]any{"observations_seeded": len(obs)})
	if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
		TenantID:  tenantID,
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
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}

	// Query all observations from the store.
	obs, err := h.Store.QueryRange(r.Context(), store.Query{})
	if err != nil {
		slog.Error("store stats query failed", "error", err)
		writeError(w, http.StatusInternalServerError, "failed to query store")
		return
	}
	tenant, all := observationReadScope(r)
	obs = scopeObservations(obs, tenant, all, 0)

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

	actors, err := h.scopedActors(r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to query store")
		return
	}
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

func handleCoverage(w http.ResponseWriter, r *http.Request) {
	if r != nil && r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}

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
			// Deployed, not fed. The layer is in model.InScopeLayers() and the
			// correlation rules already pair against it, so "not deployed" sent an
			// operator looking for a missing layer instead of a missing collector.
			// It remains a blind spot until one lands: no cloud observations are
			// arriving either way, which is why the counts below are unchanged.
			{ID: "cloud_control_plane", Layer: "cloud_control_plane", Description: "Layer deployed, awaiting a collector -- no collector is feeding cloud API calls yet"},
			// The k8saudit-kube collector and the kusari-k8s-audit bundle exist but
			// the collector defaults off (COLLECTOR_K8SAUDIT_KUBE_MODE), so like
			// cloud_control_plane this layer is deployed-not-fed until enabled.
			{ID: "kubernetes_audit", Layer: "kubernetes", Description: "Layer deployed with the k8saudit-kube collector and bundle, awaiting enablement -- no kube-apiserver audit stream is being fed yet"},
			// Unlike the above, protocol genuinely is out of scope: it is absent from
			// model.InScopeLayers() and nothing evaluates against it.
			{ID: "protocol_analysis", Layer: "protocol", Description: "Layer not deployed -- protocol-level signals not observed"},
			{ID: "encrypted_c2", Layer: "network_egress", Description: "Command-and-control over TLS to allowed destinations -- content invisible"},
		},
		CloseableByIssuance: []string{"local_transport", "session_inheritance"},
	}
	// Derive the denominator from the layer enum so adding a layer (e.g.
	// kubernetes) can never leave this reading a stale "of N" — the defect that
	// shipped when LayerKubernetes was added while this said "5 of 7".
	resp.DeploymentCoverage = fmt.Sprintf("%d of %d layers active", len(resp.CoveredLayers), len(model.ValidLayers()))
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handlers) handleStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		return
	}

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
			obs, err := h.Store.QueryRange(r.Context(), store.Query{After: t})
			if err == nil {
				tenant, all := observationReadScope(r)
				obs = scopeObservations(obs, tenant, all, 100)
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
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !requireCrossTenantRead(w, r) {
		return
	}
	if h.FairService == nil {
		writeError(w, http.StatusServiceUnavailable, "fair service not initialized")
		return
	}

	id, err := actorIDFromPath(r)
	if err != nil {
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

	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handlers) handleGetFleetRisk(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !requireCrossTenantRead(w, r) {
		return
	}
	if h.FairService == nil {
		writeError(w, http.StatusServiceUnavailable, "fair service not initialized")
		return
	}

	agentIDs := h.FairService.AgentIDs()
	if len(agentIDs) == 0 {
		if r != nil && r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"currency": "GBP",
			// An empty fleet carries a genuine zero: there is nothing to assess,
			// so the totals cover the whole (empty) population. The coverage
			// fields are emitted here too so a consumer never has to treat
			// their absence as meaningful.
			"agentCount":       0,
			"agentsAssessed":   0,
			"agentsUnassessed": []string{},
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
	// An agent that cannot be assessed is skipped, so the totals below cover a
	// SUBSET of the fleet. That subset is reported explicitly: a fleet exposure
	// figure is the most quotable number this service publishes, and one that
	// silently omits agents while being labelled with the full fleet size
	// understates risk in a way no consumer can detect. Collected, not just
	// counted, so the gap is actionable.
	agentsUnassessed := make([]string, 0)

	for _, id := range agentIDs {
		ass, err := h.FairService.Assess(id, fair.Options{})
		if err != nil {
			slog.Warn("fleet risk: agent excluded from totals",
				"agent", id, "error", err)
			agentsUnassessed = append(agentsUnassessed, id)
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
		"currency": "GBP",
		// Fleet size, which is NOT the population of the totals below whenever
		// an agent could not be assessed. The two are reported separately
		// rather than conflated: agentsAssessed is the figure the exposure
		// actually covers, and agentCount == agentsAssessed is the only case in
		// which the totals describe the whole fleet.
		"agentCount":       len(agentIDs),
		"agentsAssessed":   len(scoredAgents),
		"agentsUnassessed": agentsUnassessed,
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

	if r != nil && r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func requestLimit(r *http.Request, fallback int) int {
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 {
		return n
	}
	return fallback
}
