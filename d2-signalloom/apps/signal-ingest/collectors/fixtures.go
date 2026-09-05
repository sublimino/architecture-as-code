// Package collectors provides fixture-driven signal generators for demo purposes.
package collectors

import (
	"time"

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
			RawEvidenceRef: "openbao://audit/secret/data/cardvault/master-keys",
			Labels: map[string]string{
				"operation":      "read",
				"path":           "secret/data/cardvault/master-keys",
				"spiffe_id":      "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"role":           "cardvault",
				"accessor":       "hmac-98a72b1c4e5d6f0a",
				"lease_id":       "secret/data/cardvault/master-keys/lease-88",
				"lease_duration": "3600",
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
			RawEvidenceRef: "spire://svid/issuance/agent-cardvault-sa",
			Labels: map[string]string{
				"event_type":   "spire_svid_issuance",
				"spiffe_id":    "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa",
				"trust_domain": "cluster.local",
				"svid_type":    "JWT",
				"ttl_seconds":  "300",
				"namespace":    "fe-signalloom-agents",
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
