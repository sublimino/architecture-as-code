package model

import (
	"strings"
	"time"
)

// ActionSeverity classifies the operational and security impact of an action.
type ActionSeverity string

const (
	SeverityLow      ActionSeverity = "low"
	SeverityMedium   ActionSeverity = "medium"
	SeverityHigh     ActionSeverity = "high"
	SeverityCritical ActionSeverity = "critical"
)

// High-severity action constants.
const (
	ActionVaultReadSecret      = "vault:read_secret"
	ActionBaoReadSecret        = "bao:read_secret"
	ActionSecretRead           = "secret:read"
	ActionCredentialAccess     = "credentials:access"
	ActionNetworkAlterRouting  = "network:alter_routing"
	ActionTCRedirect           = "tc:modify_filter"
	ActionIPTablesMutate       = "iptables:mutate"
	ActionRoutingAlter         = "routing:alter"
	ActionPolicyModify         = "policy:modify"
	ActionLandlockBypass       = "landlock:bypass"
	ActionNonoDisable          = "nono:disable"
	ActionRBACBindClusterAdmin = "rbac:bind_cluster_admin"
	ActionK8sImpersonateAdmin  = "k8s:impersonate_admin"
	ActionTokenExfiltration    = "token:exfiltration"
)

// HighSeverityActionPrefixes are string prefixes that identify privileged actions.
var HighSeverityActionPrefixes = []string{
	"vault:",
	"bao:",
	"secret:",
	"credential:",
	"credentials:",
	"network:alter",
	"network:route",
	"tc:",
	"iptables:",
	"routing:",
	"policy:",
	"landlock:bypass",
	"rbac:bind",
	"k8s:impersonate",
	"security:",
}

// IsHighSeverityAction determines if an action name or its labels indicate a privileged or high-severity operation.
func IsHighSeverityAction(action string, labels map[string]string) bool {
	actLower := strings.ToLower(action)
	for _, p := range HighSeverityActionPrefixes {
		if strings.HasPrefix(actLower, p) || strings.Contains(actLower, p) {
			return true
		}
	}
	if strings.Contains(actLower, "read_secret") ||
		strings.Contains(actLower, "alter_routing") ||
		strings.Contains(actLower, "secret_engine") ||
		strings.Contains(actLower, "cluster-admin") ||
		strings.Contains(actLower, "impersonate_admin") ||
		strings.Contains(actLower, "vault_token") ||
		strings.Contains(actLower, "cgroup.freeze") ||
		strings.Contains(actLower, "landlock_bypass") {
		return true
	}
	if labels != nil {
		if labels["high_severity"] == "true" || labels["privileged"] == "true" {
			return true
		}
		if sev := labels["severity"]; strings.EqualFold(sev, "high") || strings.EqualFold(sev, "critical") {
			return true
		}
		if path := labels["path"]; strings.HasPrefix(path, "/v1/secret/") || strings.HasPrefix(path, "/etc/kubernetes") || strings.HasPrefix(path, "/sys/fs/cgroup") {
			return true
		}
		if actionLabel := labels["action"]; actionLabel != "" && actionLabel != action {
			if IsHighSeverityAction(actionLabel, nil) {
				return true
			}
		}
		if eventType := labels["event_type"]; strings.Contains(strings.ToLower(eventType), "secret") || strings.Contains(strings.ToLower(eventType), "routing") {
			return true
		}
	}
	return false
}

// ClassifyActionSeverity evaluates the severity tier of an action.
func ClassifyActionSeverity(action string, labels map[string]string) ActionSeverity {
	if IsHighSeverityAction(action, labels) {
		actLower := strings.ToLower(action)
		if strings.Contains(actLower, "cluster-admin") || strings.Contains(actLower, "impersonate_admin") || strings.Contains(actLower, "landlock:bypass") {
			return SeverityCritical
		}
		return SeverityHigh
	}
	if strings.HasPrefix(action, "read:") || strings.HasPrefix(action, "get:") || strings.HasPrefix(action, "list:") {
		return SeverityLow
	}
	return SeverityMedium
}

// ViolationReason represents the classification of a cryptographic or delegation chain defect.
type ViolationReason string

const (
	ViolationMissingCosignSignature     ViolationReason = "missing_cosign_signature"
	ViolationMissingLandlockAttestation ViolationReason = "missing_landlock_attestation"
	ViolationDelegationDepthExceeded    ViolationReason = "delegation_depth_exceeded"
	ViolationForgedClaim                ViolationReason = "forged_claim"
	ViolationIncompleteChain            ViolationReason = "incomplete_chain"
	ViolationShadowIdentity             ViolationReason = "shadow_identity"
	ViolationUntrustedDelegationAttempt ViolationReason = "untrusted_delegation_attempt"
)

// String returns the string representation of the violation reason.
func (v ViolationReason) String() string {
	return string(v)
}

// QuarantineRecord stores containment and violation state for a quarantined agent entity.
type QuarantineRecord struct {
	ActorID          string          `json:"actor_id"`
	PodName          string          `json:"pod_name,omitempty"`
	PodUID           string          `json:"pod_uid,omitempty"`
	Namespace        string          `json:"namespace,omitempty"`
	ViolationReason  ViolationReason `json:"violation_reason"`
	Action           string          `json:"action,omitempty"`
	AttemptedAt      time.Time       `json:"attempted_at"`
	QuarantinedAt    time.Time       `json:"quarantined_at"`
	StunDispatched   bool            `json:"stun_dispatched"`
	StunLatencyMS    float64         `json:"stun_latency_ms,omitempty"`
	ChainSummary     string          `json:"chain_summary,omitempty"`
	EvidenceGitOID   string          `json:"evidence_gitoid,omitempty"`
	ImmutableAuditID string          `json:"immutable_audit_id,omitempty"`
	Details          map[string]any  `json:"details,omitempty"`
}
