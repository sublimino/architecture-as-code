import type { PolicyBundle, PolicyRule } from '../types/policies'

export interface RegulatoryFrameworkMeta {
  id: string
  name: string
  version: string
  regulatory_body: string
  compliance_deadline?: string
  description: string
  official_docs_url?: string
  default_active?: boolean
  rules: PolicyRule[]
}

export const REGULATORY_FRAMEWORKS: RegulatoryFrameworkMeta[] = [
  {
    id: 'eu-ai-act',
    name: 'EU AI Act',
    version: 'v2.1.0',
    regulatory_body: 'European Parliament & Council',
    compliance_deadline: '2026-08-02',
    description: 'Mandatory conformity and risk governance for high-risk autonomous AI systems (Regulation 2024/1689).',
    official_docs_url: 'https://artificialintelligenceact.eu/',
    default_active: true,
    rules: [
      {
        id: 'container-run-as-non-root',
        name: 'Art. 9: Workload container execution as non-root',
        description: 'Ensures high-risk AI workloads do not execute with root UID privileges.',
        cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
        severity: 'high',
        remediation: 'Configure securityContext.runAsNonRoot to true in workload spec.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'no-privilege-escalation',
        name: 'Art. 9: Prohibition of container privilege escalation',
        description: 'Prohibits processes within AI workloads from gaining more privileges than parent process.',
        cel_expression: 'object.spec.containers.all(c, c.securityContext.allowPrivilegeEscalation == false)',
        severity: 'critical',
        remediation: 'Set securityContext.allowPrivilegeEscalation to false.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'training-data-provenance',
        name: 'Art. 10: Training dataset provenance and validation',
        description: 'Validates that training and fine-tuning datasets have verified provenance metadata.',
        cel_expression: 'has(agent.training_data_provenance) && agent.training_data_provenance.validated == true',
        severity: 'high',
        remediation: 'Attach verified data provenance metadata to agent manifest.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'audit-trail-retention-immutable',
        name: 'Art. 12: Tamper-evident logging and record retention',
        description: 'Enforces immutable audit logging with hash chaining and >= 365-day retention.',
        cel_expression: 'has(agent.audit_logging) && agent.audit_logging.tamper_evident == true && agent.audit_logging.retention_days >= 365',
        severity: 'high',
        remediation: 'Enable tamper-evident cryptographic audit signing and set retention >= 365 days.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'transparency-model-card-declared',
        name: 'Art. 13: Transparency and machine-readable model card',
        description: 'Verifies presence of machine-readable model card with capabilities and limitations.',
        cel_expression: 'has(agent.model_card) && has(agent.model_card.intended_purpose) && size(agent.model_card.intended_purpose) > 0',
        severity: 'medium',
        remediation: 'Publish and attach standardized model card documentation.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'human-oversight-approval-svid',
        name: 'Art. 14: Privileged action human authorization SVID',
        description: 'Mandates human approval credential for sensitive host execution or IAM operations.',
        cel_expression: "request.tool_call.action in ['exec', 'write_file', 'modify_iam'] ? (has(request.context.claims) && request.context.claims.exists(c, c.type == 'human_approval_svid' && c.valid == true)) : true",
        severity: 'critical',
        remediation: 'Obtain valid human approval SVID prior to executing privileged operations.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cybersecurity-robustness-adversarial',
        name: 'Art. 15: Adversarial attack resilience guardrail',
        description: 'Enforces input and token guardrails against prompt injection and model jailbreaking.',
        cel_expression: 'has(agent.guardrails) && agent.guardrails.prompt_injection_filter == true && agent.guardrails.output_filter == true',
        severity: 'critical',
        remediation: 'Enable dual prompt-injection and output-leakage guardrails in pipeline.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'eu-ai-act-art-11-tech-doc',
        name: 'Art. 11: Technical Documentation & Annex IV Architecture Dossier',
        description: 'Exhaustive technical documentation demonstrating compliance with Annex IV requirements prior to EU market placement.',
        cel_expression: '/* Non-CEL: Requires human architect certification and legal compliance sign-off. External audit attestation required. */',
        severity: 'high',
        remediation: 'Submit Annex IV compliance dossier through compliance portal.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires manual auditor sign-off or external documentation ingest in future releases.',
      },
      {
        id: 'eu-ai-act-art-14-human-agency',
        name: 'Art. 14: Operational Human-in-the-Loop Intervention Protocol',
        description: 'Documented SOP and escalation thresholds allowing designated human overseers to override or halt model execution.',
        cel_expression: '/* Non-CEL: Organizational policy verified via operator interview and emergency kill-switch test. */',
        severity: 'high',
        remediation: 'Attach operational human-in-the-loop SOP sign-off to agent registry.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires manual attestation of human intervention drills.',
      },
      {
        id: 'eu-ai-act-art-72-post-market',
        name: 'Art. 72: Post-Market Surveillance and Incident Reporting System',
        description: 'Continuous post-market monitoring plan and 15-day statutory severe incident reporting protocol.',
        cel_expression: '/* Non-CEL: External telemetry ingestion pipeline and statutory authority reporting plan. */',
        severity: 'medium',
        remediation: 'Register post-market surveillance pipeline with compliance officer.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires external telemetry pipeline attestation.',
      },
    ],
  },
  {
    id: 'nist-800-53',
    name: 'NIST SP 800-53',
    version: 'Rev. 5',
    regulatory_body: 'NIST',
    description: 'Security and Privacy Controls for Information Systems and Organizations.',
    official_docs_url: 'https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final',
    default_active: true,
    rules: [
      {
        id: 'no-automount-sa-token',
        name: 'AC-2: Service account token auto-mount disabled',
        description: 'Prevents automatic injection of default API credentials into container pods.',
        cel_expression: 'object.spec.automountServiceAccountToken == false',
        severity: 'high',
        remediation: 'Set automountServiceAccountToken: false in pod spec.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'least-privilege-sa-roles',
        name: 'AC-6: Least privilege service account role binding',
        description: 'Prohibits cluster-admin and wildcard verb permissions on agent role bindings.',
        cel_expression: "!object.spec.role_bindings.exists(r, r.role == 'cluster-admin' || r.verbs.exists(v, v == '*'))",
        severity: 'critical',
        remediation: 'Restrict role bindings to enumerated read/execute actions without wildcard permissions.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'spiffe-peer-authorization',
        name: 'IA-2: Cryptographic SPIFFE peer workload identity',
        description: 'Enforces cryptographically verifiable SPIFFE SVID peer authentication.',
        cel_expression: "has(request.peer.spiffe_id) && request.peer.spiffe_id.startsWith('spiffe://signalloom.demo/ns/')",
        severity: 'critical',
        remediation: 'Present valid SPIFFE SVID rooted in the Signal Loom trust domain.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cryptographic-audit-hash-chain',
        name: 'AU-2/AU-9: Cryptographic audit log integrity validation',
        description: 'Enforces tamper-evident append-only logging with hash chaining for all transactions.',
        cel_expression: 'has(agent.audit_logging) && agent.audit_logging.tamper_evident == true && agent.audit_logging.retention_days >= 365',
        severity: 'high',
        remediation: 'Enable tamper-evident cryptographic audit log signing.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'boundary-protection-network-deny',
        name: 'SC-7: Network microsegmentation boundary protection',
        description: 'Enforces strict egress and ingress boundary controls on agent communications.',
        cel_expression: 'has(agent.network_boundary) && agent.network_boundary.default_deny == true',
        severity: 'high',
        remediation: 'Enable default-deny network boundary policy on workload namespace.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'system-monitoring-realtime-telemetry',
        name: 'SI-4: Real-time system monitoring and telemetry streaming',
        description: 'Agent continuously streams health and execution telemetry to observatory sink.',
        cel_expression: 'has(agent.telemetry) && agent.telemetry.streaming_active == true && agent.telemetry.heartbeat_ms < 60000',
        severity: 'medium',
        remediation: 'Configure telemetry heartbeat interval under 60,000ms.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'nist-ps-6-access-agreements',
        name: 'PS-6: Personnel Screening & Access Agreements',
        description: 'All system operators and identity owners have completed background screening and signed NDA agreements.',
        cel_expression: '/* Non-CEL: Verified through corporate HR directory and security clearance database. */',
        severity: 'high',
        remediation: 'Verify operator credentials in enterprise HR identity provider.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires manual HR certification or enterprise IdP sync.',
      },
      {
        id: 'nist-ca-8-penetration-testing',
        name: 'CA-8: Independent Penetration Testing Assessment',
        description: 'Autonomous agent execution boundaries subjected to annual independent black-box penetration testing.',
        cel_expression: '/* Non-CEL: External certified penetration testing report required. */',
        severity: 'critical',
        remediation: 'Upload CREST/OSCP accredited penetration test findings.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires external third-party penetration report attestation.',
      },
      {
        id: 'nist-cp-4-contingency-plan',
        name: 'CP-4: Contingency Plan Testing & Disaster Recovery Drill',
        description: 'Annual multi-region failover and autonomous agent containment recovery simulation drill.',
        cel_expression: '/* Non-CEL: Documented disaster recovery drill sign-off within 365 days. */',
        severity: 'medium',
        remediation: 'Record disaster recovery drill completion in compliance ledger.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires executive business continuity sign-off.',
      },
    ],
  },
  {
    id: 'cra',
    name: 'Cyber Resilience Act',
    version: 'v1.0.0',
    regulatory_body: 'European Union',
    compliance_deadline: '2027-12-11',
    description: 'Cybersecurity requirements for products with digital elements (Regulation EU 2024/2847).',
    official_docs_url: 'https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act',
    default_active: true,
    rules: [
      {
        id: 'default-secure-configuration',
        name: 'Sec. 1: Secure-by-default runtime configuration profile',
        description: 'Ensures system components ship and execute with hardened security profiles by default.',
        cel_expression: 'has(agent.security_profile) && agent.security_profile.secure_by_default == true',
        severity: 'high',
        remediation: 'Enable default hardened security profile in agent manifest.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'sbom-verified-provenance',
        name: 'Sec. 2: Verified Software Bill of Materials (SBOM)',
        description: 'Requires machine-readable CycloneDX or SPDX SBOM with verified supply chain provenance.',
        cel_expression: "has(agent.sbom) && (agent.sbom.format == 'CycloneDX' || agent.sbom.format == 'SPDX') && agent.sbom.verified == true",
        severity: 'critical',
        remediation: 'Attach signed CycloneDX or SPDX SBOM metadata to agent workload.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'vulnerability-handling-sla',
        name: 'Sec. 3: 48-Hour critical vulnerability remediation SLA',
        description: 'Verifies container images contain zero unpatched critical CVEs older than 48 hours.',
        cel_expression: 'has(agent.vulnerability_report) && agent.vulnerability_report.critical_count == 0 && agent.vulnerability_report.sla_breached == false',
        severity: 'critical',
        remediation: 'Patch or mitigate critical vulnerabilities within the 48-hour regulatory window.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'attack-surface-reduction-ports',
        name: 'Sec. 4: External network interface and port minimization',
        description: 'Prohibits unapproved open network ingress ports and debug endpoints on production workloads.',
        cel_expression: 'object.spec.containers.all(c, !has(c.ports) || c.ports.all(p, p.containerPort in [8080, 8443, 9090]))',
        severity: 'high',
        remediation: 'Close unapproved ports and restrict container listening surfaces to authorized ports.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'automated-security-patching-cadence',
        name: 'Sec. 5: Workload container image build freshness',
        description: 'Container images must be rebuilt and patched within a 30-day freshness cadence.',
        cel_expression: 'has(agent.build_metadata) && agent.build_metadata.age_days <= 30',
        severity: 'medium',
        remediation: 'Trigger automated CI/CD base image rebuild.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cra-art-11-incident-reporting',
        name: 'Art. 11: 24-hour ENISA Early Warning & CSIRT Notification',
        description: 'Mandatory technical process to notify national CSIRT and ENISA of exploited vulnerabilities within 24 hours.',
        cel_expression: '/* Non-CEL: Verified statutory notification workflow and designated security point-of-contact. */',
        severity: 'high',
        remediation: 'Designate ENISA point-of-contact and configure automated CSIRT notification flow.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires verification of statutory incident reporting runbook.',
      },
      {
        id: 'cra-annex-ii-conformity-assessment',
        name: 'Annex II: Third-Party Conformity Assessment & CE Marking',
        description: 'Third-party conformity assessment certificate issued by an accredited notified body.',
        cel_expression: '/* Non-CEL: Official audit certificate and EU Declaration of Conformity document. */',
        severity: 'critical',
        remediation: 'Upload EU Declaration of Conformity and notified body certificate.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires external notified body audit attestation.',
      },
    ],
  },
  {
    id: 'finos-aigf',
    name: 'FINOS AI Governance Framework',
    version: 'v1.0.0',
    regulatory_body: 'FINOS',
    description: 'Financial industry standard for open-source AI agent safety, differential privacy, and governance.',
    official_docs_url: 'https://air.finos.org/',
    default_active: true,
    rules: [
      {
        id: 'registered-model-registry-entry',
        name: 'AIR-PREV-010: Model catalog registration and approval',
        description: 'Verifies AI agent model is registered and actively approved in the enterprise model inventory.',
        cel_expression: 'has(agent.registry) && agent.registry.model_registered == true',
        severity: 'high',
        remediation: 'Register model in the centralized enterprise AI model catalog.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'prompt-injection-guardrail-active',
        name: 'AIR-PREV-003: Active prompt injection filter guardrail',
        description: 'Enforces real-time input and output guardrails to detect adversarial prompt injection attacks.',
        cel_expression: 'has(agent.guardrails) && agent.guardrails.prompt_injection_filter == true',
        severity: 'critical',
        remediation: 'Enable prompt injection detection filter in agent inference pipeline.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'model-output-leakage-filter',
        name: 'AIR-PREV-003: Model output filtered for data leakage',
        description: 'Model responses are inspected for sensitive-data leakage before egressing the trust boundary.',
        cel_expression: 'has(agent.guardrails) && agent.guardrails.output_filter == true',
        severity: 'critical',
        remediation: 'Enable real-time PII and sensitive data masking on model responses.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'multi-agent-trust-boundary',
        name: 'AIR-AUTH-005: Multi-agent mutual mTLS and SPIFFE trust boundary',
        description: 'Ensures all inter-agent messages and delegations traverse SPIFFE-authenticated mTLS channels.',
        cel_expression: "has(request.peer.trust_domain) && request.peer.trust_domain == 'signalloom.demo' && request.peer.mtls_authenticated == true",
        severity: 'critical',
        remediation: 'Enforce mutual TLS and authenticate peer SPIFFE SVID rooted in trust domain.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'vector-store-data-leak-prevention',
        name: 'AIR-PRIV-007: Vector database RAG embedding data privacy',
        description: 'Requires differential privacy, PII scrubbing, and tenant partition keys on vector embeddings.',
        cel_expression: 'has(agent.rag_pipeline) && agent.rag_pipeline.pii_filter_active == true && has(agent.rag_pipeline.tenant_isolation_key)',
        severity: 'high',
        remediation: 'Enable automated PII scrubbing filter and attach tenant-scoped isolation key.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'tool-execution-explicit-allowlist',
        name: 'AIR-SEC-024: Agent tool execution explicit allowlist',
        description: 'Agent cannot execute unregistered external tools or CLI binaries without explicit allowlisting.',
        cel_expression: 'has(agent.tools) && agent.tools.all(t, t in ["read_file", "search_index", "web_query"])',
        severity: 'critical',
        remediation: 'Constrain agent tool configuration to approved enterprise tools.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'inference-rate-limit-configured',
        name: 'AIR-OPS-008: Inference request rate limit configured',
        description: 'A positive per-minute request limit is enforced on agent inference endpoints.',
        cel_expression: 'has(agent.rate_limits) && agent.rate_limits.requests_per_minute > 0',
        severity: 'medium',
        remediation: 'Set positive requests_per_minute rate limit in agent policy.',
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'finos-mrm-01-model-risk-tiering',
        name: 'MRM-01: Quantitative Model Risk Management (SR 11-7 / OCC) Tiering',
        description: 'Quantitative model risk classification and enterprise validation review in compliance with banking supervisory guidance.',
        cel_expression: '/* Non-CEL: Bank model risk governance committee independent validation and tier sign-off. */',
        severity: 'critical',
        remediation: 'Obtain Model Risk Governance committee sign-off document.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires banking Model Risk Management committee sign-off.',
      },
      {
        id: 'finos-eth-04-fairness-review',
        name: 'ETH-04: Demographic Parity and Fairness Impact Review',
        description: 'Statistical audit of agent outputs across protected categories to prove zero disparate impact.',
        cel_expression: '/* Non-CEL: Independent algorithmic bias assessment and demographic impact study. */',
        severity: 'high',
        remediation: 'Conduct and submit annual fairness and algorithmic parity audit.',
        attestation_type: 'manual',
        manual_attestation: true,
        manual_attestation_note: 'Non-CEL control. Requires demographic parity audit report attestation.',
      },
    ],
  },
  {
    id: 'k8s-cis-benchmark',
    name: 'CIS Kubernetes Benchmark',
    version: 'v1.8.0',
    regulatory_body: 'Center for Internet Security (CIS)',
    description: 'CIS Kubernetes Benchmark v1.8: Workload Security & Namespace Governance',
    official_docs_url: 'https://www.cisecurity.org/benchmark/kubernetes',
    default_active: true,
    rules: [
      {
        id: 'cis-5.2.6',
        name: 'CIS 5.2.6: Minimize the admission of root containers',
        description: 'Containers must run as a non-root user to mitigate privilege escalation and container breakout risks.',
        cel_expression: 'object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)',
        severity: 'high',
        remediation: 'Set securityContext.runAsNonRoot to true on all containers.',
        docs_url: 'https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted',
        tested_separately: false,
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cis-5.2.5',
        name: 'CIS 5.2.5: Minimize admission of containers with allowPrivilegeEscalation',
        description: 'Prohibits a container process from gaining more privileges than its parent process within the pod.',
        cel_expression: 'object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false)',
        severity: 'critical',
        remediation: 'Set securityContext.allowPrivilegeEscalation to false on all containers.',
        docs_url: 'https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted',
        tested_separately: false,
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cis-5.7.4',
        name: 'CIS 5.7.4: Ensure default seccomp profile is set to RuntimeDefault',
        description: 'Applies system call filtering via RuntimeDefault seccomp profile to restrict sensitive kernel surfaces.',
        cel_expression: 'has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile) && object.spec.securityContext.seccompProfile.type in ["RuntimeDefault", "Localhost"]',
        severity: 'high',
        remediation: 'Configure pod securityContext.seccompProfile.type to RuntimeDefault.',
        docs_url: 'https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline',
        tested_separately: false,
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cis-5.7.1',
        name: 'CIS 5.7.1: Minimize default service account token auto-mount',
        description: 'Disable automatic injection of default API credentials into container pods to prevent lateral movement.',
        cel_expression: '!has(object.spec.automountServiceAccountToken) || object.spec.automountServiceAccountToken == false',
        severity: 'medium',
        remediation: 'Set automountServiceAccountToken: false in pod spec or service account.',
        docs_url: 'https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/',
        tested_separately: false,
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cis-5.2.2',
        name: 'CIS 5.2.2: Minimize host PID, IPC, and Network namespace sharing',
        description: 'Containers must not share host PID, IPC, or network namespaces with the host operating system.',
        cel_expression: '(!has(object.spec.hostPID) || object.spec.hostPID == false) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false) && (!has(object.spec.hostNetwork) || object.spec.hostNetwork == false)',
        severity: 'critical',
        remediation: 'Ensure hostPID, hostIPC, and hostNetwork are omitted or set to false.',
        docs_url: 'https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline',
        tested_separately: false,
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cis-5.2.4',
        name: 'CIS 5.2.4: Ensure root execution filesystem is mounted read-only',
        description: 'Container root filesystems must be mounted read-only to prevent persistent malware implants.',
        cel_expression: 'object.spec.containers.all(c, has(c.securityContext) && c.securityContext.readOnlyRootFilesystem == true)',
        severity: 'high',
        remediation: 'Set securityContext.readOnlyRootFilesystem to true on all containers.',
        docs_url: 'https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted',
        tested_separately: false,
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: 'cis-5.3.1',
        name: 'CIS 5.3.1: Ensure NetworkPolicies are defined for all namespaces',
        description: 'Agent namespaces must enforce default-deny ingress and egress network microsegmentation.',
        cel_expression: '/* Cluster-level audit: audited via Cilium / NetworkPolicy controller. Not tested in pod admission CEL. */',
        severity: 'high',
        remediation: 'Apply CiliumNetworkPolicy with default-deny rules in the agent namespace.',
        docs_url: 'https://kubernetes.io/docs/concepts/services-networking/network-policies/',
        tested_separately: true,
        tested_separately_note: 'Audited at namespace/cluster scope via NetworkPolicy controller.',
        attestation_type: 'cluster',
        manual_attestation: true,
        manual_attestation_note: 'Audited at namespace/cluster scope via NetworkPolicy controller.',
      },
      {
        id: 'cis-5.4.1',
        name: 'CIS 5.4.1: Ensure ResourceQuotas are defined for agent namespaces',
        description: 'Namespaces running autonomous AI workloads must define compute and memory ResourceQuotas.',
        cel_expression: '/* Namespace-level audit: audited via ResourceQuota admission controller. Not tested in pod admission CEL. */',
        severity: 'medium',
        remediation: 'Apply ResourceQuota manifest to namespace fe-signalloom-agents.',
        docs_url: 'https://kubernetes.io/docs/concepts/policy/resource-quotas/',
        tested_separately: true,
        tested_separately_note: 'Audited at namespace scope via ResourceQuota controller.',
        attestation_type: 'cluster',
        manual_attestation: true,
        manual_attestation_note: 'Audited at namespace scope via ResourceQuota controller.',
      },
      {
        id: 'cis-5.1.1',
        name: 'CIS 5.1.1: Ensure cluster-admin role is restricted and audited',
        description: 'Agent service accounts must not be bound to cluster-admin ClusterRole.',
        cel_expression: '/* RBAC-level audit: audited via KubeSec-AFM formal verification engine (/rbac-analysis). */',
        severity: 'critical',
        remediation: 'Bind agent service account to least-privilege Role instead of ClusterRole.',
        docs_url: 'https://kubernetes.io/docs/reference/access-authn-authz/rbac/',
        tested_separately: true,
        tested_separately_note: 'Audited via KubeSec-AFM formal RBAC analysis engine (/rbac-analysis).',
        attestation_type: 'cluster',
        manual_attestation: true,
        manual_attestation_note: 'Audited via KubeSec-AFM formal RBAC analysis engine (/rbac-analysis).',
      },
    ],
  },
]

/**
 * Backwards-compatible alias map reconciling old or alternate framework keys.
 */
export const FRAMEWORK_ALIASES: Record<string, string> = {
  'cis-kubernetes': 'k8s-cis-benchmark',
}

/**
 * Normalizes any framework ID string to its canonical ID.
 */
export function normalizeFrameworkId(id: string | null | undefined): string {
  if (!id) return 'eu-ai-act'
  const trimmed = id.trim().toLowerCase()
  return FRAMEWORK_ALIASES[trimmed] || trimmed
}

/**
 * Converts a RegulatoryFrameworkMeta to a PolicyBundle.
 */
export function frameworkToPolicyBundle(fw: RegulatoryFrameworkMeta): PolicyBundle {
  return {
    id: `${fw.id}-${fw.version}`,
    framework_id: fw.id,
    version: fw.version,
    author: fw.regulatory_body,
    description: fw.description,
    created_at: '2026-10-14T00:00:00Z',
    checksum: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    official_docs_url: fw.official_docs_url,
    rules: fw.rules,
  }
}

/**
 * Generates canonical bundles mapped by framework ID.
 */
export const CANONICAL_BUNDLES: Record<string, PolicyBundle> = Object.fromEntries(
  REGULATORY_FRAMEWORKS.map((fw) => [fw.id, frameworkToPolicyBundle(fw)])
)

// Add alias mapping for backwards-compatibility
CANONICAL_BUNDLES['cis-kubernetes'] = CANONICAL_BUNDLES['k8s-cis-benchmark']

/**
 * Returns deduplicated framework options for dropdown selectors.
 */
export function getCanonicalFrameworkOptions(): Array<{ id: string; name: string }> {
  const seen = new Set<string>()
  const options: Array<{ id: string; name: string }> = []

  for (const fw of REGULATORY_FRAMEWORKS) {
    if (!seen.has(fw.id)) {
      seen.add(fw.id)
      options.push({ id: fw.id, name: fw.name })
    }
  }

  return options
}

/**
 * Look up a framework bundle by ID or alias.
 */
export function getBundleForFramework(frameworkId: string | null | undefined): PolicyBundle | null {
  const canonicalId = normalizeFrameworkId(frameworkId)
  return CANONICAL_BUNDLES[canonicalId] ?? null
}
