package transform

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/client"
)

func TestTransformWorkspaceEvent(t *testing.T) {
	evt := client.WorkspaceEvent{
		ID:         "evt-test-1",
		Type:       client.EventTypeDrive,
		ActorEmail: "agent@corp.internal",
		ActorID:    "spiffe://osramp.local/ns/agents/sa/agent-1",
		ActorIP:    "10.0.0.1",
		Timestamp:  time.Now().UTC(),
		EventName:  "download",
		Parameters: map[string]string{
			"doc_title": "Confidential-Financials.pdf",
		},
	}

	obs, err := TransformWorkspaceEvent(evt)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if obs.Layer != model.LayerApplicationSaaS {
		t.Errorf("expected layer application_saas, got %s", obs.Layer)
	}
	if obs.ActorHint != evt.ActorEmail {
		t.Errorf("expected actor hint %s, got %s", evt.ActorEmail, obs.ActorHint)
	}
	if obs.Labels["event_name"] != "download" {
		t.Errorf("expected event_name download, got %s", obs.Labels["event_name"])
	}
	if obs.Labels["param_doc_title"] != "Confidential-Financials.pdf" {
		t.Errorf("expected doc_title Confidential-Financials.pdf, got %s", obs.Labels["param_doc_title"])
	}
	if obs.Confidence < 0.9 {
		t.Errorf("expected high confidence, got %f", obs.Confidence)
	}
}

func TestTransformBatch(t *testing.T) {
	mockClient := client.NewMockReportsClient()
	events, _ := mockClient.PollEvents(nil, time.Time{})

	obsList, err := TransformBatch(events)
	if err != nil {
		t.Fatalf("batch transformation failed: %v", err)
	}
	if len(obsList) != len(events) {
		t.Errorf("expected %d observations, got %d", len(events), len(obsList))
	}
}
