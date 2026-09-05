// Package workspacesaas defines the normalised SaaS adapter contract and collector
// for Google Workspace, Microsoft 365, and generic SaaS application audit signals.
//
// Live provider integration is intentionally deferred (SFDP-P2-6); this package defines
// the stable, versioned provider-agnostic contract and fixtures required by the
// workspace_* correlation rules.
package workspacesaas

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// ProviderType identifies the SaaS provider family.
type ProviderType string

const (
	ProviderGoogleWorkspace ProviderType = "google_workspace"
	ProviderMicrosoft365     ProviderType = "microsoft_365"
	ProviderSlack            ProviderType = "slack"
	ProviderGenericSaaS      ProviderType = "generic_saas"
)

// SaaSEventType categorizes normalised SaaS audit signals.
type SaaSEventType string

const (
	// EventVolumeSpike represents high-volume download, export, or bulk transfer activity.
	EventVolumeSpike SaaSEventType = "workspace_volume_spike"
	// EventExternalOAuthGrant represents consent or token grant to external/unverified OAuth apps.
	EventExternalOAuthGrant SaaSEventType = "workspace_external_oauth_grant"
	// EventSuspiciousLogin represents an anomalous or high-risk authentication event.
	EventSuspiciousLogin SaaSEventType = "workspace_suspicious_login_egress"
	// EventDocumentAccess represents sensitive document read/share operations.
	EventDocumentAccess SaaSEventType = "workspace_document_access"
	// EventAdminPrivilege represents admin role delegation or policy changes in SaaS tenant.
	EventAdminPrivilege SaaSEventType = "workspace_admin_privilege"
)

// SaaSAdapter is the provider-agnostic interface that vendor-specific implementations
// (e.g. Google Workspace Reports API or Microsoft 365 Management Activity API) satisfy.
type SaaSAdapter interface {
	// Provider returns the SaaS provider type handled by this adapter.
	Provider() ProviderType
	// Convert normalises a raw vendor payload into a provider-agnostic NormalisedSaaSEvent.
	Convert(ctx context.Context, raw []byte) (*NormalisedSaaSEvent, error)
}

// NormalisedSaaSEvent captures the provider-agnostic fields required by the workspace_*
// CEL correlation rules and downstream identity resolution.
type NormalisedSaaSEvent struct {
	// EventID is the unique identifier from the SaaS audit log.
	EventID string `json:"event_id"`
	// Provider names the source SaaS platform.
	Provider ProviderType `json:"provider"`
	// Timestamp is the UTC time the SaaS activity occurred.
	Timestamp time.Time `json:"timestamp"`
	// EventType categorises the event signal.
	EventType SaaSEventType `json:"event_type"`
	// ActorHint is the principal identifier (email, UPN, account ID) for correlation joins.
	ActorHint string `json:"actor_hint"`
	// Layer overrides the default observability layer (defaults to LayerApplicationSaaS, or LayerIdentityAuth for logins).
	Layer model.Layer `json:"layer,omitempty"`
	// Fidelity is the evidence tier (default: FidelityStrong or FidelitySuggestive).
	Fidelity model.FidelityTier `json:"fidelity,omitempty"`
	// Confidence score in [0.0, 1.0].
	Confidence float64 `json:"confidence,omitempty"`
	// ResourceID identifies the SaaS asset (Drive file ID, SharePoint site, Mailbox, App ID).
	ResourceID string `json:"resource_id,omitempty"`
	// Action describes the specific operation (e.g. "download", "export", "consent_grant", "login").
	Action string `json:"action,omitempty"`
	// VolumeBytes is the payload size in bytes (for volume spike analysis).
	VolumeBytes int64 `json:"volume_bytes,omitempty"`
	// ItemCount is the number of items/files involved.
	ItemCount int64 `json:"item_count,omitempty"`
	// ClientIP is the caller's IP address.
	ClientIP string `json:"client_ip,omitempty"`
	// UserAgent is the client user-agent string.
	UserAgent string `json:"user_agent,omitempty"`
	// OAuthAppID is the client ID for OAuth consent/grant events.
	OAuthAppID string `json:"oauth_app_id,omitempty"`
	// OAuthAppName is the human-readable name of the OAuth application.
	OAuthAppName string `json:"oauth_app_name,omitempty"`
	// OAuthScopes lists requested/granted OAuth permission scopes.
	OAuthScopes []string `json:"oauth_scopes,omitempty"`
	// RiskLevel indicates provider-reported risk assessment (e.g. "high", "medium", "low").
	RiskLevel string `json:"risk_level,omitempty"`
	// RawEvidenceRef is a URI linking to the upstream evidence record.
	RawEvidenceRef string `json:"raw_evidence_ref,omitempty"`
	// Description provides human-readable summary of the event.
	Description string `json:"description,omitempty"`
	// Labels holds arbitrary key-value metadata for filtering and display.
	Labels map[string]string `json:"labels,omitempty"`
}

// Validate checks that required fields are present on the normalised event.
func (e *NormalisedSaaSEvent) Validate() error {
	if e.EventID == "" {
		return errors.New("event_id is required")
	}
	if e.Provider == "" {
		return errors.New("provider is required")
	}
	if e.Timestamp.IsZero() {
		return errors.New("timestamp is required")
	}
	if e.EventType == "" {
		return errors.New("event_type is required")
	}
	if e.ActorHint == "" {
		return errors.New("actor_hint is required for correlation join")
	}
	return nil
}

// ToObservation converts the normalised SaaS event into a canonical model.Observation.
func (e *NormalisedSaaSEvent) ToObservation() (*model.Observation, error) {
	if err := e.Validate(); err != nil {
		return nil, fmt.Errorf("invalid normalised saas event: %w", err)
	}

	layer := e.Layer
	if layer == "" {
		if e.EventType == EventSuspiciousLogin {
			layer = model.LayerIdentityAuth
		} else {
			layer = model.LayerApplicationSaaS
		}
	}

	fidelity := e.Fidelity
	if fidelity == "" {
		switch e.EventType {
		case EventExternalOAuthGrant, EventSuspiciousLogin:
			fidelity = model.FidelityStrong
		case EventVolumeSpike:
			fidelity = model.FidelitySuggestive
		default:
			fidelity = model.FidelitySuggestive
		}
	}

	confidence := e.Confidence
	if confidence <= 0 {
		confidence = fidelity.FidelityWeight()
	}

	rawRef := e.RawEvidenceRef
	if rawRef == "" {
		rawRef = fmt.Sprintf("%s://audit/%s/%s", e.Provider, e.EventType, e.EventID)
	}

	labels := make(map[string]string)
	for k, v := range e.Labels {
		labels[k] = v
	}
	labels["provider"] = string(e.Provider)
	labels["event_type"] = string(e.EventType)
	if e.Action != "" {
		labels["action"] = e.Action
	}
	if e.ResourceID != "" {
		labels["resource_id"] = e.ResourceID
	}
	if e.VolumeBytes > 0 {
		labels["volume_bytes"] = fmt.Sprintf("%d", e.VolumeBytes)
	}
	if e.ItemCount > 0 {
		labels["item_count"] = fmt.Sprintf("%d", e.ItemCount)
	}
	if e.ClientIP != "" {
		labels["client_ip"] = e.ClientIP
	}
	if e.OAuthAppID != "" {
		labels["oauth_app_id"] = e.OAuthAppID
	}
	if e.OAuthAppName != "" {
		labels["oauth_app_name"] = e.OAuthAppName
	}
	if len(e.OAuthScopes) > 0 {
		labels["oauth_scopes"] = fmt.Sprintf("%v", e.OAuthScopes)
	}
	if e.RiskLevel != "" {
		labels["risk_level"] = e.RiskLevel
	}

	desc := e.Description
	if desc == "" {
		desc = fmt.Sprintf("%s audit: %s on %s by %s", e.Provider, e.EventType, e.ResourceID, e.ActorHint)
	}

	obs := &model.Observation{
		ID:             fmt.Sprintf("saas-%s-%s", e.Provider, e.EventID),
		Timestamp:      e.Timestamp.UTC(),
		Layer:          layer,
		Fidelity:       fidelity,
		Source:         fmt.Sprintf("%s.audit", e.Provider),
		Confidence:     confidence,
		ActorHint:      e.ActorHint,
		RawEvidenceRef: rawRef,
		Labels:         labels,
		Description:    desc,
	}

	if err := obs.Validate(); err != nil {
		return nil, fmt.Errorf("converted observation validation failed: %w", err)
	}

	return obs, nil
}
