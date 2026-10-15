-- Canonical CEL compliance frameworks and controls for the demo tenants, applied on
-- every estate by the startup migrator rather than only by prelive-clean-down.sh, whose
-- silent '|| true' left governance_frameworks empty and Settings > Governance blank.
-- Derived from db/seed-governance-frameworks.sql: frameworks/controls upsert as there;
-- tenant_settings rows are created when missing but an existing selection is never overwritten.

-- seed-governance-frameworks.sql
-- Canonical seed for default CEL compliance frameworks, controls, and tenant settings.
-- Idempotent: safe to run multiple times across both demo and live/production environments.


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Governance Frameworks for tenant-demo
-- ══════════════════════════════════════════════════════════════════════════════

-- EU AI Act
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000001', 'tenant-demo',
    'EU AI Act', 'v1.0.0', 'European Parliament', '2026-08-02',
    7, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body,
    compliance_deadline = EXCLUDED.compliance_deadline;

-- SOC 2 Type II
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000002', 'tenant-demo',
    'SOC 2 Type II', 'TSC 2017', 'AICPA',
    3, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- CIS Kubernetes Benchmark
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000003', 'tenant-demo',
    'CIS Kubernetes Benchmark', 'v1.8.0', 'Center for Internet Security',
    17, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- FINOS AI Governance Framework
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000004', 'tenant-demo',
    'FINOS AI Governance Framework', 'v1.0.0', 'FINOS',
    16, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- NIST SP 800-53
INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body,
    control_count, activated_by
) VALUES (
    'f0000000-0000-0000-0000-000000000005', 'tenant-demo',
    'NIST SP 800-53', 'v1.0.0', 'NIST',
    14, 'admin@acme.co'
) ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Governance Controls for tenant-demo
-- ══════════════════════════════════════════════════════════════════════════════

-- EU AI Act controls (7, evaluated by eu-ai-act pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000001', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 9 -- Containers Run as Non-Root',
 'Containers must run as non-root to reduce blast radius. Evaluated by eu-ai-act/container-run-as-non-root.',
 1, 'eu-ai-act', 'container-run-as-non-root'),
('c0000000-0000-0000-0000-000000000002', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 14 -- Human Oversight (HITL Label)',
 'Agent has a named Identity Owner and HITL label. Evaluated by eu-ai-act/hitl-label.',
 2, 'eu-ai-act', 'hitl-label'),
('c0000000-0000-0000-0000-000000000003', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 10 -- Data Governance (Classification Label)',
 'Data classification label exists on workload. Evaluated by eu-ai-act/data-classification-label.',
 3, 'eu-ai-act', 'data-classification-label'),
('c0000000-0000-0000-0000-000000000040', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 9 -- No Privilege Escalation',
 'Minimize the admission of containers with allowPrivilegeEscalation. Evaluated by eu-ai-act/no-privilege-escalation.',
 4, 'eu-ai-act', 'no-privilege-escalation'),
('c0000000-0000-0000-0000-000000000041', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 9 -- No Privileged Mode',
 'Privileged mode disabled on containers. Evaluated by eu-ai-act/no-privileged-mode.',
 5, 'eu-ai-act', 'no-privileged-mode'),
('c0000000-0000-0000-0000-000000000042', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 15 -- Resource Limits Defined',
 'CPU and memory limits must be defined. Evaluated by eu-ai-act/resource-limits-set.',
 6, 'eu-ai-act', 'resource-limits-set'),
('c0000000-0000-0000-0000-000000000043', 'tenant-demo', 'f0000000-0000-0000-0000-000000000001',
 'Art. 17 -- Image Digest Required',
 'Image must use sha256 digest. Evaluated by eu-ai-act/image-digest-required.',
 7, 'eu-ai-act', 'image-digest-required')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- SOC 2 controls
INSERT INTO public.governance_controls (id, tenant_id, framework_id, name, description, control_order) VALUES
('c0000000-0000-0000-0000-000000000004', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC6.1 -- Logical Access Security',
 'Agent has Identity Owner assigned. Credentials are scoped (not wildcard). Token TTL <= 60 minutes.',
 1),
('c0000000-0000-0000-0000-000000000005', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC6.2 -- System Access Controls',
 'Agent lifecycle state is active (not enrolled/suspended/revoked) for production access. Auth token validated before each action.',
 2),
('c0000000-0000-0000-0000-000000000006', 'tenant-demo', 'f0000000-0000-0000-0000-000000000002',
 'CC7.2 -- System Monitoring',
 'Agent has audit trail events within last 24 hours. No unresolved critical violations. Heartbeat received within SLA.',
 3)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description;

-- CIS Kubernetes Benchmark controls (17, evaluated by cis-kubernetes pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000010', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.1.6 -- SA Token Automount Disabled',
 'Service account tokens are only mounted where necessary. Evaluated by cis-kubernetes/sa-token-automount-disabled.',
 1, 'cis-kubernetes', 'sa-token-automount-disabled'),
('c0000000-0000-0000-0000-000000000012', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.2 -- No Privileged Containers',
 'Minimize the admission of privileged containers. Evaluated by cis-kubernetes/no-privileged-containers.',
 2, 'cis-kubernetes', 'no-privileged-containers'),
('c0000000-0000-0000-0000-000000000011', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.3 -- No Host PID',
 'Minimize the admission of containers sharing the host process ID namespace. Evaluated by cis-kubernetes/no-host-pid.',
 3, 'cis-kubernetes', 'no-host-pid'),
('c0000000-0000-0000-0000-000000000013', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.4 -- No Host IPC',
 'Minimize the admission of containers sharing the host IPC namespace. Evaluated by cis-kubernetes/no-host-ipc.',
 4, 'cis-kubernetes', 'no-host-ipc'),
('c0000000-0000-0000-0000-000000000014', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.5 -- No Host Network',
 'Minimize the admission of containers sharing the host network namespace. Evaluated by cis-kubernetes/no-host-network.',
 5, 'cis-kubernetes', 'no-host-network'),
('c0000000-0000-0000-0000-000000000008', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.6 -- No Privilege Escalation',
 'Minimize the admission of containers with allowPrivilegeEscalation. Evaluated by cis-kubernetes/no-privilege-escalation.',
 6, 'cis-kubernetes', 'no-privilege-escalation'),
('c0000000-0000-0000-0000-000000000007', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.7 -- No Root Containers',
 'Minimize the admission of root containers. Evaluated by cis-kubernetes/no-root-containers.',
 7, 'cis-kubernetes', 'no-root-containers'),
('c0000000-0000-0000-0000-000000000015', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.8 -- No NET_RAW',
 'Minimize the admission of containers with the NET_RAW capability. Evaluated by cis-kubernetes/no-net-raw.',
 8, 'cis-kubernetes', 'no-net-raw'),
('c0000000-0000-0000-0000-000000000016', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.9 -- No Added Capabilities',
 'Minimize the admission of containers with added capabilities. Evaluated by cis-kubernetes/no-added-capabilities.',
 9, 'cis-kubernetes', 'no-added-capabilities'),
('c0000000-0000-0000-0000-000000000017', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.10 -- Capabilities Dropped ALL',
 'Minimize the admission of containers with capabilities assigned. Evaluated by cis-kubernetes/capabilities-dropped-all.',
 10, 'cis-kubernetes', 'capabilities-dropped-all'),
('c0000000-0000-0000-0000-000000000018', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.11 -- No Windows HostProcess',
 'Minimize the admission of Windows HostProcess containers. Evaluated by cis-kubernetes/no-windows-hostprocess.',
 11, 'cis-kubernetes', 'no-windows-hostprocess'),
('c0000000-0000-0000-0000-000000000019', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.12 -- No HostPath Volumes',
 'Minimize the admission of HostPath volumes. Evaluated by cis-kubernetes/no-hostpath-volumes.',
 12, 'cis-kubernetes', 'no-hostpath-volumes'),
('c0000000-0000-0000-0000-000000000020', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.2.13 -- No Host Ports',
 'Minimize the admission of containers which use HostPorts. Evaluated by cis-kubernetes/no-host-ports.',
 13, 'cis-kubernetes', 'no-host-ports'),
('c0000000-0000-0000-0000-000000000021', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.4.1 -- No Secrets in Env',
 'Prefer secrets as files over secrets as environment variables. Evaluated by cis-kubernetes/no-secrets-in-env.',
 14, 'cis-kubernetes', 'no-secrets-in-env'),
('c0000000-0000-0000-0000-000000000009', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.7.2 -- Seccomp RuntimeDefault',
 'Ensure the seccomp profile is set to RuntimeDefault in pod definitions. Evaluated by cis-kubernetes/seccomp-runtime-default.',
 15, 'cis-kubernetes', 'seccomp-runtime-default'),
('c0000000-0000-0000-0000-000000000022', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.7.3 -- Security Context Applied',
 'Apply a security context to pods and containers. Evaluated by cis-kubernetes/security-context-applied.',
 16, 'cis-kubernetes', 'security-context-applied'),
('c0000000-0000-0000-0000-000000000023', 'tenant-demo', 'f0000000-0000-0000-0000-000000000003',
 'CIS 5.7.4 -- No Default Namespace',
 'The default namespace should not be used. Evaluated by cis-kubernetes/no-default-namespace.',
 17, 'cis-kubernetes', 'no-default-namespace')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- FINOS AI Governance Framework controls (16, evaluated by finos-aigf pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000027', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-002 RAG ingestion filters sensitive data',
 'If the agent uses retrieval-augmented generation (agent.data.rag_enabled is true), sensitive-data filtering must be active on ingestion. Not applicable, and passes, when rag_enabled is false. Undeclared or non-boolean rag_enabled fails. Evaluated by finos-aigf/rag-ingestion-sensitive-data-filtered.',
 1, 'finos-aigf', 'rag-ingestion-sensitive-data-filtered'),
('c0000000-0000-0000-0000-000000000025', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-003 Active prompt injection filter guardrail',
 'Enforces real-time input guardrails to detect adversarial prompt injection attacks (agent.guardrails.prompt_injection_filter is true). Evaluated by finos-aigf/prompt-injection-guardrail-active.',
 2, 'finos-aigf', 'prompt-injection-guardrail-active'),
('c0000000-0000-0000-0000-000000000028', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-003 Model output filtered for leakage and harmful content',
 'Model responses are inspected for sensitive-data leakage and policy-violating content before they leave the system (agent.guardrails.output_filter is true). Evaluated by finos-aigf/output-leakage-filter-active.',
 3, 'finos-aigf', 'output-leakage-filter-active'),
('c0000000-0000-0000-0000-000000000029', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-008 Inference request rate limit configured',
 'A positive per-minute request limit is enforced on the agent (agent.rate_limits.requests_per_minute is a JSON number > 0). Evaluated by finos-aigf/inference-rate-limit-configured.',
 4, 'finos-aigf', 'inference-rate-limit-configured'),
('c0000000-0000-0000-0000-000000000024', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-010 Model catalog registration and approval',
 'Verifies AI agent model is registered and actively approved in the enterprise model inventory (agent.registry.model_registered is true). Evaluated by finos-aigf/registered-model-registry-entry.',
 5, 'finos-aigf', 'registered-model-registry-entry'),
('c0000000-0000-0000-0000-000000000030', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-010 Model version pinned, not a floating alias',
 'agent.registry.model_version is a non-empty string without whitespace that does not end in a ''latest'' alias segment (case-insensitive, e.g. ''-latest'', '':latest'', or bare ''latest''). Evaluated by finos-aigf/model-version-pinned.',
 6, 'finos-aigf', 'model-version-pinned'),
('c0000000-0000-0000-0000-000000000031', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-012 Caller authentication and RBAC enforced',
 'Callers must authenticate (agent.access.authentication_required is true) and role-based authorisation is enforced (agent.access.rbac_enforced is true). Evaluated by finos-aigf/user-authn-and-rbac-enforced.',
 7, 'finos-aigf', 'user-authn-and-rbac-enforced'),
('c0000000-0000-0000-0000-000000000032', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-014 All persistent AI data stores encrypted at rest',
 'Every entry of agent.data.persistent_stores has encrypted_at_rest true. An empty list (the agent persists nothing) passes; an absent or non-list field fails. Evaluated by finos-aigf/ai-data-encrypted-at-rest.',
 8, 'finos-aigf', 'ai-data-encrypted-at-rest'),
('c0000000-0000-0000-0000-000000000033', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-018 Tool grants are explicitly scoped, no wildcards',
 'Every entry of agent.tools declares a non-empty scopes list of non-empty strings, none ending in ''*'' (no ''*'' or prefix wildcards). An empty tools list passes; an absent or non-list field fails. Evaluated by finos-aigf/tool-grants-least-privilege.',
 9, 'finos-aigf', 'tool-grants-least-privilege'),
('c0000000-0000-0000-0000-000000000034', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-020 Only allow-listed MCP servers connected',
 'Every entry of agent.mcp_servers has allowlisted true. An empty list (no MCP servers) passes; an absent or non-list field fails. Evaluated by finos-aigf/mcp-servers-allowlisted.',
 10, 'finos-aigf', 'mcp-servers-allowlisted'),
('c0000000-0000-0000-0000-000000000035', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-023 No long-lived credentials exposed to the agent',
 'agent.credentials.long_lived_secrets_exposed is boolean false. Absent or non-boolean fails: lack of a finding is not evidence of protection. Evaluated by finos-aigf/no-long-lived-credentials-exposed.',
 11, 'finos-aigf', 'no-long-lived-credentials-exposed'),
('c0000000-0000-0000-0000-000000000036', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-PREV-024 High-impact tools gated by human approval',
 'Every entry of agent.tools either declares impact ''low'' or ''medium'', or has requires_human_approval true. Tools with impact ''high'' or no impact classification are treated as high (fail-closed). Not applicable, and passes, when every tool is low/medium or the list is empty; an absent or non-list field fails. Evaluated by finos-aigf/high-impact-actions-human-approved.',
 12, 'finos-aigf', 'high-impact-actions-human-approved'),
('c0000000-0000-0000-0000-000000000037', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-004 Agent interaction audit logging enabled',
 'agent.observability.audit_logging is true. Evaluated by finos-aigf/ai-interaction-audit-logging.',
 13, 'finos-aigf', 'ai-interaction-audit-logging'),
('c0000000-0000-0000-0000-000000000038', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-009 Spend budget and alerting configured',
 'agent.cost_controls.budget_limit is a JSON number > 0 and agent.cost_controls.spend_alerting is true. Evaluated by finos-aigf/spend-budget-alerting-configured.',
 14, 'finos-aigf', 'spend-budget-alerting-configured'),
('c0000000-0000-0000-0000-000000000026', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-021 Decision explainability and reasoning trace',
 'Requires recorded reasoning traces and explainability metadata for compliance auditing (agent.governance.decision_explainability is true). Evaluated by finos-aigf/decision-explainability-metadata.',
 15, 'finos-aigf', 'decision-explainability-metadata'),
('c0000000-0000-0000-0000-000000000039', 'tenant-demo', 'f0000000-0000-0000-0000-000000000004',
 'AIR-DET-021 Decision audit log is tamper-evident',
 'agent.governance.audit_log_tamper_evident is true (cryptographic integrity protection on the decision log). Evaluated by finos-aigf/decision-audit-tamper-evident.',
 16, 'finos-aigf', 'decision-audit-tamper-evident')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- NIST SP 800-53 controls (14, evaluated by nist-800-53 pack)
INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order,
    policy_framework_id, policy_check_id
) VALUES
('c0000000-0000-0000-0000-000000000050', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- Non-Root Containers',
 'AC-6: Principle of least privilege -- containers must not run as root. Evaluated by nist-800-53/container-run-as-non-root.',
 1, 'nist-800-53', 'container-run-as-non-root'),
('c0000000-0000-0000-0000-000000000051', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Host IPC',
 'Host IPC namespace not shared. Evaluated by nist-800-53/no-host-ipc.',
 2, 'nist-800-53', 'no-host-ipc'),
('c0000000-0000-0000-0000-000000000052', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Host PID',
 'Host PID namespace not shared. Evaluated by nist-800-53/no-host-pid.',
 3, 'nist-800-53', 'no-host-pid'),
('c0000000-0000-0000-0000-000000000053', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Host Network',
 'Host network namespace not shared. Evaluated by nist-800-53/no-host-network.',
 4, 'nist-800-53', 'no-host-network'),
('c0000000-0000-0000-0000-000000000054', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6(1) -- No Privilege Escalation',
 'Containers must not allow privilege escalation. Evaluated by nist-800-53/no-privilege-escalation.',
 5, 'nist-800-53', 'no-privilege-escalation'),
('c0000000-0000-0000-0000-000000000055', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6(2) -- No Privileged Mode',
 'Privileged mode disabled on containers. Evaluated by nist-800-53/no-privileged-mode.',
 6, 'nist-800-53', 'no-privileged-mode'),
('c0000000-0000-0000-0000-000000000056', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AC-6 -- No Automount SA Token',
 'Service account token auto-mount disabled. Evaluated by nist-800-53/no-automount-sa-token.',
 7, 'nist-800-53', 'no-automount-sa-token'),
('c0000000-0000-0000-0000-000000000057', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'CM-8 -- Application Label',
 'Application label exists on workload. Evaluated by nist-800-53/app-label.',
 8, 'nist-800-53', 'app-label'),
('c0000000-0000-0000-0000-000000000058', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'CM-8 -- Version Label',
 'Version label exists on workload. Evaluated by nist-800-53/version-label.',
 9, 'nist-800-53', 'version-label'),
('c0000000-0000-0000-0000-000000000059', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SC-6 -- Resource Limits Set',
 'CPU and memory limits must be defined. Evaluated by nist-800-53/resource-limits-set.',
 10, 'nist-800-53', 'resource-limits-set'),
('c0000000-0000-0000-0000-000000000060', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SC-7 -- Drop All Capabilities',
 'All capabilities dropped from containers. Evaluated by nist-800-53/drop-all-capabilities.',
 11, 'nist-800-53', 'drop-all-capabilities'),
('c0000000-0000-0000-0000-000000000061', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SI-7 -- Read-Only Root Filesystem',
 'Read-only root filesystem enforced. Evaluated by nist-800-53/read-only-rootfs.',
 12, 'nist-800-53', 'read-only-rootfs'),
('c0000000-0000-0000-0000-000000000062', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'SI-7 -- Image Digest Required',
 'Image must use sha256 digest. Evaluated by nist-800-53/image-digest-required.',
 13, 'nist-800-53', 'image-digest-required'),
('c0000000-0000-0000-0000-000000000063', 'tenant-demo', 'f0000000-0000-0000-0000-000000000005',
 'AU-2 -- Audit Label',
 'Audit logging label present. Evaluated by nist-800-53/audit-label.',
 14, 'nist-800-53', 'audit-label')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Tenant Settings for tenant-demo (with default CEL frameworks active)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status, cookie_preferences
) VALUES (
    'tenant-demo', 'tenant-demo Org', 'enterprise', 'active',
    '["eu-ai-act", "k8s-cis-benchmark", "cis-kubernetes", "finos-ai-governance-framework", "finos-aigf", "soc2", "nist-800-53"]'::jsonb,
    'active',
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Replicate canonical frameworks & controls to kusari
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline, control_count, activated_by
)
SELECT 
    ('f0000000-0000-0000-0001-' || substr(id::text, 25))::uuid,
    'kusari', name, version, regulatory_body, compliance_deadline, control_count, activated_by
FROM public.governance_frameworks WHERE tenant_id = 'tenant-demo'
ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body,
    compliance_deadline = EXCLUDED.compliance_deadline;

INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order, policy_framework_id, policy_check_id
)
SELECT 
    ('c0000000-0000-0001-' || substr(c.id::text, 20))::uuid,
    'kusari',
    ('f0000000-0000-0000-0001-' || substr(c.framework_id::text, 25))::uuid,
    c.name, c.description, c.control_order, c.policy_framework_id, c.policy_check_id
FROM public.governance_controls c WHERE c.tenant_id = 'tenant-demo'
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status, cookie_preferences
) VALUES (
    'kusari', 'Kusari Org', 'enterprise', 'active',
    '["eu-ai-act", "k8s-cis-benchmark", "cis-kubernetes", "finos-ai-governance-framework", "finos-aigf", "soc2", "nist-800-53"]'::jsonb,
    'active',
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO NOTHING;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Replicate canonical frameworks & controls to default tenant
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO public.governance_frameworks (
    id, tenant_id, name, version, regulatory_body, compliance_deadline, control_count, activated_by
)
SELECT 
    ('f0000000-0000-0000-0002-' || substr(id::text, 25))::uuid,
    'default', name, version, regulatory_body, compliance_deadline, control_count, activated_by
FROM public.governance_frameworks WHERE tenant_id = 'tenant-demo'
ON CONFLICT (tenant_id, name) DO UPDATE SET
    control_count = EXCLUDED.control_count,
    version = EXCLUDED.version,
    regulatory_body = EXCLUDED.regulatory_body,
    compliance_deadline = EXCLUDED.compliance_deadline;

INSERT INTO public.governance_controls (
    id, tenant_id, framework_id, name, description, control_order, policy_framework_id, policy_check_id
)
SELECT 
    ('c0000000-0000-0002-' || substr(c.id::text, 20))::uuid,
    'default',
    ('f0000000-0000-0000-0002-' || substr(c.framework_id::text, 25))::uuid,
    c.name, c.description, c.control_order, c.policy_framework_id, c.policy_check_id
FROM public.governance_controls c WHERE c.tenant_id = 'tenant-demo'
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    control_order = EXCLUDED.control_order,
    policy_framework_id = EXCLUDED.policy_framework_id,
    policy_check_id = EXCLUDED.policy_check_id;

INSERT INTO public.tenant_settings (
    tenant_id, org_name, plan_tier, status,
    selected_frameworks, api_key_status, cookie_preferences
) VALUES (
    'default', 'Default Org', 'enterprise', 'active',
    '["eu-ai-act", "k8s-cis-benchmark", "cis-kubernetes", "finos-ai-governance-framework", "finos-aigf", "soc2", "nist-800-53"]'::jsonb,
    'active',
    '{"strictly_necessary": true, "analytics": true}'::jsonb
) ON CONFLICT (tenant_id) DO NOTHING;

