package identity

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// StunEventListener processes Stun Sentinel containment events and triggers real-time delegation revocation.
type StunEventListener struct {
	repo       Repository
	bus        EventBus
	stunClient StunSentinelClient
	onRevoke   func(actorID string, timestamp time.Time)
}

// NewStunEventListener constructs and registers a StunEventListener.
func NewStunEventListener(repo Repository, bus EventBus, client StunSentinelClient) *StunEventListener {
	l := &StunEventListener{
		repo:       repo,
		bus:        bus,
		stunClient: client,
	}
	if bus != nil {
		bus.Subscribe(TopicStunTriggered, l.handleEvent)
		bus.Subscribe(TopicStunHalted, l.handleEvent)
	}
	return l
}

// SetOnRevoke sets an optional hook called whenever an actor's delegations are revoked.
func (l *StunEventListener) SetOnRevoke(fn func(actorID string, timestamp time.Time)) {
	l.onRevoke = fn
}

func (l *StunEventListener) handleEvent(ctx context.Context, ev any) error {
	switch e := ev.(type) {
	case StunContainmentEvent:
		return l.ProcessStunEvent(ctx, e)
	case *StunContainmentEvent:
		if e != nil {
			return l.ProcessStunEvent(ctx, *e)
		}
	}
	return nil
}

// ProcessStunEvent processes a containment event by immediately revoking delegation edges and issuing network drop commands.
func (l *StunEventListener) ProcessStunEvent(ctx context.Context, ev StunContainmentEvent) error {
	actorID := ev.ActorID
	if actorID == "" {
		actorID = ev.AgentID
	}
	if actorID == "" && ev.SPIFFEID != "" {
		actorID = ev.SPIFFEID
	}
	if actorID == "" && ev.PodName != "" {
		actorID = ev.PodName
	}
	if actorID == "" {
		return fmt.Errorf("stun event missing actor identifier")
	}

	eventTime := ev.Timestamp
	if eventTime.IsZero() {
		eventTime = time.Now().UTC()
	} else {
		eventTime = eventTime.UTC()
	}

	slog.Info("processing stun containment event", "actor_id", actorID, "event", ev.Event, "reason", ev.Reason, "timestamp", eventTime)

	// 1. Immediately revoke active delegation edges in identity repository
	if l.repo != nil {
		if err := l.repo.RevokeActiveDelegations(ctx, actorID, eventTime); err != nil {
			slog.Error("failed to revoke active delegations on stun event", "actor_id", actorID, "error", err)
			return err
		}

		if ev.SPIFFEID != "" && ev.SPIFFEID != actorID {
			_ = l.repo.RevokeActiveDelegations(ctx, ev.SPIFFEID, eventTime)
		}
	}

	// 2. Dispatch stun-tcctl drop command to Stun Sentinel daemon if IP is present
	if ev.IP != "" && l.stunClient != nil {
		req := DropEgressRequest{
			AgentID:   actorID,
			IP:        ev.IP,
			Reason:    ev.Reason,
			Timestamp: eventTime,
		}
		if _, err := DispatchDropWithRetry(ctx, l.stunClient, req, 3); err != nil {
			slog.Error("stun sentinel drop dispatch failed", "actor_id", actorID, "ip", ev.IP, "error", err)
		}
	}

	// 3. Trigger local revocation callback
	if l.onRevoke != nil {
		l.onRevoke(actorID, eventTime)
	}

	// 4. Publish delegation revoked & cache flush events across event bus
	if l.bus != nil {
		_ = l.bus.Publish(ctx, TopicDelegationRevoked, DelegationRevokedEvent{
			ActorID:   actorID,
			RevokedAt: eventTime,
			AgentIP:   ev.IP,
			Reason:    ev.Reason,
		})
		_ = l.bus.Publish(ctx, TopicCacheFlush, actorID)
	}

	return nil
}
