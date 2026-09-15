package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Default OpenBao configuration constants.
const (
	// DefaultOpenBaoAddress matches the in-cluster convention established in cardvault-agent.
	DefaultOpenBaoAddress = "http://openbao.inf-bao.svc.cluster.local:8200"

	// DefaultOpenBaoTimeout is the strict timeout bound for containment requests (< 2s SLA).
	DefaultOpenBaoTimeout = 2 * time.Second

	// DefaultWorstCaseResidual is the baseline OpenBao token TTL (5m = 300s = 300,000ms)
	// representing the worst-case residual lifetime of credentials cached downstream.
	DefaultWorstCaseResidualMs = int64(300000)

	// DefaultBreakerMaxFailures is the consecutive failure threshold before opening the breaker.
	DefaultBreakerMaxFailures = 3

	// DefaultBreakerCooldown is the wait period before moving from Open to Half-Open.
	DefaultBreakerCooldown = 5 * time.Second
)

// Sentinel errors for OpenBao client operations.
var (
	ErrCircuitBreakerOpen = errors.New("openbao circuit breaker open: requests fast-failed")
	ErrLeaseNotFound      = errors.New("openbao lease not found")
	ErrInvalidLease       = errors.New("openbao invalid lease")
)

// CircuitBreakerState represents the operational state of the client's circuit breaker.
type CircuitBreakerState string

const (
	BreakerClosed   CircuitBreakerState = "closed"
	BreakerOpen     CircuitBreakerState = "open"
	BreakerHalfOpen CircuitBreakerState = "half-open"
)

// CircuitBreaker guards the OpenBao client against repeated timeout amplification
// when OpenBao is unreachable or experiencing prolonged outages.
type CircuitBreaker struct {
	mu               sync.RWMutex
	state            CircuitBreakerState
	consecutiveFails int
	maxFailures      int
	cooldown         time.Duration
	lastStateChange  time.Time
	now              func() time.Time
}

// NewCircuitBreaker creates a new circuit breaker with configurable threshold and cooldown.
func NewCircuitBreaker(maxFailures int, cooldown time.Duration) *CircuitBreaker {
	if maxFailures <= 0 {
		maxFailures = DefaultBreakerMaxFailures
	}
	if cooldown <= 0 {
		cooldown = DefaultBreakerCooldown
	}
	return &CircuitBreaker{
		state:       BreakerClosed,
		maxFailures: maxFailures,
		cooldown:    cooldown,
		now:         time.Now,
	}
}

// State returns the current circuit breaker state.
func (cb *CircuitBreaker) State() CircuitBreakerState {
	cb.mu.RLock()
	defer cb.mu.RUnlock()
	return cb.state
}

// Allow checks if a request is allowed to proceed according to breaker state.
func (cb *CircuitBreaker) Allow() bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	now := cb.now()
	switch cb.state {
	case BreakerClosed:
		return true
	case BreakerOpen:
		if now.Sub(cb.lastStateChange) >= cb.cooldown {
			cb.state = BreakerHalfOpen
			cb.lastStateChange = now
			return true
		}
		return false
	case BreakerHalfOpen:
		return true
	default:
		return false
	}
}

// RecordResult updates circuit breaker state based on the outcome of an operation.
func (cb *CircuitBreaker) RecordResult(err error) {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	now := cb.now()
	if err == nil || errors.Is(err, ErrLeaseNotFound) || errors.Is(err, ErrInvalidLease) {
		// Benign or successful result resets failure count and closes breaker
		cb.consecutiveFails = 0
		cb.state = BreakerClosed
		return
	}

	// Transport or backend failure
	cb.consecutiveFails++
	if cb.state == BreakerHalfOpen || cb.consecutiveFails >= cb.maxFailures {
		cb.state = BreakerOpen
		cb.lastStateChange = now
	}
}

// RevokeAuditLogEntry represents a machine-readable JSON log line emitted on every
// revoke attempt. It is formatted cleanly for P5-1 cryptographic attestation.
type RevokeAuditLogEntry struct {
	Timestamp           string       `json:"timestamp"`
	Event               string       `json:"event"` // "bao_revoke_attempt"
	AgentID             string       `json:"agent_id"`
	Namespace           string       `json:"namespace,omitempty"`
	LeaseIDs            []string     `json:"lease_ids,omitempty"`
	IdempotencyKey      string       `json:"idempotency_key,omitempty"`
	Outcome             PlaneOutcome `json:"outcome"`
	HTTPStatus          int          `json:"http_status,omitempty"`
	LatencyMs           int64        `json:"latency_ms"`
	CircuitBreakerState string       `json:"circuit_breaker_state"`
	WorstCaseResidualMs int64        `json:"worst_case_residual_ms"`
	Error               string       `json:"error,omitempty"`
}

// OpenBaoConfig encapsulates settings for constructing an OpenBaoClient.
type OpenBaoConfig struct {
	Address             string
	Token               string
	Timeout             time.Duration
	WorstCaseResidualMs int64
	BreakerMaxFailures  int
	BreakerCooldown     time.Duration
	LogWriter           io.Writer
}

// OpenBaoConfigFromEnv reads OpenBao configuration from environment variables.
func OpenBaoConfigFromEnv() OpenBaoConfig {
	addr := os.Getenv("BAO_ADDR")
	if addr == "" {
		addr = DefaultOpenBaoAddress
	}

	token := os.Getenv("BAO_TOKEN")
	if token == "" {
		token = os.Getenv("VAULT_TOKEN")
	}
	if token == "" {
		// Read from serviceaccount token path if present
		if tokenBytes, err := os.ReadFile("/var/run/secrets/openbao/token"); err == nil {
			token = strings.TrimSpace(string(tokenBytes))
		}
	}

	return OpenBaoConfig{
		Address:             addr,
		Token:               token,
		Timeout:             DefaultOpenBaoTimeout,
		WorstCaseResidualMs: DefaultWorstCaseResidualMs,
		BreakerMaxFailures:  DefaultBreakerMaxFailures,
		BreakerCooldown:     DefaultBreakerCooldown,
		LogWriter:           os.Stderr,
	}
}

// OpenBaoClient provides active OpenBao lease and token revocation with fail-closed
// error classification, circuit breaking, and structured attestation logging.
type OpenBaoClient struct {
	address             string
	token               string
	httpClient          *http.Client
	breaker             *CircuitBreaker
	worstCaseResidualMs int64
	logWriter           io.Writer
	logMu               sync.Mutex
	now                 func() time.Time
}

// NewOpenBaoClient creates an OpenBaoClient from configuration.
func NewOpenBaoClient(cfg OpenBaoConfig) *OpenBaoClient {
	if cfg.Address == "" {
		cfg.Address = DefaultOpenBaoAddress
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = DefaultOpenBaoTimeout
	}
	if cfg.WorstCaseResidualMs <= 0 {
		cfg.WorstCaseResidualMs = DefaultWorstCaseResidualMs
	}
	if cfg.LogWriter == nil {
		cfg.LogWriter = os.Stderr
	}

	return &OpenBaoClient{
		address: strings.TrimRight(cfg.Address, "/"),
		token:   cfg.Token,
		httpClient: &http.Client{
			Timeout: cfg.Timeout,
		},
		breaker:             NewCircuitBreaker(cfg.BreakerMaxFailures, cfg.BreakerCooldown),
		worstCaseResidualMs: cfg.WorstCaseResidualMs,
		logWriter:           cfg.LogWriter,
		now:                 time.Now,
	}
}

// emitAuditLog formats and writes a structured audit log entry.
func (c *OpenBaoClient) emitAuditLog(entry RevokeAuditLogEntry) {
	c.logMu.Lock()
	defer c.logMu.Unlock()

	data, err := json.Marshal(entry)
	if err == nil {
		_, _ = c.logWriter.Write(append(data, '\n'))
	}
}

// executeRequest performs an HTTP request against OpenBao with circuit breaking,
// context cancellation, and auth header injection.
func (c *OpenBaoClient) executeRequest(ctx context.Context, method, path string, bodyData any) (int, []byte, error) {
	if !c.breaker.Allow() {
		err := fmt.Errorf("%w: %w", ErrEnforcementUnavailable, ErrCircuitBreakerOpen)
		return 0, nil, err
	}

	var bodyReader io.Reader
	if bodyData != nil {
		data, err := json.Marshal(bodyData)
		if err != nil {
			return 0, nil, fmt.Errorf("marshal request body: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	url := fmt.Sprintf("%s%s", c.address, path)
	req, err := http.NewRequestWithContext(ctx, method, url, bodyReader)
	if err != nil {
		return 0, nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("X-Vault-Token", c.token)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.breaker.RecordResult(err)
		return 0, nil, fmt.Errorf("%w: http request failed: %v", ErrEnforcementUnavailable, err)
	}
	defer resp.Body.Close()

	respBody, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		c.breaker.RecordResult(readErr)
		return resp.StatusCode, nil, fmt.Errorf("%w: read response body: %v", ErrEnforcementUnavailable, readErr)
	}

	// Health check considers 200 (active) and 429 (standby) as healthy
	if path == "/v1/sys/health" && (resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusTooManyRequests) {
		c.breaker.RecordResult(nil)
		return resp.StatusCode, respBody, nil
	}

	// Classify response status
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		c.breaker.RecordResult(nil)
		return resp.StatusCode, respBody, nil
	}

	// Handle 400 / 404 idempotent errors
	respStr := strings.ToLower(string(respBody))
	if resp.StatusCode == http.StatusNotFound ||
		(resp.StatusCode == http.StatusBadRequest && (strings.Contains(respStr, "lease not found") || strings.Contains(respStr, "invalid lease"))) {
		c.breaker.RecordResult(ErrLeaseNotFound)
		return resp.StatusCode, respBody, ErrLeaseNotFound
	}

	// Permission denied
	if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusUnauthorized {
		authErr := fmt.Errorf("%w: openbao permission denied (status %d): %s", ErrEnforcementDenied, resp.StatusCode, string(respBody))
		c.breaker.RecordResult(authErr)
		return resp.StatusCode, respBody, authErr
	}

	// 5xx / other server errors
	serverErr := fmt.Errorf("%w: openbao server error (status %d): %s", ErrEnforcementUnavailable, resp.StatusCode, string(respBody))
	c.breaker.RecordResult(serverErr)
	return resp.StatusCode, respBody, serverErr
}

// RevokeLease revokes one or more OpenBao leases via POST /v1/sys/leases/revoke.
func (c *OpenBaoClient) RevokeLease(ctx context.Context, req BaoRevokeRequest) (*BaoRevokeResponse, error) {
	if err := assertFrozenSchemaVersion(req.SchemaVersion); err != nil {
		return nil, err
	}

	start := c.now()
	revokedCount := 0
	var lastErr error

	leasesToRevoke := req.LeaseIDs
	if len(leasesToRevoke) == 0 {
		// Default lease prefix for target agent if explicit lease IDs are not supplied
		leasesToRevoke = []string{fmt.Sprintf("cardvault/creds/%s", req.AgentID)}
	}

	for _, leaseID := range leasesToRevoke {
		payload := map[string]any{
			"lease_id": leaseID,
			"sync":     true,
		}

		_, _, err := c.executeRequest(ctx, http.MethodPost, "/v1/sys/leases/revoke", payload)
		if err != nil {
			if errors.Is(err, ErrLeaseNotFound) {
				// Idempotent success: lease was already revoked or not found
				revokedCount++
			} else {
				lastErr = err
			}
		} else {
			revokedCount++
		}
	}

	latency := c.now().Sub(start).Milliseconds()
	outcome := OutcomeContained
	errStr := ""

	if lastErr != nil {
		if errors.Is(lastErr, ErrEnforcementUnavailable) || errors.Is(lastErr, ErrCircuitBreakerOpen) {
			outcome = OutcomeUnavailable
		} else if errors.Is(lastErr, ErrEnforcementDenied) {
			outcome = OutcomeUnavailable
		} else {
			outcome = OutcomePartial
		}
		errStr = lastErr.Error()
	} else if revokedCount == 0 && len(leasesToRevoke) > 0 {
		outcome = OutcomeNotFound
	}

	resp := &BaoRevokeResponse{
		SchemaVersion:     FrozenSchemaVersion,
		IdempotencyKey:    req.IdempotencyKey,
		AgentID:           req.AgentID,
		Plane:             PlaneBao,
		Outcome:           outcome,
		RevokedLeases:     revokedCount,
		TokensInvalidated: 0,
		LatencyMs:         latency,
		Error:             errStr,
		Timestamp:         c.now().UTC().Format(time.RFC3339),
	}

	return resp, lastErr
}

// RevokeToken revokes an OpenBao token via POST /v1/auth/token/revoke.
func (c *OpenBaoClient) RevokeToken(ctx context.Context, token string) error {
	payload := map[string]any{"token": token}
	_, _, err := c.executeRequest(ctx, http.MethodPost, "/v1/auth/token/revoke", payload)
	if errors.Is(err, ErrLeaseNotFound) {
		return nil // Idempotent success
	}
	return err
}

// RevokeTokenAccessor revokes an OpenBao token by accessor via POST /v1/auth/token/revoke-accessor.
func (c *OpenBaoClient) RevokeTokenAccessor(ctx context.Context, accessor string) error {
	payload := map[string]any{"accessor": accessor}
	_, _, err := c.executeRequest(ctx, http.MethodPost, "/v1/auth/token/revoke-accessor", payload)
	if errors.Is(err, ErrLeaseNotFound) {
		return nil // Idempotent success
	}
	return err
}

// RenewSelf refreshes the client's own OpenBao token via POST /v1/auth/token/renew-self.
func (c *OpenBaoClient) RenewSelf(ctx context.Context, increment string) error {
	payload := map[string]any{}
	if increment != "" {
		payload["increment"] = increment
	}
	_, _, err := c.executeRequest(ctx, http.MethodPost, "/v1/auth/token/renew-self", payload)
	return err
}

// Health checks OpenBao server readiness via GET /v1/sys/health.
func (c *OpenBaoClient) Health(ctx context.Context) error {
	status, _, err := c.executeRequest(ctx, http.MethodGet, "/v1/sys/health", nil)
	if err != nil {
		return fmt.Errorf("openbao health check failed: %w", err)
	}
	// OpenBao /sys/health returns:
	// 200: initialized, unsealed, and active
	// 429: unsealed and standby
	if status == http.StatusOK || status == 429 {
		return nil
	}
	return fmt.Errorf("%w: openbao health status %d", ErrEnforcementUnavailable, status)
}

// RevokeAgentCredentials executes full active credential revocation for a target agent.
// It returns an honest PlaneResult recording outcome, duration, breaker state, and residual latency.
func (c *OpenBaoClient) RevokeAgentCredentials(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	start := c.now()
	cbState := string(c.breaker.State())

	req := BaoRevokeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		Namespace:      namespace,
		Reason:         "Signal Loom containment revocation",
		Timestamp:      c.now().UTC().Format(time.RFC3339),
	}

	resp, revokeErr := c.RevokeLease(ctx, req)
	latency := c.now().Sub(start).Milliseconds()

	outcome := OutcomeUnavailable
	var httpStatus int
	var errStr string
	revokedLeases := 0

	if resp != nil {
		outcome = resp.Outcome
		revokedLeases = resp.RevokedLeases
		errStr = resp.Error
		if resp.Outcome == OutcomeContained {
			httpStatus = http.StatusNoContent
		}
	} else if revokeErr != nil {
		errStr = revokeErr.Error()
	}

	// Emit structured audit log entry for P5-1 attestation
	auditEntry := RevokeAuditLogEntry{
		Timestamp:           c.now().UTC().Format(time.RFC3339),
		Event:               "bao_revoke_attempt",
		AgentID:             agentID,
		Namespace:           namespace,
		LeaseIDs:            req.LeaseIDs,
		IdempotencyKey:      idempotencyKey,
		Outcome:             outcome,
		HTTPStatus:          httpStatus,
		LatencyMs:           latency,
		CircuitBreakerState: cbState,
		WorstCaseResidualMs: c.worstCaseResidualMs,
		Error:               errStr,
	}
	c.emitAuditLog(auditEntry)

	planeRes := &PlaneResult{
		Plane:     PlaneBao,
		Outcome:   outcome,
		Error:     errStr,
		Timestamp: c.now().UTC().Format(time.RFC3339),
		LatencyMs: latency,
		Details: map[string]any{
			"worst_case_residual_ms": c.worstCaseResidualMs,
			"circuit_breaker_state":  cbState,
			"idempotency_key":        idempotencyKey,
			"revoked_leases":         revokedLeases,
		},
	}

	if outcome == OutcomeUnavailable {
		if revokeErr != nil {
			return planeRes, revokeErr
		}
		return planeRes, fmt.Errorf("%w: %s", ErrEnforcementUnavailable, errStr)
	}

	return planeRes, nil
}

// StartAutoRenew starts a background loop to renew the client's own OpenBao token.
func (c *OpenBaoClient) StartAutoRenew(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = 2 * time.Minute
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := c.RenewSelf(ctx, "300s"); err != nil {
					slog.Warn("openbao client token auto-renew failed", "error", err)
				}
			}
		}
	}()
}
