package stun

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// StunRequest defines the parameters required to execute a Workspace agent stun cascade.
type StunRequest struct {
	AgentID             string    `json:"agent_id"`
	ServiceAccountEmail string    `json:"service_account_email"`
	Reason              string    `json:"reason"`
	RequestedAt         time.Time `json:"requested_at"`
}

// StunResult provides the cryptographic and execution status of the stun cascade.
type StunResult struct {
	AgentID                string    `json:"agent_id"`
	Status                 string    `json:"status"`
	ServiceAccountDisabled bool      `json:"service_account_disabled"`
	OpenBaoLeaseRevoked    bool      `json:"openbao_lease_revoked"`
	SuperCredState         string    `json:"supercred_state"`
	CompletedAt            time.Time `json:"completed_at"`
	LatencyMs              int64     `json:"latency_ms"`
}

// StunExecutor defines the interface for stunning a compromised agent across SaaS & IAM.
type StunExecutor interface {
	ExecuteStun(ctx context.Context, req StunRequest) (*StunResult, error)
}

// MemoryStunExecutor provides in-memory mock execution for testing and local cluster demos.
type MemoryStunExecutor struct {
	mu           sync.Mutex
	stunnedAgents map[string]*StunResult
}

// NewMemoryStunExecutor creates a new memory-backed stun cascade executor.
func NewMemoryStunExecutor() *MemoryStunExecutor {
	return &MemoryStunExecutor{
		stunnedAgents: make(map[string]*StunResult),
	}
}

// ExecuteStun performs simulated sub-second SA disablement, OpenBao lease revocation, and SuperCred state update.
func (m *MemoryStunExecutor) ExecuteStun(ctx context.Context, req StunRequest) (*StunResult, error) {
	start := time.Now()

	if req.AgentID == "" && req.ServiceAccountEmail == "" {
		return nil, fmt.Errorf("agent_id or service_account_email is required for stun cascade")
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	key := req.AgentID
	if key == "" {
		key = req.ServiceAccountEmail
	}

	res := &StunResult{
		AgentID:                key,
		Status:                 "STUNNED",
		ServiceAccountDisabled: true,
		OpenBaoLeaseRevoked:    true,
		SuperCredState:         "STUNNED",
		CompletedAt:            time.Now().UTC(),
		LatencyMs:              time.Since(start).Milliseconds(),
	}

	m.stunnedAgents[key] = res
	return res, nil
}

// IsStunned checks if an agent has been stunned.
func (m *MemoryStunExecutor) IsStunned(agentID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, exists := m.stunnedAgents[agentID]
	return exists
}
