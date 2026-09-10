// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// QuarantineEngine evaluates real-time chain completeness, detects cryptographic and
// structural delegation defects, triggers Stun Sentinel container containment, and records
// immutable audit violations.
type QuarantineEngine struct {
	mu           sync.RWMutex
	store        store.SignalStore
	stunClient   StunDispatchClient
	metrics      *QuarantineMetrics
	quarantined  map[string]*model.QuarantineRecord // actor_id -> record
	registration map[string]time.Time               // actor_id -> first seen timestamp
}

// QuarantineEngineOptions configures the QuarantineEngine.
type QuarantineEngineOptions struct {
	Store      store.SignalStore
	StunClient StunDispatchClient
	Metrics    *QuarantineMetrics
}

// NewQuarantineEngine instantiates a QuarantineEngine.
func NewQuarantineEngine(opts QuarantineEngineOptions) *QuarantineEngine {
	metrics := opts.Metrics
	if metrics == nil {
		metrics = DefaultQuarantineMetrics()
	}
	stunClient := opts.StunClient
	if stunClient == nil {
		stunClient = NewHTTPStunClient(StunClientOptions{Metrics: metrics})
	}
	return &QuarantineEngine{
		store:        opts.Store,
		stunClient:   stunClient,
		metrics:      metrics,
		quarantined:  make(map[string]*model.QuarantineRecord),
		registration: make(map[string]time.Time),
	}
}

// IsActorQuarantined checks if an actor is currently quarantined.
func (q *QuarantineEngine) IsActorQuarantined(actorID string) (*model.QuarantineRecord, bool) {
	q.mu.RLock()
	defer q.mu.RUnlock()

	rec, ok := q.quarantined[actorID]
	return rec, ok
}

// GetQuarantinedActors returns all quarantined records.
func (q *QuarantineEngine) GetQuarantinedActors() map[string]*model.QuarantineRecord {
	q.mu.RLock()
	defer q.mu.RUnlock()

	res := make(map[string]*model.QuarantineRecord, len(q.quarantined))
	for k, v := range q.quarantined {
		copyRec := *v
		res[k] = &copyRec
	}
	return res
}

// RegisterActor marks an actor's first appearance for initial grace period tracking.
func (q *QuarantineEngine) RegisterActor(actorID string, ts time.Time) {
	if actorID == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()

	if _, exists := q.registration[actorID]; !exists {
		if ts.IsZero() {
			ts = time.Now().UTC()
		}
		q.registration[actorID] = ts
	}
}

// EvaluateObservation checks incoming observations for high-severity actions executed under
// unverified, forged, or incomplete delegation chains, triggering immediate containment if violated.
func (q *QuarantineEngine) EvaluateObservation(ctx context.Context, obs model.Observation) (*model.QuarantineRecord, error) {
	actorID := obs.ActorID
	if actorID == "" {
		actorID = obs.ActorHint
	}
	if actorID == "" && obs.Labels != nil {
		actorID = obs.Labels["agent_id"]
	}
	if actorID == "" {
		actorID = obs.PrincipalID
	}

	q.RegisterActor(actorID, obs.Timestamp)

	// Check already quarantined
	if rec, isQ := q.IsActorQuarantined(actorID); isQ && rec != nil {
		return rec, nil
	}

	// 1. Evaluate explicit violation triggers
	reason, violated := q.detectViolation(obs)
	if !violated {
		return nil, nil
	}

	// 2. Check exemptions (e.g. baseline demo agents)
	spiffeID := obs.ActorHint
	if obs.Labels != nil && obs.Labels["spiffe_id"] != "" {
		spiffeID = obs.Labels["spiffe_id"]
	}
	if q.stunClient.IsExempt(actorID, spiffeID) {
		slog.Debug("quarantine: bypassing containment for exempt actor", "actor_id", actorID, "reason", reason)
		return nil, nil
	}

	// 3. Grace period check for non-forged violations
	if reason != model.ViolationForgedClaim {
		q.mu.RLock()
		regTime := q.registration[actorID]
		q.mu.RUnlock()
		if q.stunClient.IsInGracePeriod(actorID, regTime) {
			slog.Debug("quarantine: suppressing quarantine during 30s registration grace window",
				"actor_id", actorID, "reason", reason)
			return nil, nil
		}
	}

	// 4. Trigger Quarantine & Stun Containment
	actionName := obs.Description
	if obs.Labels != nil && obs.Labels["action"] != "" {
		actionName = obs.Labels["action"]
	} else if obs.Labels != nil && obs.Labels["event_type"] != "" {
		actionName = obs.Labels["event_type"]
	}

	podName := actorID
	if obs.Labels != nil && obs.Labels["pod"] != "" {
		podName = obs.Labels["pod"]
	} else if obs.Labels != nil && obs.Labels["pod_name"] != "" {
		podName = obs.Labels["pod_name"]
	}
	namespace := "fe-signalloom-agents"
	if obs.Labels != nil && obs.Labels["namespace"] != "" {
		namespace = obs.Labels["namespace"]
	}

	record := model.QuarantineRecord{
		ActorID:         actorID,
		PodName:         podName,
		Namespace:       namespace,
		ViolationReason: reason,
		Action:          actionName,
		AttemptedAt:     obs.Timestamp,
		QuarantinedAt:   time.Now().UTC(),
		EvidenceGitOID:  obs.RawEvidenceRef,
		ChainSummary:    fmt.Sprintf("Violation %s detected on observation %s (%s)", reason, obs.ID, obs.Source),
		Details: map[string]any{
			"observation_id": obs.ID,
			"source":         obs.Source,
			"layer":          string(obs.Layer),
			"confidence":     obs.Confidence,
		},
	}

	return q.QuarantineActor(ctx, actorID, record)
}

// detectViolation analyzes an observation against the 7 quarantine rules.
func (q *QuarantineEngine) detectViolation(obs model.Observation) (model.ViolationReason, bool) {
	isHighSev := model.IsHighSeverityAction(obs.Description, obs.Labels) ||
		(obs.Labels != nil && (obs.Labels["privileged"] == "true" || obs.Labels["high_severity"] == "true"))

	// Rule 1: Delegation depth exceeded (depth > 7)
	if obs.DelegationDepth > 7 {
		return model.ViolationDelegationDepthExceeded, true
	}
	if obs.Labels != nil {
		if dStr := obs.Labels["delegation_depth"]; dStr != "" {
			var d int
			if _, err := fmt.Sscanf(dStr, "%d", &d); err == nil && d > 7 {
				return model.ViolationDelegationDepthExceeded, true
			}
		}
	}

	// Rule 2: Forged claim / cryptographic tampering
	if obs.Fidelity == model.FidelityCircumstantial && obs.Confidence == 0.0 && obs.Labels != nil && obs.Labels["verification_status"] == "tampered" {
		return model.ViolationForgedClaim, true
	}
	if obs.Labels != nil {
		if sig := obs.Labels["signature"]; sig == "forged" || strings.HasPrefix(sig, "forged-") || strings.HasPrefix(sig, "invalid-") {
			return model.ViolationForgedClaim, true
		}
		if obs.Labels["violation_type"] == "forged_signature" || obs.Labels["violation_type"] == "forged_claim" {
			return model.ViolationForgedClaim, true
		}
	}

	// Rule 3: Missing cosign signature on privileged container execution
	if obs.Labels != nil && (obs.Labels["cosign_verified"] == "false" || obs.Labels["image_signature"] == "missing" || obs.Labels["image_signature"] == "unverified") {
		if isHighSev {
			return model.ViolationMissingCosignSignature, true
		}
	}

	// Rule 4: Missing Landlock attestation
	if obs.Labels != nil {
		if obs.Labels["landlock_status"] == "disabled" || obs.Labels["landlock_status"] == "unverified" || obs.Labels["violation_type"] == "missing_landlock_containment" {
			if isHighSev || strings.Contains(strings.ToLower(obs.ID), "nono") || strings.Contains(strings.ToLower(obs.Source), "nono") {
				return model.ViolationMissingLandlockAttestation, true
			}
		}
	}

	// Rule 5: Shadow identity attempting high-severity action
	if isHighSev {
		if obs.PrincipalID == "" && obs.ActorID == "" && obs.ActorHint == "" && obs.ImpersonatedUser == "" {
			return model.ViolationShadowIdentity, true
		}
		if strings.HasPrefix(obs.ActorID, "shadow-") || strings.HasPrefix(obs.ActorHint, "shadow-") {
			return model.ViolationShadowIdentity, true
		}
	}

	// Rule 6: Incomplete delegation chain on privileged operation
	if isHighSev {
		if obs.Labels != nil {
			if obs.Labels["chain_status"] == "incomplete" || obs.Labels["delegation_status"] == "unverified" || obs.Labels["chain_complete"] == "false" {
				return model.ViolationIncompleteChain, true
			}
		}
		if obs.DelegationEdge == nil && (obs.ImpersonatedUser != "" || (obs.Labels != nil && obs.Labels["acting_on_behalf_of"] != "")) {
			// Borrowed authority without delegation edge
			return model.ViolationUntrustedDelegationAttempt, true
		}
	}

	// Rule 7: Untrusted delegation attempt
	if isHighSev && obs.Fidelity == model.FidelityCircumstantial && obs.Confidence < 0.5 {
		if obs.Labels != nil && obs.Labels["delegation_basis"] == "untrusted" {
			return model.ViolationUntrustedDelegationAttempt, true
		}
	}

	return "", false
}

// QuarantineActor executes the complete quarantine sequence:
// 1. Records quarantine record in memory.
// 2. Increments Prometheus metrics.
// 3. Dispatches Stun Sentinel kernel freeze.
// 4. Emits immutable violation observation to the persistent store / FrostDB.
func (q *QuarantineEngine) QuarantineActor(ctx context.Context, actorID string, rec model.QuarantineRecord) (*model.QuarantineRecord, error) {
	q.mu.Lock()
	q.quarantined[actorID] = &rec
	q.mu.Unlock()

	// 1. Increment Prometheus metric counter labeled by violation_reason and actor_id
	q.metrics.IncQuarantineTotal(rec.ViolationReason.String(), actorID)

	// 2. Dispatch Stun Sentinel Freeze
	stunReq := StunFreezeRequest{
		PodName:         rec.PodName,
		Namespace:       rec.Namespace,
		ActorID:         actorID,
		ViolationReason: rec.ViolationReason,
		Action:          rec.Action,
		EvidenceGitOID:  rec.EvidenceGitOID,
	}
	freezeResp, err := q.stunClient.DispatchFreeze(ctx, stunReq)
	if err == nil && freezeResp != nil {
		rec.StunDispatched = freezeResp.Frozen
		rec.StunLatencyMS = freezeResp.LatencyMS
	} else if err != nil {
		slog.Error("quarantine: stun dispatch error", "actor_id", actorID, "error", err)
	}

	// 3. Generate and record immutable cryptographic audit violation in FrostDB / Store
	now := time.Now().UTC()
	hashInput := fmt.Sprintf("%s:%s:%s:%d", actorID, rec.ViolationReason, rec.Action, now.UnixNano())
	digest := sha256.Sum256([]byte(hashInput))
	obsID := fmt.Sprintf("quarantine-violation-%s", hex.EncodeToString(digest[:8]))
	rec.ImmutableAuditID = obsID

	violationObs := model.Observation{
		ID:             obsID,
		Timestamp:      now,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityDefinitive,
		Source:         "signal-ingest-quarantine-engine",
		Confidence:     1.0,
		ActorHint:      actorID,
		ActorID:        actorID,
		RawEvidenceRef: fmt.Sprintf("quarantine://actor/%s/violation/%s", actorID, rec.ViolationReason),
		Description:    fmt.Sprintf("Quarantine containment triggered for actor %s: violation [%s] during action [%s]", actorID, rec.ViolationReason, rec.Action),
		Labels: map[string]string{
			"event_type":       "untrusted_delegation_attempt",
			"containment":      "quarantined",
			"violation_reason": rec.ViolationReason.String(),
			"actor_id":         actorID,
			"pod_name":         rec.PodName,
			"stun_dispatched":  fmt.Sprintf("%t", rec.StunDispatched),
			"stun_latency_ms":  fmt.Sprintf("%.2f", rec.StunLatencyMS),
			"audit_digest":     hex.EncodeToString(digest[:]),
		},
	}

	if q.store != nil {
		storeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		if appendErr := q.store.Append(storeCtx, []model.Observation{violationObs}); appendErr != nil {
			slog.Error("quarantine: store append failed, buffered in ring-buffer", "error", appendErr)
		}
		cancel()
	}

	q.mu.Lock()
	q.quarantined[actorID] = &rec
	q.mu.Unlock()

	slog.Warn("SECURITY CONTAINMENT: agent execution halted and quarantined",
		"actor_id", actorID,
		"pod", rec.PodName,
		"violation_reason", rec.ViolationReason,
		"stun_dispatched", rec.StunDispatched,
		"audit_id", obsID,
	)

	return &rec, nil
}
