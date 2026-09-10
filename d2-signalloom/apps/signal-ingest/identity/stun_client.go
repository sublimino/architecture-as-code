package identity

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// DropEgressRequest carries parameters for executing an eBPF TC drop on a stunned agent container.
type DropEgressRequest struct {
	AgentID   string    `json:"agent_id"`
	IP        string    `json:"ip"`
	Interface string    `json:"interface,omitempty"`
	Reason    string    `json:"reason"`
	Timestamp time.Time `json:"timestamp"`
}

// DropEgressResponse encapsulates result from Stun Sentinel client execution.
type DropEgressResponse struct {
	Success    bool      `json:"success"`
	Command    string    `json:"command"`
	IP         string    `json:"ip"`
	ExecutedAt time.Time `json:"executed_at"`
	LatencyMS  float64   `json:"latency_ms"`
}

// StunSentinelClient defines the client contract for issuing stun-tcctl containment drop commands.
type StunSentinelClient interface {
	DropAgentEgress(ctx context.Context, req DropEgressRequest) (*DropEgressResponse, error)
}

// MockStunSentinelClient provides an in-memory client mock for hermetic testing and verification.
type MockStunSentinelClient struct {
	mu           sync.Mutex
	Dispatched   []DropEgressRequest
	ShouldFail   bool
	FailAttempts int
	callCount    int
	Latency      time.Duration
}

// NewMockStunSentinelClient constructs a new MockStunSentinelClient.
func NewMockStunSentinelClient() *MockStunSentinelClient {
	return &MockStunSentinelClient{
		Dispatched: make([]DropEgressRequest, 0),
		Latency:    2 * time.Millisecond,
	}
}

// DropAgentEgress simulates dispatching a drop command to stun-tcctl.
func (m *MockStunSentinelClient) DropAgentEgress(ctx context.Context, req DropEgressRequest) (*DropEgressResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.callCount++

	if m.ShouldFail || (m.FailAttempts > 0 && m.callCount <= m.FailAttempts) {
		return nil, fmt.Errorf("stun sentinel daemon unreachable (connection refused)")
	}

	m.Dispatched = append(m.Dispatched, req)
	return &DropEgressResponse{
		Success:    true,
		Command:    fmt.Sprintf("stun-tcctl drop --ip %s", req.IP),
		IP:         req.IP,
		ExecutedAt: time.Now().UTC(),
		LatencyMS:  float64(m.Latency.Milliseconds()),
	}, nil
}

// GetDispatched returns a copy of dispatched drop requests.
func (m *MockStunSentinelClient) GetDispatched() []DropEgressRequest {
	m.mu.Lock()
	defer m.mu.Unlock()
	copied := make([]DropEgressRequest, len(m.Dispatched))
	copy(copied, m.Dispatched)
	return copied
}

// DispatchDropWithRetry executes DropAgentEgress with exponential backoff retries.
func DispatchDropWithRetry(ctx context.Context, client StunSentinelClient, req DropEgressRequest, maxRetries int) (*DropEgressResponse, error) {
	if client == nil {
		return nil, nil
	}
	if maxRetries <= 0 {
		maxRetries = 3
	}
	var lastErr error
	backoff := 5 * time.Millisecond

	for attempt := 0; attempt < maxRetries; attempt++ {
		resp, err := client.DropAgentEgress(ctx, req)
		if err == nil && resp != nil {
			return resp, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(backoff):
			backoff *= 2
		}
	}
	return nil, fmt.Errorf("failed to dispatch stun drop after %d retries: %w", maxRetries, lastErr)
}
