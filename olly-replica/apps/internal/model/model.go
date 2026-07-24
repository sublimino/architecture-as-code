// Package model holds the Go shapes of the contract payloads and the MCP
// wire types. Field sets mirror the JSON Schemas exactly (the schemas set
// additionalProperties: false); the contracts unit test round-trips these
// structs through the schemas so drift fails the image build.
package model

// Event is an eligible-event.v1 payload: what Olly consumes from the NOI
// Event Queue or the IO-Declined topic. The correlation-ID is the join key
// throughout the flow.
type Event struct {
	SchemaVersion  string         `json:"schema_version"`
	EventID        string         `json:"event_id"`
	CorrelationID  string         `json:"correlation_id"`
	AppID          string         `json:"app_id"`
	CI             string         `json:"ci,omitempty"`
	Host           string         `json:"host,omitempty"`
	Source         string         `json:"source"`
	AlertType      string         `json:"alert_type"`
	Severity       int            `json:"severity"`
	DeclinedReason string         `json:"declined_reason,omitempty"`
	OccurredAt     string         `json:"occurred_at"`
	Payload        map[string]any `json:"payload"`
}

// Enrichment is an rca-enrichment.v1 payload: what Olly publishes to the
// event_response topic. The Mapping Service consumes this and updates the
// ServiceNow ticket.
type Enrichment struct {
	SchemaVersion  string     `json:"schema_version"`
	CorrelationID  string     `json:"correlation_id"`
	IdempotencyKey string     `json:"idempotency_key"`
	EnrichmentPass int        `json:"enrichment_pass,omitempty"`
	Agent          Agent      `json:"agent"`
	CI             string     `json:"ci,omitempty"`
	RCA            RCA        `json:"rca"`
	Evidence       []Evidence `json:"evidence,omitempty"`
	Redaction      Redaction  `json:"redaction"`
}

type Agent struct {
	Name      string `json:"name"`
	Version   string `json:"version"`
	EvalRunID string `json:"eval_run_id"`
	ModelID   string `json:"model_id,omitempty"`
}

type RCA struct {
	Summary          string          `json:"summary"`
	ProbableCause    string          `json:"probable_cause"`
	FaultDomain      string          `json:"fault_domain,omitempty"`
	ConfidenceScore  float64         `json:"confidence_score"`
	AffectedCIs      []string        `json:"affected_cis,omitempty"`
	SuspectedChange  string          `json:"suspected_change,omitempty"`
	EvidenceTimeline []TimelineEntry `json:"evidence_timeline,omitempty"`
	SuggestedActions []string        `json:"suggested_actions,omitempty"`
}

// TimelineEntry is one dated observation in the evidence timeline the RCA
// rests on, each attributed to the source it came from.
type TimelineEntry struct {
	At     string `json:"at,omitempty"`
	Source string `json:"source"`
	Detail string `json:"detail"`
}

type Evidence struct {
	Source     string `json:"source"`
	Scope      string `json:"scope"`
	Query      string `json:"query"`
	DocCount   int    `json:"doc_count"`
	ObservedAt string `json:"observed_at,omitempty"`
}

type Redaction struct {
	Applied      bool `json:"applied"`
	SecretsFound int  `json:"secrets_found"`
}

// Decision is a pipeline-decision.v1 payload: one record per gate the flow
// evaluates, published to olly.pipeline.decisions and keyed by correlation-ID.
// Observability only: emitting a decision never changes routing. Together the
// records for one correlation-ID are that incident's causality chain.
type Decision struct {
	SchemaVersion   string         `json:"schema_version"`
	CorrelationID   string         `json:"correlation_id"`
	EventID         string         `json:"event_id"`
	AppID           string         `json:"app_id"`
	Component       string         `json:"component"`
	Gate            string         `json:"gate"`
	Branch          string         `json:"branch"`
	Reason          string         `json:"reason"`
	TS              string         `json:"ts"`
	EnrichmentPass  int            `json:"enrichment_pass,omitempty"`
	FaultDomain     string         `json:"fault_domain,omitempty"`
	ConfidenceScore float64        `json:"confidence_score,omitempty"`
	DurationMS      float64        `json:"duration_ms,omitempty"`
	Detail          map[string]any `json:"detail,omitempty"`
}

// SearchRequest / SearchResponse are the elk_search_logs MCP wire types.
type SearchRequest struct {
	IndexPattern     string `json:"index_pattern"`
	Query            string `json:"query"`
	Size             int    `json:"size,omitempty"`
	TimeRangeMinutes int    `json:"time_range_minutes,omitempty"`
}

type SearchResponse struct {
	DocCount int      `json:"doc_count"`
	Hits     []LogHit `json:"hits"`
}

type LogHit struct {
	Timestamp string `json:"timestamp"`
	AppID     string `json:"app_id"`
	Level     string `json:"level"`
	Message   string `json:"message"`
}
