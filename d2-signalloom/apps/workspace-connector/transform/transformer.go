package transform

import (
	"fmt"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/client"
)

// TransformWorkspaceEvent converts a Workspace Reports API event into a canonical Signal Loom observation.
func TransformWorkspaceEvent(evt client.WorkspaceEvent) (model.Observation, error) {
	var layer model.Layer
	var fidelity model.FidelityTier = model.FidelityStrong
	var confidence float64 = 0.95

	switch evt.Type {
	case client.EventTypeDrive:
		layer = model.LayerApplicationSaaS
	case client.EventTypeToken:
		layer = model.LayerIdentityAuth
	case client.EventTypeLogin:
		layer = model.LayerIdentityAuth
	default:
		return model.Observation{}, fmt.Errorf("unsupported workspace event type: %s", evt.Type)
	}

	labels := make(map[string]string)
	labels["event_type"] = string(evt.Type)
	labels["event_name"] = evt.EventName
	labels["actor_email"] = evt.ActorEmail
	labels["actor_ip"] = evt.ActorIP
	if evt.ActorID != "" {
		labels["spiffe_id"] = evt.ActorID
	}
	for k, v := range evt.Parameters {
		labels["param_"+k] = v
	}

	description := fmt.Sprintf("Workspace %s audit event: %s performed by %s", evt.Type, evt.EventName, evt.ActorEmail)

	obs := model.Observation{
		ID:             fmt.Sprintf("obs-ws-%s", evt.ID),
		Timestamp:      evt.Timestamp,
		Layer:          layer,
		Fidelity:       fidelity,
		Source:         "google-workspace-reports",
		Confidence:     confidence,
		ActorHint:      evt.ActorEmail,
		RawEvidenceRef: fmt.Sprintf("gsuite://reports/v1/%s/%s", evt.Type, evt.ID),
		Labels:         labels,
		Description:    description,
	}

	if err := obs.Validate(); err != nil {
		return model.Observation{}, fmt.Errorf("invalid transformed observation: %w", err)
	}

	return obs, nil
}

// TransformBatch converts a slice of workspace events to observations.
func TransformBatch(events []client.WorkspaceEvent) ([]model.Observation, error) {
	obsList := make([]model.Observation, 0, len(events))
	for _, e := range events {
		obs, err := TransformWorkspaceEvent(e)
		if err != nil {
			return nil, err
		}
		obsList = append(obsList, obs)
	}
	return obsList, nil
}
