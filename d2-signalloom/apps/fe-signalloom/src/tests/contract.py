"""Consumer-driven contract definitions for the Signal Loom API.

Every model here is the Python equivalent of a TypeScript interface in
``dashboard-signalloom/src/types/api.ts``.  Field names and types are
matched exactly; optional fields use ``None`` defaults.  These models
are the SINGLE source of truth for contract-test assertions across all
three test tiers.

Usage::

    from tests.contract import AgentResponse
    AgentResponse.model_validate(response_json)
"""
from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


# ---- shared nested types ---------------------------------------------------

class CookiePreferences(BaseModel):
    model_config = ConfigDict(extra="forbid")

    strictly_necessary: bool
    analytics: bool


class ComplianceSummaryInline(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_controls: int
    passing: int
    failing: int
    pending: int
    posture_score: float | None


# ---- Agents ----------------------------------------------------------------

class AgentCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    type: str
    description: str | None = None
    owner: str | None = None


class AgentCredentialState(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["active", "revoked"]
    reason: str | None = None
    revoked_at: str | None = None
    revoked_by: str | None = None


class SentinelKernelTelemetry(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cgroup_frozen: bool = False
    cgroup_state: Literal["frozen", "thawed", "none", "unknown"] = "thawed"
    tc_drop_active: bool = False
    traffic_control_state: Literal["drop", "allow", "unknown"] = "allow"
    ebpf_active: bool = False
    ebpf_program_attached: bool | None = None
    observed_at: str | None = None
    last_observed_at: str | None = None
    containment_latency_ms: float | None = None
    cgroup_path: str | None = None
    veth_interface: str | None = None
    sentinel_ack: bool = False
    sentinel_ack_id: str | None = None
    sentinel_drop_count: int | None = None
    sentinel_last_ack_at: str | None = None
    containment_probe_state: Literal["confirmed", "pending", "unconfirmed"] = "unconfirmed"


class RuntimeMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cluster_id: str | None = None
    namespace: str | None = None
    pod_name: str | None = None
    pod_uid: str | None = None
    service_account: str | None = None
    framework: str | None = None
    model: str | None = None
    execution_mode: str | None = None
    node: str | None = None
    phase: str | None = None


class ResponsibilityMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    owner_id: str | None = None
    owner_name: str | None = None
    team: str | None = None
    assignment_status: Literal["assigned", "unassigned", "registry_unlinked"] = "unassigned"


class IdentityMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    spiffe_id: str | None = None
    spiffe_status: Literal["linked", "unlinked"] = "unlinked"
    aliases: list[str] = Field(default_factory=list)
    trust_domain: str | None = None
    svid_type: str | None = None
    cert_valid_from: str | None = None
    cert_valid_until: str | None = None
    cert_serial: str | None = None
    cert_issuer: str | None = None
    selectors: list[str] = Field(default_factory=list)
    authorizing_principal_id: str | None = None
    executing_actor_id: str | None = None
    delegation_hops: int | None = None
    openbao_role: str | None = None
    openbao_path: str | None = None


class ContainmentMeasures(BaseModel):
    model_config = ConfigDict(extra="forbid")

    process_freeze: Literal["active", "inactive", "requested", "unsupported"] = "inactive"
    network_isolation: Literal["active", "inactive", "requested", "unsupported"] = "inactive"
    credential_revocation: Literal["active", "inactive", "requested", "unsupported"] = "inactive"


class OperationalStateMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    runtime_status: str = "unknown"
    containment: ContainmentMeasures = Field(default_factory=ContainmentMeasures)


class AssessmentSummaryMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["assessed", "not_assessed"] = "not_assessed"
    total_controls: int = 0
    passed_controls: int = 0
    failed_controls: int = 0
    pending_controls: int = 0
    normalized_score: float | None = None


class AttentionMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    level: Literal["critical", "warning", "info", "none"] = "none"
    highest_issue: str | None = None


class TimestampsMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    created_at: str | None = None
    last_observed_at: str | None = None
    last_transition_at: str | None = None
    last_action_at: str | None = None


class EnrichedAgentRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", protected_namespaces=())

    id: str
    name: str
    record_class: Literal["registered", "discovered", "resolved", "fixture"] = "registered"
    is_registry_linked: bool = False
    runtime: RuntimeMetadata = Field(default_factory=RuntimeMetadata)
    responsibility: ResponsibilityMetadata = Field(default_factory=lambda: ResponsibilityMetadata(assignment_status="unassigned"))
    identity: IdentityMetadata = Field(default_factory=lambda: IdentityMetadata(spiffe_status="unlinked", aliases=[]))
    operational_state: OperationalStateMetadata = Field(default_factory=lambda: OperationalStateMetadata(
        runtime_status="unknown",
        containment=ContainmentMeasures(process_freeze="inactive", network_isolation="inactive", credential_revocation="inactive")
    ))
    assessment_summary: AssessmentSummaryMetadata = Field(default_factory=AssessmentSummaryMetadata)
    attention: AttentionMetadata = Field(default_factory=AttentionMetadata)
    timestamps: TimestampsMetadata = Field(default_factory=TimestampsMetadata)


class SourceHealthDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["healthy", "degraded", "error", "unavailable"]
    last_good: str | None = None
    message: str | None = None


class OriginVerificationMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    verified: bool
    origin_type: Literal["kubernetes_workload", "registered_catalog", "external_proxy", "custom", "unknown"] = "unknown"
    auth_method: Literal["jwt_bearer", "spiffe_svid", "mtls", "none"] = "none"
    issuer: str | None = None
    subject: str | None = None
    validated_at: str | None = None
    status: Literal["verified", "unverified", "failed", "unsupported"] = "unverified"
    proxy_path: str | None = None
    source_health: SourceHealthDetail | None = None


class AgentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", protected_namespaces=())

    id: str
    name: str
    type: str | None
    origin: str | None = None
    origin_verification: OriginVerificationMetadata | None = None
    owner: str | None = None
    tenant_id: str
    lifecycle_state: str
    last_transition_at: str | None
    last_transition_by: str | None = None
    eu_ai_act_risk_class: str | None
    compliance_summary: ComplianceSummaryInline
    model_name: str | None = None
    created_at: str | None
    credential_state: AgentCredentialState | None = None
    kernel_telemetry: SentinelKernelTelemetry | None = None

    # Workload / Kubernetes preserved discovery fields
    namespace: str | None = None
    service_account: str | None = None
    node: str | None = None
    phase: str | None = None
    pod_uid: str | None = None
    framework: str | None = None
    state: str | None = None
    record_class: Literal["registered", "discovered", "resolved", "fixture"] = "registered"
    is_registry_linked: bool = False

    # Section 2.1 Enriched Structures
    runtime: RuntimeMetadata | None = None
    responsibility: ResponsibilityMetadata | None = None
    identity: IdentityMetadata | None = None
    operational_state: OperationalStateMetadata | None = None
    assessment_summary: AssessmentSummaryMetadata | None = None
    attention: AttentionMetadata | None = None
    timestamps: TimestampsMetadata | None = None


class AgentListMeta(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_records: int
    operational_count: int
    registered_count: int
    discovered_count: int
    resolved_count: int
    fixture_count: int


class SourceHealthDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["healthy", "degraded", "error", "unavailable"]
    last_good: str | None = None
    message: str | None = None


class SourceHealthMap(BaseModel):
    model_config = ConfigDict(extra="forbid")

    k8s_discovery: SourceHealthDetail
    postgres_registry: SourceHealthDetail
    crypto_proofs: SourceHealthDetail


class PaginationMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    page: int
    limit: int
    total_pages: int


class AgentListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agents: list[AgentResponse]
    data: list[AgentResponse] | None = None
    total: int
    meta: AgentListMeta | None = None
    source_health: str | None = None
    source_health_detail: SourceHealthMap | None = None
    pagination: PaginationMetadata | None = None


# ---- Capabilities ----------------------------------------------------------

class ActionCapability(BaseModel):
    model_config = ConfigDict(extra="forbid")

    allowed: bool
    reason: str | None = None
    requires_confirmation: bool = False
    requires_reason: bool = False
    requires_dual_approval: bool = False
    scope: str = "tenant"


class WorkloadActionCapabilities(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str | None = None
    workload: str | None = None
    namespace: str | None = None
    freeze: ActionCapability
    thaw: ActionCapability
    network_isolate: ActionCapability
    network_restore: ActionCapability
    revoke_credentials: ActionCapability
    issue_credentials: ActionCapability
    reassess_compliance: ActionCapability
    decommission: ActionCapability
    run_scenario: ActionCapability


class TenantCapabilities(BaseModel):
    model_config = ConfigDict(extra="forbid")

    view_agents: bool = True
    register_agent: bool = True
    export_compliance: bool = True
    view_crypto_proofs: bool = True
    run_network_tests: bool = True
    view_audit_trail: bool = True
    manage_settings: bool = False
    manage_api_keys: bool = False
    manage_users: bool = False
    run_supercred_scenario: bool = False


class CapabilitiesResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant: str
    principal_id: str
    email: str | None = None
    roles: list[str]
    is_superadmin: bool
    tenant_capabilities: TenantCapabilities
    actions: dict[str, ActionCapability]
    workload: WorkloadActionCapabilities | None = None
    source_health: str | None = "healthy"


class CapabilitiesParams(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str | None = None
    workload: str | None = None
    namespace: str | None = None


# ---- Credentials -----------------------------------------------------------

class IssueCredentialResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    name: str
    identity_token: str
    token_expires_at: str
    token_note: str


class RevokeCredentialResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    name: str
    tokens_revoked: int


# ---- Transitions -----------------------------------------------------------

class TransitionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    to_state: str
    reason: str


class TransitionResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    from_state: str
    to_state: str
    actor: str
    reason: str
    timestamp: str


# ---- Reassessment ----------------------------------------------------------

class ReassessmentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    control_id: str
    status: str
    reassessment_requested_at: str
    reassessment_requested_by: str
    clickup_task_id: str | None


# ---- Violations ------------------------------------------------------------

class ViolationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    agent_id: str
    violation_type: str | None
    severity: str | None
    analysis: str | None
    recommended_action: str | None
    status: str
    acknowledged_by: str | None
    acknowledged_at: str | None
    resolved_at: str | None
    created_at: str | None


class ViolationListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    violations: list[ViolationResponse]
    total: int


# ---- Audit -----------------------------------------------------------------

class AuditEventResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    timestamp: str
    event_type: str
    agent_id: str | None
    agent_name: str | None
    actor: str
    detail: dict[str, Any]
    authorizing_principal_id: str | None = None
    executing_actor_id: str | None = None
    spiffe_id: str | None = None
    attribution_rationale: str | None = None
    evidence_ref: str | None = None
    kernel_telemetry_ref: str | None = None


class AuditListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    events: list[AuditEventResponse]
    total: int
    page: int
    limit: int
    source_health: Literal["healthy", "degraded", "unavailable"] | None = None
    source_health_detail: dict[str, Any] | None = None


# ---- Compliance ------------------------------------------------------------

class ComplianceSummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_agents: int
    agents_assessed: int
    controls_passing: int
    controls_failing: int
    controls_pending: int
    posture_score: float | None


class ControlResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    description: str | None
    control_order: int


class FrameworkResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    version: str | None
    regulatory_body: str | None
    compliance_deadline: str | None
    control_count: int
    controls: list[ControlResponse]


class AgentComplianceResultResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    control_id: str
    control_name: str
    framework_name: str
    status: str
    assessed_at: str | None
    evidence_ref: str | None


class AgentPosture(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    agent_name: str
    posture_score: float | None
    results: list[AgentComplianceResultResponse]


class PostureResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agents: list[AgentPosture]


class EUAIActControlStatus(BaseModel):
    """Defined in the consumer contract but not yet served by any endpoint."""
    model_config = ConfigDict(extra="forbid")

    control_name: str
    status: str
    detail: str | None


class EUAIActResponse(BaseModel):
    """Defined in the consumer contract but not yet served by any endpoint."""
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    risk_class: str | None
    controls: list[EUAIActControlStatus]


# ---- Crypto Health ---------------------------------------------------------

class CryptoProof(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    kind: Literal["positive", "negative"]
    status: Literal["passed", "failed", "error", "pending"]
    title: str
    description: str
    expectation: str
    evidence: str


class CryptoHealthResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str
    proofs: list[CryptoProof]
    source_health: str | None = None


# ---- NHI Discovery --------------------------------------------------------

class NHIScan(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    tenant_id: str
    scan_source: str
    started_at: str | None
    completed_at: str | None
    total_entries_scanned: int | None
    service_accounts_found: int | None
    total_at_risk: int | None
    status: str


class NHIScanListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    scans: list[NHIScan]


class NHIAccount(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    scan_id: str | None
    account_name: str
    directory_source: str
    owner_email: str | None
    last_credential_rotation: str | None
    privilege_level: str
    status: str
    findings: list[str]
    scan_count: int | None
    dismissed_at: str | None
    dismissed_by: str | None
    changes_since_dismissal: bool | None
    previous_risk_flags: list[str] | None
    first_discovered_at: str | None
    last_seen_at: str | None


class NHIAccountDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    scan_id: str | None
    account_name: str
    directory_source: str
    owner_email: str | None
    last_rotated: str | None
    privilege_level: str
    findings: list[str]
    status: str
    first_discovered_at: str | None
    last_seen_at: str | None
    dismissed_at: str | None
    dismissed_by: str | None
    dismiss_reason: str | None
    scan_count: int


class NHIDiscoveredSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_discovered: int
    needs_triage: int
    previously_dismissed: int


class NHIDiscoveredResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    accounts: list[NHIAccount]
    total: int
    summary: NHIDiscoveredSummary


# ---- Settings --------------------------------------------------------------

class TenantSettingsResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str
    org_name: str
    plan_tier: str | None
    agent_count: int
    billing_tier: str | None
    api_key_status: str | None
    selected_frameworks: list[str]
    consent_required: bool
    cookie_preferences: CookiePreferences | None
    preferred_scan_cadence_hours: int
    alert_email: str | None
    alert_threshold: int


class PreferencesUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    preferred_scan_cadence_hours: int
    alert_email: str | None
    alert_threshold: int


# ---- API Keys --------------------------------------------------------------

class InitialApiKeyResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    key: str
    prefix_hint: str
    revealed_at: str


class RotateApiKeyResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    key: str
    prefix_hint: str
    revealed_at: str
    scope: str


# ---- Support ---------------------------------------------------------------

class SupportRequestResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    subject: str
    urgency: str
    submitted_at: str
    clickup_task_id: str | None


# ---- Consent & Cookie Preferences -----------------------------------------

class ConsentStatusResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    accepted: bool
    consent_required: bool
    accepted_at: str | None
    document_versions: dict[str, str]
    cookie_preferences: CookiePreferences


class ConsentAcceptRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    document_versions: dict[str, str]
    cookie_preferences: CookiePreferences
    b2b_warranty_accepted: Literal[True]


class ConsentAcceptResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    accepted: bool
    accepted_at: str
    document_versions: dict[str, str]
    cookie_preferences: CookiePreferences


class CookiePreferencesResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cookie_preferences: CookiePreferences


# ---- Onboarding -----------------------------------------------------------

class OnboardingStatusContract(BaseModel):
    model_config = ConfigDict(extra="forbid")

    skipped_at: str | None = None
    completed_at: str | None = None
    status: Literal["pending", "completed", "skipped"]


class ProviderRunStateContract(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: str
    error: str | None = None


class OnboardingWizardStateContract(BaseModel):
    model_config = ConfigDict(extra="forbid")

    selected_provider_ids: list[str] = Field(default_factory=list)
    step_index: int = 0
    provider_run_state: dict[str, ProviderRunStateContract] = Field(default_factory=dict)

