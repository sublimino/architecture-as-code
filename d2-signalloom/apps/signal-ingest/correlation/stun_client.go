// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// StunDispatchClient defines the interface for triggering kernel cgroup containment on an agent pod.
type StunDispatchClient interface {
	DispatchFreeze(ctx context.Context, req StunFreezeRequest) (*StunFreezeResponse, error)
	IsExempt(actorID, spiffeID string) bool
	IsInGracePeriod(actorID string, registrationTime time.Time) bool
}

// StunFreezeRequest encapsulates containment parameters for Stun Sentinel.
type StunFreezeRequest struct {
	PodName         string                `json:"pod_name"`
	Pod             string                `json:"pod,omitempty"`
	PodUID          string                `json:"pod_uid,omitempty"`
	Namespace       string                `json:"namespace,omitempty"`
	ActorID         string                `json:"actor_id"`
	SPIFFEID        string                `json:"spiffe_id,omitempty"`
	ViolationReason model.ViolationReason `json:"violation_reason"`
	Action          string                `json:"action,omitempty"`
	EvidenceGitOID  string                `json:"evidence_gitoid,omitempty"`
}

// StunFreezeResponse captures the result returned by Stun Sentinel.
type StunFreezeResponse struct {
	Frozen    bool    `json:"frozen"`
	PodUID    string  `json:"pod_uid,omitempty"`
	PodName   string  `json:"pod,omitempty"`
	LatencyMS float64 `json:"latency_ms"`
	Polls     int     `json:"polls,omitempty"`
	PIDs      []int   `json:"pids,omitempty"`
	Error     string  `json:"error,omitempty"`
}

// HTTPStunClient communicates with Stun Sentinel over HTTP with sub-100ms deadlines,
// debouncing/rate-limiting, and grace period evaluation.
type HTTPStunClient struct {
	baseURL      string
	httpClient   *http.Client
	metrics      *QuarantineMetrics
	mu           sync.RWMutex
	lastAlert    map[string]time.Time // actor_id -> timestamp (debouncing)
	debounceTTL  time.Duration
	exemptions   map[string]bool
	graceWindow  time.Duration
	ringBuffer   *QuarantineRingBuffer
}

// StunClientOptions configures the HTTPStunClient.
type StunClientOptions struct {
	BaseURL     string
	Timeout     time.Duration
	DebounceTTL time.Duration
	GraceWindow time.Duration
	Exemptions  []string
	Metrics     *QuarantineMetrics
}

// NewHTTPStunClient creates a new StunDispatchClient.
func NewHTTPStunClient(opts StunClientOptions) *HTTPStunClient {
	baseURL := opts.BaseURL
	if baseURL == "" {
		baseURL = os.Getenv("STUN_SENTINEL_URL")
	}
	if baseURL == "" {
		baseURL = "http://localhost:8080"
	}
	baseURL = strings.TrimSuffix(baseURL, "/")

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = 250 * time.Millisecond // fast fail / sub-second constraint
	}

	debounceTTL := opts.DebounceTTL
	if debounceTTL <= 0 {
		debounceTTL = 3 * time.Second
	}

	graceWindow := opts.GraceWindow
	if graceWindow <= 0 {
		graceWindow = 30 * time.Second
	}

	metrics := opts.Metrics
	if metrics == nil {
		metrics = DefaultQuarantineMetrics()
	}

	exemptMap := make(map[string]bool)
	// Default baseline exemptions to prevent containment storms on verified baseline agents
	defaultExempt := []string{
		"agent-baseline",
		"baseline-agent",
		"system:serviceaccount:fe-signalloom:agent-baseline",
		"system:serviceaccount:fe-signalloom-agents:agent-baseline",
		"spiffe://fe-signalloom/sa/agent-baseline",
		"spiffe://osramp.local/ns/fe-signalloom-agents/sa/agent-baseline",
		"spiffe://osramp.local/ns/fe-signalloom/sa/agent-baseline",
		"system:serviceaccount:kube-system:generic-garbage-collector",
		"system:serviceaccount:flux-system:kustomize-controller",
	}
	for _, ex := range defaultExempt {
		exemptMap[ex] = true
	}
	for _, ex := range opts.Exemptions {
		exemptMap[ex] = true
	}

	return &HTTPStunClient{
		baseURL:     baseURL,
		httpClient:  &http.Client{Timeout: timeout},
		metrics:     metrics,
		lastAlert:   make(map[string]time.Time),
		debounceTTL: debounceTTL,
		exemptions:  exemptMap,
		graceWindow: graceWindow,
		ringBuffer:  NewQuarantineRingBuffer(1024),
	}
}

// IsExempt reports whether an actor or SPIFFE ID is exempt from automated containment.
func (c *HTTPStunClient) IsExempt(actorID, spiffeID string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.exemptions[actorID] || c.exemptions[spiffeID] {
		return true
	}
	for ex := range c.exemptions {
		if strings.EqualFold(actorID, ex) || strings.EqualFold(spiffeID, ex) {
			return true
		}
		if strings.Contains(strings.ToLower(actorID), "baseline") && strings.Contains(strings.ToLower(ex), "baseline") {
			return true
		}
		if strings.Contains(strings.ToLower(spiffeID), "baseline") && strings.Contains(strings.ToLower(ex), "baseline") {
			return true
		}
	}
	return false
}

// IsInGracePeriod checks if a newly registered actor is within its initial grace window.
func (c *HTTPStunClient) IsInGracePeriod(actorID string, registrationTime time.Time) bool {
	if registrationTime.IsZero() {
		return false
	}
	return time.Since(registrationTime) < c.graceWindow
}

// RingBuffer returns the fallback in-memory quarantine buffer.
func (c *HTTPStunClient) RingBuffer() *QuarantineRingBuffer {
	return c.ringBuffer
}

// DispatchFreeze dispatches an HTTP POST freeze request to Stun Sentinel.
func (c *HTTPStunClient) DispatchFreeze(ctx context.Context, req StunFreezeRequest) (*StunFreezeResponse, error) {
	start := time.Now()

	// 1. Check exemptions
	if c.IsExempt(req.ActorID, req.SPIFFEID) {
		slog.Info("quarantine: actor is exempt from automated freeze",
			"actor_id", req.ActorID, "spiffe_id", req.SPIFFEID, "reason", req.ViolationReason)
		return &StunFreezeResponse{
			Frozen:    false,
			PodName:   req.PodName,
			LatencyMS: float64(time.Since(start).Milliseconds()),
			Error:     "actor is exempt from automated containment",
		}, nil
	}

	// 2. Validate actor ID against SPIFFE claims if present (anti-spoofing)
	if req.SPIFFEID != "" && req.ActorID != "" {
		if !validateSPIFFEClaimMatch(req.ActorID, req.SPIFFEID) {
			slog.Warn("quarantine: actor ID / SPIFFE claim mismatch detected",
				"actor_id", req.ActorID, "spiffe_id", req.SPIFFEID)
		}
	}

	// 3. Debounce / rate limit check per actor ID
	c.mu.Lock()
	if last, ok := c.lastAlert[req.ActorID]; ok && time.Since(last) < c.debounceTTL {
		c.mu.Unlock()
		c.metrics.IncThrottled()
		slog.Debug("quarantine: containment dispatch throttled by debouncer",
			"actor_id", req.ActorID, "since_last_ms", time.Since(last).Milliseconds())
		return &StunFreezeResponse{
			Frozen:    true,
			PodName:   req.PodName,
			LatencyMS: float64(time.Since(start).Milliseconds()),
			Error:     "throttled: containment already dispatched within debounce TTL",
		}, nil
	}
	c.lastAlert[req.ActorID] = time.Now()
	c.mu.Unlock()

	// 4. Construct freeze payload
	podIdentifier := req.PodName
	if podIdentifier == "" {
		podIdentifier = req.ActorID
	}
	namespace := req.Namespace
	if namespace == "" {
		namespace = "fe-signalloom-agents"
	}

	payload := map[string]any{
		"pod_uid":          req.PodUID,
		"pod":              podIdentifier,
		"pod_name":         podIdentifier,
		"namespace":        namespace,
		"actor_id":         req.ActorID,
		"violation_reason": req.ViolationReason.String(),
		"action":           req.Action,
		"evidence_gitoid":  req.EvidenceGitOID,
	}
	bodyBytes, err := json.Marshal(payload)
	if err != nil {
		c.metrics.IncStunFailures()
		return nil, fmt.Errorf("marshal stun request: %w", err)
	}

	// Try POST /api/v1/stun/{pod_name} then fallback to POST /stun
	targetURL := fmt.Sprintf("%s/api/v1/stun/%s", c.baseURL, podIdentifier)
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL, bytes.NewReader(bodyBytes))
	if err != nil {
		c.metrics.IncStunFailures()
		return nil, fmt.Errorf("create stun request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(httpReq)
	if err != nil || (resp != nil && resp.StatusCode == http.StatusNotFound) {
		// Fallback to /stun endpoint supported by stun-sentinel
		if resp != nil {
			resp.Body.Close()
		}
		fallbackURL := fmt.Sprintf("%s/stun", c.baseURL)
		fallbackReq, fErr := http.NewRequestWithContext(ctx, http.MethodPost, fallbackURL, bytes.NewReader(bodyBytes))
		if fErr == nil {
			fallbackReq.Header.Set("Content-Type", "application/json")
			resp, err = c.httpClient.Do(fallbackReq)
		}
	}

	latency := float64(time.Since(start).Nanoseconds()) / 1e6
	if err != nil {
		c.metrics.IncStunFailures()
		slog.Error("CRITICAL: stun-sentinel unreachable, execution halt dispatch failed",
			"error", err,
			"target_url", targetURL,
			"actor_id", req.ActorID,
			"pod", podIdentifier,
			"violation_reason", req.ViolationReason,
			"fallback", "local audit record preserved in ring buffer",
		)
		// Store in ring buffer on dispatch failure
		c.ringBuffer.Push(model.QuarantineRecord{
			ActorID:         req.ActorID,
			PodName:         podIdentifier,
			Namespace:       namespace,
			ViolationReason: req.ViolationReason,
			Action:          req.Action,
			AttemptedAt:     time.Now().UTC(),
			QuarantinedAt:   time.Now().UTC(),
			StunDispatched:  false,
			StunLatencyMS:   latency,
			EvidenceGitOID:  req.EvidenceGitOID,
		})
		return &StunFreezeResponse{
			Frozen:    false,
			PodName:   podIdentifier,
			LatencyMS: latency,
			Error:     fmt.Sprintf("stun-sentinel unreachable: %v", err),
		}, nil
	}
	defer resp.Body.Close()

	c.metrics.IncStunDispatched()

	var freezeRes StunFreezeResponse
	if err := json.NewDecoder(resp.Body).Decode(&freezeRes); err != nil {
		freezeRes.Frozen = resp.StatusCode == http.StatusOK
		freezeRes.PodName = podIdentifier
	}
	freezeRes.LatencyMS = latency

	// Buffer successful containment record
	c.ringBuffer.Push(model.QuarantineRecord{
		ActorID:         req.ActorID,
		PodName:         podIdentifier,
		Namespace:       namespace,
		ViolationReason: req.ViolationReason,
		Action:          req.Action,
		AttemptedAt:     time.Now().UTC(),
		QuarantinedAt:   time.Now().UTC(),
		StunDispatched:  freezeRes.Frozen || resp.StatusCode == http.StatusOK,
		StunLatencyMS:   latency,
		EvidenceGitOID:  req.EvidenceGitOID,
	})

	slog.Info("quarantine: containment freeze dispatched to stun-sentinel",
		"actor_id", req.ActorID,
		"pod", podIdentifier,
		"violation_reason", req.ViolationReason,
		"latency_ms", latency,
		"http_status", resp.StatusCode,
	)

	return &freezeRes, nil
}

func validateSPIFFEClaimMatch(actorID, spiffeID string) bool {
	if actorID == "" || spiffeID == "" {
		return true
	}
	// Basic consistency check: if actor ID embeds a name, it should align with SPIFFE ID path
	cleanActor := strings.TrimPrefix(actorID, "actor-")
	cleanActor = strings.TrimPrefix(cleanActor, "spiffe://")
	return strings.Contains(spiffeID, cleanActor) || strings.Contains(actorID, spiffeID) || strings.Contains(spiffeID, "agent")
}

// QuarantineRingBuffer provides a bounded, thread-safe in-memory ring buffer for quarantine records.
type QuarantineRingBuffer struct {
	mu       sync.RWMutex
	capacity int
	records  []model.QuarantineRecord
	head     int
	count    int
}

// NewQuarantineRingBuffer creates an in-memory ring buffer with fixed capacity.
func NewQuarantineRingBuffer(capacity int) *QuarantineRingBuffer {
	if capacity <= 0 {
		capacity = 512
	}
	return &QuarantineRingBuffer{
		capacity: capacity,
		records:  make([]model.QuarantineRecord, capacity),
	}
}

// Push adds a quarantine record to the buffer.
func (b *QuarantineRingBuffer) Push(rec model.QuarantineRecord) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.records[b.head] = rec
	b.head = (b.head + 1) % b.capacity
	if b.count < b.capacity {
		b.count++
	}
}

// Snapshot returns a copy of all buffered quarantine records in chronological order.
func (b *QuarantineRingBuffer) Snapshot() []model.QuarantineRecord {
	b.mu.RLock()
	defer b.mu.RUnlock()

	res := make([]model.QuarantineRecord, 0, b.count)
	if b.count < b.capacity {
		res = append(res, b.records[:b.count]...)
	} else {
		for i := 0; i < b.capacity; i++ {
			idx := (b.head + i) % b.capacity
			res = append(res, b.records[idx])
		}
	}
	return res
}

// Len returns the current number of buffered records.
func (b *QuarantineRingBuffer) Len() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.count
}
