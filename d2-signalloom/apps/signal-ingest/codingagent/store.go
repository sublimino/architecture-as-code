// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package codingagent

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// MinAggregateGroupSize is the minimum number of distinct data subjects/sessions
// required before an aggregate can be returned, preventing small-group re-identification.
const MinAggregateGroupSize = store.MinAggregateGroupSize // k=5

// ErrGroupSizeBelowAnonymityFloor is returned when an aggregate request spans fewer
// distinct entities than the k-anonymity floor.
var ErrGroupSizeBelowAnonymityFloor = store.ErrGroupSizeBelowAnonymityFloor

// ErrRecordNotFound is returned when a requested record is not found.
var ErrRecordNotFound = errors.New("codingagent: telemetry record not found")

// StoredRecord wraps a validated CodingAgentTelemetry event with server-observed
// metadata (receipt time, computed clock skew, deduplication key).
type StoredRecord struct {
	Event            CodingAgentTelemetry `json:"event"`
	ObservedAt       time.Time            `json:"observed_at"`
	ClockSkew        time.Duration        `json:"clock_skew"`
	ClockSkewMs      float64              `json:"clock_skew_ms"`
	DeduplicationKey string               `json:"deduplication_key"`
	IngestedAt       time.Time            `json:"ingested_at"`
	TenantID         string               `json:"tenant_id"`
	Subject          string               `json:"subject"`
}

// IngestResult represents the outcome of an event ingestion.
type IngestResult struct {
	Status           string        `json:"status"` // "ingested" | "duplicate"
	SessionID        string        `json:"session_id"`
	ObservedAt       string        `json:"observed_at"`
	ClockSkewMs      float64       `json:"clock_skew_ms"`
	Duplicate        bool          `json:"duplicate"`
	DeduplicationKey string        `json:"deduplication_key"`
}

// OrderingVerdict represents the certainty of causal ordering between two events.
type OrderingVerdict string

const (
	OrderingDefinite  OrderingVerdict = "definite"
	OrderingUncertain OrderingVerdict = "uncertain"
)

// OrderingConfidence describes the mathematical basis for an ordering verdict.
type OrderingConfidence string

const (
	ConfidenceMonotonicAnchor OrderingConfidence = "monotonic_anchor"
	ConfidenceSkewExceeded    OrderingConfidence = "skew_exceeded"
	ConfidenceSkewBounded     OrderingConfidence = "skew_bounded"
)

// OrderingResult describes the causal relationship between two events.
type OrderingResult struct {
	RecordA       string             `json:"record_a"`
	RecordB       string             `json:"record_b"`
	Verdict       OrderingVerdict    `json:"verdict"`        // "definite" | "uncertain"
	Confidence    OrderingConfidence `json:"confidence"`     // "monotonic_anchor" | "skew_exceeded" | "skew_bounded"
	EarlierRecord string             `json:"earlier_record"` // empty if uncertain
	TimeDeltaMs   float64            `json:"time_delta_ms"`
	SkewBoundMs   float64            `json:"skew_bound_ms"`
	Explanation   string             `json:"explanation"`
}

// AggregateFilter specifies filter criteria for aggregate computation.
type AggregateFilter struct {
	Harness   Harness   `json:"harness,omitempty"`
	TaskID    string    `json:"task_id,omitempty"`
	Shortcode string    `json:"shortcode,omitempty"`
	After     time.Time `json:"after,omitempty"`
	Before    time.Time `json:"before,omitempty"`
}

// AggregateResult represents k-anonymity protected summary metrics.
type AggregateResult struct {
	GroupSize           int                `json:"group_size"` // distinct subjects/sessions (must be >= MinAggregateGroupSize)
	TotalEvents         int                `json:"total_events"`
	TotalTokensIn       uint64             `json:"total_tokens_in"`
	TotalTokensOut      uint64             `json:"total_tokens_out"`
	TotalStepCount      uint64             `json:"total_step_count"`
	TotalElapsedS       uint64             `json:"total_elapsed_s"`
	ToolCounts          ToolCounts         `json:"tool_counts"`
	HarnessDistribution map[Harness]int    `json:"harness_distribution"`
	AvgClockSkewMs      float64            `json:"avg_clock_skew_ms"`
}

// TelemetryStore defines the storage and analysis interface for CodingAgentTelemetry.
type TelemetryStore interface {
	Ingest(ctx context.Context, tenantID, subject string, event *CodingAgentTelemetry) (*IngestResult, error)
	Query(ctx context.Context, tenantID string, filter AggregateFilter) ([]StoredRecord, error)
	Aggregate(ctx context.Context, tenantID string, filter AggregateFilter) (*AggregateResult, error)
	ResolveOrdering(ctx context.Context, tenantID string, recordA, recordB *StoredRecord) (*OrderingResult, error)
}

// MemoryStore is a concurrent, in-memory implementation of TelemetryStore.
type MemoryStore struct {
	mu      sync.RWMutex
	records map[string][]StoredRecord // keyed by tenantID
	dedup   map[string]struct{}       // keyed by tenantID:dedupKey
}

// NewMemoryStore constructs a new MemoryStore.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		records: make(map[string][]StoredRecord),
		dedup:   make(map[string]struct{}),
	}
}

// BuildDeduplicationKey constructs a deterministic deduplication key from session_id
// and monotonic progression (task_id, elapsed_s, step_count).
func BuildDeduplicationKey(event *CodingAgentTelemetry) string {
	// Deduplication is keyed by session_id + monotonic sequence/anchor, NOT wall-clock timestamp.
	// This prevents duplicate ingestion of retried messages while correctly admitting distinct steps.
	return fmt.Sprintf("%s:%s:%d:%d",
		event.SessionID,
		event.Kanban.TaskID,
		event.Kanban.ElapsedS,
		event.Metrics.StepCount,
	)
}

// Ingest processes and persists a validated CodingAgentTelemetry event under the verified tenant.
func (s *MemoryStore) Ingest(ctx context.Context, tenantID, subject string, event *CodingAgentTelemetry) (*IngestResult, error) {
	if tenantID == "" {
		return nil, errors.New("codingagent: tenantID cannot be empty")
	}
	if event == nil {
		return nil, errors.New("codingagent: event cannot be nil")
	}

	// Server observes the true arrival time (RFC3339Nano UTC)
	serverNow := time.Now().UTC()
	observedAtStr := serverNow.Format(time.RFC3339Nano)

	// Parse client-declared timestamp to compute clock skew
	clientTime, err := time.Parse(time.RFC3339Nano, event.Timestamp)
	if err != nil {
		clientTime, err = time.Parse(time.RFC3339, event.Timestamp)
		if err != nil {
			return nil, fmt.Errorf("codingagent: invalid timestamp %q: %w", event.Timestamp, err)
		}
	}

	// Compute clock skew: server_time - client_time
	// Stored alongside the record; the original event.Timestamp is NEVER silently modified.
	clockSkew := serverNow.Sub(clientTime)
	clockSkewMs := float64(clockSkew.Nanoseconds()) / 1e6

	dedupKey := BuildDeduplicationKey(event)
	tenantDedupKey := fmt.Sprintf("%s:%s", tenantID, dedupKey)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Check deduplication index
	if _, exists := s.dedup[tenantDedupKey]; exists {
		// Idempotent duplicate: acknowledge without duplicate metric storage
		return &IngestResult{
			Status:           "duplicate",
			SessionID:        event.SessionID,
			ObservedAt:       observedAtStr,
			ClockSkewMs:      clockSkewMs,
			Duplicate:        true,
			DeduplicationKey: dedupKey,
		}, nil
	}

	// Mark deduplication key
	s.dedup[tenantDedupKey] = struct{}{}

	// Stamp verified tenant and server observation timestamp on the event envelope
	eventCopy := *event
	eventCopy.TenantID = tenantID
	eventCopy.ObservedAt = observedAtStr

	record := StoredRecord{
		Event:            eventCopy,
		ObservedAt:       serverNow,
		ClockSkew:        clockSkew,
		ClockSkewMs:      clockSkewMs,
		DeduplicationKey: dedupKey,
		IngestedAt:       serverNow,
		TenantID:         tenantID,
		Subject:          subject,
	}

	s.records[tenantID] = append(s.records[tenantID], record)

	return &IngestResult{
		Status:           "ingested",
		SessionID:        event.SessionID,
		ObservedAt:       observedAtStr,
		ClockSkewMs:      clockSkewMs,
		Duplicate:        false,
		DeduplicationKey: dedupKey,
	}, nil
}

// Query retrieves stored telemetry records matching the given filter for a tenant.
func (s *MemoryStore) Query(ctx context.Context, tenantID string, filter AggregateFilter) ([]StoredRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	tenantRecords, ok := s.records[tenantID]
	if !ok {
		return []StoredRecord{}, nil
	}

	var results []StoredRecord
	for _, rec := range tenantRecords {
		if filter.Harness != "" && rec.Event.Harness != filter.Harness {
			continue
		}
		if filter.TaskID != "" && rec.Event.Kanban.TaskID != filter.TaskID {
			continue
		}
		if filter.Shortcode != "" && rec.Event.Kanban.Shortcode != filter.Shortcode {
			continue
		}
		if !filter.After.IsZero() && rec.ObservedAt.Before(filter.After) {
			continue
		}
		if !filter.Before.IsZero() && rec.ObservedAt.After(filter.Before) {
			continue
		}
		results = append(results, rec)
	}

	return results, nil
}

// Aggregate computes summary metrics across telemetry records while enforcing the k-anonymity floor.
func (s *MemoryStore) Aggregate(ctx context.Context, tenantID string, filter AggregateFilter) (*AggregateResult, error) {
	records, err := s.Query(ctx, tenantID, filter)
	if err != nil {
		return nil, err
	}

	// Distinct subjects/sessions set for small-group re-identification check
	subjects := make(map[string]struct{})
	for _, rec := range records {
		identKey := rec.Event.SessionID
		if rec.Subject != "" {
			identKey = rec.Subject + ":" + rec.Event.SessionID
		}
		subjects[identKey] = struct{}{}
	}

	groupSize := len(subjects)

	// ENFORCE k-ANONYMITY: Refuse to return aggregates for cohorts below the floor (k=5)
	if groupSize < MinAggregateGroupSize {
		return nil, fmt.Errorf("%w: cohort size is %d (minimum required is %d)",
			ErrGroupSizeBelowAnonymityFloor, groupSize, MinAggregateGroupSize)
	}

	res := &AggregateResult{
		GroupSize:           groupSize,
		TotalEvents:         len(records),
		HarnessDistribution: make(map[Harness]int),
	}

	var totalSkewMs float64
	for _, rec := range records {
		res.TotalTokensIn += rec.Event.Metrics.TokensIn
		res.TotalTokensOut += rec.Event.Metrics.TokensOut
		res.TotalStepCount += rec.Event.Metrics.StepCount
		res.TotalElapsedS += rec.Event.Kanban.ElapsedS

		tc := rec.Event.Metrics.ToolCounts
		res.ToolCounts.ViewFile += tc.ViewFile
		res.ToolCounts.WriteToFile += tc.WriteToFile
		res.ToolCounts.ReplaceFileContent += tc.ReplaceFileContent
		res.ToolCounts.RunCommand += tc.RunCommand
		res.ToolCounts.GrepSearch += tc.GrepSearch
		res.ToolCounts.FindByName += tc.FindByName
		res.ToolCounts.ListDir += tc.ListDir
		res.ToolCounts.ReadURLContent += tc.ReadURLContent
		res.ToolCounts.SearchWeb += tc.SearchWeb
		res.ToolCounts.InvokeSubagent += tc.InvokeSubagent
		res.ToolCounts.SendMessage += tc.SendMessage
		res.ToolCounts.ManageTask += tc.ManageTask
		res.ToolCounts.AskQuestion += tc.AskQuestion
		res.ToolCounts.OtherCount += tc.OtherCount

		res.HarnessDistribution[rec.Event.Harness]++
		totalSkewMs += rec.ClockSkewMs
	}

	if len(records) > 0 {
		res.AvgClockSkewMs = totalSkewMs / float64(len(records))
	}

	return res, nil
}

// ResolveOrdering evaluates the causal ordering between two telemetry records.
// For intra-workstation events (same session_id), it orders by monotonic sequence.
// For cross-workstation events, it bounds ordering against estimated clock skews,
// refusing to assert causal order if the time delta is within the skew uncertainty window.
func (s *MemoryStore) ResolveOrdering(ctx context.Context, tenantID string, recA, recB *StoredRecord) (*OrderingResult, error) {
	if recA == nil || recB == nil {
		return nil, errors.New("codingagent: records cannot be nil")
	}

	idA := fmt.Sprintf("%s:%s", recA.Event.SessionID, recA.DeduplicationKey)
	idB := fmt.Sprintf("%s:%s", recB.Event.SessionID, recB.DeduplicationKey)

	// Intra-workstation case: same session
	if recA.Event.SessionID == recB.Event.SessionID {
		// Use monotonic sequence (ElapsedS, StepCount)
		seqA := int64(recA.Event.Kanban.ElapsedS)*1000000 + int64(recA.Event.Metrics.StepCount)
		seqB := int64(recB.Event.Kanban.ElapsedS)*1000000 + int64(recB.Event.Metrics.StepCount)

		earlier := idA
		if seqB < seqA {
			earlier = idB
		}

		return &OrderingResult{
			RecordA:       idA,
			RecordB:       idB,
			Verdict:       OrderingDefinite,
			Confidence:    ConfidenceMonotonicAnchor,
			EarlierRecord: earlier,
			TimeDeltaMs:   math.Abs(float64(seqA - seqB)),
			SkewBoundMs:   0,
			Explanation:   "Ordered definitively via intra-workstation monotonic anchor",
		}, nil
	}

	// Inter-workstation case: cross-session
	timeA, errA := time.Parse(time.RFC3339Nano, recA.Event.Timestamp)
	if errA != nil {
		timeA, _ = time.Parse(time.RFC3339, recA.Event.Timestamp)
	}
	timeB, errB := time.Parse(time.RFC3339Nano, recB.Event.Timestamp)
	if errB != nil {
		timeB, _ = time.Parse(time.RFC3339, recB.Event.Timestamp)
	}

	timeDelta := timeA.Sub(timeB)
	timeDeltaMs := math.Abs(float64(timeDelta.Nanoseconds()) / 1e6)

	// Maximum absolute clock skew across both workstations
	maxSkewMs := math.Max(math.Abs(recA.ClockSkewMs), math.Abs(recB.ClockSkewMs))

	// Refuse to assert causal order if delta is smaller than or equal to the estimated skew bound
	if timeDeltaMs <= maxSkewMs {
		return &OrderingResult{
			RecordA:       idA,
			RecordB:       idB,
			Verdict:       OrderingUncertain,
			Confidence:    ConfidenceSkewBounded,
			EarlierRecord: "",
			TimeDeltaMs:   timeDeltaMs,
			SkewBoundMs:   maxSkewMs,
			Explanation: fmt.Sprintf(
				"Causal order is uncertain: observed delta (%.2f ms) is within cross-workstation clock-skew uncertainty bound (%.2f ms)",
				timeDeltaMs, maxSkewMs,
			),
		}, nil
	}

	// Time delta exceeds max skew: causal ordering can be statistically asserted
	earlier := idA
	if timeB.Before(timeA) {
		earlier = idB
	}

	return &OrderingResult{
		RecordA:       idA,
		RecordB:       idB,
		Verdict:       OrderingDefinite,
		Confidence:    ConfidenceSkewExceeded,
		EarlierRecord: earlier,
		TimeDeltaMs:   timeDeltaMs,
		SkewBoundMs:   maxSkewMs,
		Explanation: fmt.Sprintf(
			"Ordered with high confidence: observed delta (%.2f ms) exceeds clock-skew bound (%.2f ms)",
			timeDeltaMs, maxSkewMs,
		),
	}, nil
}
