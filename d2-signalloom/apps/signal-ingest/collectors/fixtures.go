// Package collectors provides fixture-driven signal generators for demo purposes.
package collectors

import (
	"encoding/json"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/agentnono"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/gcpaudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/kagent"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// SeedAll returns fixture observations across all five in-scope layers,
// plus a scheduled-job negative test case.
//
// The fixtures tell a story: a shadow AI agent operating under a human's
// service account, detectable only by correlating signals across layers.
// Each individual signal is ambiguous; together they are actionable.
func SeedAll(baseTime time.Time) []model.Observation {
	var obs []model.Observation
	obs = append(obs, NetworkEgressFixtures(baseTime)...)
	obs = append(obs, IdentityAuthFixtures(baseTime)...)
	obs = append(obs, ApplicationSaaSFixtures(baseTime)...)
	obs = append(obs, EndpointHostFixtures(baseTime)...)
	obs = append(obs, BehaviouralFixtures(baseTime)...)
	obs = append(obs, CloudControlPlaneFixtures(baseTime)...)
	obs = append(obs, ScheduledJobFixtures(baseTime)...)
	obs = append(obs, GCPAuditFixtures(baseTime)...)
	obs = append(obs, BaoAuditFixtures(baseTime)...)
	obs = append(obs, SPIREIssuanceFixtures(baseTime)...)
	obs = append(obs, KAgentFixtures(baseTime)...)
	obs = append(obs, WorkspaceSaaSFixtures(baseTime)...)
	obs = append(obs, AgentNonoFixtures(baseTime)...)
	return obs
}

// NetworkEgressFixtures generates unusual outbound connections from a workload
// to model provider APIs (suggestive).
func NetworkEgressFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "net-egress-001",
			Timestamp:      baseTime,
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "prod-api-7b3c",
			Confidence:     0.4,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "netflow://prod-api-7b3c/10.0.3.42:443",
			Labels: map[string]string{
				"destination":  "api.openai.com",
				"port":         "443",
				"protocol":     "TLS1.3",
				"bytes_out":    "2.4MB",
				"workload":     "prod-api-7b3c",
				"namespace":    "default",
			},
			Description: "Outbound TLS connection to api.openai.com from prod workload — not in approved egress list",
		},
		{
			ID:             "net-egress-002",
			Timestamp:      baseTime.Add(15 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "prod-api-7b3c",
			Confidence:     0.35,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "netflow://prod-api-7b3c/10.0.3.42:443",
			Labels: map[string]string{
				"destination":  "api.anthropic.com",
				"port":         "443",
				"protocol":     "TLS1.3",
				"bytes_out":    "1.8MB",
				"workload":     "prod-api-7b3c",
			},
			Description: "Second AI provider API call from same workload within 15 minutes",
		},
		{
			ID:             "net-ebpf-001",
			Timestamp:      baseTime.Add(18 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelityStrong,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.85,
			ActorHint:      "agent-cardvault-0",
			RawEvidenceRef: "ebpf://flow/cgroup/54321/seq/101",
			Labels: map[string]string{
				"destination":    "104.18.2.161:443",
				"provider":       "OpenAI",
				"classification": "approved_model_egress",
				"domain":         "api.openai.com",
				"port":           "443",
				"bytes_sent":     "3145728",
				"pod_name":       "agent-cardvault-0",
				"namespace":      "fe-signalloom-agents",
				"spiffe_id":      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"seq_num":        "101",
			},
			Description: "Live eBPF socket trace capturing outbound TCP session to api.openai.com",
		},
		{
			ID:             "net-ebpf-002",
			Timestamp:      baseTime.Add(22 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelityStrong,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.85,
			ActorHint:      "agent-cardvault-0",
			RawEvidenceRef: "ebpf://flow/cgroup/54321/seq/102",
			Labels: map[string]string{
				"destination":    "160.155.1.1:443",
				"provider":       "Anthropic",
				"classification": "approved_model_egress",
				"domain":         "api.anthropic.com",
				"port":           "443",
				"bytes_sent":     "2097152",
				"pod_name":       "agent-cardvault-0",
				"namespace":      "fe-signalloom-agents",
				"spiffe_id":      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"seq_num":        "102",
			},
			Description: "Live eBPF socket trace capturing outbound TCP session to api.anthropic.com",
		},
	}
}

// IdentityAuthFixtures generates service account with API-only access,
// no interactive sessions (suggestive).
func IdentityAuthFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "id-auth-001",
			Timestamp:      baseTime.Add(2 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelitySuggestive,
			Source:         "iam-audit-log",
			Confidence:     0.4,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "cloudtrail://iam/sa-ml-pipeline",
			Labels: map[string]string{
				"principal":    "sa-ml-pipeline@project.iam",
				"auth_method":  "workload_identity",
				"session_type": "api_only",
				"interactive":  "false",
			},
			Description: "Service account sa-ml-pipeline uses API-only auth — no interactive sessions in 90 days",
		},
		{
			ID:             "id-auth-002",
			Timestamp:      baseTime.Add(5 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelitySuggestive,
			Source:         "iam-audit-log",
			Confidence:     0.3,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "cloudtrail://iam/sa-ml-pipeline/token-refresh",
			Labels: map[string]string{
				"principal":      "sa-ml-pipeline@project.iam",
				"token_lifetime": "3600s",
				"refresh_count":  "47",
			},
			Description: "High token refresh rate on sa-ml-pipeline — 47 refreshes in 24h, typical of automated tooling",
		},
		{
			ID:             "id-bao-001",
			Timestamp:      baseTime.Add(6 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "openbao-audit",
			Confidence:     0.95,
			ActorHint:      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			RawEvidenceRef: "openbao://audit/secret/data/cardvault/master-keys",
			Labels: map[string]string{
				"operation":       "read",
				"path":            "secret/data/cardvault/master-keys",
				"spiffe_id":       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"sa_principal":    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
				"namespace":       "fe-signalloom-agents",
				"service_account": "agent-cardvault-sa",
				"role":            "cardvault",
				"accessor":        "hmac-98a72b1c4e5d6f0a",
				"lease_id":        "secret/data/cardvault/master-keys/lease-88",
				"lease_duration":  "3600",
			},
			Description: "OpenBao audit record: agent-cardvault-sa read secret/data/cardvault/master-keys under definitive SPIFFE SVID role",
		},
		{
			ID:             "id-spire-001",
			Timestamp:      baseTime.Add(1 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "spire-agent",
			Confidence:     0.85,
			ActorHint:      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			RawEvidenceRef: "spire://svid/issuance/agent-cardvault-sa",
			Labels: map[string]string{
				"event_type":      "spire_svid_issuance",
				"spiffe_id":       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"sa_principal":    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
				"trust_domain":    "cluster.local",
				"svid_type":       "JWT",
				"ttl_seconds":     "300",
				"namespace":       "fe-signalloom-agents",
				"service_account": "agent-cardvault-sa",
			},
			Description: "SPIRE issued JWT SVID for spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa (TTL=300s)",
		},
	}
}

// ApplicationSaaSFixtures generates Slack audit trail showing automated
// message patterns (suggestive).
func ApplicationSaaSFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "app-saas-001",
			Timestamp:      baseTime.Add(8 * time.Minute),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "slack-audit",
			Confidence:     0.35,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "slack://audit/msg-pattern-analysis",
			Labels: map[string]string{
				"channel":          "#ml-ops",
				"message_cadence":  "every_15_min",
				"content_pattern":  "structured_json",
				"user_agent":       "python-slack-sdk/3.27",
			},
			Description: "Slack messages posted every 15 min with structured JSON payloads — no human typing patterns",
		},
	}
}

// EndpointHostFixtures generates process with no TTY, spawned by container
// runtime (circumstantial).
func EndpointHostFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "host-001",
			Timestamp:      baseTime.Add(1 * time.Minute),
			Layer:          model.LayerEndpointHost,
			Fidelity:       model.FidelityCircumstantial,
			Source:         "prod-api-7b3c",
			Confidence:     0.2,
			ActorHint:      "",
			RawEvidenceRef: "procfs://prod-api-7b3c/pid/4217",
			Labels: map[string]string{
				"process":   "python3",
				"tty":       "none",
				"parent":    "containerd-shim",
				"uid":       "65532",
				"cmdline":   "python3 /app/agent_loop.py",
			},
			Description: "Process with no TTY, spawned by container runtime — consistent with autonomous agent",
		},
	}
}

// BehaviouralFixtures generates regular timing patterns, high throughput,
// no human interaction signals (suggestive).
func BehaviouralFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "beh-001",
			Timestamp:      baseTime.Add(10 * time.Minute),
			Layer:          model.LayerBehavioural,
			Fidelity:       model.FidelitySuggestive,
			Source:         "prod-api-7b3c",
			Confidence:     0.4,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "metrics://prod-api-7b3c/request-pattern",
			Labels: map[string]string{
				"request_interval_cv": "0.03",
				"requests_per_hour":   "240",
				"human_markers":       "none",
				"mouse_events":        "0",
				"keyboard_events":     "0",
			},
			Description: "Request timing coefficient of variation 0.03 — near-perfect regularity, no human interaction markers",
		},
		{
			ID:             "beh-002",
			Timestamp:      baseTime.Add(12 * time.Minute),
			Layer:          model.LayerBehavioural,
			Fidelity:       model.FidelitySuggestive,
			Source:         "prod-api-7b3c",
			Confidence:     0.45,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "metrics://prod-api-7b3c/response-analysis",
			Labels: map[string]string{
				"avg_response_time_ms": "847",
				"response_variance":    "low",
				"error_handling":       "retry_with_backoff",
			},
			Description: "Consistent response processing with programmatic retry-with-backoff — no pause-and-think pattern",
		},
	}
}

// ScheduledJobFixtures returns the negative test case: a workload that matches
// suggestive timing signals but should NOT be classified as an agent.
func ScheduledJobFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "cron-001",
			Timestamp:      baseTime.Add(20 * time.Minute),
			Layer:          model.LayerBehavioural,
			Fidelity:       model.FidelitySuggestive,
			Source:         "batch-etl-runner",
			Confidence:     0.3,
			ActorHint:      "", // No actor hint — this is the key differentiator.
			RawEvidenceRef: "k8s://cronjob/batch-etl/run-47",
			Labels: map[string]string{
				"schedule":       "*/5 * * * *",
				"job_controller": "kubernetes_cronjob",
				"workload_type":  "batch",
			},
			Description: "Regular 5-minute execution pattern from a Kubernetes CronJob — timing regularity without identity signals",
		},
	}
}

// CloudControlPlaneFixtures generates Kubernetes APIServer audit and GCP Cloud Audit observations (definitive).
func CloudControlPlaneFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "cloud-audit-001",
			Timestamp:      baseTime.Add(5 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			Confidence:     1.0,
			ActorHint:      "sa-ml-pipeline",
			RawEvidenceRef: "k8s-audit://default/secrets/vault-token",
			Labels: map[string]string{
				"verb":        "get",
				"resource":    "secrets",
				"namespace":   "default",
				"name":        "vault-token",
				"status_code": "200",
			},
			Description: "K8s APIServer audit: get secret default/vault-token by sa-ml-pipeline",
		},
		{
			ID:             "cloud-audit-002",
			Timestamp:      baseTime.Add(10 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     1.0,
			ActorHint:      "deployer-sa@osramp-demo.iam.gserviceaccount.com",
			RawEvidenceRef: "gcp-audit://osramp-demo/projects/osramp-demo",
			Labels: map[string]string{
				"service_name": "iam.googleapis.com",
				"method_name":  "google.iam.v1.SetIamPolicy",
				"project_id":   "osramp-demo",
				"status_code":  "0",
			},
			Description: "GCP Audit: deployer-sa called google.iam.v1.SetIamPolicy on osramp-demo",
		},
	}
}

// GCPAuditFixtures generates deterministic GCP Cloud Audit observations from canned LogEntries.
func GCPAuditFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "gcp-audit-fixture-001",
			Timestamp:      baseTime.Add(12 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     1.0,
			ActorHint:      "security-admin@controlplane.io",
			RawEvidenceRef: "gcp-audit://osramp-demo/projects/osramp-demo/roles/custom.agentRunner",
			Labels: map[string]string{
				"insert_id":       "gcp-audit-fixture-001",
				"service_name":    "iam.googleapis.com",
				"method_name":     "google.iam.admin.v1.CreateRole",
				"resource_name":   "projects/osramp-demo/roles/custom.agentRunner",
				"principal_email": "security-admin@controlplane.io",
				"caller_ip":       "198.51.100.42",
				"project_id":      "osramp-demo",
				"status_code":     "0",
				"severity":        "NOTICE",
				"log_name":        "projects/osramp-demo/logs/cloudaudit.googleapis.com%2Factivity",
			},
			Description: "GCP Audit: security-admin@controlplane.io called google.iam.admin.v1.CreateRole on projects/osramp-demo/roles/custom.agentRunner",
		},
	}
}

// KAgentFixtures generates deterministic observations calibrated from live KAgent telemetry (strong).
func KAgentFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:               "kagent-obs-p0-calibrated-span-001",
			Timestamp:        baseTime.Add(25 * time.Minute),
			Layer:            model.LayerIdentityAuth,
			Fidelity:         model.FidelityStrong,
			Source:           "kagent.telemetry",
			Confidence:       0.85,
			ActorHint:        "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader",
			ActorID:          "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader",
			PrincipalID:      "admin@kagent.dev",
			SessionID:        "01a0722f-a1c4-7963-890c-37184946daca",
			ImpersonatedUser: "admin@kagent.dev",
			DelegationDepth:  1,
			RawEvidenceRef:   "otel://kagent/fe-signalloom-agents/kagent-k8s-reader/span/p0-calibrated-span-001",
			Labels: map[string]string{
				"framework":       "kagent",
				"runtime_version": "0.9.9",
				"agent_namespace": "fe-signalloom-agents",
				"agent_name":      "kagent-k8s-reader",
				"service_account": "kagent-k8s-reader",
				"spiffe_id":       "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader",
				"tool_name":       "k8s_get_resources",
				"invoked_action":  "tool:k8s_get_resources",
				"context_id":      "01a0722f-a1c4-7963-890c-37184946daca",
				"task_id":         "01a0722f-a1c4-7874-a9c0-d55a1638c1e5",
				"caller_id":       "admin@kagent.dev",
				"delegation_tag":  "inferred",
				"trace_id":        "p0-calibrated-trace-001",
			},
			Description: "Kagent agent kagent-k8s-reader invoked action tool:k8s_get_resources in namespace fe-signalloom-agents (context: 01a0722f-a1c4-7963-890c-37184946daca)",
		},
	}
}
// BaoAuditFixtures generates OpenBao identity audit observations.
func BaoAuditFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "id-bao-fixture-001",
			Timestamp:      baseTime.Add(6 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "openbao-audit",
			Confidence:     0.95,
			ActorHint:      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			RawEvidenceRef: "openbao://audit/secret/data/cardvault/master-keys",
			Labels: map[string]string{
				"event_type":      "response",
				"operation":       "read",
				"path":            "secret/data/cardvault/master-keys",
				"spiffe_id":       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"sa_principal":    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
				"namespace":       "fe-signalloom-agents",
				"service_account": "agent-cardvault-sa",
				"role":            "cardvault",
				"accessor":        "hmac-98a72b1c4e5d6f0a",
				"lease_id":        "secret/data/cardvault/master-keys/lease-88",
				"lease_duration":  "3600",
			},
			Description: "OpenBao audit record: agent-cardvault-sa read secret/data/cardvault/master-keys under definitive SPIFFE SVID role",
		},
	}
}

// SPIREIssuanceFixtures generates SPIRE SVID issuance observations.
func SPIREIssuanceFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		{
			ID:             "id-spire-fixture-001",
			Timestamp:      baseTime.Add(1 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "spire-agent",
			Confidence:     0.85,
			ActorHint:      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			RawEvidenceRef: "spire://svid/issuance/agent-cardvault-sa",
			Labels: map[string]string{
				"event_type":      "spire_svid_issuance",
				"spiffe_id":       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"sa_principal":    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
				"trust_domain":    "cluster.local",
				"svid_type":       "JWT",
				"ttl_seconds":     "300",
				"namespace":       "fe-signalloom-agents",
				"service_account": "agent-cardvault-sa",
			},
			Description: "SPIRE issued JWT SVID for spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa (TTL=300s)",
		},
	}
}

// WorkspaceSaaSFixtures generates Google Workspace and Microsoft 365 SaaS observations
// paired with identity authorization and network egress signals to exercise all three
// workspace_* correlation rules: workspace_volume_spike, workspace_external_oauth_grant,
// and workspace_suspicious_login_egress (SFDP-P2-6).
func WorkspaceSaaSFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		// 1. workspace_volume_spike pair (Google Workspace Drive download spike + IAM token refresh within 300s)
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
				"event_type":   "workspace_volume_spike",
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
				"event_type": "workspace_external_oauth_grant",
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
				"event_type":   "workspace_suspicious_login_egress",
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

// --- Collector Falsification Twins (SFDP-P3-5) ---

// GCPAuditAcceptTwinLogEntry returns a valid GCP Cloud Audit LogEntry for accept twin testing.
func GCPAuditAcceptTwinLogEntry(baseTime time.Time) *gcpaudit.GCPLogEntry {
	return &gcpaudit.GCPLogEntry{
		InsertID:  "gcp-accept-twin-001",
		LogName:   "projects/osramp-demo/logs/cloudaudit.googleapis.com%2Factivity",
		Timestamp: baseTime,
		Severity:  "NOTICE",
		Resource: gcpaudit.GCPMonitoredResource{
			Type: "project",
			Labels: map[string]string{
				"project_id": "osramp-demo",
			},
		},
		ProtoPayload: &gcpaudit.GCPAuditLogPayload{
			Type:         "type.googleapis.com/google.cloud.audit.AuditLog",
			ServiceName:  "iam.googleapis.com",
			MethodName:   "google.iam.admin.v1.CreateRole",
			ResourceName: "projects/osramp-demo/roles/custom.twinRunner",
			AuthenticationInfo: gcpaudit.GCPAuthInfo{
				PrincipalEmail: "twin-admin@osramp-demo.iam.gserviceaccount.com",
			},
			RequestMetadata: gcpaudit.GCPRequestMetadata{
				CallerIP: "198.51.100.55",
			},
		},
	}
}

// GCPAuditAcceptTwinPayload returns raw JSON bytes for the accept twin LogEntry.
func GCPAuditAcceptTwinPayload(baseTime time.Time) []byte {
	b, _ := json.Marshal(GCPAuditAcceptTwinLogEntry(baseTime))
	return b
}

// GCPAuditRejectTwinPayload returns deliberately malformed JSON bytes that must be rejected.
func GCPAuditRejectTwinPayload() []byte {
	return []byte(`{"insertId": "gcp-corrupt-001", "protoPayload": "MALFORMED_NON_OBJECT"`)
}

// GCPAuditUnderReportTwinLogEntry returns an under-reporting LogEntry missing protoPayload & principal.
func GCPAuditUnderReportTwinLogEntry(baseTime time.Time) *gcpaudit.GCPLogEntry {
	return &gcpaudit.GCPLogEntry{
		InsertID:  "gcp-underreport-001",
		Timestamp: baseTime,
		Severity:  "INFO",
	}
}

// BaoAuditAcceptTwinEvent returns a valid OpenBao audit event for accept twin testing.
func BaoAuditAcceptTwinEvent(baseTime time.Time) *baoaudit.OpenBaoAuditEvent {
	return &baoaudit.OpenBaoAuditEvent{
		Type: "response",
		Time: baseTime.Format(time.RFC3339Nano),
		Request: &baoaudit.AuditRequest{
			ID:                  "req-bao-accept-twin-001",
			Operation:           "read",
			Path:                "secret/data/cardvault/twin-keys",
			ClientTokenAccessor: "acc-twin-999",
		},
		Auth: &baoaudit.AuditAuth{
			DisplayName: "token-cardvault-sa",
			Policies:    []string{"cardvault-read"},
			TokenType:   "service",
			Metadata: map[string]string{
				"spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"role":      "cardvault",
			},
		},
	}
}

// BaoAuditAcceptTwinPayload returns JSON bytes for the accept twin OpenBao audit event.
func BaoAuditAcceptTwinPayload(baseTime time.Time) []byte {
	b, _ := json.Marshal(BaoAuditAcceptTwinEvent(baseTime))
	return b
}

// BaoAuditRejectTwinPayload returns deliberately malformed JSON bytes.
func BaoAuditRejectTwinPayload() []byte {
	return []byte(`{"type":"response","request":{MALFORMED_JSON_UNCLOSED_OBJECT`)
}

// BaoAuditUnderReportTwinPayload returns an empty JSON object missing request and response.
func BaoAuditUnderReportTwinPayload() []byte {
	return []byte(`{}`)
}

// SPIREIssuanceAcceptTwinEvent returns a valid SPIRE SVID issuance event for accept twin testing.
func SPIREIssuanceAcceptTwinEvent(baseTime time.Time) *spirea.SVIDIssuanceEvent {
	return &spirea.SVIDIssuanceEvent{
		Timestamp:      baseTime,
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		TrustDomain:    "cluster.local",
		SVIDType:       spirea.SVIDTypeJWT,
		IssuedAt:       baseTime,
		ExpiresAt:      baseTime.Add(5 * time.Minute),
		TTLSeconds:     300,
		PodNamespace:   "fe-signalloom-agents",
		ServiceAccount: "agent-cardvault-sa",
	}
}

// SPIREIssuanceRejectTwinEvent returns an invalid SVID issuance event with an empty SPIFFE ID.
func SPIREIssuanceRejectTwinEvent(baseTime time.Time) *spirea.SVIDIssuanceEvent {
	return &spirea.SVIDIssuanceEvent{
		Timestamp:   baseTime,
		SPIFFEID:    "", // Missing SPIFFE ID must not yield an observation
		TrustDomain: "cluster.local",
	}
}

// NetEBPFAcceptTwinEvent returns a valid eBPF socket flow event for accept twin testing.
func NetEBPFAcceptTwinEvent(baseTime time.Time) *netebpf.InboundFlowEvent {
	return &netebpf.InboundFlowEvent{
		TimestampNs:    uint64(baseTime.UnixNano()),
		Time:           baseTime,
		CgroupID:       54321,
		SockCookie:     998877,
		SeqNum:         1,
		SrcIP:          "10.0.3.42",
		DstIP:          "104.18.2.161",
		SrcPort:        45678,
		DstPort:        443,
		Family:         2,
		BytesSent:      2048,
		PodName:        "agent-cardvault-0",
		PodNamespace:   "fe-signalloom-agents",
		ServiceAccount: "agent-cardvault-sa",
		SPIFFEID:       "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
		Provider:       "OpenAI",
		Classification: "approved_model_egress",
		Domain:         "api.openai.com",
		NodeName:       "node-worker-1",
	}
}

// NetEBPFRejectTwinEvent returns a nil flow event that must cause an error.
func NetEBPFRejectTwinEvent() *netebpf.InboundFlowEvent {
	return nil
}

// NetEBPFUnderReportTwinEvent returns a flow event with a sequence gap to test gap flagging.
func NetEBPFUnderReportTwinEvent(baseTime time.Time) *netebpf.InboundFlowEvent {
	ev := NetEBPFAcceptTwinEvent(baseTime)
	ev.SeqNum = 9999 // Jump in sequence
	return ev
}

// K8sAuditAcceptTwinEventList returns a valid K8s APIServer audit EventList for accept twin testing.
func K8sAuditAcceptTwinEventList(baseTime time.Time) *audit.K8sEventList {
	return &audit.K8sEventList{
		Kind:       "EventList",
		APIVersion: "audit.k8s.io/v1",
		Items: []audit.K8sEvent{
			{
				AuditID:    "k8s-twin-audit-001",
				Stage:      "ResponseComplete",
				RequestURI: "/api/v1/namespaces/default/secrets/vault-token",
				Verb:       "get",
				User: audit.K8sUserInfo{
					Username: "system:serviceaccount:default:sa-ml-pipeline",
					UID:      "sa-uid-456",
					Groups:   []string{"system:serviceaccounts", "system:serviceaccounts:default"},
				},
				SourceIPs: []string{"10.0.1.10"},
				UserAgent: "kubectl/v1.28.0",
				ObjectRef: &audit.K8sObjRef{
					Resource:   "secrets",
					Namespace:  "default",
					Name:       "vault-token",
					APIVersion: "v1",
				},
				ResponseStatus:  &audit.K8sRespStat{Code: 200},
				StageTimestamp:  baseTime,
				RequestReceived: baseTime,
			},
		},
	}
}

// K8sAuditAcceptTwinPayload returns JSON bytes for K8s APIServer audit EventList.
func K8sAuditAcceptTwinPayload(baseTime time.Time) []byte {
	b, _ := json.Marshal(K8sAuditAcceptTwinEventList(baseTime))
	return b
}

// K8sAuditRejectTwinPayload returns non-JSON bytes that must be rejected.
func K8sAuditRejectTwinPayload() []byte {
	return []byte("MALFORMED_NON_JSON_K8S_AUDIT_PAYLOAD")
}

// KAgentAcceptTwinSpan returns a valid Kagent telemetry span for accept twin testing.
func KAgentAcceptTwinSpan(baseTime time.Time) kagent.TelemetrySpan {
	return kagent.TelemetrySpan{
		SpanID:         "kagent-twin-span-001",
		TraceID:        "kagent-twin-trace-001",
		RuntimeVersion: "0.9.9",
		Name:           "Tool execution",
		Timestamp:      baseTime,
		Attributes: map[string]string{
			"kagent.namespace":        "fe-signalloom-agents",
			"kagent.agent_name":       "kagent-k8s-reader",
			"service_account":         "kagent-k8s-reader",
			"tool.name":               "k8s_get_resources",
			"a2a.context_id":          "ctx-twin-001",
			"a2a.task_id":             "task-twin-001",
			"a2a.user_id":             "admin@kagent.dev",
			"kagent.runtime_version": "0.9.9",
		},
	}
}

// KAgentRejectTwinSpan returns a malformed Kagent telemetry span missing required attributes.
func KAgentRejectTwinSpan() kagent.TelemetrySpan {
	return kagent.TelemetrySpan{
		SpanID: "",
		Name:   "",
	}
}

// WorkspaceSaaSAcceptTwinObservation returns a valid Workspace SaaS observation.
func WorkspaceSaaSAcceptTwinObservation(baseTime time.Time) model.Observation {
	return model.Observation{
		ID:             "ws-twin-accept-001",
		Timestamp:      baseTime,
		Layer:          model.LayerApplicationSaaS,
		Fidelity:       model.FidelitySuggestive,
		Source:         "google-workspace.drive-audit",
		Confidence:     0.75,
		ActorHint:      "workspace-analyst-sa@corp.internal",
		RawEvidenceRef: "workspace://drive/activities/twin-export-001",
		Labels: map[string]string{
			"provider":     "google_workspace",
			"event_type":   "workspace_volume_spike",
			"event_name":   "drive_bulk_download",
			"volume_bytes": "524288000",
			"file_count":   "350",
			"client_ip":    "198.51.100.42",
		},
		Description: "Google Workspace Drive audit: 500MB downloaded by workspace-analyst-sa@corp.internal",
	}
}

// WorkspaceSaaSRejectTwinObservation returns an invalid observation failing model validation.
func WorkspaceSaaSRejectTwinObservation() model.Observation {
	return model.Observation{
		ID:    "",
		Layer: "invalid-layer",
	}
}

// FixtureAcceptTwinObservations returns a valid full seed dataset.
func FixtureAcceptTwinObservations(baseTime time.Time) []model.Observation {
	return SeedAll(baseTime)
}

// FixtureRejectTwinObservations returns an invalid empty observation slice that fails layer coverage.
func FixtureRejectTwinObservations() []model.Observation {
	return []model.Observation{
		{ID: ""},
	}
}

// AdversarialHiddenAliasFixtures generates observations where a single actor operates under multiple aliases
// joined by a genuine deterministic identity edge (e.g. SPIFFE ID, GCP SA, or K8s SA).
func AdversarialHiddenAliasFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		// Pair 1: agent-cardvault-0 vs vault-client-payments sharing SPIFFE SVID in spire-agent and openbao-audit
		{
			ID:             "adv-ha-001a",
			Timestamp:      baseTime,
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "spire-agent",
			Confidence:     0.9,
			ActorHint:      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			RawEvidenceRef: "spire://issuance/adv-ha-001a",
			Labels: map[string]string{
				"event_type":   "spire_svid_issuance",
				"spiffe_id":    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"sa_principal": "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
				"caller_alias": "agent-cardvault-0",
			},
			Description: "Adversarial HA-01a: SPIRE SVID issuance for agent-cardvault-sa",
		},
		{
			ID:             "adv-ha-001b",
			Timestamp:      baseTime.Add(2 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "openbao-audit",
			Confidence:     0.95,
			ActorHint:      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
			RawEvidenceRef: "openbao://audit/adv-ha-001b",
			Labels: map[string]string{
				"spiffe_id":    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"sa_principal": "system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa",
				"caller_alias": "vault-client-payments",
			},
			Description: "Adversarial HA-01b: OpenBao secret read under alias vault-client-payments with identical SPIFFE ID",
		},
		// Pair 2: pipeline-worker-east vs deployer-bot sharing GCP Service Account email in gcp-cloud-audit
		{
			ID:             "adv-ha-002a",
			Timestamp:      baseTime.Add(5 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     0.95,
			ActorHint:      "pipeline-runner@corp.iam.gserviceaccount.com",
			PrincipalID:    "pipeline-runner@corp.iam.gserviceaccount.com",
			RawEvidenceRef: "gcp://audit/adv-ha-002a",
			Labels: map[string]string{
				"principal_email": "pipeline-runner@corp.iam.gserviceaccount.com",
				"project_id":      "corp-production",
				"caller_alias":    "pipeline-worker-east",
			},
			Description: "Adversarial HA-02a: GCP audit log for pipeline-runner under alias pipeline-worker-east",
		},
		{
			ID:             "adv-ha-002b",
			Timestamp:      baseTime.Add(8 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     0.95,
			ActorHint:      "pipeline-runner@corp.iam.gserviceaccount.com",
			PrincipalID:    "pipeline-runner@corp.iam.gserviceaccount.com",
			RawEvidenceRef: "gcp://audit/adv-ha-002b",
			Labels: map[string]string{
				"principal_email": "pipeline-runner@corp.iam.gserviceaccount.com",
				"project_id":      "corp-production",
				"caller_alias":    "deployer-bot",
			},
			Description: "Adversarial HA-02b: GCP audit log for pipeline-runner under alias deployer-bot",
		},
		// Pair 3: kagent-exec vs kagent-worker sharing K8s Service Account in k8s-apiserver-audit
		{
			ID:             "adv-ha-003a",
			Timestamp:      baseTime.Add(10 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			Confidence:     0.9,
			ActorHint:      "system:serviceaccount:fe-signalloom-agents:kagent-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:kagent-sa",
			RawEvidenceRef: "k8s://audit/adv-ha-003a",
			Labels: map[string]string{
				"sa_principal": "system:serviceaccount:fe-signalloom-agents:kagent-sa",
				"workload":     "kagent-exec",
			},
			Description: "Adversarial HA-03a: K8s APIServer audit for kagent-sa via kagent-exec",
		},
		{
			ID:             "adv-ha-003b",
			Timestamp:      baseTime.Add(12 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			Confidence:     0.9,
			ActorHint:      "system:serviceaccount:fe-signalloom-agents:kagent-sa",
			PrincipalID:    "system:serviceaccount:fe-signalloom-agents:kagent-sa",
			RawEvidenceRef: "k8s://audit/adv-ha-003b",
			Labels: map[string]string{
				"sa_principal": "system:serviceaccount:fe-signalloom-agents:kagent-sa",
				"workload":     "kagent-worker",
			},
			Description: "Adversarial HA-03b: K8s APIServer audit for kagent-sa via kagent-worker",
		},
		// Pair 4: Multi-region checkout workload joined by SPIFFE ID across spire-agent and openbao-audit
		{
			ID:             "adv-ha-004a",
			Timestamp:      baseTime.Add(15 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "spire-agent",
			Confidence:     0.9,
			ActorHint:      "spiffe://cluster.local/ns/payments/sa/checkout-sa",
			PrincipalID:    "system:serviceaccount:payments:checkout-sa",
			RawEvidenceRef: "spire://issuance/adv-ha-004a",
			Labels: map[string]string{
				"event_type":   "spire_svid_issuance",
				"spiffe_id":    "spiffe://cluster.local/ns/payments/sa/checkout-sa",
				"sa_principal": "system:serviceaccount:payments:checkout-sa",
				"region":       "us-east-1",
			},
			Description: "Adversarial HA-04a: SPIRE SVID issuance in us-east-1 for checkout-sa",
		},
		{
			ID:             "adv-ha-004b",
			Timestamp:      baseTime.Add(17 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "openbao-audit",
			Confidence:     0.95,
			ActorHint:      "spiffe://cluster.local/ns/payments/sa/checkout-sa",
			PrincipalID:    "system:serviceaccount:payments:checkout-sa",
			RawEvidenceRef: "openbao://audit/adv-ha-004b",
			Labels: map[string]string{
				"spiffe_id":    "spiffe://cluster.local/ns/payments/sa/checkout-sa",
				"sa_principal": "system:serviceaccount:payments:checkout-sa",
				"region":       "us-west-2",
			},
			Description: "Adversarial HA-04b: OpenBao secret read in us-west-2 with same checkout-sa SPIFFE ID",
		},
		// Pair 5: Multi-tool coordinator with aliases agent-step-1 and agent-step-2 joined by GCP service account
		{
			ID:             "adv-ha-005a",
			Timestamp:      baseTime.Add(20 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     0.95,
			ActorHint:      "agent-coordinator@corp-prod.iam.gserviceaccount.com",
			PrincipalID:    "agent-coordinator@corp-prod.iam.gserviceaccount.com",
			RawEvidenceRef: "gcp://audit/adv-ha-005a",
			Labels: map[string]string{
				"principal_email": "agent-coordinator@corp-prod.iam.gserviceaccount.com",
				"project_id":      "corp-prod",
				"step":            "agent-step-1",
			},
			Description: "Adversarial HA-05a: GCP audit for agent-coordinator step 1",
		},
		{
			ID:             "adv-ha-005b",
			Timestamp:      baseTime.Add(22 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     0.95,
			ActorHint:      "agent-coordinator@corp-prod.iam.gserviceaccount.com",
			PrincipalID:    "agent-coordinator@corp-prod.iam.gserviceaccount.com",
			RawEvidenceRef: "gcp://audit/adv-ha-005b",
			Labels: map[string]string{
				"principal_email": "agent-coordinator@corp-prod.iam.gserviceaccount.com",
				"project_id":      "corp-prod",
				"step":            "agent-step-2",
			},
			Description: "Adversarial HA-05b: GCP audit for agent-coordinator step 2",
		},
		// Pair 6: Cross-layer actor in k8s-apiserver-audit and openbao-audit linked by SPIFFE ID
		{
			ID:             "adv-ha-006a",
			Timestamp:      baseTime.Add(25 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "k8s-apiserver-audit",
			Confidence:     0.95,
			ActorHint:      "spiffe://cluster.local/ns/prod-infra/sa/vault-agent",
			PrincipalID:    "spiffe://cluster.local/ns/prod-infra/sa/vault-agent",
			RawEvidenceRef: "k8s://audit/adv-ha-006a",
			Labels: map[string]string{
				"spiffe_id": "spiffe://cluster.local/ns/prod-infra/sa/vault-agent",
			},
			Description: "Adversarial HA-06a: K8s audit for vault-agent via SPIFFE",
		},
		{
			ID:             "adv-ha-006b",
			Timestamp:      baseTime.Add(28 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityDefinitive,
			Source:         "openbao-audit",
			Confidence:     0.95,
			ActorHint:      "spiffe://cluster.local/ns/prod-infra/sa/vault-agent",
			PrincipalID:    "system:serviceaccount:prod-infra:vault-agent",
			RawEvidenceRef: "openbao://audit/adv-ha-006b",
			Labels: map[string]string{
				"spiffe_id":    "spiffe://cluster.local/ns/prod-infra/sa/vault-agent",
				"sa_principal": "system:serviceaccount:prod-infra:vault-agent",
			},
			Description: "Adversarial HA-06b: OpenBao audit for vault-agent via SPIFFE",
		},
	}
}

// AdversarialSplitHumanFixtures generates observations where distinct principals share only a NAT/egress IP
// or host IP, with NO deterministic identity edge between them. Collapsing them is a false merge.
func AdversarialSplitHumanFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		// Pair 1: Two Google Workspace users sharing NAT IP 198.51.100.42
		{
			ID:             "adv-sh-001a",
			Timestamp:      baseTime,
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "google-workspace.drive-audit",
			Confidence:     0.7,
			ActorHint:      "alice@example.com",
			RawEvidenceRef: "workspace://drive/adv-sh-001a",
			Labels: map[string]string{
				"client_ip":  "198.51.100.42",
				"src_ip":     "198.51.100.42",
				"user_email": "alice@example.com",
			},
			Description: "Adversarial SH-01a: Google Workspace download by alice from NAT gateway 198.51.100.42",
		},
		{
			ID:             "adv-sh-001b",
			Timestamp:      baseTime.Add(30 * time.Second),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "google-workspace.drive-audit",
			Confidence:     0.7,
			ActorHint:      "bob@example.com",
			RawEvidenceRef: "workspace://drive/adv-sh-001b",
			Labels: map[string]string{
				"client_ip":  "198.51.100.42",
				"src_ip":     "198.51.100.42",
				"user_email": "bob@example.com",
			},
			Description: "Adversarial SH-01b: Google Workspace download by bob from NAT gateway 198.51.100.42",
		},
		// Pair 2: Two distinct users accessing K8s APIServer from office NAT IP 203.0.113.50
		{
			ID:             "adv-sh-002a",
			Timestamp:      baseTime.Add(2 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "k8s-apiserver-audit",
			Confidence:     0.8,
			ActorHint:      "system:user:carol",
			PrincipalID:    "system:user:carol",
			RawEvidenceRef: "k8s://audit/adv-sh-002a",
			Labels: map[string]string{
				"src_ip":    "203.0.113.50",
				"client_ip": "203.0.113.50",
			},
			Description: "Adversarial SH-02a: K8s APIServer request by user carol from office NAT 203.0.113.50",
		},
		{
			ID:             "adv-sh-002b",
			Timestamp:      baseTime.Add(2*time.Minute + 15*time.Second),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelityStrong,
			Source:         "k8s-apiserver-audit",
			Confidence:     0.8,
			ActorHint:      "system:user:dave",
			PrincipalID:    "system:user:dave",
			RawEvidenceRef: "k8s://audit/adv-sh-002b",
			Labels: map[string]string{
				"src_ip":    "203.0.113.50",
				"client_ip": "203.0.113.50",
			},
			Description: "Adversarial SH-02b: K8s APIServer request by user dave from office NAT 203.0.113.50",
		},
		// Pair 3: Two distinct workloads on the same node egressing from node IP 10.244.0.15
		{
			ID:             "adv-sh-003a",
			Timestamp:      baseTime.Add(5 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.4,
			ActorHint:      "sa-analytics",
			RawEvidenceRef: "ebpf://flow/adv-sh-003a",
			Labels: map[string]string{
				"src_ip":    "10.244.0.15",
				"egress_ip": "10.244.0.15",
				"workload":  "sa-analytics",
			},
			Description: "Adversarial SH-03a: Socket trace for sa-analytics from node 10.244.0.15",
		},
		{
			ID:             "adv-sh-003b",
			Timestamp:      baseTime.Add(5*time.Minute + 10*time.Second),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.4,
			ActorHint:      "sa-reporting",
			RawEvidenceRef: "ebpf://flow/adv-sh-003b",
			Labels: map[string]string{
				"src_ip":    "10.244.0.15",
				"egress_ip": "10.244.0.15",
				"workload":  "sa-reporting",
			},
			Description: "Adversarial SH-03b: Socket trace for sa-reporting from node 10.244.0.15",
		},
		// Pair 4: Two users on corporate VPN NAT IP 192.0.2.100 in SaaS audit
		{
			ID:             "adv-sh-004a",
			Timestamp:      baseTime.Add(10 * time.Minute),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "slack-audit",
			Confidence:     0.6,
			ActorHint:      "eve@partner.org",
			RawEvidenceRef: "slack://audit/adv-sh-004a",
			Labels: map[string]string{
				"src_ip":    "192.0.2.100",
				"client_ip": "192.0.2.100",
			},
			Description: "Adversarial SH-04a: Slack audit for eve from VPN 192.0.2.100",
		},
		{
			ID:             "adv-sh-004b",
			Timestamp:      baseTime.Add(10*time.Minute + 20*time.Second),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "slack-audit",
			Confidence:     0.6,
			ActorHint:      "frank@partner.org",
			RawEvidenceRef: "slack://audit/adv-sh-004b",
			Labels: map[string]string{
				"src_ip":    "192.0.2.100",
				"client_ip": "192.0.2.100",
			},
			Description: "Adversarial SH-04b: Slack audit for frank from VPN 192.0.2.100",
		},
		// Pair 5: Two GCP IAM accounts accessing cloud console from ISP NAT IP 198.51.100.88
		{
			ID:             "adv-sh-005a",
			Timestamp:      baseTime.Add(15 * time.Minute),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     0.95,
			ActorHint:      "admin-1@corp.com",
			PrincipalID:    "admin-1@corp.com",
			RawEvidenceRef: "gcp://audit/adv-sh-005a",
			Labels: map[string]string{
				"principal_email": "admin-1@corp.com",
				"project_id":      "corp-prod",
				"src_ip":          "198.51.100.88",
			},
			Description: "Adversarial SH-05a: GCP audit for admin-1 from NAT IP 198.51.100.88",
		},
		{
			ID:             "adv-sh-005b",
			Timestamp:      baseTime.Add(15*time.Minute + 45*time.Second),
			Layer:          model.LayerCloudControlPlane,
			Fidelity:       model.FidelityDefinitive,
			Source:         "gcp-cloud-audit",
			Confidence:     0.95,
			ActorHint:      "admin-2@corp.com",
			PrincipalID:    "admin-2@corp.com",
			RawEvidenceRef: "gcp://audit/adv-sh-005b",
			Labels: map[string]string{
				"principal_email": "admin-2@corp.com",
				"project_id":      "corp-prod",
				"src_ip":          "198.51.100.88",
			},
			Description: "Adversarial SH-05b: GCP audit for admin-2 from NAT IP 198.51.100.88",
		},
		// Pair 6: Distinct actors in network egress sharing egress NAT IP 203.0.113.99
		{
			ID:             "adv-sh-006a",
			Timestamp:      baseTime.Add(20 * time.Minute),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.35,
			ActorHint:      "operator-alpha",
			RawEvidenceRef: "ebpf://flow/adv-sh-006a",
			Labels: map[string]string{
				"src_ip":   "203.0.113.99",
				"workload": "operator-alpha",
			},
			Description: "Adversarial SH-06a: Socket trace for operator-alpha from 203.0.113.99",
		},
		{
			ID:             "adv-sh-006b",
			Timestamp:      baseTime.Add(20*time.Minute + 15*time.Second),
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.35,
			ActorHint:      "operator-beta",
			RawEvidenceRef: "ebpf://flow/adv-sh-006b",
			Labels: map[string]string{
				"src_ip":   "203.0.113.99",
				"workload": "operator-beta",
			},
			Description: "Adversarial SH-06b: Socket trace for operator-beta from 203.0.113.99",
		},
	}
}

// AdversarialShadowAgentFixtures generates observations where an unauthenticated agent/action
// presents no valid SPIFFE SVID or authenticated identity. It must resolve as provisional/unresolved,
// and never merge into any authenticated real actor.
func AdversarialShadowAgentFixtures(baseTime time.Time) []model.Observation {
	return []model.Observation{
		// Case 1: Unauthenticated socket flow to model provider API with missing SPIFFE SVID
		{
			ID:             "adv-sa-001",
			Timestamp:      baseTime,
			Layer:          model.LayerNetworkEgress,
			Fidelity:       model.FidelitySuggestive,
			Source:         "sentinel.ebpf.socket_trace",
			Confidence:     0.35,
			ActorHint:      "",
			RawEvidenceRef: "ebpf://flow/adv-sa-001",
			Labels: map[string]string{
				"destination":     "api.openai.com:443",
				"missing_svid":    "true",
				"unauthenticated": "true",
			},
			Description: "Adversarial SA-01: Unauthenticated eBPF socket trace to api.openai.com without SVID",
		},
		// Case 2: Anonymous K8s APIServer probe without ServiceAccount credentials
		{
			ID:             "adv-sa-002",
			Timestamp:      baseTime.Add(3 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelitySuggestive,
			Source:         "k8s-apiserver-audit",
			Confidence:     0.3,
			ActorHint:      "system:anonymous",
			PrincipalID:    "system:anonymous",
			RawEvidenceRef: "k8s://audit/adv-sa-002",
			Labels: map[string]string{
				"anonymous":    "true",
				"svid_present": "false",
			},
			Description: "Adversarial SA-02: Anonymous K8s APIServer audit event without SVID",
		},
		// Case 3: Workspace bulk download without authentication envelope
		{
			ID:             "adv-sa-003",
			Timestamp:      baseTime.Add(6 * time.Minute),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "google-workspace.drive-audit",
			Confidence:     0.4,
			ActorHint:      "",
			RawEvidenceRef: "workspace://drive/adv-sa-003",
			Labels: map[string]string{
				"client_ip":  "198.51.100.200",
				"auth_type":  "none",
				"event_name": "bulk_download",
			},
			Description: "Adversarial SA-03: Workspace bulk export without authentication envelope",
		},
		// Case 4: OpenBao unauthenticated token lookup attempt without SPIFFE attestation
		{
			ID:             "adv-sa-004",
			Timestamp:      baseTime.Add(9 * time.Minute),
			Layer:          model.LayerIdentityAuth,
			Fidelity:       model.FidelitySuggestive,
			Source:         "openbao-audit",
			Confidence:     0.3,
			ActorHint:      "",
			RawEvidenceRef: "openbao://audit/adv-sa-004",
			Labels: map[string]string{
				"auth_status": "unauthenticated",
				"path":        "auth/token/lookup-self",
			},
			Description: "Adversarial SA-04: OpenBao unauthenticated lookup probe without SVID",
		},
		// Case 5: Behavioral trace from unknown container executing model commands without SVID
		{
			ID:             "adv-sa-005",
			Timestamp:      baseTime.Add(12 * time.Minute),
			Layer:          model.LayerBehavioural,
			Fidelity:       model.FidelityCircumstantial,
			Source:         "agent-monitor",
			Confidence:     0.25,
			ActorHint:      "",
			RawEvidenceRef: "agent://trace/adv-sa-005",
			Labels: map[string]string{
				"process": "shadow-inference.py",
				"svid":    "none",
			},
			Description: "Adversarial SA-05: Behavioral trace from unknown container running shadow-inference.py",
		},
		// Case 6: KAgent tool span with blank SVID and unregistered caller
		{
			ID:             "adv-sa-006",
			Timestamp:      baseTime.Add(15 * time.Minute),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "kagent",
			Confidence:     0.35,
			ActorHint:      "",
			RawEvidenceRef: "kagent://span/adv-sa-006",
			Labels: map[string]string{
				"tool_name": "k8s_exec",
				"spiffe_id": "",
			},
			Description: "Adversarial SA-06: KAgent tool execution span with missing SVID",
		},
	}
}

// AdversarialAllFixtures returns all adversarial fixtures across the three attack classes.
func AdversarialAllFixtures(baseTime time.Time) []model.Observation {
	var all []model.Observation
	all = append(all, AdversarialHiddenAliasFixtures(baseTime)...)
	all = append(all, AdversarialSplitHumanFixtures(baseTime)...)
	all = append(all, AdversarialShadowAgentFixtures(baseTime)...)
	return all
}
// AgentNonoFixtures generates Landlock-confined, SPIFFE-signed audit session observations.
func AgentNonoFixtures(baseTime time.Time) []model.Observation {
	return agentnono.AgentNonoFixtures(baseTime)
}
