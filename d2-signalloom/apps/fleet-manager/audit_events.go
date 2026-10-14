package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// AuditEvent represents an immutable record of an automated or manual containment action.
type AuditEvent struct {
	EventID           string   `json:"eventId"`
	Timestamp         string   `json:"timestamp"`
	ActionType        string   `json:"actionType"`
	PolicyName        string   `json:"policyName,omitempty"`
	TriggerCondition  string   `json:"triggerCondition,omitempty"`
	TargetAgentID     string   `json:"targetAgentId"`
	AffectedAgents    []string `json:"affectedAgents"`
	DurationMs        int64    `json:"durationMs"`
	// The three risk fields are POINTERS so that "no risk figure" is structurally
	// absent rather than a zero, and they are omitted when nothing computed one.
	//
	// They used to be float64 and the manual-stun and recover handlers wrote
	// RiskBefore 847000.0 / RiskAfter 12400.0 / RiskDelta -834600.0
	// unconditionally, on every event. That is the same literal this service's
	// own read path now REFUSES to report: aggregateRisk answers
	// AUTHORED_NOT_COMPUTED because fleet.yaml's figure is authored
	// configuration and not a measurement (see topology.go). So the refusal was
	// on the read path while the audit trail still asserted the figures as
	// fact -- and an audit trail is the worst place for that, because it is the
	// record someone later cites.
	//
	// A zero would have been no better. In a money field a zero reads as the
	// claim "no risk", which is itself a figure. Absent reads as absent.
	// policy_engine.go computes these from real inputs and still populates
	// them, so the fields are not dead -- only the fabricated writes are gone.
	RiskBefore        *float64 `json:"riskBefore,omitempty"`
	RiskAfter         *float64 `json:"riskAfter,omitempty"`
	RiskDelta         *float64 `json:"riskDelta,omitempty"`
	Actor             string   `json:"actor"`
	OperatorSignature string   `json:"operatorSignature"`
}

// AuditRingBuffer maintains a bounded, thread-safe FIFO history of audit events
// and broadcasts new events to active SSE subscribers.
type AuditRingBuffer struct {
	mu          sync.RWMutex
	capacity    int
	events      []AuditEvent
	subscribers map[chan AuditEvent]struct{}
}

// NewAuditRingBuffer creates a new audit ring buffer with the specified capacity.
func NewAuditRingBuffer(capacity int) *AuditRingBuffer {
	if capacity <= 0 {
		capacity = 1000
	}
	return &AuditRingBuffer{
		capacity:    capacity,
		events:      make([]AuditEvent, 0, capacity),
		subscribers: make(map[chan AuditEvent]struct{}),
	}
}

// Append adds a new audit event, evicts the oldest entry if capacity is exceeded,
// and broadcasts the event to all active subscribers without blocking.
func (b *AuditRingBuffer) Append(evt AuditEvent) {
	if evt.EventID == "" {
		evt.EventID = fmt.Sprintf("evt-%d-%s", time.Now().UnixNano(), evt.TargetAgentID)
	}
	if evt.Timestamp == "" {
		evt.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}
	if evt.OperatorSignature == "" {
		h := sha256.New()
		h.Write([]byte(fmt.Sprintf("%s:%s:%s:%s", evt.EventID, evt.ActionType, evt.TargetAgentID, evt.Actor)))
		evt.OperatorSignature = "sig-sha256-" + hex.EncodeToString(h.Sum(nil))[:16]
	}

	b.mu.Lock()
	if len(b.events) >= b.capacity {
		// FIFO eviction: drop the oldest event (index 0)
		b.events = b.events[1:]
	}
	b.events = append(b.events, evt)

	// Collect active subscribers to notify outside of lock
	subs := make([]chan AuditEvent, 0, len(b.subscribers))
	for ch := range b.subscribers {
		subs = append(subs, ch)
	}
	b.mu.Unlock()

	// Non-blocking notification to all subscribers
	for _, ch := range subs {
		select {
		case ch <- evt:
		default:
			// Subscriber buffer full: drop to prevent slow clients hanging server
		}
	}
}

// List returns a slice of audit events matching optional filters.
func (b *AuditRingBuffer) List(limit int, targetAgent, actionType string) []AuditEvent {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if limit <= 0 || limit > len(b.events) {
		limit = len(b.events)
	}

	res := make([]AuditEvent, 0, limit)
	// Iterate in reverse (newest first)
	for i := len(b.events) - 1; i >= 0 && len(res) < limit; i-- {
		evt := b.events[i]
		if targetAgent != "" && evt.TargetAgentID != targetAgent {
			continue
		}
		if actionType != "" && evt.ActionType != actionType {
			continue
		}
		res = append(res, evt)
	}
	return res
}

// Count returns total events currently stored.
func (b *AuditRingBuffer) Count() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.events)
}

// Subscribe registers a new subscriber channel with a buffer.
func (b *AuditRingBuffer) Subscribe() chan AuditEvent {
	b.mu.Lock()
	defer b.mu.Unlock()
	ch := make(chan AuditEvent, 64)
	b.subscribers[ch] = struct{}{}
	return ch
}

// Unsubscribe removes a subscriber channel.
func (b *AuditRingBuffer) Unsubscribe(ch chan AuditEvent) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.subscribers[ch]; ok {
		delete(b.subscribers, ch)
		close(ch)
	}
}

// handleAuditEvents returns paginated audit events matching query parameters.
func (s *server) handleAuditEvents(w http.ResponseWriter, r *http.Request) {
	defer drainAndCloseBody(r)
	if !requireReadMethod(w, r) {
		return
	}

	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 {
			if parsed > 500 {
				parsed = 500
			}
			limit = parsed
		}
	}

	targetAgent := r.URL.Query().Get("agent")
	actionType := r.URL.Query().Get("action")

	buf := s.getAuditBuffer()
	events := buf.List(limit, targetAgent, actionType)

	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	json.NewEncoder(w).Encode(map[string]any{
		"events": events,
		"count":  len(events),
		"total":  buf.Count(),
	})
}

// handleAuditStream handles real-time SSE event streaming for operators.
func (s *server) handleAuditStream(w http.ResponseWriter, r *http.Request) {
	defer drainAndCloseBody(r)
	if !requireReadMethod(w, r) {
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported: flusher unavailable")
		return
	}

	// Send initial ping to establish connection
	if _, err := fmt.Fprintf(w, ": connected\n\n"); err != nil {
		return
	}
	flusher.Flush()

	buf := s.getAuditBuffer()
	sub := buf.Subscribe()
	defer buf.Unsubscribe(sub)

	for {
		select {
		case <-r.Context().Done():
			return
		case evt, ok := <-sub:
			if !ok {
				return
			}
			data, err := json.Marshal(evt)
			if err != nil {
				continue
			}
			if _, err := fmt.Fprintf(w, "event: audit\ndata: %s\n\n", data); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}
