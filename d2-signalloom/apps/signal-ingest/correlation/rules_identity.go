// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

// IdentityAuditRules returns specialized CEL correlation rules for OpenBao audit and SPIRE SVID identity tracking.
func IdentityAuditRules() []Rule {
	return []Rule{
		{
			Name:        "vault_out_of_role_access",
			Description: "OpenBao identity audit observation correlated with network egress or cloud control plane access under same actor hint",
			CEL: `((a.layer == "identity_authorization" && (b.layer == "network_egress" || b.layer == "cloud_control_plane")) ||
			       (b.layer == "identity_authorization" && (a.layer == "network_egress" || a.layer == "cloud_control_plane"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "vault_privilege_escalation",
			Description: "OpenBao/SPIRE identity token creation or policy escalation correlated with endpoint host or behavioural anomaly",
			CEL: `((a.layer == "identity_authorization" && (b.layer == "endpoint_host" || b.layer == "behavioural")) ||
			       (b.layer == "identity_authorization" && (a.layer == "endpoint_host" || a.layer == "behavioural"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "vault_secret_exfiltration_spike",
			Description: "OpenBao secret read or lease creation correlated with live eBPF egress or SaaS access within 5 minutes",
			CEL: `((a.layer == "identity_authorization" && (b.layer == "network_egress" || b.layer == "application_saas")) ||
			       (b.layer == "identity_authorization" && (a.layer == "network_egress" || a.layer == "application_saas"))) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 300`,
		},
		{
			Name:        "spire_svid_lease_replay_anomaly",
			Description: "SPIRE SVID issuance event correlated with cloud control plane audit event within 10 minutes",
			CEL: `((a.layer == "identity_authorization" && b.layer == "cloud_control_plane") ||
			       (b.layer == "identity_authorization" && a.layer == "cloud_control_plane")) &&
			      a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 600`,
		},
	}
}
