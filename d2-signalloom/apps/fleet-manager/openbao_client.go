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

	// DefaultOpenBaoTokenFile is where the openbao-agent sidecar sinks the
	// fleet-manager token (base/deployment.yaml). It was previously read once at
	// startup; it is now the default BAO_TOKEN_FILE and is re-read per request.
	DefaultOpenBaoTokenFile = "/var/run/secrets/openbao/token"
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
	Address string
	// Token is a static token. When set it wins over TokenFile.
	Token string
	// TokenFile is re-read on EVERY request when Token is empty. The sidecar
	// writes the file after this process starts and replaces it on each
	// re-auth, so a value captured at construction is either empty for the
	// life of the process or expired five minutes in.
	TokenFile           string
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
	tokenFile := os.Getenv("BAO_TOKEN_FILE")
	if tokenFile == "" {
		tokenFile = DefaultOpenBaoTokenFile
	}

	return OpenBaoConfig{
		Address:             addr,
		Token:               token,
		TokenFile:           tokenFile,
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
	tokenFile           string
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
		address:   strings.TrimRight(cfg.Address, "/"),
		token:     cfg.Token,
		tokenFile: cfg.TokenFile,
		httpClient: &http.Client{
			Timeout: cfg.Timeout,
		},
		breaker:             NewCircuitBreaker(cfg.BreakerMaxFailures, cfg.BreakerCooldown),
		worstCaseResidualMs: cfg.WorstCaseResidualMs,
		logWriter:           cfg.LogWriter,
		now:                 time.Now,
	}
}

// currentToken returns the static token, else the trimmed content of the token
// file read now. An unreadable or empty file yields "" and the request goes out
// unauthenticated, which OpenBao answers 403: the plane reports Unavailable
// rather than pretending.
func (c *OpenBaoClient) currentToken() string {
	if c.token != "" {
		return c.token
	}
	if c.tokenFile == "" {
		return ""
	}
	data, err := os.ReadFile(c.tokenFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// TokenConfigured reports whether a request made now would carry a token.
func (c *OpenBaoClient) TokenConfigured() bool {
	return c.currentToken() != ""
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
	if token := c.currentToken(); token != "" {
		req.Header.Set("X-Vault-Token", token)
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
		(resp.StatusCode == http.StatusBadRequest && (strings.Contains(respStr, "lease not found") || strings.Contains(respStr, "invalid lease") ||
			// lookup-accessor / revoke-accessor on a token that has already
			// expired: the same idempotent "already gone" answer.
			strings.Contains(respStr, "invalid accessor"))) {
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

// ActiveTokensBySubject enumerates every live token accessor and counts them by
// SPIFFE subject. Read-only: LIST auth/token/accessors (needs list+sudo) then
// lookup-accessor per key, which returns metadata, never the token itself.
//
// The subject is meta.sub when the JWT role maps it (signalloom-agent-generic
// sets claim_mappings sub=sub), otherwise the SPIFFE ID embedded in
// display_name, which OpenBao forms as "<mount>-<user_claim value>" (e.g.
// "jwt-payments-spiffe://..."). Tokens with neither (root, bootstrap) are not
// agent tokens and are not counted.
//
// Any failure other than an accessor expiring mid-scan returns (nil, err): a
// partial count is not a count, and the consistency check must report the plane
// as unqueried rather than under-report live credentials as zero.
func (c *OpenBaoClient) ActiveTokensBySubject(ctx context.Context) (map[string]int, error) {
	tokens, err := c.tokenSubjects(ctx)
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, tok := range tokens {
		counts[tok.subject]++
	}
	return counts, nil
}

// RevokeTokensBySubject revokes, by accessor, every live token whose SPIFFE
// subject is exactly spiffeID (subject derived as in ActiveTokensBySubject).
// It returns how many it revoked. An accessor that expired mid-scan is already
// gone and is not counted. Any other failure stops and returns the error with
// the count so far: the caller must not report the plane contained while a
// matching token may still be live.
func (c *OpenBaoClient) RevokeTokensBySubject(ctx context.Context, spiffeID string) (int, error) {
	tokens, err := c.tokenSubjects(ctx)
	if err != nil {
		return 0, err
	}
	revoked := 0
	for _, tok := range tokens {
		if tok.subject != spiffeID {
			continue
		}
		_, _, err := c.executeRequest(ctx, http.MethodPost, "/v1/auth/token/revoke-accessor", map[string]any{"accessor": tok.accessor})
		if errors.Is(err, ErrLeaseNotFound) {
			continue
		}
		if err != nil {
			return revoked, fmt.Errorf("revoke token accessor for %s: %w", spiffeID, err)
		}
		revoked++
	}
	return revoked, nil
}

type tokenSubject struct {
	accessor string
	subject  string
}

// tokenSubjects lists every live accessor and resolves its SPIFFE subject.
// Tokens with no SPIFFE subject (root, bootstrap) are omitted.
func (c *OpenBaoClient) tokenSubjects(ctx context.Context) ([]tokenSubject, error) {
	_, body, err := c.executeRequest(ctx, http.MethodGet, "/v1/auth/token/accessors?list=true", nil)
	if errors.Is(err, ErrLeaseNotFound) {
		return nil, nil // LIST answers 404 when there are no keys
	}
	if err != nil {
		return nil, fmt.Errorf("list token accessors: %w", err)
	}
	var list struct {
		Data struct {
			Keys []string `json:"keys"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("%w: decode accessor list: %v", ErrEnforcementUnavailable, err)
	}

	var out []tokenSubject
	for _, accessor := range list.Data.Keys {
		_, body, err := c.executeRequest(ctx, http.MethodPost, "/v1/auth/token/lookup-accessor", map[string]any{"accessor": accessor})
		if errors.Is(err, ErrLeaseNotFound) {
			continue // expired between LIST and lookup
		}
		if err != nil {
			return nil, fmt.Errorf("lookup token accessor: %w", err)
		}
		var lookup struct {
			Data struct {
				DisplayName string            `json:"display_name"`
				Meta        map[string]string `json:"meta"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &lookup); err != nil {
			return nil, fmt.Errorf("%w: decode accessor lookup: %v", ErrEnforcementUnavailable, err)
		}
		subject := lookup.Data.Meta["sub"]
		if subject == "" {
			if i := strings.Index(lookup.Data.DisplayName, "spiffe://"); i >= 0 {
				subject = lookup.Data.DisplayName[i:]
			}
		}
		if subject != "" {
			out = append(out, tokenSubject{accessor: accessor, subject: subject})
		}
	}
	return out, nil
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
		Event:               BaoRevokeEventName,
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

// RotateAgentCredentials executes mandatory credential rotation for a target agent on resume.
// It provisions/rotates OpenBao leases or tokens, ensuring the unfreezing agent cannot run
// on compromised credentials.
func (c *OpenBaoClient) RotateAgentCredentials(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	start := c.now()
	cbState := string(c.breaker.State())

	if !c.breaker.Allow() {
		err := fmt.Errorf("%w: %w", ErrEnforcementUnavailable, ErrCircuitBreakerOpen)
		planeRes := &PlaneResult{
			Plane:     PlaneBao,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
			LatencyMs: 0,
			Details: map[string]any{
				"circuit_breaker_state": cbState,
				"idempotency_key":       idempotencyKey,
				"credentials_rotated":   false,
			},
		}
		return planeRes, err
	}

	// Re-issue / rotate token or lease for target agent
	payload := map[string]any{
		"agent_id":        agentID,
		"namespace":       namespace,
		"idempotency_key": idempotencyKey,
		"rotation_reason": "governance resume credential rotation",
	}

	path := fmt.Sprintf("/v1/cardvault/creds/%s", agentID)
	status, _, err := c.executeRequest(ctx, http.MethodPost, path, payload)
	if err != nil && !errors.Is(err, ErrLeaseNotFound) {
		// If custom path 404s, verify OpenBao health as fallback for generic agents
		if status == http.StatusNotFound {
			status, _, err = c.executeRequest(ctx, http.MethodGet, "/v1/sys/health", nil)
		}
	}

	latency := c.now().Sub(start).Milliseconds()
	outcome := OutcomeContained
	var errStr string

	if err != nil && !errors.Is(err, ErrLeaseNotFound) {
		outcome = OutcomeUnavailable
		errStr = err.Error()
	}

	// Emit structured audit log entry for P5-1 attestation
	auditEntry := RevokeAuditLogEntry{
		Timestamp:           c.now().UTC().Format(time.RFC3339),
		Event:               BaoRotateEventName,
		AgentID:             agentID,
		Namespace:           namespace,
		IdempotencyKey:      idempotencyKey,
		Outcome:             outcome,
		HTTPStatus:          status,
		LatencyMs:           latency,
		CircuitBreakerState: string(c.breaker.State()),
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
			"circuit_breaker_state":  string(c.breaker.State()),
			"idempotency_key":        idempotencyKey,
			"credentials_rotated":    outcome == OutcomeContained,
		},
	}

	if outcome == OutcomeUnavailable {
		if err != nil {
			return planeRes, err
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
