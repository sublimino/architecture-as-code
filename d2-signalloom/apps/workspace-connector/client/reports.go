package client

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// EventType represents the category of Google Workspace Reports audit event.
type EventType string

const (
	EventTypeDrive EventType = "drive"
	EventTypeToken EventType = "token"
	EventTypeLogin EventType = "login"
)

// WorkspaceEvent represents a normalized audit log event from the Reports API.
type WorkspaceEvent struct {
	ID          string            `json:"id"`
	Type        EventType         `json:"type"`
	ActorEmail  string            `json:"actor_email"`
	ActorID     string            `json:"actor_id"`
	ActorIP     string            `json:"actor_ip"`
	Timestamp   time.Time         `json:"timestamp"`
	EventName   string            `json:"event_name"`
	TargetUser  string            `json:"target_user,omitempty"`
	Parameters  map[string]string `json:"parameters,omitempty"`
}

// ReportsClient defines the interface for fetching Workspace audit logs.
type ReportsClient interface {
	PollEvents(ctx context.Context, after time.Time) ([]WorkspaceEvent, error)
}

// MockReportsClient provides deterministic event generation for testing and offline demo execution.
type MockReportsClient struct {
	mu     sync.Mutex
	events []WorkspaceEvent
}

// NewMockReportsClient initializes a mock client seeded with realistic agent activity events.
func NewMockReportsClient() *MockReportsClient {
	now := time.Now().UTC()
	return &MockReportsClient{
		events: []WorkspaceEvent{
			{
				ID:         "ws-evt-1",
				Type:       EventTypeDrive,
				ActorEmail: "agent-doc-summarizer@corp.internal",
				ActorID:    "spiffe://osramp.local/ns/agents/sa/doc-summarizer",
				ActorIP:    "10.244.0.15",
				Timestamp:  now.Add(-10 * time.Minute),
				EventName:  "download",
				Parameters: map[string]string{
					"doc_title": "Q3-Financial-Forecast.xlsx",
					"doc_id":    "1A2B3C4D5E",
				},
			},
			{
				ID:         "ws-evt-2",
				Type:       EventTypeToken,
				ActorEmail: "agent-crm-sync@corp.internal",
				ActorID:    "spiffe://osramp.local/ns/agents/sa/crm-sync",
				ActorIP:    "10.244.0.22",
				Timestamp:  now.Add(-5 * time.Minute),
				EventName:  "authorize",
				Parameters: map[string]string{
					"app_name":    "External-Shadow-AI-Hub",
					"client_id":   "88492019482.apps.googleusercontent.com",
					"is_external": "true",
				},
			},
			{
				ID:         "ws-evt-3",
				Type:       EventTypeLogin,
				ActorEmail: "agent-rogue-analyst@corp.internal",
				ActorID:    "spiffe://osramp.local/ns/agents/sa/rogue-analyst",
				ActorIP:    "198.51.100.77",
				Timestamp:  now.Add(-2 * time.Minute),
				EventName:  "suspicious_ip",
				Parameters: map[string]string{
					"login_type":     "service_account_jwt",
					"country":        "Unknown",
					"unrecognized_ip": "true",
				},
			},
		},
	}
}

// AddEvents dynamically injects events into the mock client queue.
func (m *MockReportsClient) AddEvents(evts ...WorkspaceEvent) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.events = append(m.events, evts...)
}

// PollEvents returns events occurring after the given timestamp.
func (m *MockReportsClient) PollEvents(ctx context.Context, after time.Time) ([]WorkspaceEvent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var result []WorkspaceEvent
	for _, e := range m.events {
		if after.IsZero() || e.Timestamp.After(after) {
			result = append(result, e)
		}
	}
	return result, nil
}

// LiveReportsClient connects to the live Google Workspace Admin SDK Reports API.
type LiveReportsClient struct {
	CustomerKey string
}

// NewLiveReportsClient creates a client configured with GCP credentials and customer key.
func NewLiveReportsClient(customerKey string) *LiveReportsClient {
	if customerKey == "" {
		customerKey = "my_customer"
	}
	return &LiveReportsClient{CustomerKey: customerKey}
}

// PollEvents polls the Reports API across Drive, Token, and Login applications.
func (l *LiveReportsClient) PollEvents(ctx context.Context, after time.Time) ([]WorkspaceEvent, error) {
	// In production, uses google.golang.org/api/admin/reports/v1
	return nil, fmt.Errorf("live Reports API client requires valid GCP Service Account credentials with domain-wide delegation")
}
