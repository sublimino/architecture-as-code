package workspacesaas

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestNormalisedSaaSEvent_Validate(t *testing.T) {
	now := time.Now().UTC()

	tests := []struct {
		name    string
		event   NormalisedSaaSEvent
		wantErr bool
	}{
		{
			name: "valid volume spike event",
			event: NormalisedSaaSEvent{
				EventID:     "evt-001",
				Provider:    ProviderGoogleWorkspace,
				Timestamp:   now,
				EventType:   EventVolumeSpike,
				ActorHint:   "user@example.com",
				VolumeBytes: 104857600,
			},
			wantErr: false,
		},
		{
			name: "missing event_id",
			event: NormalisedSaaSEvent{
				Provider:  ProviderGoogleWorkspace,
				Timestamp: now,
				EventType: EventVolumeSpike,
				ActorHint: "user@example.com",
			},
			wantErr: true,
		},
		{
			name: "missing provider",
			event: NormalisedSaaSEvent{
				EventID:   "evt-001",
				Timestamp: now,
				EventType: EventVolumeSpike,
				ActorHint: "user@example.com",
			},
			wantErr: true,
		},
		{
			name: "missing timestamp",
			event: NormalisedSaaSEvent{
				EventID:   "evt-001",
				Provider:  ProviderGoogleWorkspace,
				EventType: EventVolumeSpike,
				ActorHint: "user@example.com",
			},
			wantErr: true,
		},
		{
			name: "missing event_type",
			event: NormalisedSaaSEvent{
				EventID:   "evt-001",
				Provider:  ProviderGoogleWorkspace,
				Timestamp: now,
				ActorHint: "user@example.com",
			},
			wantErr: true,
		},
		{
			name: "missing actor_hint",
			event: NormalisedSaaSEvent{
				EventID:   "evt-001",
				Provider:  ProviderGoogleWorkspace,
				Timestamp: now,
				EventType: EventVolumeSpike,
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.event.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestNormalisedSaaSEvent_ToObservation(t *testing.T) {
	now := time.Now().UTC()

	t.Run("volume spike mapping", func(t *testing.T) {
		evt := NormalisedSaaSEvent{
			EventID:     "vol-101",
			Provider:    ProviderGoogleWorkspace,
			Timestamp:   now,
			EventType:   EventVolumeSpike,
			ActorHint:   "analyst@corp.internal",
			ResourceID:  "drive/folder-xyz",
			Action:      "bulk_export",
			VolumeBytes: 209715200,
			ItemCount:   250,
			ClientIP:    "198.51.100.5",
		}

		obs, err := evt.ToObservation()
		if err != nil {
			t.Fatalf("ToObservation failed: %v", err)
		}

		if obs.ID != "saas-google_workspace-vol-101" {
			t.Errorf("unexpected ID: %s", obs.ID)
		}
		if obs.Layer != model.LayerApplicationSaaS {
			t.Errorf("expected layer %s, got %s", model.LayerApplicationSaaS, obs.Layer)
		}
		if obs.Fidelity != model.FidelitySuggestive {
			t.Errorf("expected fidelity %s, got %s", model.FidelitySuggestive, obs.Fidelity)
		}
		if obs.ActorHint != "analyst@corp.internal" {
			t.Errorf("expected ActorHint analyst@corp.internal, got %s", obs.ActorHint)
		}
		if obs.Labels["volume_bytes"] != "209715200" {
			t.Errorf("expected volume_bytes label, got %v", obs.Labels["volume_bytes"])
		}
		if obs.Labels["provider"] != "google_workspace" {
			t.Errorf("expected provider label, got %v", obs.Labels["provider"])
		}
	})

	t.Run("external oauth grant mapping", func(t *testing.T) {
		evt := NormalisedSaaSEvent{
			EventID:      "oauth-202",
			Provider:     ProviderMicrosoft365,
			Timestamp:    now,
			EventType:    EventExternalOAuthGrant,
			ActorHint:    "admin@corp.internal",
			OAuthAppID:   "app-uuid-999",
			OAuthAppName: "RogueCopilot",
			OAuthScopes:  []string{"Mail.Read", "Files.ReadWrite.All"},
		}

		obs, err := evt.ToObservation()
		if err != nil {
			t.Fatalf("ToObservation failed: %v", err)
		}

		if obs.Layer != model.LayerApplicationSaaS {
			t.Errorf("expected layer %s, got %s", model.LayerApplicationSaaS, obs.Layer)
		}
		if obs.Fidelity != model.FidelityStrong {
			t.Errorf("expected fidelity %s, got %s", model.FidelityStrong, obs.Fidelity)
		}
		if obs.Labels["oauth_app_id"] != "app-uuid-999" {
			t.Errorf("expected oauth_app_id label, got %v", obs.Labels["oauth_app_id"])
		}
	})

	t.Run("suspicious login mapping to identity layer", func(t *testing.T) {
		evt := NormalisedSaaSEvent{
			EventID:   "login-303",
			Provider:  ProviderGoogleWorkspace,
			Timestamp: now,
			EventType: EventSuspiciousLogin,
			ActorHint: "operator@corp.internal",
			ClientIP:  "203.0.113.199",
			RiskLevel: "high",
		}

		obs, err := evt.ToObservation()
		if err != nil {
			t.Fatalf("ToObservation failed: %v", err)
		}

		// Suspicious login defaults to LayerIdentityAuth for correlation join
		if obs.Layer != model.LayerIdentityAuth {
			t.Errorf("expected layer %s for suspicious login, got %s", model.LayerIdentityAuth, obs.Layer)
		}
		if obs.Fidelity != model.FidelityStrong {
			t.Errorf("expected fidelity %s, got %s", model.FidelityStrong, obs.Fidelity)
		}
		if obs.Labels["risk_level"] != "high" {
			t.Errorf("expected risk_level label, got %v", obs.Labels["risk_level"])
		}
	})
}

// Mock Google Workspace Reports API adapter
type mockGoogleWorkspaceAdapter struct{}

func (m *mockGoogleWorkspaceAdapter) Provider() ProviderType {
	return ProviderGoogleWorkspace
}

func (m *mockGoogleWorkspaceAdapter) Convert(ctx context.Context, raw []byte) (*NormalisedSaaSEvent, error) {
	var gwsRecord struct {
		Kind string `json:"kind"`
		ID   struct {
			Time       time.Time `json:"time"`
			UniqueQual string    `json:"uniqueQualifier"`
		} `json:"id"`
		Actor struct {
			Email string `json:"email"`
		} `json:"actor"`
		Events []struct {
			Type       string `json:"type"`
			Name       string `json:"name"`
			Parameters []struct {
				Name      string `json:"name"`
				Value     string `json:"value"`
				IntValue  int64  `json:"intValue,string"`
			} `json:"parameters"`
		} `json:"events"`
	}

	if err := json.Unmarshal(raw, &gwsRecord); err != nil {
		return nil, err
	}
	if len(gwsRecord.Events) == 0 {
		return nil, errors.New("empty events in gws record")
	}

	evt := &NormalisedSaaSEvent{
		EventID:   gwsRecord.ID.UniqueQual,
		Provider:  ProviderGoogleWorkspace,
		Timestamp: gwsRecord.ID.Time,
		ActorHint: gwsRecord.Actor.Email,
		EventType: EventVolumeSpike,
		Action:    gwsRecord.Events[0].Name,
	}
	for _, p := range gwsRecord.Events[0].Parameters {
		if p.Name == "num_bytes" {
			evt.VolumeBytes = p.IntValue
		}
	}
	return evt, nil
}

func TestSaaSAdapter_ContractImplementation(t *testing.T) {
	adapter := &mockGoogleWorkspaceAdapter{}
	if adapter.Provider() != ProviderGoogleWorkspace {
		t.Errorf("expected provider %s, got %s", ProviderGoogleWorkspace, adapter.Provider())
	}

	rawJSON := []byte(`{
		"kind": "admin#reports#activity",
		"id": {
			"time": "2026-09-05T12:00:00Z",
			"uniqueQualifier": "gws-act-9901"
		},
		"actor": {
			"email": "analyst-bot@corp.internal"
		},
		"events": [
			{
				"type": "drive",
				"name": "download",
				"parameters": [
					{"name": "num_bytes", "intValue": "104857600"}
				]
			}
		]
	}`)

	norm, err := adapter.Convert(context.Background(), rawJSON)
	if err != nil {
		t.Fatalf("Convert failed: %v", err)
	}

	if norm.EventID != "gws-act-9901" {
		t.Errorf("expected EventID gws-act-9901, got %s", norm.EventID)
	}
	if norm.ActorHint != "analyst-bot@corp.internal" {
		t.Errorf("expected ActorHint analyst-bot@corp.internal, got %s", norm.ActorHint)
	}
	if norm.VolumeBytes != 104857600 {
		t.Errorf("expected VolumeBytes 104857600, got %d", norm.VolumeBytes)
	}

	obs, err := norm.ToObservation()
	if err != nil {
		t.Fatalf("ToObservation failed: %v", err)
	}
	if obs.Layer != model.LayerApplicationSaaS {
		t.Errorf("expected layer %s, got %s", model.LayerApplicationSaaS, obs.Layer)
	}
}
