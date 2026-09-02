// Package correlation provides CEL-based signal correlation for actor identification.
package correlation

// Rule is a named CEL expression with metadata.
type Rule struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	CEL         string `json:"cel"`
	Negative    bool   `json:"negative"` // true = exclusion rule
}

// DefaultRules returns the built-in correlation rule set.
func DefaultRules() []Rule {
	return []Rule{
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
			CEL: `(a.layer == "identity_authorization" && b.layer == "behavioural" ||
			       a.layer == "behavioural" && b.layer == "identity_authorization") &&
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
			CEL:         `a.layer == "application_saas" && (b.layer == "identity_authorization" || b.layer == "network_egress") && a.actor_hint != "" && a.actor_hint == b.actor_hint && abs(a.timestamp - b.timestamp) <= 300`,
		},
		{
			Name:        "workspace_external_oauth_grant",
			Description: "External OAuth token grant observed from identity layer correlated with SaaS access",
			CEL:         `a.layer == "identity_authorization" && b.layer == "application_saas" && a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
		{
			Name:        "workspace_suspicious_login_egress",
			Description: "Suspicious login event from unrecognized IP range correlated with network egress or behavioral anomaly",
			CEL:         `a.layer == "identity_authorization" && (b.layer == "network_egress" || b.layer == "behavioural") && a.actor_hint != "" && a.actor_hint == b.actor_hint`,
		},
	}
}

