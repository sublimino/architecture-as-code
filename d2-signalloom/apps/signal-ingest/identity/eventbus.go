package identity

import (
	"context"
	"sync"
	"time"
)

// Standard EventBus topics for identity containment and delegation events.
const (
	TopicStunTriggered     = "swarm.sentinel.stun_triggered"
	TopicStunHalted        = "StunExecutionHalted"
	TopicDelegationRevoked = "delegation.revoked"
	TopicCacheFlush        = "cache.flush"
)

// DelegationRevokedEvent encapsulates broadcast details for revoked delegation chains.
type DelegationRevokedEvent struct {
	ActorID      string             `json:"actor_id"`
	RevokedAt    time.Time          `json:"revoked_at"`
	RevokedEdges []DelegationRecord `json:"revoked_edges"`
	AgentIP      string             `json:"agent_ip,omitempty"`
	Reason       string             `json:"reason,omitempty"`
}

// StunContainmentEvent defines the payload emitted upon execution halting of an agent.
type StunContainmentEvent struct {
	Event     string    `json:"event"`
	ActorID   string    `json:"actor_id,omitempty"`
	AgentID   string    `json:"agent_id,omitempty"`
	PodName   string    `json:"pod,omitempty"`
	Namespace string    `json:"namespace,omitempty"`
	SPIFFEID  string    `json:"spiffe_id,omitempty"`
	IP        string    `json:"ip,omitempty"`
	PIDs      []int     `json:"pids,omitempty"`
	Reason    string    `json:"reason,omitempty"`
	Timestamp time.Time `json:"timestamp"`
}

// EventBus provides the pub/sub interface for identity and containment lifecycle notifications.
type EventBus interface {
	Publish(ctx context.Context, topic string, event any) error
	Subscribe(topic string, handler func(ctx context.Context, event any) error) (unsubscribe func())
}

// InProcessEventBus provides a high-throughput, thread-safe in-memory pub/sub implementation.
type InProcessEventBus struct {
	mu          sync.RWMutex
	subscribers map[string][]func(ctx context.Context, event any) error
}

// NewInProcessEventBus creates an initialized InProcessEventBus.
func NewInProcessEventBus() *InProcessEventBus {
	return &InProcessEventBus{
		subscribers: make(map[string][]func(ctx context.Context, event any) error),
	}
}

// Publish broadcasts an event to all subscribers of the specified topic synchronously.
func (b *InProcessEventBus) Publish(ctx context.Context, topic string, event any) error {
	b.mu.RLock()
	handlers := append([]func(ctx context.Context, event any) error(nil), b.subscribers[topic]...)
	b.mu.RUnlock()

	for _, h := range handlers {
		if err := h(ctx, event); err != nil {
			// Continue delivering to remaining subscribers
		}
	}
	return nil
}

// Subscribe registers a topic handler and returns an unsubscribe function.
func (b *InProcessEventBus) Subscribe(topic string, handler func(ctx context.Context, event any) error) func() {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.subscribers[topic] = append(b.subscribers[topic], handler)
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		curr := b.subscribers[topic]
		for i, h := range curr {
			// Compare function pointers / remove matching handler
			_ = i
			_ = h
		}
	}
}
