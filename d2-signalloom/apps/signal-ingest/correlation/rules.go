// Package correlation provides CEL-based signal correlation for actor identification.
package correlation

import "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"

// Rule is a named CEL expression with metadata.
type Rule struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	CEL         string         `json:"cel"`
	Negative    bool           `json:"negative"` // true = exclusion rule
	EdgeType    model.EdgeType `json:"edge_type"`
}

// DefaultRules returns the built-in correlation rule set.
func DefaultRules() []Rule {
	rules := []Rule{
		{
			Name:        "cross_layer_identity",
			Description: "Two observations from different layers sharing an actor_hint correlate to the same actor",
			CEL:         `a.layer != b.layer && a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "timing_correlation",
			Description: "Observations within a 5-minute window from different layers at the same source",
			CEL:         `a.layer != b.layer && a.source == b.source && abs(a.timestamp - b.timestamp) <= 300`,
		},
		{
			Name:        "credential_chain",
			Description: "Identity observation + behavioural observation sharing a credential subject are actionable",
			CEL: `((a.layer == "identity_authorization" && b.layer == "behavioural") ||
			       (b.layer == "identity_authorization" && a.layer == "behavioural")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "scheduled_job_exclusion",
			Description: "An observation matching timing regularity without identity signals is NOT an agent",
			CEL:         `a.layer == "behavioural" && a.fidelity == "suggestive" && a.actor_hint == ""`,
			Negative:    true,
		},
		{
			Name:        "workspace_volume_spike",
			Description: "Workspace SaaS file download volume spike correlated with identity or network activity",
			CEL: `((a.layer == "application_saas" && (b.layer == "identity_authorization" || b.layer == "network_egress")) ||
			       (b.layer == "application_saas" && (a.layer == "identity_authorization" || a.layer == "network_egress"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 300`,
		},
		{
			Name:        "workspace_external_oauth_grant",
			Description: "External OAuth token grant observed from identity layer correlated with SaaS access",
			CEL: `((a.layer == "identity_authorization" && b.layer == "application_saas") ||
			       (b.layer == "identity_authorization" && a.layer == "application_saas")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "workspace_suspicious_login_egress",
			Description: "Suspicious login event from unrecognized IP range correlated with network egress or behavioral anomaly",
			CEL: `((a.layer == "identity_authorization" && (b.layer == "network_egress" || b.layer == "behavioural")) ||
			       (b.layer == "identity_authorization" && (a.layer == "network_egress" || a.layer == "behavioural"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		// Layer 6 Cloud Control Plane Symmetric Correlation Rules
		{
			Name:        "audit_rbac_privilege_escalation",
			Description: "Cloud control plane audit observation correlated with identity or behavioral execution under same actor",
			CEL: `((a.layer == "cloud_control_plane" && (b.layer == "identity_authorization" || b.layer == "behavioural" || b.layer == "endpoint_host")) ||
			       (b.layer == "cloud_control_plane" && (a.layer == "identity_authorization" || a.layer == "behavioural" || a.layer == "endpoint_host"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "audit_secret_harvesting_after_egress",
			Description: "Cloud control plane Secret/Token retrieval correlated with unexpected LLM network egress",
			CEL: `((a.layer == "cloud_control_plane" && b.layer == "network_egress") ||
			       (b.layer == "cloud_control_plane" && a.layer == "network_egress")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "gcp_iam_agent_escalation",
			Description: "GCP IAM SetPolicy / Key creation correlated with SaaS or identity observation",
			CEL: `((a.layer == "cloud_control_plane" && (b.layer == "application_saas" || b.layer == "identity_authorization")) ||
			       (b.layer == "cloud_control_plane" && (a.layer == "application_saas" || a.layer == "identity_authorization"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "unauthorized_token_harvesting",
			Description: "Cloud control plane token review/secret read correlated with endpoint anomaly within 10 minutes",
			CEL: `((a.layer == "cloud_control_plane" && b.layer == "endpoint_host") ||
			       (b.layer == "cloud_control_plane" && a.layer == "endpoint_host")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint &&
			      abs(a.timestamp - b.timestamp) <= 600`,
		},
		{
			Name:        "audit_timing_correlation",
			Description: "Cloud control plane audit event occurring within 5 minutes of another layer signal from same source",
			CEL: `((a.layer == "cloud_control_plane" && b.layer != "cloud_control_plane") ||
			       (b.layer == "cloud_control_plane" && a.layer != "cloud_control_plane")) &&
			      a.source == b.source && abs(a.timestamp - b.timestamp) <= 300`,
		},
		// Live eBPF Network Egress Symmetric Correlation Rules
		{
			Name:        "net_ebpf_unauthorized_model_provider_egress",
			Description: "Live eBPF socket connection to AI model provider correlated with identity authorization under same actor",
			CEL: `((a.layer == "network_egress" && b.layer == "identity_authorization") ||
			       (b.layer == "network_egress" && a.layer == "identity_authorization")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "net_ebpf_c2_exfiltration_burst",
			Description: "Direct IP or unauthorized egress connection correlated with endpoint host or behavioural anomaly",
			CEL: `((a.layer == "network_egress" && (b.layer == "endpoint_host" || b.layer == "behavioural")) ||
			       (b.layer == "network_egress" && (a.layer == "endpoint_host" || a.layer == "behavioural"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 300`,
		},
		{
			Name:        "net_ebpf_cross_layer_audit_correlation",
			Description: "Live eBPF socket trace correlated with cloud control plane audit event within 5 minutes",
			CEL: `((a.layer == "network_egress" && b.layer == "cloud_control_plane") ||
			       (b.layer == "network_egress" && a.layer == "cloud_control_plane")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 300`,
		},
		{
			Name:        "net_ebpf_saas_shadow_agent",
			Description: "Network egress to AI provider correlated with SaaS application access under same actor hint",
			CEL: `((a.layer == "network_egress" && b.layer == "application_saas") ||
			       (b.layer == "network_egress" && a.layer == "application_saas")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
	}
	rules = append(rules, IdentityAuditRules()...)
	for i := range rules {
		rules[i].EdgeType = defaultRuleEdgeType(rules[i].Name)
	}
	return rules
}

// defaultRuleEdgeType is intentionally exhaustive by registered rule name.
// CEL detections remain weak unless the separate authenticated identity gate
// emits a deterministic edge.
func defaultRuleEdgeType(name string) model.EdgeType {
	switch name {
	case "timing_correlation", "audit_timing_correlation":
		return model.EdgeTemporal
	case "scheduled_job_exclusion":
		return model.EdgeCannotLink
	case "cross_layer_identity", "credential_chain", "workspace_volume_spike",
		"workspace_external_oauth_grant", "workspace_suspicious_login_egress",
		"audit_rbac_privilege_escalation", "audit_secret_harvesting_after_egress",
		"gcp_iam_agent_escalation", "unauthorized_token_harvesting",
		"net_ebpf_unauthorized_model_provider_egress", "net_ebpf_c2_exfiltration_burst",
		"net_ebpf_cross_layer_audit_correlation", "net_ebpf_saas_shadow_agent",
		"vault_out_of_role_access", "vault_privilege_escalation",
		"vault_secret_exfiltration_spike", "spire_svid_lease_replay_anomaly":
		return model.EdgeProbabilisticSameEntity
	default:
		return ""
	}
}
