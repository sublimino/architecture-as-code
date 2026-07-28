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

from pydantic import BaseModel, ConfigDict


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


class AgentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    type: str | None
    owner: str | None = None
    tenant_id: str
    lifecycle_state: str
    last_transition_at: str | None
    last_transition_by: str | None = None
    eu_ai_act_risk_class: str | None
    compliance_summary: ComplianceSummaryInline
    model_name: str | None = None
    created_at: str | None


class AgentListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agents: list[AgentResponse]
    total: int


# ---- Credentials -----------------------------------------------------------

class IssueCredentialResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    name: str
    identity_token: str
    token_expires_at: str
    token_note: str


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


class AuditListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    events: list[AuditEventResponse]
    total: int
    page: int
    limit: int


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
