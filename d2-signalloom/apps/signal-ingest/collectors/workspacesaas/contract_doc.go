// Package workspacesaas provides the specification and documentation for the
// SaaS adapter contract powering Signal Fusion correlation rules.
//
// # Adapter Contract Specification (SFDP-P2-6)
//
// This document specifies the provider-agnostic fields and structural invariants required
// by the three workspace_* CEL correlation rules in the correlation engine:
//
//  1. workspace_volume_spike:
//     CEL: `((a.layer == "application_saas" && (b.layer == "identity_authorization" || b.layer == "network_egress")) ||
//            (b.layer == "application_saas" && (a.layer == "identity_authorization" || a.layer == "network_egress"))) &&
//           a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 300`
//     Requirements:
//     - Layer: "application_saas" (model.LayerApplicationSaaS)
//     - ActorHint: Non-empty principal identity (e.g. user primary email, UPN, service account).
//     - Timestamp: Must fall within 300 seconds (5 minutes) of the correlated identity_authorization or network_egress observation.
//     - Event Signal: High data export/download volume (e.g. volume_bytes >= 100MB or item_count >= 100).
//     - Correlated Partner: An identity_authorization (e.g. IAM token refresh/issuance) or network_egress observation sharing exact actor_hint.
//
//  2. workspace_external_oauth_grant:
//     CEL: `((a.layer == "identity_authorization" && b.layer == "application_saas") ||
//            (b.layer == "identity_authorization" && a.layer == "application_saas")) &&
//           a.actor_hint != "" && a.actor_hint == b.actor_hint`
//     Requirements:
//     - Layer: "application_saas" (model.LayerApplicationSaaS)
//     - ActorHint: Non-empty principal identity who consented or authorized the OAuth application.
//     - Timestamp: UTC timestamp of OAuth consent or third-party marketplace app authorization.
//     - Event Signal: OAuth 2.0 grant or permission escalation with high-privilege scopes (e.g. Mail.ReadWrite, Files.ReadWrite.All).
//     - Correlated Partner: An identity_authorization observation sharing exact actor_hint.
//
//  3. workspace_suspicious_login_egress:
//     CEL: `((a.layer == "identity_authorization" && (b.layer == "network_egress" || b.layer == "behavioural")) ||
//            (b.layer == "identity_authorization" && (a.layer == "network_egress" || a.layer == "behavioural"))) &&
//           a.actor_hint != "" && a.actor_hint == b.actor_hint`
//     Requirements:
//     - Layer: "identity_authorization" (model.LayerIdentityAuth) representing SaaS login authentication.
//     - ActorHint: Non-empty principal identity attempting authentication.
//     - Timestamp: UTC timestamp of authentication anomaly.
//     - Event Signal: High-risk authentication (e.g. unrecognized foreign IP, impossible travel, anomalous ASN).
//     - Correlated Partner: A network_egress or behavioural observation sharing exact actor_hint.
//
// # Future Live Provider Implementation Seam
//
// A future live Google Workspace (Reports API) or Microsoft 365 (Management Activity API)
// collector must implement the `SaaSAdapter` interface:
//
//	type SaaSAdapter interface {
//	    Provider() ProviderType
//	    Convert(ctx context.Context, raw []byte) (*NormalisedSaaSEvent, error)
//	}
//
// Each raw JSON log entry from Google Workspace or M365 is deserialized and mapped
// to `NormalisedSaaSEvent`, then converted via `ToObservation()` to a `*model.Observation`
// and pushed to the `IngestionSink`.
package workspacesaas
