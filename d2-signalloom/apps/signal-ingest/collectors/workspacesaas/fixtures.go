package workspacesaas

import (
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DefaultWorkspaceFixtures returns a deterministic suite of SaaS observations
// tailored to satisfy and trigger all three workspace_* correlation rules.
func DefaultWorkspaceFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		// 1. workspace_volume_spike pair (Google Workspace Drive download spike + IAM token refresh)
		{
			ID:             "ws-saas-volume-001",
			Timestamp:      baseTime.Add(2 * time.Minute),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "google-workspace.drive-audit",
			Confidence:     0.75,
			ActorHint:      "workspace-analyst-sa@corp.internal",
			RawEvidenceRef: "workspace://drive/activities/export-spike-8472",
			Labels: map[string]string{
				"provider":     "google_workspace",
				"event_type":   string(EventVolumeSpike),
				"event_name":   "drive_bulk_download",
				"volume_bytes": "524288000",
				"file_count":   "350",
				"client_ip":    "198.51.100.42",
			},
			Description: "Google Workspace Drive audit: 500MB / 350 files downloaded in 2 minutes by workspace-analyst-sa@corp.internal",
		},
		{
			ID:             "ws-id-auth-volume-001",
			Timestamp:      baseTime.Add(3 * time.Minute), // Delta = 60s (<= 300s)
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelitySuggestive,
			Source:         "google-workspace.iam-audit",
			Confidence:     0.7,
			ActorHint:      "workspace-analyst-sa@corp.internal",
			RawEvidenceRef: "workspace://iam/auth/token-grant-8472",
			Labels: map[string]string{
				"provider":     "google_workspace",
				"principal":    "workspace-analyst-sa@corp.internal",
				"session_type": "api_key_refresh",
			},
			Description: "Google Workspace IAM: API token refresh for workspace-analyst-sa@corp.internal preceding high-volume download",
		},

		// 2. workspace_external_oauth_grant pair (M365 OAuth 2.0 app consent + Entra ID token issuance)
		{
			ID:             "ws-saas-oauth-001",
			Timestamp:      baseTime.Add(6 * time.Minute),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelityStrong,
			Source:         "microsoft-365.entra-audit",
			Confidence:     0.85,
			ActorHint:      "m365-developer-agent@corp.internal",
			RawEvidenceRef: "m365://entra/oauth-grants/consent-9921",
			Labels: map[string]string{
				"provider":   "microsoft_365",
				"event_type": string(EventExternalOAuthGrant),
				"app_id":     "9e8b7c6d-5a4f-3e2d-1c0b-a9876543210f",
				"app_name":   "ThirdPartyShadowCopilot",
				"scopes":     "Mail.ReadWrite,Files.ReadWrite.All,User.Read",
				"client_ip":  "203.0.113.88",
			},
			Description: "Microsoft 365 Entra ID: External multi-tenant OAuth app consent granted with Mail.ReadWrite and Files.ReadWrite.All",
		},
		{
			ID:             "ws-id-auth-oauth-001",
			Timestamp:      baseTime.Add(7 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "microsoft-365.directory-audit",
			Confidence:     0.8,
			ActorHint:      "m365-developer-agent@corp.internal",
			RawEvidenceRef: "m365://directory/oauth/token-issuance-9921",
			Labels: map[string]string{
				"provider":   "microsoft_365",
				"principal":  "m365-developer-agent@corp.internal",
				"grant_type": "authorization_code",
			},
			Description: "Microsoft 365 OAuth 2.0 token issuance to external app ThirdPartyShadowCopilot under m365-developer-agent@corp.internal",
		},

		// 3. workspace_suspicious_login_egress pair (Google Workspace suspicious sign-in + Sentinel network egress)
		{
			ID:             "ws-id-auth-login-001",
			Timestamp:      baseTime.Add(10 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "google-workspace.login-audit",
			Confidence:     0.85,
			ActorHint:      "suspicious-agent-operator@corp.internal",
			RawEvidenceRef: "workspace://login/events/signin-anomaly-3310",
			Labels: map[string]string{
				"provider":     "google_workspace",
				"event_type":   string(EventSuspiciousLogin),
				"client_ip":    "198.51.100.99",
				"risk_level":   "high",
				"risk_reason":  "impossible_travel_and_anonymous_vpn",
				"geo_location": "RO/Bucharest",
			},
			Description: "Google Workspace Login audit: High-risk suspicious login from unrecognized IP/anomalous VPN for suspicious-agent-operator@corp.internal",
		},
		{
			ID:             "ws-net-egress-login-001",
			Timestamp:      baseTime.Add(11 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "sentinel.network-egress",
			Confidence:     0.6,
			ActorHint:      "suspicious-agent-operator@corp.internal",
			RawEvidenceRef: "netflow://egress/session-99812",
			Labels: map[string]string{
				"destination": "198.51.100.99:8443",
				"bytes_out":   "12582912",
				"protocol":    "TLS1.3",
			},
			Description: "Outbound network connection to suspicious login source IP 198.51.100.99:8443 shortly after anomalous login",
		},
	}
}
