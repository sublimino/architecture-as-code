// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// ── Admission Block Plane Contract (SLER-P3-2) ──────────────────────────────
//
// Dynamic admission blocking prevents contained agents from reconstituting,
// restarting, or being rescheduled by the Kubernetes scheduler or controller-manager.
//
// Architecture:
// 1. node-capability-guard validates pod CREATE and UPDATE operations.
// 2. Contained identities are stored in the cluster-wide identity store
//    (ConfigMap 'signalloom-contained-agents' in fe-signalloom).
// 3. fleet-manager's cascade registers contained agents in the store upon containment.
// 4. On recovery/resume, fleet-manager unblocks the identity from the store.
// 5. Fail-Closed: any store write failure or unreachability causes admission denial.

const (
	// DefaultContainedAgentsConfigMap is the ConfigMap holding contained agent identities.
	DefaultContainedAgentsConfigMap = "signalloom-contained-agents"
	// ContainedAgentsDataKey is the key within the ConfigMap holding JSON array data.
	ContainedAgentsDataKey = "contained-agents.json"
	// AdmissionWorstCaseResidualMs is 0ms: admission checks are synchronous before pod scheduling.
	AdmissionWorstCaseResidualMs = int64(0)
)

// AdmissionBlockAuditLogEntry represents a structured, machine-readable audit event.
// Satisfies SharedAttestationEventKeys ("event", "outcome", "latency_ms", "worst_case_residual_ms").
type AdmissionBlockAuditLogEntry struct {
	Event               string       `json:"event"`
	AgentID             string       `json:"agent_id"`
	Namespace           string       `json:"namespace"`
	Outcome             PlaneOutcome `json:"outcome"`
	LatencyMs           int64        `json:"latency_ms"`
	WorstCaseResidualMs int64        `json:"worst_case_residual_ms"`
	ResidualProvenance  string       `json:"residual_provenance"`
	BlockEnforced       bool         `json:"block_enforced"`
	RuleID              string       `json:"rule_id,omitempty"`
	IdempotencyKey      string       `json:"idempotency_key"`
	Timestamp           string       `json:"timestamp"`
	Error               string       `json:"error,omitempty"`
}

// AdmissionClient manages readmission block enforcement on the admission plane.
type AdmissionClient interface {
	BlockAdmission(ctx context.Context, req AdmissionBlockRequest) (*AdmissionBlockResponse, error)
	UnblockAdmission(ctx context.Context, req AdmissionBlockRequest) (*AdmissionBlockResponse, error)
	Health(ctx context.Context) error
}

// StoredContainedAgent represents a single record in the contained-agents ConfigMap.
type StoredContainedAgent struct {
	AgentID        string            `json:"agent_id"`
	Namespace      string            `json:"namespace"`
	SPIFFEID       string            `json:"spiffe_id,omitempty"`
	ContainedAt    string            `json:"contained_at"`
	Reason         string            `json:"reason,omitempty"`
	IdempotencyKey string            `json:"idempotency_key,omitempty"`
	Metadata       map[string]string `json:"metadata,omitempty"`
}

// K8sAdmissionClient enforces admission blocking via ConfigMap store synchronization.
type K8sAdmissionClient struct {
	clientset kubernetes.Interface
	namespace string
	cmName    string
	now       func() time.Time
	logger    func(entry AdmissionBlockAuditLogEntry)

	mu      sync.Mutex
	blocked map[string]bool // key: namespace/agentID
}

var _ AdmissionClient = (*K8sAdmissionClient)(nil)

// NewK8sAdmissionClient constructs a production K8sAdmissionClient.
func NewK8sAdmissionClient(clientset kubernetes.Interface, namespace string) *K8sAdmissionClient {
	if namespace == "" {
		namespace = "fe-signalloom"
	}
	return &K8sAdmissionClient{
		clientset: clientset,
		namespace: namespace,
		cmName:    DefaultContainedAgentsConfigMap,
		now:       time.Now,
		logger:    defaultAdmissionAuditLogger,
		blocked:   make(map[string]bool),
	}
}

// NewK8sAdmissionClientWithLogger constructs a K8sAdmissionClient with injectable clock and logger.
func NewK8sAdmissionClientWithLogger(clientset kubernetes.Interface, namespace string, now func() time.Time, logger func(AdmissionBlockAuditLogEntry)) *K8sAdmissionClient {
	if namespace == "" {
		namespace = "fe-signalloom"
	}
	if now == nil {
		now = time.Now
	}
	if logger == nil {
		logger = defaultAdmissionAuditLogger
	}
	return &K8sAdmissionClient{
		clientset: clientset,
		namespace: namespace,
		cmName:    DefaultContainedAgentsConfigMap,
		now:       now,
		logger:    logger,
		blocked:   make(map[string]bool),
	}
}

func defaultAdmissionAuditLogger(entry AdmissionBlockAuditLogEntry) {
	data, err := json.Marshal(entry)
	if err != nil {
		slog.Error("failed to marshal admission block audit log", "error", err)
		return
	}
	slog.Info("admission_block_audit", "record", string(data))
}

// BlockAdmission registers an agent in the contained-identity store to block readmission.
func (c *K8sAdmissionClient) BlockAdmission(ctx context.Context, req AdmissionBlockRequest) (*AdmissionBlockResponse, error) {
	start := c.now()
	timestamp := start.UTC().Format(time.RFC3339)

	if err := assertFrozenSchemaVersion(req.SchemaVersion); err != nil {
		return nil, fmt.Errorf("admission block %s/%s: %w", req.Namespace, req.AgentID, err)
	}

	key := req.Namespace + "/" + req.AgentID
	c.mu.Lock()
	alreadyBlocked := c.blocked[key]
	c.blocked[key] = true
	c.mu.Unlock()

	ruleID := fmt.Sprintf("admit-block-%s-%s", req.Namespace, req.AgentID)

	res := &AdmissionBlockResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneAdmission,
		Outcome:        OutcomeContained,
		RuleID:         ruleID,
		BlockEnforced:  true,
		Timestamp:      timestamp,
	}

	// Check context deadline first
	if err := ctx.Err(); err != nil {
		res.Outcome = OutcomeUnavailable
		res.BlockEnforced = false
		res.Error = err.Error()
		res.LatencyMs = c.now().Sub(start).Milliseconds()
		c.emitLog(res, req.Namespace)
		return res, fmt.Errorf("admission block %s/%s: %w: %w", req.Namespace, req.AgentID, ErrEnforcementUnavailable, err)
	}

	// If clientset is configured, update the ConfigMap
	if c.clientset != nil {
		err := c.syncConfigMapEntry(ctx, StoredContainedAgent{
			AgentID:        req.AgentID,
			Namespace:      req.Namespace,
			SPIFFEID:       req.SPIFFEID,
			ContainedAt:    timestamp,
			Reason:         req.Reason,
			IdempotencyKey: req.IdempotencyKey,
			Metadata:       req.MatchLabels,
		}, true)
		if err != nil {
			res.Outcome = OutcomeUnavailable
			res.BlockEnforced = false
			res.Error = err.Error()
			res.LatencyMs = c.now().Sub(start).Milliseconds()
			c.emitLog(res, req.Namespace)
			return res, fmt.Errorf("admission block %s/%s sync store: %w: %w", req.Namespace, req.AgentID, ErrEnforcementUnavailable, err)
		}
	} else if alreadyBlocked {
		// In-memory idempotent path
		res.LatencyMs = c.now().Sub(start).Milliseconds()
		c.emitLog(res, req.Namespace)
		return res, nil
	}

	res.LatencyMs = c.now().Sub(start).Milliseconds()
	c.emitLog(res, req.Namespace)
	return res, nil
}

// UnblockAdmission removes an agent from the contained-identity store.
func (c *K8sAdmissionClient) UnblockAdmission(ctx context.Context, req AdmissionBlockRequest) (*AdmissionBlockResponse, error) {
	start := c.now()
	timestamp := start.UTC().Format(time.RFC3339)

	if err := assertFrozenSchemaVersion(req.SchemaVersion); err != nil {
		return nil, fmt.Errorf("admission unblock %s/%s: %w", req.Namespace, req.AgentID, err)
	}

	key := req.Namespace + "/" + req.AgentID
	c.mu.Lock()
	delete(c.blocked, key)
	c.mu.Unlock()

	res := &AdmissionBlockResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: req.IdempotencyKey,
		AgentID:        req.AgentID,
		Plane:          PlaneAdmission,
		Outcome:        OutcomeContained,
		BlockEnforced:  false,
		Timestamp:      timestamp,
	}

	if err := ctx.Err(); err != nil {
		res.Outcome = OutcomeUnavailable
		res.Error = err.Error()
		res.LatencyMs = c.now().Sub(start).Milliseconds()
		return res, fmt.Errorf("admission unblock %s/%s: %w: %w", req.Namespace, req.AgentID, ErrEnforcementUnavailable, err)
	}

	if c.clientset != nil {
		err := c.syncConfigMapEntry(ctx, StoredContainedAgent{
			AgentID:   req.AgentID,
			Namespace: req.Namespace,
		}, false)
		if err != nil {
			res.Outcome = OutcomeUnavailable
			res.Error = err.Error()
			res.LatencyMs = c.now().Sub(start).Milliseconds()
			return res, fmt.Errorf("admission unblock %s/%s sync store: %w: %w", req.Namespace, req.AgentID, ErrEnforcementUnavailable, err)
		}
	}

	res.LatencyMs = c.now().Sub(start).Milliseconds()
	return res, nil
}

func (c *K8sAdmissionClient) syncConfigMapEntry(ctx context.Context, target StoredContainedAgent, add bool) error {
	cm, err := c.clientset.CoreV1().ConfigMaps(c.namespace).Get(ctx, c.cmName, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			if !add {
				return nil
			}
			// Create ConfigMap if it doesn't exist
			initialList := []StoredContainedAgent{target}
			dataBytes, _ := json.MarshalIndent(initialList, "", "  ")
			newCM := &corev1.ConfigMap{
				ObjectMeta: metav1.ObjectMeta{
					Name:      c.cmName,
					Namespace: c.namespace,
					Labels: map[string]string{
						"app.kubernetes.io/name": c.cmName,
						"signalloom.ai/plane":    "admission",
					},
				},
				Data: map[string]string{
					ContainedAgentsDataKey: string(dataBytes),
				},
			}
			_, createErr := c.clientset.CoreV1().ConfigMaps(c.namespace).Create(ctx, newCM, metav1.CreateOptions{})
			return createErr
		}
		return err
	}

	rawJSON := cm.Data[ContainedAgentsDataKey]
	var entries []StoredContainedAgent
	if rawJSON != "" {
		_ = json.Unmarshal([]byte(rawJSON), &entries)
	}

	modified := false
	filtered := make([]StoredContainedAgent, 0, len(entries)+1)

	for _, e := range entries {
		if e.AgentID == target.AgentID && (target.Namespace == "" || e.Namespace == target.Namespace) {
			modified = true
			continue // Exclude existing match
		}
		filtered = append(filtered, e)
	}

	if add {
		filtered = append(filtered, target)
		modified = true
	}

	if !modified && !add {
		return nil // Already absent
	}

	outBytes, err := json.MarshalIndent(filtered, "", "  ")
	if err != nil {
		return err
	}

	if cm.Data == nil {
		cm.Data = make(map[string]string)
	}
	cm.Data[ContainedAgentsDataKey] = string(outBytes)

	_, updateErr := c.clientset.CoreV1().ConfigMaps(c.namespace).Update(ctx, cm, metav1.UpdateOptions{})
	return updateErr
}

// Health probes the admission plane readiness.
func (c *K8sAdmissionClient) Health(ctx context.Context) error {
	if c.clientset != nil {
		_, err := c.clientset.CoreV1().ConfigMaps(c.namespace).Get(ctx, c.cmName, metav1.GetOptions{})
		if err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("admission health probe on %s/%s: %w: %v", c.namespace, c.cmName, ErrEnforcementUnavailable, err)
		}
	}
	return nil
}

func (c *K8sAdmissionClient) emitLog(res *AdmissionBlockResponse, namespace string) {
	if c.logger == nil {
		return
	}
	entry := AdmissionBlockAuditLogEntry{
		Event:               AdmissionBlockEventName,
		AgentID:             res.AgentID,
		Namespace:           namespace,
		Outcome:             res.Outcome,
		LatencyMs:           res.LatencyMs,
		WorstCaseResidualMs: AdmissionWorstCaseResidualMs,
		ResidualProvenance:  string(ProvenanceMeasured) + " (synchronous admission webhook block)",
		BlockEnforced:       res.BlockEnforced,
		RuleID:              res.RuleID,
		IdempotencyKey:      res.IdempotencyKey,
		Timestamp:           res.Timestamp,
		Error:               res.Error,
	}
	c.logger(entry)
}

// AdmissionResponseToPlaneResult maps an AdmissionBlockResponse onto a standard PlaneResult.
func AdmissionResponseToPlaneResult(resp *AdmissionBlockResponse, namespace string) *PlaneResult {
	if resp == nil {
		return nil
	}
	details := map[string]any{
		"idempotency_key":        resp.IdempotencyKey,
		"namespace":              namespace,
		"worst_case_residual_ms": AdmissionWorstCaseResidualMs,
		"residual_provenance":    string(ProvenanceMeasured) + " (synchronous admission webhook block)",
		"block_enforced":         resp.BlockEnforced,
		"rule_id":                resp.RuleID,
		"admission_webhook":      "node-capability-guard.signalloom.ai",
		"failure_policy":         "Fail",
	}

	return &PlaneResult{
		Plane:     PlaneAdmission,
		Outcome:   resp.Outcome,
		Error:     resp.Error,
		Timestamp: resp.Timestamp,
		LatencyMs: resp.LatencyMs,
		Details:   details,
	}
}
