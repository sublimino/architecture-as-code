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
        id: "sa-token-automount-disabled",
        name: "CIS-5.1.6: Service account token auto-mount disabled",
        description: "The pod sets automountServiceAccountToken: false. Absent means the ServiceAccount's setting, whose default is true, so absent fails.",
        cel_expression: "has(object.spec) && (has(object.spec.automountServiceAccountToken) && object.spec.automountServiceAccountToken == false)",
        severity: "high",
        remediation: "Set spec.automountServiceAccountToken: false on pods that do not call the Kubernetes API.",
        docs_url: "https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-privileged-containers",
        name: "CIS-5.2.2: No privileged containers",
        description: "No container, init container or ephemeral container sets securityContext.privileged: true. Absent defaults to false.",
        cel_expression: "has(object.spec) && (((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, !(has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged == true)))",
        severity: "critical",
        remediation: "Remove securityContext.privileged: true from every container; grant only the specific capabilities required.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-host-pid",
        name: "CIS-5.2.3: Host PID namespace not shared",
        description: "spec.hostPID is absent or false. Absent defaults to false.",
        cel_expression: "has(object.spec) && (!has(object.spec.hostPID) || object.spec.hostPID == false)",
        severity: "critical",
        remediation: "Remove spec.hostPID: true.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-host-ipc",
        name: "CIS-5.2.4: Host IPC namespace not shared",
        description: "spec.hostIPC is absent or false. Absent defaults to false.",
        cel_expression: "has(object.spec) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false)",
        severity: "high",
        remediation: "Remove spec.hostIPC: true.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-host-network",
        name: "CIS-5.2.5: Host network namespace not shared",
        description: "spec.hostNetwork is absent or false. Absent defaults to false.",
        cel_expression: "has(object.spec) && (!has(object.spec.hostNetwork) || object.spec.hostNetwork == false)",
        severity: "high",
        remediation: "Remove spec.hostNetwork: true; expose the workload through a Service instead.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-privilege-escalation",
        name: "CIS-5.2.6: Privilege escalation disallowed",
        description: "Every container sets securityContext.allowPrivilegeEscalation: false. Absent defaults to true, so absent fails. Pods with spec.os.name: windows are exempt (the field is Linux-only and forbidden there).",
        cel_expression: "has(object.spec) && ((has(object.spec.os) && has(object.spec.os.name) && object.spec.os.name == 'windows') || ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false))",
        severity: "high",
        remediation: "Set securityContext.allowPrivilegeEscalation: false on every container, init container and ephemeral container.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-root-containers",
        name: "CIS-5.2.7: Containers do not run as root",
        description: "As Pod Security Admission decides it: the effective runAsNonRoot (container, else pod) must be explicitly true for every container, and no runAsUser may be 0 at pod level or at any container level. runAsNonRoot: true is what makes the kubelet refuse an image whose USER is root, so a non-zero runAsUser alone does not substitute for it; a container setting runAsNonRoot: false is rejected whatever the effective UID; and pod-level runAsUser: 0 is rejected even if every container overrides it. An explicit runAsNonRoot: false is fatal at EITHER level, irrespective of the effective value or of a container override: PSS restricted rejects it outright, and CIS 5.2.7 is framed on admission. Anchored by the external PSA oracle inheritance matrix.",
        cel_expression: "has(object.spec) && (!(has(object.spec.securityContext) && has(object.spec.securityContext.runAsUser) && object.spec.securityContext.runAsUser == 0) && !(has(object.spec.securityContext) && has(object.spec.securityContext.runAsNonRoot) && object.spec.securityContext.runAsNonRoot == false) && ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, ((has(c.securityContext) && has(c.securityContext.runAsNonRoot)) ? c.securityContext.runAsNonRoot == true : (has(object.spec.securityContext) && has(object.spec.securityContext.runAsNonRoot) && object.spec.securityContext.runAsNonRoot == true)) && !(has(c.securityContext) && has(c.securityContext.runAsUser) && c.securityContext.runAsUser == 0) && !(has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == false)))",
        severity: "high",
        remediation: "Set runAsNonRoot: true and a non-zero runAsUser in the pod securityContext, and do not override them per container.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-net-raw",
        name: "CIS-5.2.8: NET_RAW capability not held",
        description: "Container runtimes grant NET_RAW by default, so each container must drop NET_RAW or ALL, must not add it back (NET_RAW, CAP_NET_RAW or ALL), and must not be privileged. Pods with spec.os.name: windows are exempt.",
        cel_expression: "has(object.spec) && ((has(object.spec.os) && has(object.spec.os.name) && object.spec.os.name == 'windows') || ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, !(has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged == true) && has(c.securityContext) && has(c.securityContext.capabilities) && has(c.securityContext.capabilities.drop) && c.securityContext.capabilities.drop.exists(d, d.matches('(?i)^((cap_)?net_raw|all)$')) && !(has(c.securityContext.capabilities.add) && c.securityContext.capabilities.add.exists(a, a.matches('(?i)^(cap_)?(net_raw|all)$')))))",
        severity: "medium",
        remediation: "Add capabilities.drop: [\"ALL\"] (or at least NET_RAW) to every container and do not add NET_RAW back.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-added-capabilities",
        name: "CIS-5.2.9: No added capabilities",
        description: "No container has a non-empty securityContext.capabilities.add. Absent adds nothing.",
        cel_expression: "has(object.spec) && (((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, !(has(c.securityContext) && has(c.securityContext.capabilities) && has(c.securityContext.capabilities.add) && size(c.securityContext.capabilities.add) > 0)))",
        severity: "high",
        remediation: "Remove capabilities.add from every container; redesign the workload if it needs a capability.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "capabilities-dropped-all",
        name: "CIS-5.2.10: All capabilities dropped",
        description: "Every container lists \"ALL\" in securityContext.capabilities.drop, compared exactly as Pod Security Admission compares it: \"all\" in any other case does not satisfy the restricted profile and the pod is rejected, so it fails here too. Absent keeps the runtime default set, so absent fails. Pods with spec.os.name: windows are exempt.",
        cel_expression: "has(object.spec) && ((has(object.spec.os) && has(object.spec.os.name) && object.spec.os.name == 'windows') || ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, has(c.securityContext) && has(c.securityContext.capabilities) && has(c.securityContext.capabilities.drop) && c.securityContext.capabilities.drop.exists(d, d == 'ALL')))",
        severity: "medium",
        remediation: "Add capabilities.drop: [\"ALL\"] to every container, init container and ephemeral container.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-windows-hostprocess",
        name: "CIS-5.2.11: No Windows HostProcess containers",
        description: "Neither the pod nor any container sets securityContext.windowsOptions.hostProcess: true. Absent defaults to false.",
        cel_expression: "has(object.spec) && (!(has(object.spec.securityContext) && has(object.spec.securityContext.windowsOptions) && has(object.spec.securityContext.windowsOptions.hostProcess) && object.spec.securityContext.windowsOptions.hostProcess == true) && ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, !(has(c.securityContext) && has(c.securityContext.windowsOptions) && has(c.securityContext.windowsOptions.hostProcess) && c.securityContext.windowsOptions.hostProcess == true)))",
        severity: "critical",
        remediation: "Remove windowsOptions.hostProcess: true; run node-level Windows agents outside tenant namespaces.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-hostpath-volumes",
        name: "CIS-5.2.12: No hostPath volumes",
        description: "No entry in spec.volumes is a hostPath volume. Absent volumes pass.",
        cel_expression: "has(object.spec) && (!has(object.spec.volumes) || object.spec.volumes.all(v, !has(v.hostPath)))",
        severity: "critical",
        remediation: "Replace hostPath volumes with emptyDir, a PersistentVolumeClaim, a ConfigMap or a CSI volume.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-host-ports",
        name: "CIS-5.2.13: No host ports",
        description: "No container port sets a non-zero hostPort, and spec.hostNetwork is not true. The hostNetwork test sits outside the ports loop on purpose: a hostNetwork pod shares the host network namespace, so every port its processes bind is a host port whether or not the spec declares one, and the API server defaults hostPort to containerPort for any port it does declare. Declaring no ports is therefore not a defence, and a hostNetwork pod fails even with no ports.",
        cel_expression: "has(object.spec) && (!(has(object.spec.hostNetwork) && object.spec.hostNetwork == true) && ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, !has(c.ports) || c.ports.all(p, !(has(p.hostPort) && p.hostPort != 0))))",
        severity: "medium",
        remediation: "Remove hostPort from container ports and expose the workload through a Service.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-secrets-in-env",
        name: "CIS-5.4.1: Secrets not exposed as environment variables",
        description: "No container has an env entry with valueFrom.secretKeyRef or an envFrom entry with secretRef.",
        cel_expression: "has(object.spec) && (((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, (!has(c.env) || c.env.all(e, !(has(e.valueFrom) && has(e.valueFrom.secretKeyRef)))) && (!has(c.envFrom) || c.envFrom.all(f, !has(f.secretRef)))))",
        severity: "medium",
        remediation: "Mount Secrets as volumes and read them from files instead of env/envFrom.",
        docs_url: "https://kubernetes.io/docs/concepts/configuration/secret/",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "seccomp-runtime-default",
        name: "CIS-5.7.2: Seccomp profile RuntimeDefault or Localhost",
        description: "As Pod Security Admission decides it. A pod-level seccompProfile type of Unconfined fails outright, whatever the containers override it with: PSA forbids it at baseline as well as restricted, and any container added later without an override inherits it. Otherwise each container's effective profile (container, else pod) must have type RuntimeDefault, or type Localhost with a non-empty localhostProfile -- Localhost without localhostProfile is rejected by the API server itself (validateSeccompProfileField in pkg/apis/core/validation/validation.go). Unconfined fails; absent everywhere fails (the kubelet default is Unconfined). Pods with spec.os.name: windows are exempt (seccomp is Linux-only).",
        cel_expression: "has(object.spec) && ((has(object.spec.os) && has(object.spec.os.name) && object.spec.os.name == 'windows') || (!(has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile) && has(object.spec.securityContext.seccompProfile.type) && object.spec.securityContext.seccompProfile.type == 'Unconfined') && ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, (has(c.securityContext) && has(c.securityContext.seccompProfile)) ? (has(c.securityContext.seccompProfile.type) && (c.securityContext.seccompProfile.type == 'RuntimeDefault' || (c.securityContext.seccompProfile.type == 'Localhost' && has(c.securityContext.seccompProfile.localhostProfile) && c.securityContext.seccompProfile.localhostProfile != ''))) : (has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile) && (has(object.spec.securityContext.seccompProfile.type) && (object.spec.securityContext.seccompProfile.type == 'RuntimeDefault' || (object.spec.securityContext.seccompProfile.type == 'Localhost' && has(object.spec.securityContext.seccompProfile.localhostProfile) && object.spec.securityContext.seccompProfile.localhostProfile != '')))))))",
        severity: "medium",
        remediation: "Set spec.securityContext.seccompProfile.type: RuntimeDefault and do not override it with Unconfined per container.",
        docs_url: "https://kubernetes.io/docs/concepts/security/pod-security-standards/#baseline",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "security-context-applied",
        name: "CIS-5.7.3: SecurityContext applied to pod and containers",
        description: "spec.securityContext is present and non-empty, and every container, init container and ephemeral container has a non-empty securityContext.",
        cel_expression: "has(object.spec) && (has(object.spec.securityContext) && size(object.spec.securityContext) > 0 && ((has(object.spec.containers) ? object.spec.containers : []) + (has(object.spec.initContainers) ? object.spec.initContainers : []) + (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, has(c.securityContext) && size(c.securityContext) > 0))",
        severity: "low",
        remediation: "Set a pod-level securityContext and a container-level securityContext on every container.",
        docs_url: "https://kubernetes.io/docs/tasks/configure-pod-container/security-context/",
        attestation_type: 'cel',
        manual_attestation: false,
      },
      {
        id: "no-default-namespace",
        name: "CIS-5.7.4: Not in the default namespace",
        description: "metadata.namespace is set and is neither empty nor \"default\". Absent fails: an unset namespace resolves to \"default\" unless the client context says otherwise.",
        cel_expression: "has(object.metadata) && has(object.metadata.namespace) && object.metadata.namespace != '' && object.metadata.namespace != 'default'",
        severity: "low",
        remediation: "Deploy the workload into a dedicated namespace and set metadata.namespace explicitly.",
        docs_url: "https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/",
        attestation_type: 'cel',
        manual_attestation: false,
      },
    ],
  },
]

/**
 * Backwards-compatible alias map reconciling old or alternate framework keys.
 */
export const FRAMEWORK_ALIASES: Record<string, string> = {
  // CIS Kubernetes Benchmark
  'cis-kubernetes': 'k8s-cis-benchmark',
  'k8s-cis': 'k8s-cis-benchmark',
  'cis': 'k8s-cis-benchmark',
  'k8s-cis-benchmark': 'k8s-cis-benchmark',
  'f0000000-0000-0000-0000-000000000003': 'k8s-cis-benchmark',
  'cis kubernetes benchmark': 'k8s-cis-benchmark',

  // EU AI Act
  'eu-ai-act': 'eu-ai-act',
  'eu-ai': 'eu-ai-act',
  'eu ai act': 'eu-ai-act',
  'f0000000-0000-0000-0000-000000000001': 'eu-ai-act',

  // SOC 2 Type II
  'soc2': 'soc2-type-2',
  'soc 2': 'soc2-type-2',
  'soc-2': 'soc2-type-2',
  'soc 2 type ii': 'soc2-type-2',
  'soc2-type-ii': 'soc2-type-2',
  'soc2-type-2': 'soc2-type-2',
  'f0000000-0000-0000-0000-000000000002': 'soc2-type-2',

  // FINOS
  'finos': 'finos-aigf',
  'finos-aigf': 'finos-aigf',
  'finos-ai-governance-framework': 'finos-aigf',
  'finos ai governance framework': 'finos-aigf',
  'f0000000-0000-0000-0000-000000000004': 'finos-aigf',

  // NIST SP 800-53
  'nist': 'nist-800-53',
  'nist-800-53': 'nist-800-53',
  'nist-sp-800-53': 'nist-800-53',
  'nist sp 800-53': 'nist-800-53',

  // CRA
  'cra': 'cra',
  'cyber-resilience-act': 'cra',
  'cyber resilience act': 'cra',

  // NIST AI RMF
  'nist-ai-rmf': 'nist-ai-rmf-1.0',
  'nist ai rmf': 'nist-ai-rmf-1.0',
  'nist-ai-rmf-1.0': 'nist-ai-rmf-1.0',
}

const CRA_TOKEN = /(?:^|[^a-z0-9])cra(?:[^a-z0-9]|$)/

/**
 * Normalizes any framework ID string or name to its canonical ID.
 */
export function normalizeFrameworkId(id: string | null | undefined, name?: string | null): string {
  if (!id && !name) return 'eu-ai-act'
  const trimmedId = id ? id.trim().toLowerCase() : ''
  if (trimmedId && FRAMEWORK_ALIASES[trimmedId]) return FRAMEWORK_ALIASES[trimmedId]

  const trimmedName = name ? name.trim().toLowerCase() : ''
  if (trimmedName && FRAMEWORK_ALIASES[trimmedName]) return FRAMEWORK_ALIASES[trimmedName]

  // Substring heuristics for database names
  if (trimmedName.includes('cis') || trimmedId.includes('cis')) return 'k8s-cis-benchmark'
  if (trimmedName.includes('eu ai') || trimmedId.includes('eu-ai')) return 'eu-ai-act'
  if (trimmedName.includes('soc 2') || trimmedId.includes('soc2')) return 'soc2-type-2'
  if (trimmedName.includes('finos') || trimmedId.includes('finos')) return 'finos-aigf'
  if (trimmedName.includes('800-53') || trimmedId.includes('800-53')) return 'nist-800-53'
  // `cra` only as a whole token: "democracy", "scra" and "craft-ai-standard" are not the CRA.
  if (CRA_TOKEN.test(trimmedName) || trimmedName.includes('cyber resilience') || CRA_TOKEN.test(trimmedId)) return 'cra'
  if (trimmedName.includes('ai rmf') || trimmedId.includes('ai-rmf')) return 'nist-ai-rmf-1.0'

  return trimmedId || trimmedName || 'eu-ai-act'
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

// Add alias mappings so lookup by database UUID or alias succeeds
for (const [alias, canonical] of Object.entries(FRAMEWORK_ALIASES)) {
  if (CANONICAL_BUNDLES[canonical]) {
    CANONICAL_BUNDLES[alias] = CANONICAL_BUNDLES[canonical]
  }
}

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
 * Control-identifier families recognised in rule ids and names, e.g. `CIS 5.4.1`,
 * `cis-5.4.1`, `Art. 10`, `AC-2`, `IA-2`, `CC6.1`. The family is part of the key, so
 * `IA-2` never matches `AC-2`, and the number is taken whole, so `5.4` never matches
 * `5.4.1` and `1` never matches `10`.
 */
const CONTROL_KEY_PATTERN =
  /(?:^|[^a-z0-9])(cis|article|art|ac|ia|au|sc|si|ps|ca|cp|cm|cc)[\s.-]*(\d+(?:\.\d+)*)(?!\.?\d)/g

/** Extracts every control key (`family:number`) from a rule's id and name. */
export function controlKeys(rule: Pick<PolicyRule, 'id' | 'name'>): Set<string> {
  const keys = new Set<string>()
  for (const text of [rule.id, rule.name]) {
    if (!text) continue
    for (const m of text.toLowerCase().matchAll(CONTROL_KEY_PATTERN)) {
      keys.add(`${m[1] === 'article' ? 'art' : m[1]}:${m[2]}`)
    }
  }
  return keys
}

/**
 * Harmonizes rules between an active backend bundle (from the Go CEL policy-engine)
 * and the static regulatory catalogue.
 *
 * The engine is the authority. The result is:
 * 1. Every engine rule with its own fields intact; a one-to-one catalogue match only
 *    fills display-only reference text (description, docs_url).
 * 2. Every unmatched catalogue rule, appended with `catalogue_only: true`: shown as
 *    regulatory context, never presented as evaluated, never saved.
 *
 * Matching prefers correctness over recall: exact id, then a control key that is
 * unambiguous on both sides, then exact name. A catalogue rule is claimed at most once.
 */
export function harmonizeBundleRules(
  templateRules: PolicyRule[] = [],
  activeRules: PolicyRule[] = []
): PolicyRule[] {
  if (!activeRules || activeRules.length === 0) {
    return templateRules || []
  }
  if (!templateRules || templateRules.length === 0) {
    return activeRules || []
  }

  const templates = templateRules
  const matchOf = new Map<number, number>() // active index -> template index
  const claimed = new Set<number>()
  const claim = (a: number, t: number) => {
    matchOf.set(a, t)
    claimed.add(t)
  }

  // 1. Exact id.
  activeRules.forEach((active, a) => {
    const aId = active.id.toLowerCase()
    const t = templates.findIndex((tr, i) => !claimed.has(i) && tr.id.toLowerCase() === aId)
    if (t !== -1) claim(a, t)
  })

  // 2. Control key, only when it identifies exactly one catalogue rule and no other
  //    unmatched engine rule competes for it.
  const templateKeys = templates.map((t) => controlKeys(t))
  const activeKeys = activeRules.map((r) => controlKeys(r))
  const shares = (x: Set<string>, y: Set<string>) => [...x].some((k) => y.has(k))
  activeRules.forEach((_active, a) => {
    if (matchOf.has(a) || activeKeys[a].size === 0) return
    const candidates = templates.map((_t, i) => i).filter((i) => shares(activeKeys[a], templateKeys[i]))
    if (candidates.length !== 1 || claimed.has(candidates[0])) return
    const rival = activeRules.some(
      (_r, other) => other !== a && !matchOf.has(other) && shares(activeKeys[other], templateKeys[candidates[0]]),
    )
    if (!rival) claim(a, candidates[0])
  })

  // 3. Exact name.
  activeRules.forEach((active, a) => {
    if (matchOf.has(a)) return
    const aName = active.name.trim().toLowerCase()
    const t = templates.findIndex((tr, i) => !claimed.has(i) && tr.name.trim().toLowerCase() === aName)
    if (t !== -1) claim(a, t)
  })

  // Engine rules keep their own fields; a match only fills display-only reference text.
  const result: PolicyRule[] = activeRules.map((active, a) => {
    const t = matchOf.get(a)
    if (t === undefined) return active
    const template = templates[t]
    return {
      ...active,
      description: active.description || template.description,
      docs_url: active.docs_url || template.docs_url,
    }
  })

  // Unmatched catalogue rules are regulatory context only: the engine never evaluated them.
  templates.forEach((template, i) => {
    if (!claimed.has(i)) result.push({ ...template, catalogue_only: true })
  })

  return result
}

/**
 * Builds the registerBundle payload from an edited bundle. Only the engine's own rules
 * and the engine's own framework id are sent: catalogue-only rules are dropped, catalogue
 * enrichment is not written back, and the only edit carried is each engine rule's CEL.
 */
export function buildEngineSavePayload(
  edited: PolicyBundle,
  engineBundle: PolicyBundle,
  engineFrameworkId: string,
): PolicyBundle {
  const editedById = new Map(
    (edited.rules || []).filter((r) => !r.catalogue_only).map((r) => [r.id, r] as const),
  )
  return {
    ...engineBundle,
    framework_id: engineFrameworkId,
    version: edited.version,
    created_at: edited.created_at,
    rules: (engineBundle.rules || []).map((rule) => {
      const e = editedById.get(rule.id)
      return e ? { ...rule, cel_expression: e.cel_expression } : rule
    }),
  }
}

/**
 * Picks the engine summary for a canonical framework. The engine registers some
 * frameworks under two ids (`cis-kubernetes` and `k8s-cis-benchmark`) and lists them in
 * random map order, so prefer the summary whose id is the canonical id, then the lexically
 * first alias. Writes must use the chosen summary's own framework_id.
 */
export function selectEngineSummary<T extends { framework_id: string }>(
  summaries: T[],
  canonicalId: string,
): T | undefined {
  const candidates = summaries.filter((s) => normalizeFrameworkId(s.framework_id) === canonicalId)
  return (
    candidates.find((s) => s.framework_id === canonicalId) ??
    [...candidates].sort((x, y) => x.framework_id.localeCompare(y.framework_id))[0]
  )
}

/**
 * Look up a framework bundle by ID or alias.
 */
export function getBundleForFramework(frameworkId: string | null | undefined): PolicyBundle | null {
  const canonicalId = normalizeFrameworkId(frameworkId)
  return CANONICAL_BUNDLES[canonicalId] ?? null
}
