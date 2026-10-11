// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

const (
	defaultLandlockRuleID   = "landlock-verified-denial"
	defaultLandlockWindowID = "landlock-denial-burst"
	defaultLandlockWindow   = 5 * time.Minute

	// ViolationLandlockDenial identifies a verified Landlock denial as the reason for containment.
	ViolationLandlockDenial model.ViolationReason = "landlock_denial"
)

// RemoteStunRequester requests containment without coupling signal-ingest to the fleet-manager module.
type RemoteStunRequester interface {
	RequestRemoteStun(clusterID, namespace, name, reason, requestedBy string)
}

// DispatchOptions configures decision matching, de-duplication, and remote targeting.
type DispatchOptions struct {
	Now       func() time.Time
	Window    time.Duration
	ClusterID string
	RuleID    string
	WindowID  string
	Logger    *slog.Logger
}

// DispatchOutcome reports whether and how a matching decision was handled.
type DispatchOutcome struct {
	Skipped         bool
	Deduped         bool
	LocalExempt     bool
	LocalDispatched bool
	WorkloadKey     string
	Reason          string
	FreezeResponse  *StunFreezeResponse
}

// DecisionStunDispatcher routes verified Landlock-denial decisions to local and remote containment.
type DecisionStunDispatcher struct {
	local     StunDispatchClient
	remote    RemoteStunRequester
	now       func() time.Time
	window    time.Duration
	clusterID string
	ruleID    string
	windowID  string
	logger    *slog.Logger

	mu      sync.Mutex
	handled map[string]time.Time
}

// NewDecisionStunDispatcher constructs a concurrency-safe decision-to-stun dispatcher.
func NewDecisionStunDispatcher(
	local StunDispatchClient,
	remote RemoteStunRequester,
	opts DispatchOptions,
) *DecisionStunDispatcher {
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	window := opts.Window
	if window <= 0 {
		window = defaultLandlockWindow
	}
	ruleID := opts.RuleID
	if ruleID == "" {
		ruleID = defaultLandlockRuleID
	}
	windowID := opts.WindowID
	if windowID == "" {
		windowID = defaultLandlockWindowID
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}

	return &DecisionStunDispatcher{
		local:     local,
		remote:    remote,
		now:       now,
		window:    window,
		clusterID: opts.ClusterID,
		ruleID:    ruleID,
		windowID:  windowID,
		logger:    logger,
		handled:   make(map[string]time.Time),
	}
}

// Matches reports whether a decision and its triggering observation represent a verified Landlock denial.
func (d *DecisionStunDispatcher) Matches(dec obscel.Decision, trigger model.Observation) bool {
	if d == nil || dec.RuleID != d.ruleID || dec.WindowID != d.windowID {
		return false
	}
	if trigger.Layer != model.LayerEndpointHost {
		return false
	}
	verificationStatus := trigger.Labels["verification_status"]
	return (verificationStatus == "verified" || verificationStatus == "VERIFIED") &&
		trigger.Labels["denial_reason"] != ""
}

// Dispatch sends one containment request per tenant, decision window, and workload within the configured duration.
func (d *DecisionStunDispatcher) Dispatch(
	ctx context.Context,
	dec obscel.Decision,
	trigger model.Observation,
) (DispatchOutcome, error) {
	if !d.Matches(dec, trigger) {
		return DispatchOutcome{Skipped: true, Reason: "not a landlock-denial decision"}, nil
	}

	// FrostDB segment-schema v2 pseudonymises ActorID/ActorHint, so keying on
	// either would make a dispatch over a read-back observation disagree with the
	// live one and defeat de-duplication. The agent_id / spiffe_id LABELS are
	// copied verbatim (never pseudonymised), so they are the stable workload
	// identity. Source scopes the key so two collectors reporting the same agent
	// cannot collide on one counter.
	workloadKey := firstNonEmpty(
		trigger.Labels["agent_id"],
		trigger.Labels["spiffe_id"],
	)
	idempotencyKey := dec.TenantID + "|" + dec.WindowID + "|" + trigger.Source + "|" + workloadKey
	now := d.now()

	d.mu.Lock()
	for key, handledAt := range d.handled {
		if now.Sub(handledAt) > d.window {
			delete(d.handled, key)
		}
	}
	if _, alreadyHandled := d.handled[idempotencyKey]; alreadyHandled {
		d.mu.Unlock()
		return DispatchOutcome{
			Deduped:     true,
			WorkloadKey: workloadKey,
			Reason:      "already handled within stun window",
		}, nil
	}
	d.handled[idempotencyKey] = now
	d.mu.Unlock()

	denialReason := trigger.Labels["denial_reason"]
	reason := "landlock-denial: " + denialReason +
		" (rule=" + dec.RuleID + ", window=" + dec.WindowID + ")"
	outcome := DispatchOutcome{WorkloadKey: workloadKey, Reason: reason}
	if d.local == nil && d.remote == nil {
		outcome.Skipped = true
		outcome.Reason = "no stun clients configured"
		return outcome, nil
	}

	// Same reason as the idempotency key: target the workload by its cleartext
	// label identity, never the pseudonymisable ActorID/ActorHint fields.
	agentID := firstNonEmpty(trigger.Labels["agent_id"], trigger.Labels["spiffe_id"])
	spiffeID := trigger.Labels["spiffe_id"]
	namespace := firstNonEmpty(parseSpiffeNamespace(spiffeID), trigger.Labels["namespace"])
	podName := firstNonEmpty(trigger.Labels["pod"], trigger.Labels["pod_name"], agentID)

	var dispatchErr error
	if d.local != nil {
		if d.local.IsExempt(agentID, spiffeID) {
			outcome.LocalExempt = true
			d.logger.Info(
				"landlock denial stun skipped for exempt local workload",
				"tenant_id", dec.TenantID,
				"window_id", dec.WindowID,
				"workload_key", workloadKey,
				"actor_id", agentID,
				"spiffe_id", spiffeID,
			)
		} else {
			outcome.LocalDispatched = true
			response, err := d.local.DispatchFreeze(ctx, StunFreezeRequest{
				PodName:         podName,
				Namespace:       namespace,
				ActorID:         agentID,
				SPIFFEID:        spiffeID,
				ViolationReason: ViolationLandlockDenial,
				Action:          reason,
				EvidenceGitOID:  trigger.Labels["signature_gitoid"],
			})
			outcome.FreezeResponse = response
			if err != nil {
				wrapped := fmt.Errorf(
					"dispatch local landlock-denial stun for tenant %q workload %q: %w",
					dec.TenantID,
					workloadKey,
					err,
				)
				d.logger.Error(
					"local landlock denial stun failed",
					"tenant_id", dec.TenantID,
					"window_id", dec.WindowID,
					"workload_key", workloadKey,
					"error", wrapped,
				)
				dispatchErr = errors.Join(dispatchErr, wrapped)
			}
		}
	}

	if d.remote != nil {
		name := firstNonEmpty(agentID, workloadKey)
		d.remote.RequestRemoteStun(
			d.clusterID,
			namespace,
			name,
			reason,
			"signalloom-policy-engine",
		)
	}

	return outcome, dispatchErr
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func parseSpiffeNamespace(spiffe string) string {
	segments := strings.Split(spiffe, "/")
	for index := 0; index+1 < len(segments); index++ {
		if segments[index] == "ns" && segments[index+1] != "" {
			return segments[index+1]
		}
	}
	return ""
}
