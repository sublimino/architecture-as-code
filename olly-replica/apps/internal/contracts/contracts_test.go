package contracts

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/acme-co/osramp/olly-replica/apps/internal/model"
)

// The drift gate: round-trip the Go payload shapes through the schemas.
// If a contract and the code disagree, this fails, and it runs during the
// image build, so nothing ships with drifted contracts.

func setDir(t *testing.T) {
	if os.Getenv("CONTRACTS_DIR") == "" {
		t.Setenv("CONTRACTS_DIR", "../../../contracts")
	}
}

func TestEventMatchesEligibleEventSchema(t *testing.T) {
	setDir(t)
	schema, err := Load(EligibleEvent)
	if err != nil {
		t.Fatalf("load schema: %v", err)
	}
	ev := model.Event{
		SchemaVersion: "v1",
		EventID:       "evt-0001",
		CorrelationID: "corr-0001",
		AppID:         "inventory-service",
		CI:            "ci-inventory-01",
		Host:          "host-a",
		Source:        "replay",
		AlertType:     "app_failure_burst",
		Severity:      2,
		OccurredAt:    "2026-07-17T00:00:00Z",
		Payload:       map[string]any{"raw": "db connection pool exhausted"},
	}
	raw, _ := json.Marshal(ev)
	if err := ValidateJSON(schema, raw); err != nil {
		t.Fatalf("event does not validate against %s: %v", EligibleEvent, err)
	}
	// A message without the join key must be rejected.
	bad := map[string]any{"schema_version": "v1", "event_id": "x"}
	rawBad, _ := json.Marshal(bad)
	if err := ValidateJSON(schema, rawBad); err == nil {
		t.Fatal("event without correlation_id validated; the spoofed-event control is broken")
	}
}

func TestEnrichmentMatchesRcaSchema(t *testing.T) {
	setDir(t)
	schema, err := Load(RcaEnrichment)
	if err != nil {
		t.Fatalf("load schema: %v", err)
	}
	enr := model.Enrichment{
		SchemaVersion:  "v1",
		CorrelationID:  "corr-0001",
		IdempotencyKey: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		EnrichmentPass: 1,
		Agent: model.Agent{
			Name: "olly-sentinel", Version: "dev", EvalRunID: "local-dev", ModelID: "deterministic-fallback",
		},
		CI: "INVENTORY-APP-01",
		RCA: model.RCA{
			Summary:         "connection pool exhaustion after dependency slowdown",
			ProbableCause:   "stock-db latency exhausted the reduced pool",
			FaultDomain:     "dependency",
			ConfidenceScore: 0.75,
			AffectedCIs:     []string{"POSITIONS-LEDGER-DB-02"},
			SuspectedChange: "CHG0044821",
			EvidenceTimeline: []model.TimelineEntry{
				{At: "2026-07-17T13:58:00Z", Source: "drift", Detail: "CHG0044821 connection_pool.max 50 -> 20"},
				{At: "2026-07-17T14:02:00Z", Source: "elk", Detail: "pool exhausted: timeout acquiring connection"},
			},
			SuggestedActions: []string{"raise connection_pool.max back to 50"},
		},
		Evidence: []model.Evidence{{
			Source: "elk", Scope: "elk.logs.read",
			Query: "app_id:inventory-service AND level:ERROR", DocCount: 12,
			ObservedAt: "2026-07-17T00:00:00Z",
		}},
		Redaction: model.Redaction{Applied: true, SecretsFound: 1},
	}
	raw, _ := json.Marshal(enr)
	if err := ValidateJSON(schema, raw); err != nil {
		t.Fatalf("enrichment does not validate against %s: %v", RcaEnrichment, err)
	}
}
