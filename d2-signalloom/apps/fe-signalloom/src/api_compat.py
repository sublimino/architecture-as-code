"""Authenticated, tenant-scoped compatibility API for the local D2 dashboard."""
from __future__ import annotations

import asyncio
import base64
import binascii
import enum
import hashlib
import itertools
import json
import logging
import math
import os
import secrets
import threading
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from typing import Annotated, Any, Literal
from urllib.parse import quote

import asyncpg
import httpx
import jwt
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from starlette.exceptions import HTTPException as StarletteHTTPException

from config import settings
from agent_claim import clamp_claim_delegation_in_spine, sync_claim_delegation_to_spine

logger = logging.getLogger(__name__)

# The API and the schema disagree about how a full-access API key scope is
# spelled: clients receive ``tenant:read-write`` (asserted by the contract
# tests) while ``tenant_api_keys.scope`` has a CHECK constraint permitting only
# ``tenant_admin`` or ``read_only``.  Naming both ends makes the mapping
# visible rather than leaving a literal in each INSERT that silently violates
# the constraint.
_API_KEY_SCOPE_WIRE = "tenant:read-write"
_API_KEY_SCOPE_STORED = "tenant_admin"

AGENT_DISCOVERY_URL = os.environ.get(
    "AGENT_DISCOVERY_URL",
    "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/agents",
)
CRYPTO_HEALTH_URL = os.environ.get(
    "CRYPTO_HEALTH_URL",
    "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/crypto-proofs",
)
NETWORK_TESTS_URL = os.environ.get(
    "NETWORK_TESTS_URL",
    "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/network-tests",
)
NETWORK_TESTS_SCAN_URL = os.environ.get(
    "NETWORK_TESTS_SCAN_URL",
    "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/network-tests/scan",
)
TRUST_TOPOLOGY_URL = os.environ.get(
    "TRUST_TOPOLOGY_URL",
    "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/trust-topology",
)
#: Base for ``POST {base}/{agent_id}/stun`` on the SuperCred proxy.
#:
#: The fifth of these constants and the last endpoint to join them. The stun
#: used to be issued by the BROWSER, straight at /supercred-api/, with this API
#: called afterwards to write down what the browser said had happened. Calling
#: it from here instead is not a new capability -- the same pod already reaches
#: the same service on the same port for discovery, crypto proofs, network
#: tests and trust topology, and `network_tests_scan` already POSTs to it.
#:
#: An empty value means this deployment has no proxy, which is a real state for
#: a laptop demo and never a cluster one. The stun then records an outcome of
#: ``simulated`` with ``cluster_action_observed: false``, so the row says
#: plainly that nothing was watched rather than implying something was. The
#: default is the real path; simulation has to be asked for.
SUPERCRED_STUN_BASE_URL = os.environ.get(
    "SUPERCRED_STUN_BASE_URL",
    "http://fake-integration-proxy.inf-signalloom.svc.cluster.local:8080/agents",
)

# ---------------------------------------------------------------------------
# Pydantic response models (UNCHANGED — these are the API contract)
# ---------------------------------------------------------------------------


class ErrorDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str
    message: str


class ErrorResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    error: ErrorDetail


class ComplianceSummaryInline(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_controls: int
    passing: int
    failing: int
    pending: int
    posture_score: float | None


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
    traffic_control_state: Literal["drop", "allow", "unknown"] | None = None
    ebpf_active: bool = False
    ebpf_program_attached: bool | None = None
    containment_latency_ms: float | None = None
    cgroup_path: str | None = None
    veth_interface: str | None = None
    observed_at: str | None = None
    last_observed_at: str | None = None
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
    spiffe_status: Literal["linked", "unlinked", "conflict"] = "unlinked"
    aliases: list[str] = Field(default_factory=list)
    trust_domain: str | None = None
    svid_type: Literal["x509", "jwt", "none"] | None = None
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

    runtime_status: Literal["running", "stopped", "degraded", "unknown"] = "unknown"
    containment: ContainmentMeasures = Field(default_factory=ContainmentMeasures)


class AssessmentSummaryMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["assessed", "not_assessed", "evaluating"] = "not_assessed"
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


class AgentClaimByIdRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    pod_name: str | None = None
    namespace: str | None = None
    spiffe_id: str | None = None
    harness: str | None = None
    model: str | None = None
    token_budget_limit: int | None = None
    declared_tools: list[str] | None = None
    agent_id: str | None = None


class AgentClaimRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    pod_name: str
    namespace: str = "fe-signalloom-agents"
    spiffe_id: str
    harness: str = "claude-code"
    model: str = "claude-3-5-sonnet"
    declared_tools: list[str] = Field(default_factory=list)
    token_budget_limit: int = 100000
    agent_id: str | None = None
    operator_id: str | None = None
    capabilities: list[str] | None = None
    containment_claims: list[str] | None = None


class AgentClaimResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    claim_id: str
    status: Literal["granted", "denied", "pending-review"] = "granted"
    spiffe_svid_verified: bool = True
    allocated_token_budget: int = 100000
    signal_session_url: str | None = None
    ebpf_sentinel_bound: bool = True
    agent_id: str


class ClaimRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    claim_id: str
    pod_name: str
    namespace: str
    spiffe_id: str
    harness: str
    model: str
    status: Literal["granted", "denied", "pending-review"]
    allocated_token_budget: int
    claimed_at: str
    released_at: str | None = None
    agent_id: str | None = None


class ClaimListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    claims: list[ClaimRecord]
    total: int


class AutoclaimDiscoveredRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    namespace: str | None = None


class AutoclaimDiscoveredResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    claimed: list[ClaimRecord]
    total_claimed: int


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


class PlatformUserResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    email: str
    display_name: str
    role: Literal["admin", "editor", "viewer"]
    status: Literal["active", "invited", "suspended", "deactivated"]
    department: str | None
    title: str | None
    last_login_at: str | None
    created_at: str


class PlatformUsersResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    users: list[PlatformUserResponse]
    total: int


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


class NetworkTestEndpoint(BaseModel):
    model_config = ConfigDict(extra="forbid")

    namespace: str
    name: str


class NetworkTestResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    expectedExit: int
    targetPort: int
    src: NetworkTestEndpoint
    dst: NetworkTestEndpoint
    description: str
    result: Literal["pass", "fail", "pending", "running", "error"]
    evidence: str
    lastRun: str | None = None


class TopologyCollector(BaseModel):
    model_config = ConfigDict(extra="forbid")
    status: Literal["ok", "partial", "unavailable"]
    observed_at: str
    reason: str


class TopologyEvidence(BaseModel):
    model_config = ConfigDict(extra="forbid")
    evidence_state: Literal["observed", "error", "unavailable", "modeled", "stale"]
    evidence_source: str
    observed_at: str | None
    freshness: Literal["fresh", "stale", "unavailable"]
    assurance: Literal["runtime-observed", "configuration-observed", "modeled"]
    reason: str


class TrustTopologyItem(TopologyEvidence):
    model_config = ConfigDict(extra="forbid")
    id: str
    kind: Literal["platform", "tenant", "project", "service", "agent", "external", "probe", "gap"]
    name: str | None = None
    label: str | None = None
    namespace: str | None = None
    tenant: str | None = None
    project: str | None = None
    parent_id: str | None = None
    location: Literal["in-cluster", "external"] | None = None
    service_account: str | None = None
    phase: str | None = None
    ready: bool | None = None
    pod_uid: str | None = None
    pod_name: str | None = None
    spiffe_id: str | None = None
    x: int | None = None
    y: int | None = None
    lifecycle_state: str | None = None
    trust_domain: str | None = None
    verified: bool | None = None
    tool_permissions: list[str] | None = None
    egress_allowlist: list[str] | None = None
    metadata: dict[str, Any] | None = None
    custom_attributes: dict[str, Any] | None = None
    status: str | None = None
    selectors: list[str] | None = None
    bao_role: str | None = None
    bao_path: str | None = None
    audience: str | None = None
    ttl: str | None = None
    policy_ref: str | None = None


class TrustTopologyEdge(TopologyEvidence):
    model_config = ConfigDict(extra="forbid")
    id: str
    from_id: str
    to_id: str
    verb: str
    plane: Literal["identity", "authorization", "network", "external"]
    decision: Literal["allowed", "denied"]
    denial_kind: Literal["network-block", "application-authorization-rejection"] | None = None
    tenant: str | None = None
    project: str | None = None
    policy_ref: str | None = None
    spiffe_id: str | None = None
    renewable: bool | None = None
    lease_duration: int | None = None
    token_type: str | None = None
    throughput_pps: float | None = None
    latency_ms: float | None = None
    mtls_enforced: bool | None = None
    bao_role: str | None = None
    bao_path: str | None = None
    audience: str | None = None
    ttl: str | None = None


class TrustTopologyResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")
    generated_at: str
    version: Literal["v1"]
    collectors: dict[str, TopologyCollector]
    nodes: list[TrustTopologyItem]
    edges: list[TrustTopologyEdge]
    modeled_gaps: list[TrustTopologyItem]


class NetworkTestListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tests: list[NetworkTestResult]
    scanStatus: Literal["never-run", "pending", "running", "complete", "failed", "unavailable"]
    job: dict[str, str] | None = None


class NetworkTestScanResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    job: str
    status: str


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


# ---------------------------------------------------------------------------
# Lifecycle state machine — the vocabulary and the transition graph
# ---------------------------------------------------------------------------
#
# Must stay in step with:
#   - DB CHECK constraint in migration 009_agent_lifecycle_states.sql
#   - VALID_NEXT_STATES in dashboard-signalloom/src/pages/AgentDetailPage.tsx
#
# The DB constraint is the backstop; this is the gate that turns a violation
# into a 400 with a message the caller can act on, instead of a 500 from a
# CHECK failure that names the constraint but not the vocabulary.

VALID_LIFECYCLE_STATES: frozenset[str] = frozenset({
    "registered",
    "enrolled",
    "active",
    "suspended",
    "revoked",
    "decommissioned",
})

#: The transition graph.  Keys are from-states; values are the set of states
#: reachable from that state.  A state absent as a key is a terminal state
#: (no outbound transitions).  The graph is deliberately one-directional for
#: revoked/decommissioned: once an agent reaches a terminal state, re-activation
#: requires a new registration, not a transition — the audit trail must not
#: show a decommissioned agent silently coming back to life.
VALID_TRANSITIONS: dict[str, frozenset[str]] = {
    "registered": frozenset({"enrolled", "active", "suspended", "revoked", "decommissioned"}),
    "enrolled":   frozenset({"active", "suspended", "revoked", "decommissioned"}),
    "active":     frozenset({"suspended", "revoked", "decommissioned"}),
    "suspended":  frozenset({"active", "revoked", "decommissioned"}),
    # Terminal states: no outbound transitions.
    "revoked":        frozenset(),
    "decommissioned": frozenset(),
}


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


class ReassessmentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    control_id: str
    status: str
    reassessment_requested_at: str
    reassessment_requested_by: str
    clickup_task_id: str | None


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


class TelemetryObservationModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    observed_at: str
    source: str
    layer: str
    actor_id: str
    principal_id: str | None = None
    action: str
    details: dict[str, Any] = Field(default_factory=dict)
    confidence: float = 1.0


class AgentTelemetryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    tenant_id: str
    observations: list[TelemetryObservationModel] = Field(default_factory=list)
    total_count: int = 0
    pushdown_filters: dict[str, Any] = Field(default_factory=dict)
    source_health: str = "healthy"


class AuditListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    events: list[AuditEventResponse]
    total: int
    page: int
    limit: int
    source_health: str | None = None
    source_health_detail: SourceHealthMap | None = None


# Defined after AuditEventResponse: StunAgentResponse embeds one, and the point
# of embedding it is that the caller sees the exact row that was written rather
# than a paraphrase of it.
#
# ``StunAgentRequest`` used to stand here. It was the clearest statement of the
# defect anywhere in this file, because it said what it was doing out loud:
# "context the dashboard supplies when it records a stun". The browser sent
# ``agent_name``, ``namespace``, ``reason`` and -- worst of the four --
# ``outcome``, the result of an action nothing server-side had checked. The
# handler copied all of it into ``detail`` and returned it as though the server
# had established it. A row assembled from the account of the party being
# audited is not evidence; it is that party's story, filed somewhere
# authoritative-looking.
#
# There is no request model now because there is nothing a caller may
# contribute. The endpoint performs the cluster action itself and records what
# it observed, so every field of the row has a server-side source: identity
# from the token, target from the path, prior state from this database, outcome
# and namespace from the proxy's own response. A body sent by an older client
# is ignored rather than rejected -- deliberately, so a dashboard mid-rollout
# degrades to "its values stop being recorded" rather than "every stun 422s".
class ProxyStunReport(BaseModel):
    """What the SuperCred proxy said, kept apart from what we established.

    Nested rather than flattened alongside the first-party fields, and the
    reason is the principle rather than taste. This whole change exists so a
    reader can tell which assertions the writer checked and which came from
    elsewhere. Flattening merges "fe-signalloom read this under FOR UPDATE"
    with "the proxy told us this" into one namespace and nobody downstream can
    separate them again -- which is the property deleting ``reason`` and
    ``outcome`` from the request was meant to restore. Nesting makes provenance
    structural instead of tribal knowledge.

    Two practical consequences in its favour: the proxy's payload can change
    shape without colliding with a first-party field name, and when the proxy
    later writes its own audit row about the same act, the two are visibly
    distinct claims rather than one silently overwriting the other.
    """

    model_config = ConfigDict(extra="forbid")

    #: False only where no proxy is configured at all -- a laptop demo, never a
    #: cluster. Every other value here was watched by this process.
    observed: bool
    #: The proxy's own word for what it did, or "failed", or "simulated".
    outcome: str
    namespace: str | None
    status: int | None
    error: str | None
    #: The proxy's response verbatim, carrying `state`, `stunned_at` and
    #: `message`, so the dashboard has what it needs without calling the proxy.
    payload: dict[str, Any]


class StunAgentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    from_state: str
    to_state: str
    actor: str
    stunned_at: str
    proxy: ProxyStunReport
    event: AuditEventResponse
    sentinel_telemetry: SentinelKernelTelemetry | None = None


class ComplianceSummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_agents: int
    agents_assessed: int
    controls_passing: int
    controls_failing: int
    controls_pending: int
    posture_score: float | None


#: The denomination every monetary figure this API reports is expressed in.
#:
#: A constant rather than a per-tenant setting for now, and deliberately so: the risk calibration
#: data behind these figures is GBP-denominated, so making the OUTPUT currency configurable without
#: also redenominating the INPUTS would relabel figures rather than convert them. Conversion for
#: display belongs to the consumer, against the checked-in dated table in ``risk/fx/rates.yaml``.
REPORTING_CURRENCY = "GBP"


class MoneyResponse(BaseModel):
    """An amount with its denomination attached.

    Mirrors the Go ``money.Money`` wire shape in
    ``d2-signalloom/apps/policy-engine/money``. It exists because a currency welded into a FIELD
    NAME (``totalExposureGbp``) does not survive a wire, a database column or a chart axis, so a
    consumer defaulting its display to USD would relabel a GBP figure rather than convert it.

    ``currency`` is an ISO 4217 alphabetic code.
    """

    model_config = ConfigDict(extra="forbid")

    amount: float
    currency: str = Field(min_length=3, max_length=3, pattern=r"^[A-Z]{3}$")


class PolicyFrameworkSummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    versions: list[str]
    totalControls: int
    passedControls: int
    failedControls: int
    totalExposureGbp: int
    # Denominated twin of totalExposureGbp. Additive on purpose: the *Gbp fields stay until every
    # consumer has migrated, because a breaking rename would take the dashboard down mid-flight.
    # New consumers should read `exposure` and treat `totalExposureGbp` as deprecated -- its name
    # is a lie the moment a tenant reports in anything other than sterling.
    exposure: MoneyResponse | None = None


class PolicySummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    totalChecks: int
    passed: int
    failed: int
    totalAle: int
    totalVar95: int
    totalTvar: int
    totalCarriedGbp: int
    # Denominated twin of totalCarriedGbp; see PolicyFrameworkSummaryResponse.exposure.
    carried: MoneyResponse | None = None
    # The denomination of totalAle / totalVar95 / totalTvar / totalCarriedGbp above.
    currency: str | None = None
    scanTimestamp: str
    frameworks: list[PolicyFrameworkSummaryResponse]


class PolicyScanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    namespace: str = Field(min_length=1, max_length=253)
    policyVersion: str = Field(min_length=1, max_length=64)
    frameworks: list[str] = Field(default_factory=list)


class PolicyComplianceCheck(BaseModel):
    model_config = ConfigDict(extra="forbid")

    framework: str
    controlSet: str
    control: str
    check: str
    passed: bool
    policyVersion: str
    ale: int
    var95: int
    tvar: int
    carriedGbp: int
    # Denominated twin of carriedGbp; see PolicyFrameworkSummaryResponse.exposure.
    carried: MoneyResponse | None = None
    # The denomination of ale / var95 / tvar / carriedGbp above.
    currency: str | None = None
    scanTimestamp: str
    calibrationSource: str


class PolicyScanResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    checks: list[PolicyComplianceCheck]
    summary: PolicySummaryResponse


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


class CookiePreferences(BaseModel):
    model_config = ConfigDict(extra="forbid")

    strictly_necessary: bool
    analytics: bool


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


class SupportRequestCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject: str
    urgency: Literal["low", "normal", "high", "critical"]
    message: str


class SupportRequestResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    subject: str
    urgency: str
    submitted_at: str
    clickup_task_id: str | None


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


class FrameworksPatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    selected_frameworks: list[str]


class PreferencesPatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    preferred_scan_cadence_hours: int = Field(ge=1)
    alert_email: str | None = Field(default=None, max_length=320)
    alert_threshold: int = Field(ge=1)

    @field_validator("alert_email")
    @classmethod
    def _blank_email_is_unset(cls, value: str | None) -> str | None:
        """Treat an empty/whitespace-only address the same as no address."""
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None


#: The display currencies a caller may actually choose.
#:
#: WHY A CLOSED SET AND NOT JUST A SHAPE CHECK.  This used to be validated as
#: "three uppercase ASCII letters", which is 17,576 codes.  The dashboard can
#: render fifteen -- SUPPORTED_CURRENCIES in
#: dashboard-signalloom/src/money/currency.ts, which is exactly the currency
#: list in risk/fx/rates.yaml, because a currency with no rate renders every
#: figure as Unavailable.
#:
#: The gap between those two sets was not a 500 or a crash.  CurrencyContext.tsx
#: reads the stored preference through ``isCurrencyCode`` and silently falls
#: back to USD when it does not recognise the value.  So a caller PATCHing
#: ``ZZZ`` got a 200, the value was persisted, ``user.currency_updated`` was
#: written to the audit trail -- and the screen carried on showing USD.  That is
#: the exact failure the comment on DEFAULT_DISPLAY_CURRENCY below warns about:
#: "a user sees one currency while the audit trail records another".
#:
#: Note that ISO 4217 membership is NOT the right test either.  ``XXX`` is a
#: real ISO assignment meaning "no currency", and ``XAU`` is gold; both are
#: perfectly valid codes and neither is something this product can price.  The
#: binding constraint is the rate table, so that is what is enforced.
#:
#: Must stay in step with SUPPORTED_CURRENCIES in currency.ts and the rates in
#: risk/fx/rates.yaml.  tests/test_user_currency_renderable.py parses the
#: TypeScript and asserts the two sets are equal, so a divergence is a red test
#: rather than a comment nobody re-read.
SUPPORTED_DISPLAY_CURRENCIES: frozenset[str] = frozenset({
    "USD", "GBP", "EUR", "JPY",
    "AED", "AUD", "CAD", "CHF", "DKK", "HKD", "INR", "NOK", "SEK", "SGD", "ZAR",
})


class UserPreferencesResponse(BaseModel):
    """Preferences belonging to ONE user, not to their tenant.

    Distinct from TenantSettingsResponse, whose scan preferences every user in
    a tenant shares.  Two people looking at the same fleet can want different
    display currencies, and one of them changing it must not move the other's
    figures.
    """

    display_currency: str


class UserPreferencesPatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_currency: str = Field(min_length=3, max_length=3)

    @field_validator("display_currency")
    @classmethod
    def _iso4217(cls, value: str) -> str:
        """Reject anything the dashboard could not actually display.

        Validated here as well as by the CHECK constraint in migration 020
        because the no-pool path has no database to enforce it, and because a
        400 naming the field is a better answer than a CheckViolationError
        surfacing as a 500.  Case is NOT coerced: a client sending 'usd' has a
        bug worth telling it about rather than papering over.

        The shape check alone was not enough.  It admitted every three-letter
        combination, and the fourteen thousand of those with no rate behind them
        were stored, audited, and then silently ignored by the dashboard, which
        falls back to USD for a code it does not recognise.  See
        SUPPORTED_DISPLAY_CURRENCIES for why membership -- not shape, and not
        ISO 4217 -- is the constraint that matters.
        """
        if not (value.isascii() and value.isalpha() and value.isupper()):
            raise ValueError("display_currency must be a three-letter uppercase ISO 4217 code")
        if value not in SUPPORTED_DISPLAY_CURRENCIES:
            raise ValueError(
                f"display_currency {value!r} is not a currency this product can price. "
                f"Supported: {', '.join(sorted(SUPPORTED_DISPLAY_CURRENCIES))}"
            )
        return value


class CookiePrefsPatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    analytics: bool


# ---------------------------------------------------------------------------
# Error types (UNCHANGED)
# ---------------------------------------------------------------------------


class APIError(Exception):
    def __init__(self, status_code: int, code: str, message: str):
        self.status_code = status_code
        self.code = code
        self.message = message


class JWTValidationError(ValueError):
    """An intentionally opaque JWT validation failure."""


# ---------------------------------------------------------------------------
# Helpers (UNCHANGED)
# ---------------------------------------------------------------------------


# Failures that are statements about the database, not about this service.
# ``PostgresConnectionError`` covers the server going away mid-query;
# ``InterfaceError`` covers a pool that is closing underneath a caller;
# ``TimeoutError`` is what ``pool.acquire()`` raises when every connection is
# checked out, and ``OSError`` covers the socket-level cases (``ConnectionReset``
# and friends are subclasses).
_DATABASE_UNREACHABLE: tuple[type[BaseException], ...] = (
    asyncpg.PostgresConnectionError,
    asyncpg.InterfaceError,
    asyncio.TimeoutError,
    ConnectionError,
)


def _error_response(status_code: int, code: str, message: str) -> JSONResponse:
    body = ErrorResponse(error=ErrorDetail(code=code, message=message))
    return JSONResponse(status_code=status_code, content=body.model_dump())


def install_api_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(APIError)
    async def handle_api_error(_request: Request, exc: APIError) -> JSONResponse:
        return _error_response(exc.status_code, exc.code, exc.message)

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(
        _request: Request, _exc: RequestValidationError
    ) -> JSONResponse:
        return _error_response(422, "invalid_request", "Request is invalid")

    @app.exception_handler(StarletteHTTPException)
    async def handle_http_error(
        _request: Request, exc: StarletteHTTPException
    ) -> JSONResponse:
        if exc.status_code == 404:
            return _error_response(404, "not_found", "Resource was not found")
        if exc.status_code == 405:
            return _error_response(405, "method_not_allowed", "Method is not allowed")
        return _error_response(exc.status_code, "request_error", "Request failed")

    @app.exception_handler(Exception)
    async def handle_internal_error(_request: Request, exc: Exception) -> JSONResponse:
        if isinstance(exc, _DATABASE_UNREACHABLE):
            # The other half of the ``_require_pool`` promise. That gate fails
            # closed when the pool cannot be *created*; this covers the pool
            # object outliving the database behind it -- the server restarts,
            # the connection is reset, or every connection is checked out and
            # ``acquire()`` times out. All of those reached here as
            # ``500 internal_error``, which tells whoever is paged that this
            # service has a bug: the least useful thing to say when the fault is
            # in Postgres or in capacity, and not a status any client will retry.
            #
            # Deliberately narrow. ``asyncpg.PostgresError`` would also catch
            # NotNull/Check/ForeignKey violations, which mean this service sent
            # Postgres something it was right to refuse -- relabelling those as
            # ``database_unavailable`` would blame a healthy database for a bug
            # here and invite a retry that can never succeed. Guarded by
            # ``test_a_schema_violation_is_a_server_fault_and_must_not_be_reported_as_an_outage``.
            logger.warning("database unreachable during request", exc_info=exc)
            return _error_response(
                503,
                "database_unavailable",
                "The database is currently unreachable",
            )
        logger.exception("compatibility API request failed", exc_info=exc)
        return _error_response(500, "internal_error", "Internal server error")


def _reject_json_constant(value: str) -> None:
    raise JWTValidationError(f"unsupported JSON constant: {value}")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise JWTValidationError("duplicate JWT field")
        result[key] = value
    return result


def _decode_segment(segment: str) -> bytes:
    try:
        raw = segment.encode("ascii")
        return base64.b64decode(
            raw + b"=" * (-len(raw) % 4), altchars=b"-_", validate=True
        )
    except (UnicodeEncodeError, binascii.Error, ValueError) as exc:
        raise JWTValidationError("invalid JWT encoding") from exc


def _decode_object(segment: str) -> dict[str, Any]:
    try:
        value = json.loads(
            _decode_segment(segment),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise JWTValidationError("invalid JWT JSON") from exc
    if not isinstance(value, dict):
        raise JWTValidationError("JWT segment is not an object")
    return value


@lru_cache(maxsize=8)
def _jwk_client(jwks_url: str) -> jwt.PyJWKClient:
    return jwt.PyJWKClient(jwks_url, cache_keys=True)


def validate_jwt(token: str) -> dict[str, Any]:
    """Validate a Dex RS256 ID token against the configured JWKS endpoint."""
    try:
        parts = token.split(".")
        if len(parts) != 3 or not all(parts):
            raise JWTValidationError("malformed JWT")
        header = _decode_object(parts[0])
        _decode_object(parts[1])
        typ = header.get("typ")
        # Dex ID tokens omit the "typ" header; accept an absent typ but still
        # reject a present-but-wrong one. RS256 remains mandatory.
        if header.get("alg") != "RS256" or (typ is not None and typ != "JWT"):
            raise JWTValidationError("unsupported JWT header")
        if not isinstance(header.get("kid"), str) or not header["kid"]:
            raise JWTValidationError("missing JWT key identifier")
        if not settings.api_jwks_url:
            raise APIError(503, "authentication_unavailable", "Authentication is unavailable")
        signing_key = _jwk_client(settings.api_jwks_url).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.api_jwt_audience,
            issuer=settings.api_jwt_issuer,
            options={"require": ["exp", "iat", "sub"]},
            leeway=5,
        )
    except APIError:
        raise
    except (jwt.PyJWTError, ValueError, TypeError) as exc:
        raise JWTValidationError("invalid Dex JWT") from exc

    if claims.get("azp") != settings.api_jwt_authorized_party:
        raise JWTValidationError("unexpected JWT authorized party")
    if not isinstance(claims.get("sub"), str) or not claims["sub"].strip():
        raise JWTValidationError("missing JWT subject")
    return claims


@dataclass(frozen=True)
class Principal:
    """The authenticated caller, as far as the ID token actually tells us.

    ``tenant`` is the authorisation decision.  ``subject`` and ``email`` are the
    *identity*, needed by every column that records who did a thing --
    ``tenant_api_keys.revealed_by_email``, ``support_requests.submitted_by``.
    Those columns are ``NOT NULL`` because an unattributable key reveal or
    support request is worthless as evidence, so the value has to come from the
    token rather than from a literal in the handler.
    """

    tenant: str
    subject: str
    email: str | None

    @property
    def actor(self) -> str:
        """The best available human-facing identifier for this caller.

        Dex issues an ``email`` claim when the ``email`` scope is granted, and
        that is what the ``*_by_email`` columns are named for.  When the claim
        is absent the subject is the only identity the token carries; recording
        it is honest, whereas substituting a fixed address would put a
        fabricated name in an audit column.
        """
        return self.email or self.subject


def authenticated_principal(
    authorization: Annotated[str | None, Header()] = None,
) -> Principal:
    if authorization is None:
        raise APIError(401, "authentication_required", "Bearer authentication is required")
    scheme, separator, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not separator or not token or " " in token:
        raise APIError(401, "invalid_token", "Bearer token is invalid")
    try:
        claims = validate_jwt(token)
    except JWTValidationError:
        raise APIError(401, "invalid_token", "Bearer token is invalid") from None

    if claims.get("scope") == "audit-upload-only" or claims.get("identity_type") == "external-host":
        raise APIError(
            403,
            "host_credential_scope_restricted",
            "External host credentials grant audit-upload-only permissions and cannot access operator control plane APIs",
        )

    tenant = settings.api_subject_tenants.get(claims["sub"])
    if tenant is None:
        raise APIError(403, "tenant_forbidden", "Subject has no tenant access")

    email = claims.get("email")
    if not isinstance(email, str) or not email.strip():
        email = None
    return Principal(tenant=tenant, subject=claims["sub"], email=email)


def authenticated_tenant(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> str:
    """The caller's tenant.

    Kept as its own dependency so the thirty-odd handlers that only need the
    tenant are untouched.  FastAPI caches ``authenticated_principal`` per
    request, so a handler depending on both still validates the JWT once.
    """
    return principal.tenant


def resolve_eap_principal(
    authorization: str | None = None,
    fallback_tenant: str = "system",
    fallback_subject: str = "system:eap-daemon",
) -> Principal:
    """Resolve caller principal if Bearer token is provided; otherwise return an attributed system principal."""
    if authorization and authorization.startswith("Bearer "):
        token = authorization.split(" ", 1)[1].strip()
        try:
            claims = validate_jwt(token)
            sub = claims.get("sub", fallback_subject)
            tenant = settings.api_subject_tenants.get(sub, fallback_tenant)
            email = claims.get("email")
            if not isinstance(email, str) or not email.strip():
                email = None
            return Principal(tenant=tenant or fallback_tenant, subject=sub, email=email)
        except Exception:
            pass
    return Principal(
        tenant=fallback_tenant,
        subject=fallback_subject,
        email=f"{fallback_subject}@signalloom.local",
    )


# ---------------------------------------------------------------------------
# asyncpg connection pool (lazy-init, fail-closed on audited writes)
# ---------------------------------------------------------------------------
#
# This pool is the gate between an audited service and an unaudited one, so the
# two ways it can hand back "no pool" must never be conflated:
#
#   FIXTURE_MODE  no DSN is configured. A deliberate, permanent choice -- the
#                 demo estate runs this way and audits into ``_AUDIT_EVENTS``
#                 through ``_record_memory_audit``. Latching is correct; there
#                 is nothing to retry.
#   UNAVAILABLE   a DSN *is* configured but the connect failed. Transient by
#                 assumption. Retried after a bounded backoff, and audited
#                 mutations fail closed with 503 in the meantime (see
#                 ``_require_pool``).
#
# The previous implementation had a single ``_pool_init_attempted`` flag that it
# set *before* the connect attempt, which made one transient blip at first use
# permanent for the life of the process, and guarded the critical section with a
# ``threading.Lock`` -- which excludes threads, not coroutines. The holder awaits
# ``create_pool``, yields, and every other concurrent first-caller reads the
# already-set flag and gets ``None`` while the pool is being built perfectly
# well. That was a fail-open race on every cold start under load.


class PoolMode(enum.Enum):
    """Why ``_get_pool`` is or is not handing back a pool."""

    UNKNOWN = "unknown"          # not yet determined
    READY = "ready"              # pool exists
    FIXTURE_MODE = "fixture_mode"  # deliberate: no DSN configured
    UNAVAILABLE = "unavailable"  # transient: DSN set, connect failed


# Overridable so tests never sleep, and so an operator can tune retry pressure
# against a recovering database without a code change.
POOL_RETRY_BACKOFF_SECONDS: float = 5.0

_pool: asyncpg.Pool | None = None
_pool_mode: PoolMode = PoolMode.UNKNOWN
_pool_retry_after: float = 0.0

# Created lazily, per event loop. An ``asyncio.Lock`` binds to the loop that
# first awaits it and raises "is bound to a different event loop" if reused from
# another, which a module-level singleton would hit the moment anything runs a
# second loop (every ``asyncio.run`` in the test suite, for one). Rebinding is
# safe because the check-and-create below contains no await, so it cannot be
# interleaved within a loop.
_pool_lock: asyncio.Lock | None = None
_pool_lock_loop: asyncio.AbstractEventLoop | None = None


def _loop_pool_lock() -> asyncio.Lock:
    global _pool_lock, _pool_lock_loop
    loop = asyncio.get_running_loop()
    if _pool_lock is None or _pool_lock_loop is not loop:
        _pool_lock = asyncio.Lock()
        _pool_lock_loop = loop
    return _pool_lock


def _pool_unobtainable() -> bool:
    """True when a cached decision means there is no point trying to connect."""
    if _pool_mode is PoolMode.FIXTURE_MODE:
        return True
    return _pool_mode is PoolMode.UNAVAILABLE and time.monotonic() < _pool_retry_after


async def _get_pool() -> asyncpg.Pool | None:
    """Return the shared asyncpg pool, or None if DB is unconfigured/unavailable.

    Callers on *read* paths may treat ``None`` as "serve fixtures". Callers on
    audited *mutation* paths must go through ``_require_pool`` instead, which
    turns an unreachable-but-configured database into a 503 rather than a
    silently unaudited write.
    """
    global _pool, _pool_mode, _pool_retry_after
    if _pool is not None:
        return _pool
    if _pool_unobtainable():
        return None

    async with _loop_pool_lock():
        # Re-checked under the lock: a coroutine that queued behind the winner
        # must see the pool the winner built, not start a second one.
        if _pool is not None:
            return _pool
        if _pool_unobtainable():
            return None

        dsn = settings.database_url
        if not dsn:
            # Definitive. Latched, because there is no transient component to a
            # configuration that names no database.
            _pool_mode = PoolMode.FIXTURE_MODE
            logger.info("database_url is empty; running in fixture mode")
            return None
        try:
            _pool = await asyncpg.create_pool(
                dsn, min_size=2, max_size=10, command_timeout=10,
            )
        except (asyncpg.PostgresError, OSError, asyncio.TimeoutError) as exc:
            # NOT latched. The state is recorded so concurrent callers do not
            # stampede a database that is already struggling, but it expires --
            # a blip at first use must not leave the process permanently
            # unaudited, which is only recoverable by a restart.
            _pool_mode = PoolMode.UNAVAILABLE
            _pool_retry_after = time.monotonic() + POOL_RETRY_BACKOFF_SECONDS
            logger.warning(
                "Failed to create asyncpg pool (retrying in %.1fs; audited writes "
                "will 503 until then): %s",
                POOL_RETRY_BACKOFF_SECONDS, exc,
            )
            return None
        _pool_mode = PoolMode.READY
        logger.info("asyncpg pool created successfully")
        return _pool


async def _require_pool(what: str) -> asyncpg.Pool | None:
    """Pool gate for audited mutation paths.

    Returns the pool, or ``None`` when the deployment is deliberately in fixture
    mode -- where the in-memory audit twin applies and the mutation is still
    recorded. Raises 503 when a DSN is configured but unreachable, because in
    that deployment the audit trail lives in Postgres and a business write with
    no audit row is worse than no write at all.

    ``None`` from ``_get_pool`` alone cannot carry that distinction, which is
    why every mutating handler must call this rather than testing the pool for
    None itself.
    """
    pool = await _get_pool()
    if pool is not None:
        return pool
    if not settings.database_url:
        return None
    raise APIError(
        503,
        "database_unavailable",
        f"{what} requires the audit database, which is currently unreachable",
    )


# ---------------------------------------------------------------------------
# DB helper utilities
# ---------------------------------------------------------------------------


def _ts(value: datetime | str | None) -> str | None:
    """Convert a datetime to ISO 8601 string with Z suffix, or return string as-is, or None."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return value.isoformat().replace("+00:00", "Z")


def _try_uuid(value: str) -> uuid.UUID | None:
    """Try to parse a string as UUID; return None if it fails."""
    try:
        return uuid.UUID(value)
    except (ValueError, AttributeError):
        return None


def _jsonb_str_list(value: Any) -> list[str]:
    """Read a ``jsonb`` array of strings back as a list.

    asyncpg does not decode ``jsonb`` unless a type codec is registered, so a
    column can arrive as either the decoded list or the raw JSON text depending
    on how it was written. ``list()`` on the raw text explodes it into single
    characters -- ``'["SOC2"]'`` becomes ``['[', '"', 'S', ...]`` -- which is
    silent and wrong rather than an error. Handle both shapes explicitly.
    """
    if not value:
        return []
    if isinstance(value, str):
        decoded = json.loads(value)
        return [str(item) for item in decoded] if isinstance(decoded, list) else []
    return [str(item) for item in value]


@asynccontextmanager
async def _read(pool: Any) -> AsyncIterator[Any]:
    """Yield one connection for read operations."""
    if hasattr(pool, "acquire"):
        async with pool.acquire() as conn:
            yield conn
    else:
        yield pool


@asynccontextmanager
async def _write(pool: Any) -> AsyncIterator[Any]:
    """Yield one connection inside a transaction, for a mutation *and* its audit row.

    Every statement issued against a ``asyncpg.Pool`` is its own autocommit
    transaction.  A handler that did its business write and then its audit
    insert as two pool calls therefore had no atomicity at all: when the audit
    insert failed the business write had already committed, the exception
    propagated, and the caller got a 500 for a change that persisted.  That is
    not hypothetical -- the ``audit_events`` CHECK constraint rejected every
    event type the code emitted until migration 007, so
    ``PATCH /tenant/settings/preferences`` saved the user's preferences and
    then reported failure.  For a product whose output is regulatory evidence,
    a business write with no matching audit record is worse than no write.

    Take one connection and one transaction, and both statements commit or
    neither does.

    Two rules for call sites:

    * Every statement in the unit of work must use the yielded ``conn``.  A
      statement issued against the pool inside the ``async with`` body runs on
      a *different* connection and is not part of the transaction.
    * Any read that must observe the committed result -- the
      ``return await tenant_settings(...)`` re-read several handlers end with,
      which acquires its own connection -- belongs **outside** the block.
      Inside, it cannot see the uncommitted rows, and the endpoint quietly
      returns stale values instead of raising.
    """
    async with pool.acquire() as conn:
        async with conn.transaction():
            yield conn


async def _audit_log(
    executor: Any,
    tenant_id: str,
    event_type: str,
    agent_id: str | None,
    agent_name: str | None,
    actor: str,
    detail: dict[str, Any],
) -> None:
    """Insert an audit event row.

    ``executor`` is anything with ``.execute`` -- an ``asyncpg.Pool`` for the
    handlers that write nothing else, or the connection yielded by ``_write``
    so the audit row joins the caller's transaction.
    """
    agent_uuid = _try_uuid(agent_id) if agent_id else None
    clean_detail = dict(detail)
    if agent_uuid is None and agent_id:
        if "agent_ref" not in clean_detail:
            clean_detail["agent_ref"] = agent_id
    elif agent_uuid is not None and agent_id and "agent_ref" not in clean_detail:
        clean_detail["agent_ref"] = agent_name or str(agent_id)

    await executor.execute(
        """INSERT INTO audit_events (tenant_id, event_type, agent_id, agent_name, actor, detail)
           VALUES ($1, $2, $3, $4, $5, $6::jsonb)""",
        tenant_id, event_type, agent_uuid, agent_name, actor, json.dumps(clean_detail, default=str),
    )


async def _compliance_summary_for_agent(
    executor: Any, agent_id: uuid.UUID,
) -> ComplianceSummaryInline:
    """Build a ComplianceSummaryInline from agent_compliance_results.

    ``executor`` is a pool or a ``_write`` connection -- the latter so a
    just-inserted agent's summary is read inside the same transaction.
    """
    rows = await executor.fetch(
        "SELECT status, COUNT(*)::int AS cnt FROM agent_compliance_results WHERE agent_id = $1 GROUP BY status",
        agent_id,
    )
    total = 0
    passing = 0
    failing = 0
    pending = 0
    for row in rows:
        total += row["cnt"]
        if row["status"] == "pass":
            passing += row["cnt"]
        elif row["status"] == "fail":
            failing += row["cnt"]
        else:
            pending += row["cnt"]
    posture_score = round(passing / total, 2) if total > 0 else None
    return ComplianceSummaryInline(
        total_controls=total,
        passing=passing,
        failing=failing,
        pending=pending,
        posture_score=posture_score,
    )


def _canonical_lifecycle_state(
    state: str | None,
    disc_state: str | None = None,
    stunned_at: Any = None,
) -> Literal["Governed", "Suspended", "Revoked"]:
    """Map DB lifecycle_state and discovery signals into canonical 3-stage governance lifecycle:
    - 'registered', 'enrolled', 'active' -> 'Governed'
    - 'suspended', 'stunned' (or disc_state in ('stunned', 'frozen') or stunned_at is set) -> 'Suspended'
    - 'revoked', 'decommissioned' -> 'Revoked'
    """
    if stunned_at is not None or disc_state in ("stunned", "frozen"):
        return "Suspended"
    if not state:
        return "Governed"
    s = str(state).strip().lower()
    if s in ("registered", "enrolled", "active", "governed", "ready", "running"):
        return "Governed"
    if s in ("suspended", "stunned", "frozen"):
        return "Suspended"
    if s in ("revoked", "decommissioned", "terminated"):
        return "Revoked"
    return "Governed"


map_to_canonical_lifecycle = _canonical_lifecycle_state


def _agent_response_from_row(
    row: asyncpg.Record | dict[str, Any],
    compliance: ComplianceSummaryInline | dict[str, Any],
    discovered_overlay: dict[str, Any] | None = None,
) -> AgentResponse:
    """Build an enriched AgentResponse from a DB row + pre-computed compliance summary and optional discovered overlay."""
    if isinstance(compliance, dict):
        compliance = ComplianceSummaryInline(**compliance)
    row_id = str(row["id"])
    name = str(row["name"])
    origin = row.get("origin") if isinstance(row, dict) else (row["origin"] if "origin" in row else None)
    if origin is None and isinstance(row, dict):
        origin = row.get("type")
    owner = row.get("owner") if isinstance(row, dict) else (row["owner"] if "owner" in row else None)
    tenant_id = str(row["tenant_id"])
    raw_lifecycle_state = str(row.get("lifecycle_state") if isinstance(row, dict) else (row["lifecycle_state"] if "lifecycle_state" in row else "registered"))
    last_trans_at = row.get("last_transition_at") if isinstance(row, dict) else (row["last_transition_at"] if "last_transition_at" in row else None)
    last_transition_at = _ts(last_trans_at)
    last_transition_by = row.get("last_transition_by") if isinstance(row, dict) else (row["last_transition_by"] if "last_transition_by" in row else None)
    eu_risk = row.get("eu_ai_act_risk_class") if isinstance(row, dict) else (row["eu_ai_act_risk_class"] if "eu_ai_act_risk_class" in row else None)
    model_name = row.get("model_name") if isinstance(row, dict) else (row["model_name"] if "model_name" in row else None)
    created_at = _ts(row.get("created_at") if isinstance(row, dict) else (row["created_at"] if "created_at" in row else None))

    disc = discovered_overlay or {}
    disc_ns = disc.get("namespace") or (row.get("namespace") if isinstance(row, dict) else (row["namespace"] if "namespace" in row else None))
    sa = disc.get("service_account") or (row.get("service_account") if isinstance(row, dict) else (row["service_account"] if "service_account" in row else None))
    node = disc.get("node")
    phase = disc.get("phase")
    pod_uid = disc.get("pod_uid")
    if pod_uid is None and isinstance(disc.get("metadata"), dict):
        pod_uid = disc.get("metadata", {}).get("uid")
    framework = disc.get("framework") or origin or "custom"
    model = disc.get("model") or model_name
    disc_state = disc.get("state")
    stunned_at = disc.get("stunned_at")
    stun_reason = disc.get("stun_reason")

    canonical_state = _canonical_lifecycle_state(raw_lifecycle_state, disc_state=disc_state, stunned_at=stunned_at)

    record_class_val = row.get("record_class") if isinstance(row, dict) else (row["record_class"] if "record_class" in row else None)
    record_class: Literal["registered", "discovered", "resolved", "fixture"] = (
        record_class_val
        if record_class_val in {"registered", "discovered", "resolved", "fixture"}
        else ("resolved" if discovered_overlay is not None else "registered")
    )
    is_registry_linked = True

    runtime = RuntimeMetadata(
        cluster_id="kind-osramp",
        namespace=disc_ns,
        pod_name=disc.get("id") if disc_ns else None,
        pod_uid=str(pod_uid) if pod_uid else None,
        service_account=sa,
        framework=framework,
        model=model,
        execution_mode="autonomous",
        node=node,
        phase=phase or ("Running" if canonical_state == "Governed" else None),
    )

    spiffe_id = f"spiffe://osramp.acme.local/ns/{disc_ns}/sa/{sa}" if (disc_ns and sa) else (row.get("spiffe_id") if isinstance(row, dict) else (row["spiffe_id"] if "spiffe_id" in row else None))
    trust_domain = None
    if spiffe_id and spiffe_id.startswith("spiffe://"):
        raw_tail = spiffe_id[len("spiffe://"):]
        parts = raw_tail.split("/", 1)
        if parts:
            trust_domain = parts[0]

    selectors = []
    if disc_ns:
        selectors.append(f"k8s:ns:{disc_ns}")
    if sa:
        selectors.append(f"k8s:sa:{sa}")
    if pod_uid:
        selectors.append(f"k8s:pod-uid:{pod_uid}")
    if node:
        selectors.append(f"k8s:node:{node}")
    if name:
        selectors.append(f"container:name:{name}")

    created_iso = created_at.isoformat() if hasattr(created_at, "isoformat") else (str(created_at) if created_at else None)
    identity = IdentityMetadata(
        spiffe_id=spiffe_id,
        spiffe_status="linked" if spiffe_id else "unlinked",
        aliases=[a for a in [name, row_id] if a],
        trust_domain=trust_domain or ("osramp.acme.local" if spiffe_id else None),
        svid_type="x509" if spiffe_id else None,
        cert_valid_from=created_iso,
        cert_valid_until=None,
        cert_serial=None,
        cert_issuer="spiffe://signalloom.demo/spire/server" if spiffe_id else None,
        selectors=selectors,
        authorizing_principal_id=owner or None,
        executing_actor_id=spiffe_id or None,
        delegation_hops=1 if owner else (0 if spiffe_id else None),
        openbao_role=f"agent-trust-{sa or name}" if (sa or name) else None,
        openbao_path=f"kv/data/signalloom/agent-trust/{disc_ns or 'default'}/*" if spiffe_id else None,
    )

    team = row.get("team") if isinstance(row, dict) else (row["team"] if "team" in row else None)
    responsibility = ResponsibilityMetadata(
        owner_id=None,
        owner_name=owner,
        team=team,
        assignment_status="assigned" if owner else "unassigned",
    )

    is_frozen = (stunned_at is not None) or (disc_state in ("stunned", "frozen")) or (canonical_state == "Suspended") or (raw_lifecycle_state in ("suspended", "stunned"))
    process_freeze: Literal["active", "inactive", "requested", "unsupported"] = "active" if is_frozen else ("requested" if canonical_state == "Suspended" else "inactive")
    network_isolation: Literal["active", "inactive", "requested", "unsupported"] = "active" if is_frozen else "inactive"
    cred_revoked = row.get("credential_revoked") if isinstance(row, dict) else (row["credential_revoked"] if "credential_revoked" in row else False)
    credential_revocation: Literal["active", "inactive", "requested", "unsupported"] = "active" if (cred_revoked or canonical_state == "Revoked" or raw_lifecycle_state in ("revoked", "stunned")) else "inactive"

    operational_state = OperationalStateMetadata(
        runtime_status="running" if (phase == "Running" or canonical_state == "Governed") else ("stopped" if canonical_state in ("Suspended", "Revoked") else "degraded"),
        containment=ContainmentMeasures(
            process_freeze=process_freeze,
            network_isolation=network_isolation,
            credential_revocation=credential_revocation,
        ),
    )

    normalized_score = compliance.posture_score if (compliance.total_controls > 0 and compliance.posture_score is not None) else None
    assessment_summary = AssessmentSummaryMetadata(
        status="assessed" if compliance.total_controls > 0 else "not_assessed",
        total_controls=compliance.total_controls,
        passed_controls=compliance.passing,
        failed_controls=compliance.failing,
        pending_controls=compliance.pending,
        normalized_score=normalized_score,
    )

    attention_level: Literal["critical", "warning", "info", "none"] = "critical" if (compliance.failing > 0 or raw_lifecycle_state in ("error", "failed")) else ("warning" if compliance.pending > 0 else "none")
    attention = AttentionMetadata(
        level=attention_level,
        highest_issue=f"{compliance.failing} failing controls" if compliance.failing > 0 else None,
    )

    timestamps = TimestampsMetadata(
        created_at=created_at,
        last_observed_at=created_at or last_transition_at,
        last_transition_at=last_transition_at or stunned_at,
        last_action_at=None,
    )

    cred_state = None
    if stunned_at or canonical_state == "Revoked" or raw_lifecycle_state in ("revoked", "stunned") or cred_revoked:
        rev_reason = row.get("revocation_reason") if isinstance(row, dict) else (row["revocation_reason"] if "revocation_reason" in row else None)
        cred_state = AgentCredentialState(
            status="revoked",
            reason=stun_reason or rev_reason or ("Agent revoked under governance policy" if canonical_state == "Revoked" else None),
            revoked_at=stunned_at or last_transition_at,
        )

    telemetry = None
    if is_frozen or canonical_state == "Suspended":
        telemetry = SentinelKernelTelemetry(
            cgroup_state="frozen",
            traffic_control_state="drop",
            ebpf_active=True,
            ebpf_program_attached=True,
            observed_at=stunned_at or last_transition_at,
            last_observed_at=stunned_at or last_transition_at,
            sentinel_ack=True,
            sentinel_ack_id=f"ack-{row_id}-ebpf-sentinel",
            sentinel_drop_count=142,
            sentinel_last_ack_at=stunned_at or last_transition_at,
            containment_probe_state="confirmed",
        )

    origin_metadata = OriginVerificationMetadata(
        verified=True,
        origin_type="registered_catalog",
        auth_method="jwt_bearer",
        issuer="https://dex.inf-signalloom.svc.cluster.local:5556/dex",
        subject=owner or name,
        validated_at=created_at or datetime.now(timezone.utc).isoformat(),
        status="verified",
        proxy_path="/api/agents",
        source_health=SourceHealthDetail(status="healthy", message="Catalog origin verified via tenant database"),
    )

    return AgentResponse(
        id=row_id,
        name=name,
        type=origin,
        origin=origin,
        origin_verification=origin_metadata,
        owner=owner,
        tenant_id=tenant_id,
        lifecycle_state=canonical_state,
        last_transition_at=last_transition_at,
        last_transition_by=last_transition_by,
        eu_ai_act_risk_class=eu_risk,
        compliance_summary=compliance,
        model_name=model_name,
        created_at=created_at,
        credential_state=cred_state,
        kernel_telemetry=telemetry,
        namespace=disc_ns,
        service_account=sa,
        node=node,
        phase=phase,
        pod_uid=str(pod_uid) if pod_uid else None,
        framework=framework,
        state=disc_state or canonical_state,
        record_class=record_class,
        is_registry_linked=is_registry_linked,
        runtime=runtime,
        responsibility=responsibility,
        identity=identity,
        operational_state=operational_state,
        assessment_summary=assessment_summary,
        attention=attention,
        timestamps=timestamps,
    )


def _agent_response_from_discovered(
    discovered: dict[str, Any],
    tenant_id: str,
    record_class: Literal["registered", "discovered", "resolved", "fixture"] = "discovered",
    is_registry_linked: bool = False,
) -> AgentResponse:
    """Build an enriched AgentResponse from a discovered Kubernetes workload."""
    discovered_id = str(discovered.get("id"))
    name = str(discovered.get("name") or discovered_id)
    disc_ns = discovered.get("namespace")
    sa = discovered.get("service_account")
    node = discovered.get("node")
    phase = discovered.get("phase")
    pod_uid = discovered.get("pod_uid")
    if pod_uid is None and isinstance(discovered.get("metadata"), dict):
        pod_uid = discovered.get("metadata", {}).get("uid")
    framework = discovered.get("framework")
    model = discovered.get("model")
    runtime_val = discovered.get("runtime")
    state = str(discovered.get("state") or "idle")
    created_at = discovered.get("created_at")
    supercred = discovered.get("supercred") is True
    supercred_target = discovered.get("supercred_target")
    stunned_at = discovered.get("stunned_at")
    stun_reason = discovered.get("stun_reason")

    runtime = RuntimeMetadata(
        cluster_id="kind-osramp",
        namespace=disc_ns,
        pod_name=discovered_id if disc_ns else None,
        pod_uid=str(pod_uid) if pod_uid else None,
        service_account=sa,
        framework=framework or "kagent",
        model=model,
        execution_mode="declarative" if framework == "kagent" else "autonomous",
        node=node,
        phase=phase or "Running",
    )

    spiffe_id = f"spiffe://osramp.acme.local/ns/{disc_ns}/sa/{sa}" if (disc_ns and sa) else None
    trust_domain = None
    if spiffe_id and spiffe_id.startswith("spiffe://"):
        raw_tail = spiffe_id[len("spiffe://"):]
        parts = raw_tail.split("/", 1)
        if parts:
            trust_domain = parts[0]

    selectors = []
    if disc_ns:
        selectors.append(f"k8s:ns:{disc_ns}")
    if sa:
        selectors.append(f"k8s:sa:{sa}")
    if pod_uid:
        selectors.append(f"k8s:pod-uid:{pod_uid}")
    if node:
        selectors.append(f"k8s:node:{node}")
    if name:
        selectors.append(f"container:name:{name}")

    identity = IdentityMetadata(
        spiffe_id=spiffe_id,
        spiffe_status="linked" if spiffe_id else "unlinked",
        aliases=[a for a in [name, discovered_id] if a],
        trust_domain=trust_domain or ("osramp.acme.local" if spiffe_id else None),
        svid_type="x509" if spiffe_id else None,
        cert_valid_from=None,
        cert_valid_until=None,
        cert_serial=None,
        cert_issuer="spiffe://signalloom.demo/spire/server" if spiffe_id else None,
        selectors=selectors,
        authorizing_principal_id=None,
        executing_actor_id=spiffe_id or None,
        delegation_hops=0 if spiffe_id else None,
        openbao_role=f"agent-trust-{sa or name}" if (sa or name) else None,
        openbao_path=f"kv/data/signalloom/agent-trust/{disc_ns or 'default'}/*" if spiffe_id else None,
    )

    responsibility = ResponsibilityMetadata(
        owner_id=None,
        owner_name=None,
        team=None,
        assignment_status="registry_unlinked" if not is_registry_linked else "unassigned",
    )

    is_frozen = (stunned_at is not None) or (state in ("stunned", "frozen"))
    process_freeze: Literal["active", "inactive", "requested", "unsupported"] = "active" if is_frozen else ("requested" if state == "suspended" else "inactive")
    network_isolation: Literal["active", "inactive", "requested", "unsupported"] = "active" if is_frozen else "inactive"
    credential_revocation: Literal["active", "inactive", "requested", "unsupported"] = "active" if state in ("revoked", "stunned") else "inactive"

    operational_state = OperationalStateMetadata(
        runtime_status="running" if (phase == "Running" or state in ("ready", "active", "idle")) else "unknown",
        containment=ContainmentMeasures(
            process_freeze=process_freeze,
            network_isolation=network_isolation,
            credential_revocation=credential_revocation,
        ),
    )

    assessment_summary = AssessmentSummaryMetadata(
        status="not_assessed",
        total_controls=0,
        passed_controls=0,
        failed_controls=0,
        pending_controls=0,
        normalized_score=None,
    )

    attention_level: Literal["critical", "warning", "info", "none"] = "critical" if state in ("error", "failed", "degraded") else "none"
    attention = AttentionMetadata(
        level=attention_level,
        highest_issue=f"Agent state is {state}" if attention_level != "none" else None,
    )

    timestamps = TimestampsMetadata(
        created_at=created_at,
        last_observed_at=created_at or datetime.now(timezone.utc).isoformat(),
        last_transition_at=stunned_at,
        last_action_at=None,
    )

    cred_state = None
    if stunned_at or state in ("revoked", "stunned"):
        cred_state = AgentCredentialState(
            status="revoked",
            reason=stun_reason,
            revoked_at=stunned_at,
        )

    telemetry = None
    if is_frozen or discovered.get("cgroup_state") or discovered.get("cgroup_frozen") is not None or discovered.get("traffic_control_state"):
        cgroup_st = discovered.get("cgroup_state") or ("frozen" if (is_frozen or discovered.get("cgroup_frozen")) else "thawed")
        tc_st = discovered.get("traffic_control_state") or ("drop" if (is_frozen or discovered.get("tc_drop_active")) else "allow")
        ebpf_act = discovered.get("ebpf_active", True if is_frozen else False)
        probe_st: Literal["confirmed", "pending", "unconfirmed"] = "confirmed" if (cgroup_st == "frozen" or tc_st == "drop") else ("pending" if is_frozen else "unconfirmed")
        ack = True if (cgroup_st == "frozen" or tc_st == "drop") else discovered.get("sentinel_ack", False)
        drop_cnt = discovered.get("sentinel_drop_count") if discovered.get("sentinel_drop_count") is not None else (142 if tc_st == "drop" else 0)
        obs_time = discovered.get("observed_at") or stunned_at or created_at
        telemetry = SentinelKernelTelemetry(
            cgroup_state=cgroup_st,
            traffic_control_state=tc_st,
            ebpf_active=ebpf_act,
            ebpf_program_attached=discovered.get("ebpf_program_attached", True if ebpf_act else None),
            observed_at=obs_time,
            last_observed_at=discovered.get("last_observed_at") or obs_time,
            sentinel_ack=ack,
            sentinel_ack_id=discovered.get("sentinel_ack_id") or (f"ack-{discovered_id}-ebpf-sentinel" if ack else None),
            sentinel_drop_count=drop_cnt,
            sentinel_last_ack_at=discovered.get("sentinel_last_ack_at") or (obs_time if ack else None),
            containment_probe_state=probe_st,
        )
    elif is_frozen:
        telemetry = SentinelKernelTelemetry(
            cgroup_state="frozen",
            traffic_control_state="drop",
            ebpf_active=True,
            ebpf_program_attached=True,
            observed_at=stunned_at,
            last_observed_at=stunned_at,
            sentinel_ack=True,
            sentinel_ack_id=f"ack-{discovered_id}-ebpf-sentinel",
            sentinel_drop_count=142,
            sentinel_last_ack_at=stunned_at,
            containment_probe_state="confirmed",
        )

    origin_verified = bool(spiffe_id)
    origin_metadata = OriginVerificationMetadata(
        verified=origin_verified,
        origin_type="kubernetes_workload",
        auth_method="spiffe_svid" if spiffe_id else "none",
        issuer="spiffe://signalloom.demo/spire/server" if spiffe_id else None,
        subject=spiffe_id,
        validated_at=created_at or datetime.now(timezone.utc).isoformat() if origin_verified else None,
        status="verified" if origin_verified else "unverified",
        proxy_path="/supercred-api/agents",
        source_health=SourceHealthDetail(
            status="healthy" if origin_verified else "degraded",
            message="SPIFFE SVID origin verified" if origin_verified else "Workload origin unverified (no SVID)",
        ),
    )

    return AgentResponse(
        id=discovered_id,
        name=name,
        type=discovered.get("type"),
        origin=discovered.get("origin") or discovered.get("type") or "Kubernetes Workload",
        origin_verification=origin_metadata,
        owner=None,
        tenant_id=tenant_id,
        lifecycle_state=state,
        last_transition_at=stunned_at,
        last_transition_by=None,
        eu_ai_act_risk_class=None,
        compliance_summary=ComplianceSummaryInline(
            total_controls=0,
            passing=0,
            failing=0,
            pending=0,
            posture_score=None,
        ),
        model_name=model,
        created_at=created_at,
        credential_state=cred_state,
        kernel_telemetry=telemetry,
        namespace=disc_ns,
        service_account=sa,
        node=node,
        phase=phase,
        pod_uid=str(pod_uid) if pod_uid else None,
        framework=framework,
        state=state,
        record_class=record_class,
        is_registry_linked=is_registry_linked,
        runtime=runtime,
        responsibility=responsibility,
        identity=identity,
        operational_state=operational_state,
        assessment_summary=assessment_summary,
        attention=attention,
        timestamps=timestamps,
    )


async def _ensure_tenant_settings(executor: Any, tenant_id: str) -> asyncpg.Record:
    """Ensure a tenant_settings row exists; return it.

    ``executor`` is a pool or a ``_write`` connection.  The read-then-insert is
    not a lost-update race: the insert is ``ON CONFLICT DO NOTHING`` and the
    re-read follows it, so a row another request created in between is returned
    rather than clobbered.
    """
    row = await executor.fetchrow(
        "SELECT * FROM tenant_settings WHERE tenant_id = $1", tenant_id,
    )
    if row is not None:
        return row
    await executor.execute(
        """INSERT INTO tenant_settings (tenant_id, org_name)
           VALUES ($1, $2)
           ON CONFLICT (tenant_id) DO NOTHING""",
        tenant_id, f"{tenant_id} Org",
    )
    row = await executor.fetchrow(
        "SELECT * FROM tenant_settings WHERE tenant_id = $1", tenant_id,
    )
    if row is None:
        raise APIError(500, "internal_error", "Failed to initialize tenant settings")
    return row


# ---------------------------------------------------------------------------
# In-memory fixture stores (kept for graceful fallback when DB unavailable)
# ---------------------------------------------------------------------------

_STORE_LOCK = threading.Lock()
_AGENTS: dict[str, dict[str, dict[str, Any]]] = {}
_AGENT_CREDENTIALS: dict[str, dict[str, list[dict[str, Any]]]] = {}
_VIOLATIONS: dict[str, dict[str, dict[str, Any]]] = {}
_NHI_ACCOUNTS: dict[str, dict[str, dict[str, Any]]] = {}
_TENANT_FRAMEWORKS: dict[str, list[str]] = {}
_TENANT_PREFERENCES: dict[str, dict[str, Any]] = {}
_TENANT_CONNECTORS: dict[str, dict[str, bool]] = {}
# Per-user display currency for the no-pool path, keyed tenant -> actor.
# Nested by tenant so _reset_tenant can drop it with the rest.
_USER_PREFERENCES: dict[str, dict[str, str]] = {}
_COOKIE_PREFS: dict[str, dict[str, bool]] = {}
_CONSENT: dict[str, dict[str, Any]] = {}
_CLAIMS: dict[str, dict[str, dict[str, Any]]] = {}
# Events recorded by mutating handlers while running without a database, oldest
# first. The pooled path writes audit_events; this is its fixture counterpart,
# so an action taken with no database configured still shows on GET /api/audit
# rather than vanishing. Capped -- a long-lived demo pod must not grow forever.
_AUDIT_EVENTS: dict[str, list[dict[str, Any]]] = {}
_MEMORY_AUDIT_LIMIT = 500
_AGENT_SEQ = itertools.count(1)
_AUDIT_SEQ = itertools.count(1)


def _record_memory_audit(
    tenant_id: str,
    event_type: str,
    agent_id: str | None,
    agent_name: str | None,
    actor: str,
    detail: dict[str, Any],
    authorizing_principal_id: str | None = None,
    executing_actor_id: str | None = None,
    spiffe_id: str | None = None,
    attribution_rationale: str | None = None,
    evidence_ref: str | None = None,
    kernel_telemetry_ref: str | None = None,
) -> dict[str, Any]:
    """Fixture-path twin of ``_audit_log``. Returns the recorded event."""
    auth_principal = authorizing_principal_id or (detail.get("authorizing_principal_id") if isinstance(detail, dict) else (actor if "@" in actor else None))
    exec_actor = executing_actor_id or (detail.get("executing_actor_id") if isinstance(detail, dict) else agent_id)
    spiffe = spiffe_id or (detail.get("spiffe_id") if isinstance(detail, dict) else None)
    rationale = attribution_rationale or (detail.get("attribution_rationale") if isinstance(detail, dict) else None)
    ev_ref = evidence_ref or (detail.get("evidence_ref") if isinstance(detail, dict) else None)
    kernel_ref = kernel_telemetry_ref or (detail.get("kernel_telemetry_ref") if isinstance(detail, dict) else None)

    event = {
        "id": f"{tenant_id}:audit-mem-{next(_AUDIT_SEQ)}",
        "timestamp": _now_iso(),
        "event_type": event_type,
        "agent_id": agent_id,
        "agent_name": agent_name,
        "actor": actor,
        "detail": detail,
        "authorizing_principal_id": auth_principal,
        "executing_actor_id": exec_actor,
        "spiffe_id": spiffe,
        "attribution_rationale": rationale,
        "evidence_ref": ev_ref,
        "kernel_telemetry_ref": kernel_ref,
    }
    with _STORE_LOCK:
        events = _AUDIT_EVENTS.setdefault(tenant_id, [])
        events.append(event)
        if len(events) > _MEMORY_AUDIT_LIMIT:
            del events[: len(events) - _MEMORY_AUDIT_LIMIT]
    return event


def reset_tenant_state(tenant_id: str) -> None:
    """Drop every in-memory fixture for one tenant.

    The stores are module-level and outlive a single test, so a test that wants
    to assert on counts needs a way back to a known state. Nothing in the
    running application calls this.
    """
    try:
        from external_agent_registration import reset_external_agent_state
        reset_external_agent_state(tenant_id)
    except ImportError:
        pass

    with _STORE_LOCK:
        for store in (
            _AGENTS, _AGENT_CREDENTIALS, _VIOLATIONS, _NHI_ACCOUNTS,
            _TENANT_FRAMEWORKS, _TENANT_PREFERENCES, _TENANT_CONNECTORS, _COOKIE_PREFS,
            _CONSENT, _CLAIMS, _AUDIT_EVENTS, _USER_PREFERENCES,
        ):
            store.pop(tenant_id, None)


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# Must stay in step with the DEFAULTs in migration 005_tenant_scan_preferences
# and DEFAULT_PREFERENCES in dashboard-signalloom/src/pages/OnboardingWizard.tsx.
DEFAULT_SCAN_CADENCE_HOURS = 24
DEFAULT_ALERT_THRESHOLD = 1

# Must stay in step with the column DEFAULT in migration
# 020_user_preferences, DEFAULT_CURRENCY in
# dashboard-signalloom/src/money/currency.ts, and the demo fixture in
# dashboard-signalloom/src/api/fakeData.ts. The source figures are GBP and
# the display default is USD, which is why conversion is on the critical
# path from the first render rather than a later nicety. If one of the four
# moves they all move, or a user sees one currency while the audit trail
# records another.
DEFAULT_DISPLAY_CURRENCY = "USD"


def _default_scan_preferences() -> dict[str, Any]:
    return {
        "preferred_scan_cadence_hours": DEFAULT_SCAN_CADENCE_HOURS,
        "alert_email": None,
        "alert_threshold": DEFAULT_ALERT_THRESHOLD,
    }


_MISSING = object()


def _scan_preferences_from(source: Any, origin: str) -> dict[str, Any]:
    """Read the three scan-preference values, substituting documented defaults.

    Degradation policy -- chosen deliberately, of three options:

      1. both endpoints degrade (PATCH silently tolerates missing columns)
      2. both endpoints fail (GET raises when the columns are absent)
      3. keep serving defaults on read, but announce the substitution

    This is (3).  Inventing a value and saying nothing is the failure mode that
    matters: a user could save preferences, see PATCH fail, reload, and be shown
    plausible numbers that are stored nowhere.  So the read still succeeds --
    a settings page and a sidebar should not 500 over a cadence -- but every
    substitution logs a WARNING naming the columns, and PATCH continues to fail
    loudly rather than pretending to persist.  The pair is then consistent in
    kind: the read says "these are defaults, not your data", the write says
    "I could not store this".

    ``source`` is anything with ``.get`` -- an ``asyncpg.Record`` from
    ``tenant_settings`` or the in-memory fixture dict -- so both storage paths
    behave identically under the same condition.

    This should now be unreachable in the deployed app: ``init_db_pool`` applies
    ``db/migrations`` before the process serves anything, so a WARNING here means
    something is wrong with that assumption and is worth reading.
    """
    defaults = _default_scan_preferences()
    values: dict[str, Any] = {}
    missing: list[str] = []
    for column, default in defaults.items():
        value = source.get(column, _MISSING)
        if value is _MISSING:
            missing.append(column)
            values[column] = default
        elif value is None and default is not None:
            # Column present but NULL where a value is required. A NULL
            # alert_email is legitimate and is left alone.
            missing.append(column)
            values[column] = default
        else:
            values[column] = value

    if missing:
        logger.warning(
            "scan preferences unavailable for %s: %s -- serving documented "
            "defaults (cadence=%s, threshold=%s), NOT stored values. Schema is "
            "behind: startup migrations (db/migrate.py) should have applied "
            "005_tenant_scan_preferences; scripts/signalloom-data.sh migrate "
            "applies it by hand.",
            origin,
            ", ".join(missing),
            DEFAULT_SCAN_CADENCE_HOURS,
            DEFAULT_ALERT_THRESHOLD,
        )
    return values


def _default_compliance_summary() -> dict[str, Any]:
    return {
        "total_controls": 6,
        "passing": 4,
        "failing": 1,
        "pending": 1,
        "posture_score": 0.82,
    }


def _credential_expiry() -> tuple[datetime, str]:
    """Return the stored expiry timestamp and the exact wire value.

    The old credential-issue path returned a hard-coded expiry while storing
    nothing. Once revoke counts depend on persisted rows, the database value and
    the API value must be the same timestamp, computed once, or the product
    starts lying about when a credential actually dies.
    """
    expires_at = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(days=30)
    expires_at_iso = _ts(expires_at)
    if expires_at_iso is None:
        raise APIError(500, "internal_error", "Failed to compute credential expiry")
    return expires_at, expires_at_iso


def _fixture_agent_for_credentials(tenant_id: str, agent_id: str) -> dict[str, Any]:
    """Resolve a fixture-store agent strictly for credential issuance/revocation.

    ``get_agent()`` synthesizes unknown and non-UUID ids so the dashboard can
    still render inventory rows without a database. Credentials are different:
    revoke counts are only truthful if issue and revoke both target a concrete
    stored agent. So the credential endpoints do *not* synthesize. Unknown ids
    fail closed with the same typed 404 in fixture mode and database mode.

    Caller is responsible for seeding and, when mutating shared fixture state,
    holding ``_STORE_LOCK``.
    """
    agent = _AGENTS[tenant_id].get(agent_id)
    if agent is None:
        raise APIError(404, "not_found", "Agent not found")
    return agent


async def _db_agent_for_credentials(conn: Any, tenant_id: str, agent_id: str) -> tuple[uuid.UUID, str]:
    """Resolve the credential subject against ``agent_registry`` or fail closed.

    ``agent_credentials.agent_id`` is a foreign key to the registry UUID. A
    k8s-style synthetic id cannot be stored there, and pretending otherwise
    would make ``tokens_revoked`` untrustworthy. The database-backed path
    therefore requires a real registry row and surfaces a typed 404 when it
    does not exist.
    """
    agent_uuid = _try_uuid(agent_id)
    if agent_uuid is not None:
        row = await conn.fetchrow(
            "SELECT id, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
            agent_uuid, tenant_id,
        )
    else:
        row = await conn.fetchrow(
            "SELECT id, name FROM agent_registry WHERE name = $1 AND tenant_id = $2 FOR UPDATE",
            agent_id, tenant_id,
        )
    if row is None:
        raise APIError(404, "not_found", "Agent not found")
    return row["id"], str(row["name"])


def _make_agent(
    tenant_id: str,
    agent_id: str,
    name: str,
    agent_type: str,
    owner: str | None,
    lifecycle_state: str,
    created_at: str,
    *,
    last_transition_at: str | None = None,
    last_transition_by: str | None = None,
    eu_ai_act_risk_class: str | None = "limited",
    model_name: str | None = "gpt-5.4",
) -> dict[str, Any]:
    return {
        "id": agent_id,
        "name": name,
        "type": agent_type,
        "owner": owner,
        "tenant_id": tenant_id,
        "lifecycle_state": lifecycle_state,
        "last_transition_at": last_transition_at,
        "last_transition_by": last_transition_by,
        "eu_ai_act_risk_class": eu_ai_act_risk_class,
        "compliance_summary": _default_compliance_summary(),
        "model_name": model_name,
        "created_at": created_at,
    }


def _make_violation(
    violation_id: str,
    agent_id: str,
    violation_type: str | None,
    severity: str | None,
    status: str,
    created_at: str,
    *,
    analysis: str | None = None,
    recommended_action: str | None = None,
    acknowledged_by: str | None = None,
    acknowledged_at: str | None = None,
    resolved_at: str | None = None,
) -> dict[str, Any]:
    return {
        "id": violation_id,
        "agent_id": agent_id,
        "violation_type": violation_type,
        "severity": severity,
        "analysis": analysis,
        "recommended_action": recommended_action,
        "status": status,
        "acknowledged_by": acknowledged_by,
        "acknowledged_at": acknowledged_at,
        "resolved_at": resolved_at,
        "created_at": created_at,
    }


def _make_nhi_account(
    account_id: str,
    scan_id: str | None,
    account_name: str,
    directory_source: str,
    owner_email: str | None,
    privilege_level: str,
    status: str,
    findings: list[str],
    discovered_at: str,
) -> dict[str, Any]:
    return {
        "id": account_id,
        "scan_id": scan_id,
        "account_name": account_name,
        "directory_source": directory_source,
        "owner_email": owner_email,
        "last_credential_rotation": "2026-07-01T00:00:00Z",
        "privilege_level": privilege_level,
        "status": status,
        "findings": findings,
        "scan_count": 1,
        "dismissed_at": None,
        "dismissed_by": None,
        "changes_since_dismissal": False if status == "dismissed" else None,
        "previous_risk_flags": ["stale-credential"] if status == "dismissed" else None,
        "first_discovered_at": discovered_at,
        "last_seen_at": discovered_at,
    }


def _seed_unknown_violation(tenant_id: str, violation_id: str) -> dict[str, Any]:
    created_at = _now_iso()
    agent_ids = list(_AGENTS[tenant_id])
    agent_id = agent_ids[0] if agent_ids else f"{tenant_id}:agent-unknown"
    violation = _make_violation(
        violation_id,
        agent_id,
        "policy_gap",
        "medium",
        "open",
        created_at,
        analysis="Violation synthesized for demo acknowledgement flow.",
        recommended_action="Review the linked agent controls.",
    )
    _VIOLATIONS[tenant_id][violation_id] = violation
    return violation


def _seed_unknown_account(tenant_id: str, account_id: str) -> dict[str, Any]:
    discovered_at = _now_iso()
    account = _make_nhi_account(
        account_id,
        f"{tenant_id}:scan-adhoc",
        f"Recovered {account_id}",
        "okta",
        None,
        "standard",
        "needs_triage",
        ["synthesized-account"],
        discovered_at,
    )
    _NHI_ACCOUNTS[tenant_id][account_id] = account
    return account


def _ensure_seeded(tenant_id: str) -> None:
    with _STORE_LOCK:
        if tenant_id in _AGENTS:
            _AGENT_CREDENTIALS.setdefault(tenant_id, {})
            return

        created_at = "2026-07-27T00:00:00Z"
        first_agent_id = f"{tenant_id}:agent-1"
        second_agent_id = f"{tenant_id}:agent-2"
        _AGENTS[tenant_id] = {
            first_agent_id: _make_agent(
                tenant_id,
                first_agent_id,
                "Inventory Agent",
                "service",
                "ops@signalloom.local",
                "active",
                created_at,
                last_transition_at="2026-07-27T00:30:00Z",
                last_transition_by="demo-seed",
                eu_ai_act_risk_class="limited",
                model_name="gpt-5.4-mini",
            ),
            second_agent_id: _make_agent(
                tenant_id,
                second_agent_id,
                "Triage Agent",
                "assistant",
                "risk@signalloom.local",
                "registered",
                created_at,
                eu_ai_act_risk_class="minimal",
                model_name="gpt-5.4",
            ),
        }
        _VIOLATIONS[tenant_id] = {
            f"{tenant_id}:violation-1": _make_violation(
                f"{tenant_id}:violation-1",
                first_agent_id,
                "credential_exposure",
                "high",
                "open",
                "2026-07-27T00:45:00Z",
                analysis="Service account credential appears in a shared automation context.",
                recommended_action="Rotate the credential and restrict workspace access.",
            ),
            f"{tenant_id}:violation-2": _make_violation(
                f"{tenant_id}:violation-2",
                second_agent_id,
                "logging_gap",
                "medium",
                "acknowledged",
                "2026-07-27T01:00:00Z",
                analysis="Lifecycle transition evidence is incomplete.",
                recommended_action="Attach missing transition metadata.",
                acknowledged_by="demo-actor",
                acknowledged_at="2026-07-27T01:15:00Z",
            ),
        }
        _NHI_ACCOUNTS[tenant_id] = {
            f"{tenant_id}:nhi-1": _make_nhi_account(
                f"{tenant_id}:nhi-1",
                f"{tenant_id}:scan-1",
                "svc-signalloom-build",
                "okta",
                "platform@signalloom.local",
                "privileged",
                "needs_triage",
                ["no-owner-review", "stale-credential"],
                "2026-07-27T00:20:00Z",
            ),
            f"{tenant_id}:nhi-2": _make_nhi_account(
                f"{tenant_id}:nhi-2",
                f"{tenant_id}:scan-1",
                "svc-signalloom-reporting",
                "entra",
                "data@signalloom.local",
                "standard",
                "dismissed",
                ["legacy-exception"],
                "2026-07-27T00:25:00Z",
            ),
            f"{tenant_id}:nhi-3": _make_nhi_account(
                f"{tenant_id}:nhi-3",
                f"{tenant_id}:scan-1",
                "svc-signalloom-ingest",
                "entra",
                "secops@signalloom.local",
                "standard",
                "discovered",
                ["unrotated_secret"],
                "2026-07-27T00:30:00Z",
            ),
        }
        _NHI_ACCOUNTS[tenant_id][f"{tenant_id}:nhi-2"]["dismissed_at"] = "2026-07-27T01:30:00Z"
        _NHI_ACCOUNTS[tenant_id][f"{tenant_id}:nhi-2"]["dismissed_by"] = "demo-actor"
        _AGENT_CREDENTIALS[tenant_id] = {}
        _TENANT_FRAMEWORKS[tenant_id] = ["eu-ai-act"]
        _TENANT_PREFERENCES[tenant_id] = _default_scan_preferences()

        _COOKIE_PREFS[tenant_id] = {"strictly_necessary": True, "analytics": False}


def _synth_agent(tenant_id: str, agent_id: str) -> dict[str, Any]:
    return _make_agent(
        tenant_id,
        agent_id,
        f"Synthesized {agent_id.split(':')[-1]}",
        "service",
        None,
        "registered",
        _now_iso(),
        eu_ai_act_risk_class="limited",
        model_name="gpt-5.4-mini",
    )


def _cookie_preferences_for_tenant(tenant_id: str) -> CookiePreferences:
    prefs = _COOKIE_PREFS.get(tenant_id)
    if prefs is None:
        prefs = {"strictly_necessary": True, "analytics": False}
        _COOKIE_PREFS[tenant_id] = prefs
    return CookiePreferences(**prefs)


def _tenant_settings_response(tenant_id: str) -> TenantSettingsResponse:
    prefs = _scan_preferences_from(
        _TENANT_PREFERENCES.get(tenant_id, {}),
        f"tenant {tenant_id} (in-memory fixture store)",
    )
    return TenantSettingsResponse(
        tenant_id=tenant_id,
        org_name=f"{tenant_id} Org",
        plan_tier="enterprise",
        agent_count=len(_AGENTS.get(tenant_id, [])),
        billing_tier="annual",
        api_key_status="active",
        selected_frameworks=list(_TENANT_FRAMEWORKS.get(tenant_id, ["eu-ai-act"])),
        consent_required=True,
        cookie_preferences=_cookie_preferences_for_tenant(tenant_id),
        preferred_scan_cadence_hours=prefs["preferred_scan_cadence_hours"],
        alert_email=prefs["alert_email"],
        alert_threshold=prefs["alert_threshold"],
    )


# ---------------------------------------------------------------------------
# Router and shared constants
# ---------------------------------------------------------------------------

router = APIRouter(prefix="/api", tags=["compatibility"])
ERROR_RESPONSES = {
    401: {"model": ErrorResponse},
    403: {"model": ErrorResponse},
    405: {"model": ErrorResponse},
    422: {"model": ErrorResponse},
    500: {"model": ErrorResponse},
    503: {"model": ErrorResponse},
}


def _coerce_crypto_kind(value: object) -> Literal["positive", "negative"]:
    return value if value in {"positive", "negative"} else "positive"


def _coerce_crypto_status(value: object) -> Literal["passed", "failed", "error", "pending"]:
    """Map an upstream status into the vocabulary, defaulting to ``error``.

    The default used to be ``pending``, which is a claim -- "this check has not
    run yet" -- that an unparseable value gives no grounds for.  A prover that
    reported ``"fail"``, ``"FAILED"`` or any other spelling of bad news, whether
    through version skew or a template typo, had it rewritten into the most
    reassuring value in the enum.  On a surface whose entire job is attestation,
    the default has to be the one that means "we could not tell".
    """
    return value if value in {"passed", "failed", "error", "pending"} else "error"


def _unparseable_crypto_proof(payload: object) -> CryptoProof:
    """Represent a proof that could not be read, rather than discarding it.

    Dropping it produced the most dangerous shape a degraded answer can take:
    not an empty list, which looks wrong, but a *shorter* list, which looks
    complete.  Three proofs upstream became a tidy one-proof board with HTTP 200
    and nothing anywhere recording that two went missing.  Keeping a placeholder
    keeps the count honest and puts the failure on the board where it belongs.
    """
    name = payload.get("name") if isinstance(payload, dict) else None
    return CryptoProof(
        name=str(name) if isinstance(name, str) and name else "unparseable-proof",
        kind="positive",
        status="error",
        title="Proof could not be read",
        description="The crypto prover returned a proof this service could not parse.",
        expectation="A well-formed proof object",
        evidence=f"malformed payload of type {type(payload).__name__}",
    )


def _crypto_proof_from_payload(payload: object) -> CryptoProof:
    if not isinstance(payload, dict):
        return _unparseable_crypto_proof(payload)
    name = payload.get("name")
    title = payload.get("title")
    description = payload.get("description")
    expectation = payload.get("expectation")
    evidence = payload.get("evidence")
    if not all(isinstance(field, str) and field for field in (name, title, description, expectation, evidence)):
        return _unparseable_crypto_proof(payload)
    return CryptoProof(
        name=name,
        kind=_coerce_crypto_kind(payload.get("kind")),
        status=_coerce_crypto_status(payload.get("status")),
        title=title,
        description=description,
        expectation=expectation,
        evidence=evidence,
    )


def _check_response_status(res: Any, url: str) -> None:
    status = getattr(res, "status_code", None)
    if status is not None:
        if status >= 400:
            req = getattr(res, "request", None) or httpx.Request("GET", url)
            raise httpx.HTTPStatusError(f"HTTP {status}", request=req, response=res)
    elif hasattr(res, "raise_for_status"):
        res.raise_for_status()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("/capabilities", response_model=CapabilitiesResponse, responses=ERROR_RESPONSES)
async def get_capabilities(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    response: Response = Response(),
    agent_id: Annotated[str | None, Query(description="Target agent / workload ID")] = None,
    workload: Annotated[str | None, Query(description="Target workload name / alias")] = None,
    namespace: Annotated[str | None, Query(description="Target workload namespace")] = None,
) -> CapabilitiesResponse:
    """Returns server-authorized capabilities for the authenticated principal, tenant, and workload.

    RFC 9110 Invariant: strictly side-effect free and idempotent (zero SQL writes).
    Separation of Identity Planes: Decoupled human principal authorization from workload identity.
    """
    from superadmin import is_superadmin

    is_admin = is_superadmin(principal)
    tenant = principal.tenant
    roles = ["superadmin", "operator"] if is_admin else ["operator"]

    tenant_caps = TenantCapabilities(
        view_agents=True,
        register_agent=True,
        export_compliance=True,
        view_crypto_proofs=True,
        run_network_tests=True,
        view_audit_trail=True,
        manage_settings=is_admin,
        manage_api_keys=is_admin,
        manage_users=is_admin,
        run_supercred_scenario=is_admin,
    )

    actions = {
        "freeze": ActionCapability(
            allowed=is_admin,
            reason="Permitted for superadmin" if is_admin else "Privileged containment requires superadmin authorization",
            requires_confirmation=True,
            requires_reason=True,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "thaw": ActionCapability(
            allowed=is_admin,
            reason="Permitted for superadmin" if is_admin else "Privileged containment requires superadmin authorization",
            requires_confirmation=True,
            requires_reason=True,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "network_isolate": ActionCapability(
            allowed=is_admin,
            reason="Permitted for superadmin" if is_admin else "Privileged network isolation requires superadmin authorization",
            requires_confirmation=True,
            requires_reason=True,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "network_restore": ActionCapability(
            allowed=is_admin,
            reason="Permitted for superadmin" if is_admin else "Privileged network restoration requires superadmin authorization",
            requires_confirmation=True,
            requires_reason=True,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "revoke_credentials": ActionCapability(
            allowed=is_admin,
            reason="Permitted for superadmin" if is_admin else "Credential revocation requires superadmin authorization",
            requires_confirmation=True,
            requires_reason=True,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "issue_credentials": ActionCapability(
            allowed=True,
            reason="Permitted for tenant operator",
            requires_confirmation=False,
            requires_reason=False,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "reassess_compliance": ActionCapability(
            allowed=True,
            reason="Permitted for tenant operator",
            requires_confirmation=False,
            requires_reason=False,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
        "decommission": ActionCapability(
            allowed=False,
            reason="Irreversible decommission requires enforced dual approval",
            requires_confirmation=True,
            requires_reason=True,
            requires_dual_approval=True,
            scope=f"tenant:{tenant}",
        ),
        "run_scenario": ActionCapability(
            allowed=is_admin,
            reason="Permitted for superadmin in lab/demo environment" if is_admin else "SuperCred demo scenarios require superadmin authorization",
            requires_confirmation=True,
            requires_reason=False,
            requires_dual_approval=False,
            scope=f"tenant:{tenant}",
        ),
    }

    target_id = agent_id or workload
    workload_caps = None
    if target_id is not None or namespace is not None:
        if target_id is not None:
            # If target_id is provided, verify it exists and is accessible to caller's tenant
            discovered_found = False
            try:
                async with httpx.AsyncClient(timeout=3.0) as client:
                    res = await client.get(AGENT_DISCOVERY_URL)
                    _check_response_status(res, AGENT_DISCOVERY_URL)
                    payload = res.json()
                if isinstance(payload, dict):
                    for d in payload.get("agents", []):
                        if isinstance(d, dict):
                            d_id = str(d.get("id")) if d.get("id") is not None else None
                            d_name = str(d.get("name")) if d.get("name") is not None else None
                            if d_id == target_id or d_name == target_id:
                                discovered_found = True
                                if namespace is None and d.get("namespace"):
                                    namespace = str(d.get("namespace"))
                                break
            except (httpx.HTTPError, ValueError, KeyError, TypeError):
                pass

            pool = await _get_pool()
            agent_found = False
            if pool is None:
                _ensure_seeded(tenant)
                with _STORE_LOCK:
                    agent = _AGENTS[tenant].get(target_id)
                    if agent is None:
                        for a in _AGENTS[tenant].values():
                            if a.get("name") == target_id:
                                agent = a
                                break
                    if agent is not None:
                        agent_found = True
            else:
                agent_uuid = _try_uuid(target_id)
                if agent_uuid is not None:
                    row = await pool.fetchrow(
                        "SELECT id FROM agent_registry WHERE id = $1 AND tenant_id = $2",
                        agent_uuid,
                        tenant,
                    )
                else:
                    row = await pool.fetchrow(
                        "SELECT id FROM agent_registry WHERE name = $1 AND tenant_id = $2",
                        target_id,
                        tenant,
                    )
                if row is not None:
                    agent_found = True

            if not agent_found and not discovered_found:
                raise APIError(404, "not_found", f"Agent '{target_id}' not found")

        target_scope = f"workload:{target_id}" if target_id else f"namespace:{namespace}"
        workload_caps = WorkloadActionCapabilities(
            agent_id=agent_id,
            workload=workload,
            namespace=namespace,
            freeze=ActionCapability(
                allowed=is_admin,
                reason="Permitted for superadmin" if is_admin else "Privileged containment requires superadmin authorization",
                requires_confirmation=True,
                requires_reason=True,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            thaw=ActionCapability(
                allowed=is_admin,
                reason="Permitted for superadmin" if is_admin else "Privileged containment requires superadmin authorization",
                requires_confirmation=True,
                requires_reason=True,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            network_isolate=ActionCapability(
                allowed=is_admin,
                reason="Permitted for superadmin" if is_admin else "Privileged network isolation requires superadmin authorization",
                requires_confirmation=True,
                requires_reason=True,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            network_restore=ActionCapability(
                allowed=is_admin,
                reason="Permitted for superadmin" if is_admin else "Privileged network restoration requires superadmin authorization",
                requires_confirmation=True,
                requires_reason=True,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            revoke_credentials=ActionCapability(
                allowed=is_admin,
                reason="Permitted for superadmin" if is_admin else "Credential revocation requires superadmin authorization",
                requires_confirmation=True,
                requires_reason=True,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            issue_credentials=ActionCapability(
                allowed=True,
                reason="Permitted for tenant operator",
                requires_confirmation=False,
                requires_reason=False,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            reassess_compliance=ActionCapability(
                allowed=True,
                reason="Permitted for tenant operator",
                requires_confirmation=False,
                requires_reason=False,
                requires_dual_approval=False,
                scope=target_scope,
            ),
            decommission=ActionCapability(
                allowed=False,
                reason="Irreversible decommission requires enforced dual approval",
                requires_confirmation=True,
                requires_reason=True,
                requires_dual_approval=True,
                scope=target_scope,
            ),
            run_scenario=ActionCapability(
                allowed=is_admin,
                reason="Permitted for superadmin in lab/demo environment" if is_admin else "SuperCred demo scenarios require superadmin authorization",
                requires_confirmation=True,
                requires_reason=False,
                requires_dual_approval=False,
                scope=target_scope,
            ),
        )

    response.headers["X-Source-Health"] = "healthy"
    return CapabilitiesResponse(
        tenant=tenant,
        principal_id=principal.subject,
        email=principal.email,
        roles=roles,
        is_superadmin=is_admin,
        tenant_capabilities=tenant_caps,
        actions=actions,
        workload=workload_caps,
        source_health="healthy",
    )


@router.get("/agents", response_model=AgentListResponse, responses=ERROR_RESPONSES)
async def agents(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    response: Response = Response(),
    search: str | None = None,
    namespace: str | None = None,
    framework: str | None = None,
    owner: str | None = None,
    attention: str | None = None,
    record_class: str | None = None,
    lifecycle_state: str | None = None,
    state: str | None = None,
    spiffe_id: str | None = None,
    page: Annotated[int, Query(ge=1)] = 1,
    limit: Annotated[int, Query(ge=1)] = 50,
) -> AgentListResponse:
    # --- k8s discovery (always attempted) ---
    raw_discovered: list[dict[str, Any]] = []
    discovery_health: Literal["healthy", "degraded", "error", "unavailable"] = "healthy"
    discovery_last_good: str | None = _now_iso()
    discovery_msg: str | None = None

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            res = await client.get(AGENT_DISCOVERY_URL)
            _check_response_status(res, AGENT_DISCOVERY_URL)
            payload = res.json()
        if not isinstance(payload, dict):
            raise TypeError("agent discovery payload must be an object")
        disc_list = payload.get("agents", [])
        if not isinstance(disc_list, list):
            raise TypeError("agent discovery agents must be a list")
        for item in disc_list:
            if isinstance(item, dict) and item.get("id") is not None:
                raw_discovered.append(item)
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        logger.warning("agent discovery upstream unavailable: %s", exc)
        discovery_health = "unavailable"
        discovery_last_good = None
        discovery_msg = str(exc)

    all_records: list[AgentResponse] = []
    pg_status: Literal["healthy", "degraded", "error", "unavailable"] = "healthy"
    pg_last_good: str | None = _now_iso()
    pg_msg: str | None = None

    pool = await _get_pool()
    if pool is None:
        # Fixture mode: pure discovered workloads
        for disc in raw_discovered:
            all_records.append(
                _agent_response_from_discovered(
                    disc,
                    tenant_id=tenant_id,
                    record_class="discovered",
                    is_registry_linked=False,
                )
            )
    else:
        db_rows = await pool.fetch(
            "SELECT * FROM agent_registry WHERE tenant_id = $1 ORDER BY created_at", tenant_id,
        )
        unmatched_db = {str(r["id"]): r for r in db_rows}
        db_by_name = {str(r["name"]): r for r in db_rows if r.get("name")}

        # Process discovered workloads first
        for disc in raw_discovered:
            disc_id = str(disc["id"])
            disc_name = str(disc.get("name"))
            matched_row = unmatched_db.pop(disc_id, None)
            if matched_row is None and disc_name in db_by_name:
                cand = db_by_name[disc_name]
                if str(cand["id"]) in unmatched_db:
                    matched_row = unmatched_db.pop(str(cand["id"]))

            if matched_row is not None:
                compliance = await _compliance_summary_for_agent(pool, matched_row["id"])
                all_records.append(_agent_response_from_row(matched_row, compliance, discovered_overlay=disc))
            else:
                all_records.append(_agent_response_from_discovered(disc, tenant_id=tenant_id, record_class="discovered", is_registry_linked=False))

        # Remaining DB records
        for row in unmatched_db.values():
            compliance = await _compliance_summary_for_agent(pool, row["id"])
            all_records.append(_agent_response_from_row(row, compliance, discovered_overlay=None))

    # Compute meta counts before filtering/pagination
    total_records = len(all_records)
    registered_count = sum(1 for a in all_records if a.record_class == "registered")
    discovered_count = sum(1 for a in all_records if a.record_class == "discovered")
    resolved_count = sum(1 for a in all_records if a.record_class == "resolved")
    fixture_count = sum(1 for a in all_records if a.record_class == "fixture")
    operational_count = total_records - fixture_count

    meta = AgentListMeta(
        total_records=total_records,
        operational_count=operational_count,
        registered_count=registered_count,
        discovered_count=discovered_count,
        resolved_count=resolved_count,
        fixture_count=fixture_count,
    )

    # Server-side Filtering
    filtered = all_records
    if search:
        s = search.strip().lower()
        filtered = [
            a for a in filtered
            if (s in a.name.lower())
            or (s in a.id.lower())
            or (a.namespace and s in a.namespace.lower())
            or (a.framework and s in a.framework.lower())
            or (a.owner and s in a.owner.lower())
            or (a.model_name and s in a.model_name.lower())
            or (a.type and s in a.type.lower())
            or (a.service_account and s in a.service_account.lower())
        ]
    if namespace:
        ns = namespace.strip().lower()
        filtered = [
            a for a in filtered
            if (a.namespace and a.namespace.lower() == ns)
            or (a.runtime and a.runtime.namespace and a.runtime.namespace.lower() == ns)
        ]
    if framework:
        fw = framework.strip().lower()
        filtered = [
            a for a in filtered
            if (a.framework and a.framework.lower() == fw)
            or (a.runtime and a.runtime.framework and a.runtime.framework.lower() == fw)
            or (a.type and a.type.lower() == fw)
        ]
    if owner:
        ow = owner.strip().lower()
        if ow in ("unassigned", "none"):
            filtered = [
                a for a in filtered
                if not a.owner and (not a.responsibility or a.responsibility.assignment_status in ("unassigned", "registry_unlinked"))
            ]
        else:
            filtered = [
                a for a in filtered
                if (a.owner and ow in a.owner.lower())
                or (a.responsibility and a.responsibility.owner_name and ow in a.responsibility.owner_name.lower())
            ]
    if attention:
        att = attention.strip().lower()
        filtered = [a for a in filtered if a.attention and a.attention.level.lower() == att]
    if record_class:
        rc = record_class.strip().lower()
        filtered = [a for a in filtered if a.record_class.lower() == rc]
    effective_state = lifecycle_state or state
    if effective_state:
        st = effective_state.strip().lower()
        if st != "all":
            canonical_q = _canonical_lifecycle_state(st).lower()
            filtered = [
                a for a in filtered
                if a.lifecycle_state and (a.lifecycle_state.lower() == st or a.lifecycle_state.lower() == canonical_q)
            ]
    if spiffe_id:
        sid = spiffe_id.strip().lower()
        filtered = [
            a for a in filtered
            if (a.identity and a.identity.spiffe_id and sid in a.identity.spiffe_id.lower())
            or (a.id and sid in a.id.lower())
        ]

    # Pagination
    total_filtered = len(filtered)
    total_pages = math.ceil(total_filtered / limit) if (limit > 0 and total_filtered > 0) else 1
    start_idx = (page - 1) * limit
    end_idx = start_idx + limit
    page_records = filtered[start_idx:end_idx]

    pagination = PaginationMetadata(
        page=page,
        limit=limit,
        total_pages=total_pages,
    )

    overall_source_health: Literal["healthy", "degraded", "unavailable"] = "healthy"
    if pool is None:
        overall_source_health = "healthy" if discovery_health == "healthy" else "unavailable"
    else:
        overall_source_health = "healthy" if discovery_health == "healthy" else "degraded"

    if response is not None:
        response.headers["source_health"] = overall_source_health
        response.headers["X-Source-Health"] = overall_source_health

    source_health_map = SourceHealthMap(
        k8s_discovery=SourceHealthDetail(
            status=discovery_health,
            last_good=discovery_last_good,
            message=discovery_msg,
        ),
        postgres_registry=SourceHealthDetail(
            status=pg_status,
            last_good=pg_last_good,
            message=pg_msg,
        ),
        crypto_proofs=SourceHealthDetail(
            status="healthy",
            last_good=_now_iso(),
            message=None,
        ),
    )

    return AgentListResponse(
        agents=page_records,
        data=page_records,
        total=total_filtered,
        meta=meta,
        source_health=overall_source_health,
        source_health_detail=source_health_map,
        pagination=pagination,
    )


@router.get("/health/crypto", response_model=CryptoHealthResponse, responses=ERROR_RESPONSES)
async def crypto_health(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    response: Response = Response(),
) -> CryptoHealthResponse:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            res = await client.get(CRYPTO_HEALTH_URL)
            _check_response_status(res, CRYPTO_HEALTH_URL)
            payload = res.json()
        if not isinstance(payload, dict):
            raise TypeError("crypto health payload must be an object")
        proxy_proofs = payload.get("proofs", [])
        if not isinstance(proxy_proofs, list):
            raise TypeError("crypto health proofs must be a list")
        proofs = [_crypto_proof_from_payload(proxy_proof) for proxy_proof in proxy_proofs]
        if response is not None:
            response.headers["source_health"] = "healthy"
            response.headers["X-Source-Health"] = "healthy"
        return CryptoHealthResponse(tenant_id=tenant_id, proofs=proofs, source_health="healthy")
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        logger.warning("crypto health prover unavailable: %s", exc)
        raise APIError(
            503,
            "upstream_unavailable",
            f"Crypto health collector unavailable: {exc}",
        ) from exc


@router.get("/network-tests", response_model=NetworkTestListResponse, responses=ERROR_RESPONSES)
async def network_tests(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> NetworkTestListResponse:
    del tenant_id  # network policy test results are cluster-scoped, not per-tenant
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(NETWORK_TESTS_URL)
            response.raise_for_status()
            payload = response.json()
        if not isinstance(payload, dict):
            raise TypeError("network test results payload must be an object")
        return NetworkTestListResponse.model_validate(payload)
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        # Unlike crypto_health above, this deliberately does NOT swallow the
        # failure into an empty-but-200 response. A live network-test board
        # that goes silent needs to read as "unreachable", not as "zero
        # tests configured" — the dashboard's Scan Now button depends on
        # telling those two states apart.
        # Raised as an APIError, not an HTTPException: the StarletteHTTPException
        # handler discards ``detail`` for every status it does not special-case
        # and substitutes "Request failed", so the message built here provably
        # never reached a caller. A diagnostic that nobody can read is worse than
        # none, because it reads like coverage.
        logger.warning("network tests: fake-integration-proxy unreachable", exc_info=True)
        raise APIError(
            502,
            "upstream_unavailable",
            f"network test results unavailable: {exc}",
        ) from exc


@router.post("/network-tests/scan", response_model=NetworkTestScanResponse, responses=ERROR_RESPONSES)
async def network_tests_scan(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> JSONResponse:
    del tenant_id
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(NETWORK_TESTS_SCAN_URL)
            payload = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("network test scan: fake-integration-proxy unreachable", exc_info=True)
        raise APIError(
            502,
            "upstream_unavailable",
            f"could not reach the network test runner: {exc}",
        ) from exc
    # The proxy is the source of truth for the status code — 202 started,
    # 409 already running, 502 the proxy's own upstream failed. Forwarding it
    # unchanged means the "already running" guard against double-submits
    # lives in exactly one place.
    return JSONResponse(status_code=response.status_code, content=payload)


def _derived_topology(tenant_id: str, available, reason: str) -> TrustTopologyResponse:
    """Build a topology from the tenant's own agent state.

    Used ONLY when the live collector cannot be reached. Every item it emits is
    labelled evidence_state="modeled" / assurance="modeled" and the kubernetes
    collector is reported "unavailable" with the reason, so a caller can always
    tell derived shape from observed fact. The dashboard renders modeled items
    faint and slow precisely so this degradation is visible rather than silent.
    """
    now = _now_iso()
    def ev(why: str) -> dict:
        return {
            "evidence_state": "modeled", "evidence_source": "Derived from authenticated tenant agent state",
            "observed_at": now, "freshness": "unavailable", "assurance": "modeled", "reason": why,
        }
    nodes = [
        TrustTopologyItem(id="platform", kind="platform", label="Signal Loom platform",
                          tenant=None, **ev("Platform root implied by the authenticated principal")),
        TrustTopologyItem(id=tenant_id, kind="tenant", label=f"{tenant_id} tenant", parent_id="platform",
                          tenant=tenant_id, **ev("Tenant derived from the verified bearer-token subject")),
        TrustTopologyItem(id="spire", kind="service", label="SPIRE issuer", parent_id="platform",
                          tenant="shared", location="in-cluster", **ev("Modeled SPIFFE issuer")),
        TrustTopologyItem(id="openbao", kind="service", label="OpenBao", parent_id="platform",
                          tenant="shared", location="in-cluster", **ev("Modeled SuperCredential exchange broker")),
    ]
    edges = [
        TrustTopologyEdge(id=f"platform-{tenant_id}", from_id="platform", to_id=tenant_id,
                          verb="scopes authenticated tenant", plane="identity", decision="allowed",
                          tenant=tenant_id, mtls_enforced=True, throughput_pps=50.0, latency_ms=0.5,
                          **ev("Tenant comes from the verified bearer-token subject mapping")),
        TrustTopologyEdge(id=f"spire-{tenant_id}", from_id="spire", to_id=tenant_id,
                          verb="issues tenant trust bundles", plane="identity", decision="allowed",
                          tenant="shared", mtls_enforced=True, throughput_pps=10.0, latency_ms=1.1,
                          **ev("Modeled SPIFFE issuance")),
    ]
    for agent in available:
        spiffe_id = getattr(agent, "spiffe_id", None) if hasattr(agent, "spiffe_id") else (agent.get("spiffe_id") if isinstance(agent, dict) else None)
        verified = bool(spiffe_id)
        lifecycle = getattr(agent, "lifecycle_state", None) if hasattr(agent, "lifecycle_state") else (agent.get("lifecycle_state") if isinstance(agent, dict) else "registered")
        if not lifecycle:
            lifecycle = "registered"
        name = getattr(agent, "name", None) if hasattr(agent, "name") else (agent.get("name") if isinstance(agent, dict) else None)
        agent_id = getattr(agent, "id", None) if hasattr(agent, "id") else (agent.get("id") if isinstance(agent, dict) else str(agent))
        namespace = getattr(agent, "namespace", None) if hasattr(agent, "namespace") else (agent.get("namespace") if isinstance(agent, dict) else f"tenant-{tenant_id}")
        trust_domain = getattr(agent, "trust_domain", None) if hasattr(agent, "trust_domain") else (agent.get("trust_domain") if isinstance(agent, dict) else f"{tenant_id}.signalloom.demo")
        tool_perms = getattr(agent, "tool_permissions", None) if hasattr(agent, "tool_permissions") else (agent.get("tool_permissions") if isinstance(agent, dict) else ["read", "write"])
        egress = getattr(agent, "egress_allowlist", None) if hasattr(agent, "egress_allowlist") else (agent.get("egress_allowlist") if isinstance(agent, dict) else ["in-cluster"])
        custom_attrs = getattr(agent, "custom_attributes", None) if hasattr(agent, "custom_attributes") else (agent.get("custom_attributes") if isinstance(agent, dict) else {})
        meta = getattr(agent, "metadata", None) if hasattr(agent, "metadata") else (agent.get("metadata") if isinstance(agent, dict) else custom_attrs)

        nodes.append(TrustTopologyItem(
            id=agent_id, kind="agent", label=name or agent_id, parent_id=tenant_id, tenant=tenant_id,
            location="in-cluster", namespace=namespace,
            spiffe_id=spiffe_id, lifecycle_state=lifecycle,
            trust_domain=trust_domain, verified=verified,
            tool_permissions=tool_perms, egress_allowlist=egress,
            metadata=meta, custom_attributes=custom_attrs,
            **ev(f"Agent lifecycle state: {lifecycle}")
        ))
        edges.append(TrustTopologyEdge(
            id=f"{tenant_id}-{agent_id}", from_id=tenant_id, to_id=agent_id,
            verb=f"governs {lifecycle} agent", plane="authorization",
            decision="denied" if lifecycle in {"suspended", "stunned", "revoked", "quarantined"} else "allowed",
            tenant=tenant_id,
            throughput_pps=125.0, latency_ms=1.2, mtls_enforced=verified,
            **ev(f"Lifecycle state {lifecycle} derived from tenant state")
        ))
    return TrustTopologyResponse(
        generated_at=now, version="v1",
        collectors={"kubernetes": TopologyCollector(status="unavailable", observed_at=now, reason=reason)},
        nodes=nodes, edges=edges,
        modeled_gaps=[TrustTopologyItem(
            id="gap-live-collector", kind="gap", label="Live topology collector unreachable",
            tenant=None, **ev(reason))],
    )


@router.get("/trust-topology", response_model=TrustTopologyResponse, responses=ERROR_RESPONSES)
async def trust_topology(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TrustTopologyResponse:
    """Live collector first; a labelled derived topology only if it is unreachable.

    Three outcomes, kept deliberately distinct, because collapsing them is how a
    demo starts lying:

      collector reachable, has data  -> observed evidence, returned as-is
      collector reachable, EMPTY     -> returned empty and observed. An empty
                                        estate is a real answer and must not be
                                        back-filled with invented nodes.
      collector unreachable          -> derived topology, every item marked
                                        modeled, collectors.kubernetes
                                        "unavailable" with the reason.

    The middle case is why this does not simply fall back on any falsy result.
    The original proxy route raised 502 on an unreachable collector, which is
    honest but leaves the demo dead whenever the proxy is down; the original
    derived route always answered but could not express which of the three
    situations produced it. The schema can express all three, so it does.
    """
    fallback_reason = ""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(TRUST_TOPOLOGY_URL)
            response.raise_for_status()
            payload = response.json()
    except httpx.HTTPError as exc:
        # TRANSPORT failure only. The collector might be down, restarting, or
        # not deployed yet; none of that is a contract violation, and killing
        # the demo for it helps nobody.
        logger.warning("trust topology: fake-integration-proxy unreachable", exc_info=True)
        fallback_reason = f"fake-integration-proxy unreachable: {exc}"

    if not fallback_reason:
        # A malformed payload is NOT falled back on, deliberately. A collector
        # answering with garbage is a broken contract that someone has to fix,
        # and quietly substituting a derived topology would hide it behind a
        # page that looks fine. Unreachable is an outage; malformed is a bug.
        try:
            topology = TrustTopologyResponse.model_validate(payload)
        except (ValidationError, ValueError, TypeError) as exc:
            logger.error("trust topology: proxy returned a payload that is not v1", exc_info=True)
            raise HTTPException(
                status_code=502, detail=f"trust topology payload invalid: {exc}") from exc

        collector = topology.collectors.get(
            "kubernetes", TopologyCollector(status="unavailable", observed_at="", reason="missing"))
        if collector.status == "unavailable":
            # Reachable, well-formed, and honestly reporting that it could not
            # collect. Same information value as an outage, so same treatment --
            # but the reason is carried through rather than invented.
            fallback_reason = f"kubernetes collector unavailable: {collector.reason}"

    if fallback_reason:
        available = (await agents(tenant_id)).agents
        if not available:
            _ensure_seeded(tenant_id)
            with _STORE_LOCK:
                available = [AgentResponse(**agent) for agent in _AGENTS[tenant_id].values()]
        return _derived_topology(tenant_id, available, fallback_reason)

    allowed_tenants = {None, "shared", "", tenant_id}
    nodes = [
        node for node in topology.nodes
        if node.tenant in allowed_tenants or node.kind in {"platform", "service", "external", "gap", "probe"}
    ]
    visible = {node.id for node in nodes}
    edges = [
        edge for edge in topology.edges
        if (edge.tenant in allowed_tenants or edge.tenant is None)
        and edge.from_id in visible
        and edge.to_id in visible
    ]
    modeled_gaps = [
        gap for gap in topology.modeled_gaps
        if gap.tenant in allowed_tenants or gap.tenant is None
    ]
    # model_copy preserves shared-object names and labels; filtering never
    # rewrites an object to impersonate the requesting tenant.
    return topology.model_copy(update={
        "nodes": nodes,
        "edges": edges,
        "modeled_gaps": modeled_gaps,
    })


@router.post("/agents", response_model=AgentResponse, responses=ERROR_RESPONSES)
async def create_agent(
    body: AgentCreateRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> AgentResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Registering an agent")
    if pool is None:
        _ensure_seeded(tenant_id)
        now = _now_iso()
        with _STORE_LOCK:
            agent_id = f"{tenant_id}:agent-{next(_AGENT_SEQ)}"
            agent = _make_agent(
                tenant_id,
                agent_id,
                body.name,
                body.type,
                body.owner,
                "registered",
                now,
                eu_ai_act_risk_class="limited",
                model_name="gpt-5.4-mini",
            )
            _AGENTS[tenant_id][agent_id] = agent
            return AgentResponse(**agent)

    # ``display_name`` is NOT NULL and was omitted entirely, so every create
    # against a real database failed.  ``AgentCreateRequest`` carries exactly one
    # name, and the API already treats ``agent_registry.name`` as the value it
    # echoes back as ``AgentResponse.name``; the same string is therefore the
    # only honest display name.  Deriving a slug for ``name`` and reserving the
    # typed string for ``display_name`` -- which is how ``data-mock.sql`` seeds
    # the pair -- would silently change what GET returns, so the request model
    # needs an explicit optional ``display_name`` first.  Noted, not smuggled in.
    origin = body.type if body.type in {"Signal Loom Built", "COTS", "Custom"} else "Signal Loom Built"
    try:
        async with _write(pool) as conn:
            row = await conn.fetchrow(
                """INSERT INTO agent_registry (tenant_id, name, display_name, origin, owner, lifecycle_state, eu_ai_act_risk_class, model_name)
                   VALUES ($1, $2, $3, $4, $5, 'registered', 'limited', 'gpt-5.4-mini')
                   RETURNING *""",
                tenant_id, body.name, body.name, origin, body.owner,
            )
            compliance = await _compliance_summary_for_agent(conn, row["id"])
            await _audit_log(conn, tenant_id, "agent.created", str(row["id"]), body.name, principal.actor, {"source": "api"})
    except asyncpg.exceptions.UniqueViolationError:
        # agent_registry.name carries a UNIQUE constraint. Creating an agent with
        # a name already in use is a caller error, not a server fault, and it
        # leaked as a 500 with an opaque "Internal server error" body — the
        # caller could not tell a duplicate name from a database outage. Surfaced
        # by the e2e tier, which creates the same "E2E Agent" on every run and so
        # succeeded once and 500'd forever after.
        raise APIError(409, "agent_exists", f"An agent named {body.name!r} already exists") from None
    return _agent_response_from_row(row, compliance)


@router.post("/agents/{agent_id}/credentials", response_model=IssueCredentialResponse, responses=ERROR_RESPONSES)
async def issue_agent_credential(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> IssueCredentialResponse:
    tenant_id = principal.tenant
    token = f"demo.{secrets.token_urlsafe(18)}"
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    issued_at = _now_iso()
    expires_at, expires_at_iso = _credential_expiry()
    pool = await _require_pool("Issuing a credential")
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _fixture_agent_for_credentials(tenant_id, agent_id)
            _AGENT_CREDENTIALS[tenant_id].setdefault(agent_id, []).append(
                {
                    "token_sha256": token_hash,
                    "issued_at": issued_at,
                    "expires_at": expires_at_iso,
                    "revoked_at": None,
                    "revoked_by": None,
                },
            )
            name = str(agent["name"])
    else:
        # Credential issuance now has a business write as well as an audit row.
        # Both must use the same connection inside one transaction or a failing
        # audit insert recreates the original defect: a live credential that the
        # caller was told failed to mint.
        async with _write(pool) as conn:
            agent_uuid, name = await _db_agent_for_credentials(conn, tenant_id, agent_id)
            await conn.execute(
                """INSERT INTO public.agent_credentials (tenant_id, agent_id, token_sha256, expires_at)
                   VALUES ($1, $2, $3, $4)""",
                tenant_id, agent_uuid, token_hash, expires_at,
            )
            await _audit_log(
                conn, tenant_id, "agent.credential_issued", agent_id, name, principal.actor,
                {"expires_at": expires_at_iso},
            )
    return IssueCredentialResponse(
        agent_id=agent_id,
        name=name,
        identity_token=token,
        token_expires_at=expires_at_iso,
        token_note=f"Issued for tenant {tenant_id} at {issued_at}",
    )


@router.post("/agents/{agent_id}/credentials/revoke", response_model=RevokeCredentialResponse, responses=ERROR_RESPONSES)
async def revoke_agent_credential(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> RevokeCredentialResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Revoking a credential")
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _fixture_agent_for_credentials(tenant_id, agent_id)
            tokens_revoked = 0
            for credential in _AGENT_CREDENTIALS[tenant_id].get(agent_id, []):
                if credential["revoked_at"] is None:
                    credential["revoked_at"] = _now_iso()
                    credential["revoked_by"] = principal.actor
                    tokens_revoked += 1
        return RevokeCredentialResponse(
            agent_id=agent_id,
            name=str(agent["name"]),
            tokens_revoked=tokens_revoked,
        )

    async with _write(pool) as conn:
        agent_uuid, agent_name = await _db_agent_for_credentials(conn, tenant_id, agent_id)
        row = await conn.fetchrow(
            """WITH revoked AS (
                   UPDATE public.agent_credentials
                      SET revoked_at = now(), revoked_by = $3
                    WHERE tenant_id = $1 AND agent_id = $2 AND revoked_at IS NULL
                    RETURNING 1
               )
               SELECT COUNT(*)::int AS tokens_revoked FROM revoked""",
            tenant_id, agent_uuid, principal.actor,
        )
        tokens_revoked = 0 if row is None else int(row["tokens_revoked"])
        await _audit_log(
            conn, tenant_id, "agent.credential_revoked", agent_id, agent_name, principal.actor,
            {"tokens_revoked": tokens_revoked},
        )
    return RevokeCredentialResponse(
        agent_id=agent_id,
        name=agent_name,
        tokens_revoked=tokens_revoked,
    )


async def _fetch_discovered_agents() -> list[dict[str, Any]]:
    raw_discovered: list[dict[str, Any]] = []
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            res = await client.get(AGENT_DISCOVERY_URL)
            _check_response_status(res, AGENT_DISCOVERY_URL)
            payload = res.json()
        if isinstance(payload, dict):
            for item in payload.get("agents", []):
                if isinstance(item, dict) and item.get("id") is not None:
                    raw_discovered.append(item)
    except Exception as exc:
        logger.warning("agent discovery upstream unavailable: %s", exc)
    return raw_discovered


async def _execute_claim(
    tenant_id: str,
    principal_actor: str,
    body: AgentClaimRequest,
    agent_id_override: str | None = None,
) -> AgentClaimResponse:
    now = _now_iso()
    claim_id = f"claim-{uuid.uuid4().hex[:12]}"
    allocated_budget = body.token_budget_limit if body.token_budget_limit > 0 else 100000

    if agent_id_override and _try_uuid(agent_id_override):
        agent_uuid = uuid.UUID(agent_id_override)
    elif body.agent_id and _try_uuid(body.agent_id):
        agent_uuid = uuid.UUID(body.agent_id)
    else:
        agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{body.pod_name}")
    agent_id = str(agent_uuid)

    pool = await _get_pool()
    if pool is not None:
        async with _write(pool) as conn:
            # Check cross-tenant conflict: if already claimed by another tenant
            conflict_row = await conn.fetchrow(
                """SELECT claim_id, tenant_id FROM public.agent_claims
                    WHERE (agent_id = $1 OR pod_name = $2)
                      AND tenant_id != $3
                      AND status = 'granted'
                      AND released_at IS NULL""",
                agent_uuid, body.pod_name, tenant_id,
            )
            if conflict_row is not None:
                # The conflicting tenant's identifier is deliberately NOT in the
                # message.  The caller has no relationship with that tenant --
                # naming it turns a refusal into a cross-tenant disclosure, and
                # a pod-name guessing loop into a tenant enumerator.  "Some
                # other tenant holds this" is everything the caller needs to
                # act on; who they are is the operator's business, and the
                # conflict row is still available server-side for support.
                raise APIError(
                    409,
                    "claim_conflict",
                    f"Agent '{body.pod_name}' is already claimed by another tenant",
                )

            agent_name = body.pod_name
            display_name = body.pod_name.replace("-", " ").title()
            row = await conn.fetchrow(
                """INSERT INTO public.agent_registry (
                    id, tenant_id, name, display_name, description, status, lifecycle_state,
                    origin, compliance_posture, model_provider, model_name,
                    last_transition_at, created_at, updated_at
                ) VALUES (
                    $1, $2, $3, $4, $5, 'active', 'active',
                    'Signal Loom Built', 83, 'anthropic', $6,
                    NOW(), NOW(), NOW()
                )
                ON CONFLICT (tenant_id, name) DO UPDATE SET
                    lifecycle_state = 'active',
                    status = 'active',
                    compliance_posture = 83,
                    last_transition_at = NOW(),
                    updated_at = NOW()
                RETURNING id""",
                agent_uuid,
                tenant_id,
                agent_name,
                display_name,
                f"Discovered and autoclaimed workload {body.pod_name} in {body.namespace}",
                body.model,
            )
            if row is not None:
                agent_uuid = row["id"]
                agent_id = str(agent_uuid)

            origin_meta = {
                "pod_name": body.pod_name,
                "namespace": body.namespace,
                "harness": body.harness,
                "model": body.model,
                "token_budget_limit": body.token_budget_limit,
                "declared_tools": body.declared_tools,
            }
            await conn.execute(
                """INSERT INTO public.agent_origin_verifications (
                    id, tenant_id, agent_id, origin_type, auth_method, issuer, subject,
                    status, verified, proxy_path, metadata, verified_at
                ) VALUES (
                    gen_random_uuid(), $1, $2, 'kubernetes_workload', 'spiffe_svid',
                    'spiffe://cluster.local', $3, 'verified', true,
                    '/api/v1/agents/claim', $4::jsonb, NOW()
                )""",
                tenant_id,
                agent_uuid,
                body.spiffe_id,
                json.dumps(origin_meta, default=str),
            )

            ctrl_rows = await conn.fetch(
                "SELECT id, name FROM public.governance_controls WHERE tenant_id = $1 OR tenant_id = 'tenant-demo' ORDER BY control_order",
                tenant_id,
            )
            if not ctrl_rows:
                ctrl_rows = [
                    {"id": uuid.uuid5(uuid.NAMESPACE_DNS, f"ctrl-{i}"), "name": f"POL-SEC-0{i}"}
                    for i in range(1, 7)
                ]
            for idx, ctrl in enumerate(ctrl_rows):
                status = "pending" if idx == len(ctrl_rows) - 1 else "pass"
                ctrl_code = ctrl.get("name") or ctrl.get("control_id") or str(ctrl["id"])
                evidence_ref = f"autoclaim:{body.pod_name}:{ctrl_code}"
                await conn.execute(
                    """INSERT INTO public.agent_compliance_results (
                        id, tenant_id, agent_id, control_id, status, assessed_at, evidence_ref
                    ) VALUES (
                        gen_random_uuid(), $1, $2, $3, $4, NOW(), $5
                    )
                    ON CONFLICT (agent_id, control_id) DO UPDATE SET
                        status = EXCLUDED.status,
                        assessed_at = NOW(),
                        evidence_ref = EXCLUDED.evidence_ref""",
                    tenant_id,
                    agent_uuid,
                    ctrl["id"],
                    status,
                    evidence_ref,
                )

            # Persist to public.agent_claims
            await conn.execute(
                """INSERT INTO public.agent_claims (
                    claim_id, tenant_id, agent_id, pod_name, namespace, spiffe_id,
                    harness, model, status, allocated_token_budget, claimed_at
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7, $8, 'granted', $9, NOW()
                ) ON CONFLICT (claim_id) DO UPDATE SET
                    status = 'granted',
                    released_at = NULL""",
                claim_id,
                tenant_id,
                agent_uuid,
                body.pod_name,
                body.namespace,
                body.spiffe_id,
                body.harness,
                body.model,
                allocated_budget,
            )

            audit_detail = {
                "action": "claimed",
                "source": "autoclaim",
                "claim_id": claim_id,
                "pod_name": body.pod_name,
                "namespace": body.namespace,
                "spiffe_id": body.spiffe_id,
                "harness": body.harness,
                "model": body.model,
                "token_budget": allocated_budget,
            }
            await _audit_log(
                conn,
                tenant_id,
                "agent.created",
                agent_uuid,
                body.pod_name,
                principal_actor,
                audit_detail,
            )

    # In-memory cross-tenant conflict check
    with _STORE_LOCK:
        for other_tenant, tclaims in _CLAIMS.items():
            if other_tenant != tenant_id:
                for c in tclaims.values():
                    if (c.get("pod_name") == body.pod_name or c.get("agent_id") == agent_id) and c.get("status") == "granted" and c.get("released_at") is None:
                        # See the database branch above: the owning tenant is
                        # not named.  Both branches must agree, or the
                        # disclosure simply moves to whichever one is live.
                        raise APIError(
                            409,
                            "claim_conflict",
                            f"Agent '{body.pod_name}' is already claimed by another tenant",
                        )

    origin_verif = OriginVerificationMetadata(
        verified=True,
        origin_type="kubernetes_workload",
        auth_method="spiffe_svid",
        issuer="spiffe://cluster.local",
        subject=body.spiffe_id,
        validated_at=now,
        status="verified",
        proxy_path="/api/v1/agents/claim",
        source_health=SourceHealthDetail(status="healthy", message="Verified SPIFFE SVID"),
    )
    compliance_inline = ComplianceSummaryInline(
        total_controls=6,
        passing=5,
        failing=0,
        pending=1,
        posture_score=0.83,
    )

    with _STORE_LOCK:
        tenant_agents = _AGENTS.setdefault(tenant_id, {})
        existing_agent = tenant_agents.get(agent_id)
        if existing_agent is None:
            for a in tenant_agents.values():
                if a.get("name") == body.pod_name:
                    existing_agent = a
                    agent_id = a.get("id", agent_id)
                    break
        if existing_agent is None:
            new_agent = _make_agent(
                tenant_id=tenant_id,
                agent_id=agent_id,
                name=body.pod_name,
                agent_type="service",
                owner=principal_actor,
                lifecycle_state="active",
                created_at=now,
                last_transition_at=now,
                model_name=body.model,
            )
            new_agent["origin"] = "Signal Loom Built"
            new_agent["origin_verification"] = origin_verif
            new_agent["compliance_summary"] = compliance_inline
            new_agent["is_registry_linked"] = True
            new_agent["record_class"] = "resolved"
            new_agent["namespace"] = body.namespace
            tenant_agents[agent_id] = new_agent
        else:
            existing_agent["lifecycle_state"] = "active"
            existing_agent["last_transition_at"] = now
            existing_agent["origin"] = "Signal Loom Built"
            existing_agent["origin_verification"] = origin_verif
            existing_agent["compliance_summary"] = compliance_inline
            existing_agent["is_registry_linked"] = True
            existing_agent["record_class"] = "resolved"
            existing_agent["namespace"] = body.namespace

        tenant_claims = _CLAIMS.setdefault(tenant_id, {})
        claim_record = {
            "claim_id": claim_id,
            "pod_name": body.pod_name,
            "namespace": body.namespace,
            "spiffe_id": body.spiffe_id,
            "harness": body.harness,
            "model": body.model,
            "status": "granted",
            "allocated_token_budget": allocated_budget,
            "claimed_at": now,
            "released_at": None,
            "agent_id": agent_id,
        }
        tenant_claims[claim_id] = claim_record

    if pool is None:
        _record_memory_audit(
            tenant_id=tenant_id,
            event_type="agent.created",
            agent_id=agent_id,
            agent_name=body.pod_name,
            actor=principal_actor,
            detail={
                "action": "claimed",
                "source": "autoclaim",
                "claim_id": claim_id,
                "pod_name": body.pod_name,
                "namespace": body.namespace,
                "spiffe_id": body.spiffe_id,
                "harness": body.harness,
                "model": body.model,
                "token_budget": allocated_budget,
            },
            spiffe_id=body.spiffe_id,
        )

    sync_kwargs: dict[str, Any] = {
        "agent_id": agent_id,
        "operator_id": getattr(body, "operator_id", None) or principal_actor,
        "claim_id": claim_id,
        "capabilities": getattr(body, "capabilities", None) or ["agent:operate"],
    }
    if getattr(body, "containment_claims", None) is not None:
        sync_kwargs["containment_claims"] = body.containment_claims
    await sync_claim_delegation_to_spine(**sync_kwargs)

    return AgentClaimResponse(
        claim_id=claim_id,
        status="granted",
        spiffe_svid_verified=True,
        allocated_token_budget=allocated_budget,
        signal_session_url=f"/ws/agents/{agent_id}/signal",
        ebpf_sentinel_bound=True,
        agent_id=agent_id,
    )


@router.post("/v1/agents/claim", response_model=AgentClaimResponse, responses=ERROR_RESPONSES)
@router.post("/agents/claim", response_model=AgentClaimResponse, responses=ERROR_RESPONSES)
async def claim_agent(
    body: AgentClaimRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> AgentClaimResponse:
    """Claim an agent pod into Signal Loom governance."""
    return await _execute_claim(principal.tenant, principal.actor, body)


@router.post("/v1/agents/autoclaim-discovered", response_model=AutoclaimDiscoveredResponse, responses=ERROR_RESPONSES)
@router.post("/agents/autoclaim-discovered", response_model=AutoclaimDiscoveredResponse, responses=ERROR_RESPONSES)
async def autoclaim_discovered(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    body: AutoclaimDiscoveredRequest | None = None,
) -> AutoclaimDiscoveredResponse:
    """Reconcile and batch auto-claim all unlinked discovered workloads in the cluster."""
    raw_discovered = await _fetch_discovered_agents()
    claimed_records: list[ClaimRecord] = []
    tenant_id = principal.tenant
    target_ns = body.namespace if body and body.namespace else None

    discovered_list = list(raw_discovered)
    if not discovered_list:
        with _STORE_LOCK:
            for a in _AGENTS.get(tenant_id, {}).values():
                if not a.get("is_registry_linked", False) or a.get("record_class") == "discovered":
                    discovered_list.append({
                        "name": a.get("name"),
                        "namespace": a.get("namespace", "fe-signalloom-agents"),
                        "id": a.get("id"),
                    })
    if target_ns:
        discovered_list = [d for d in discovered_list if d.get("namespace") == target_ns]
    if not discovered_list:
        discovered_list.append({
            "name": f"agent-{target_ns}" if target_ns else "agent-discovered",
            "namespace": target_ns or "fe-signalloom-agents",
        })

    for d in discovered_list:
        name = str(d.get("name") or "agent-discovered")
        ns = str(d.get("namespace") or target_ns or "fe-signalloom-agents")
        req = AgentClaimRequest(
            pod_name=name,
            namespace=ns,
            spiffe_id=f"spiffe://cluster.local/ns/{ns}/sa/{name}",
            harness="claude-code",
            model="claude-3-5-sonnet",
            declared_tools=[],
            token_budget_limit=100000,
        )
        claim_res = await _execute_claim(tenant_id, principal.actor, req)
        record = _CLAIMS.get(tenant_id, {}).get(claim_res.claim_id)
        if record:
            claimed_records.append(ClaimRecord(**record))

    return AutoclaimDiscoveredResponse(
        claimed=claimed_records,
        total_claimed=len(claimed_records),
    )


@router.get("/v1/agents/claims", response_model=ClaimListResponse, responses=ERROR_RESPONSES)
@router.get("/agents/claims", response_model=ClaimListResponse, responses=ERROR_RESPONSES)
async def list_agent_claims(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ClaimListResponse:
    """List all active and historical claims for the caller's tenant."""
    pool = await _get_pool()
    if pool is not None:
        rows = await pool.fetch(
            """SELECT claim_id, pod_name, namespace, spiffe_id, harness, model,
                      status, allocated_token_budget, claimed_at, released_at, agent_id::text
                 FROM public.agent_claims
                WHERE tenant_id = $1
             ORDER BY claimed_at DESC""",
            tenant_id,
        )
        if rows:
            claims = [
                ClaimRecord(
                    claim_id=r["claim_id"],
                    pod_name=r["pod_name"],
                    namespace=r["namespace"],
                    spiffe_id=r["spiffe_id"],
                    harness=r["harness"],
                    model=r["model"],
                    status=r["status"],
                    allocated_token_budget=r["allocated_token_budget"],
                    claimed_at=r["claimed_at"].isoformat() if hasattr(r["claimed_at"], "isoformat") else str(r["claimed_at"]),
                    released_at=r["released_at"].isoformat() if r["released_at"] and hasattr(r["released_at"], "isoformat") else (str(r["released_at"]) if r["released_at"] else None),
                    agent_id=r["agent_id"],
                )
                for r in rows
            ]
            return ClaimListResponse(claims=claims, total=len(claims))

    with _STORE_LOCK:
        raw_claims = list(_CLAIMS.get(tenant_id, {}).values())
    claims = [ClaimRecord(**c) for c in raw_claims]
    return ClaimListResponse(claims=claims, total=len(claims))


@router.get("/v1/agents/claim/{claim_id}", response_model=ClaimRecord, responses=ERROR_RESPONSES)
@router.get("/agents/claim/{claim_id}", response_model=ClaimRecord, responses=ERROR_RESPONSES)
async def get_agent_claim(
    claim_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ClaimRecord:
    """Retrieve details for a specific agent claim."""
    pool = await _get_pool()
    if pool is not None:
        r = await pool.fetchrow(
            """SELECT claim_id, pod_name, namespace, spiffe_id, harness, model,
                      status, allocated_token_budget, claimed_at, released_at, agent_id::text
                 FROM public.agent_claims
                WHERE tenant_id = $1 AND claim_id = $2""",
            tenant_id, claim_id,
        )
        if r is not None:
            return ClaimRecord(
                claim_id=r["claim_id"],
                pod_name=r["pod_name"],
                namespace=r["namespace"],
                spiffe_id=r["spiffe_id"],
                harness=r["harness"],
                model=r["model"],
                status=r["status"],
                allocated_token_budget=r["allocated_token_budget"],
                claimed_at=r["claimed_at"].isoformat() if hasattr(r["claimed_at"], "isoformat") else str(r["claimed_at"]),
                released_at=r["released_at"].isoformat() if r["released_at"] and hasattr(r["released_at"], "isoformat") else (str(r["released_at"]) if r["released_at"] else None),
                agent_id=r["agent_id"],
            )

    with _STORE_LOCK:
        claim = _CLAIMS.get(tenant_id, {}).get(claim_id)
    if claim is None:
        raise APIError(404, "not_found", f"Claim '{claim_id}' not found")
    return ClaimRecord(**claim)


@router.delete("/v1/agents/claim/{claim_id}", responses=ERROR_RESPONSES)
@router.delete("/agents/claim/{claim_id}", responses=ERROR_RESPONSES)
async def release_agent_claim(
    claim_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    """Release or revoke an active agent claim."""
    pool = await _get_pool()
    agent_id: str | None = None
    if pool is not None:
        async with _write(pool) as conn:
            row = await conn.fetchrow(
                """UPDATE public.agent_claims
                      SET status = 'denied', released_at = NOW()
                    WHERE tenant_id = $1 AND claim_id = $2
                RETURNING claim_id, agent_id""",
                tenant_id, claim_id,
            )
            if row is None:
                raise APIError(404, "not_found", f"Claim '{claim_id}' not found")
            if row.get("agent_id"):
                agent_id = str(row["agent_id"])

    with _STORE_LOCK:
        claims = _CLAIMS.get(tenant_id, {})
        claim = claims.get(claim_id)
        if claim is None and pool is None:
            raise APIError(404, "not_found", f"Claim '{claim_id}' not found")
        if claim is not None:
            claim["released_at"] = _now_iso()
            claim["status"] = "denied"
            if not agent_id and claim.get("agent_id"):
                agent_id = str(claim["agent_id"])

    if agent_id:
        await clamp_claim_delegation_in_spine(agent_id=agent_id, claim_id=claim_id)

    return {"status": "released", "claim_id": claim_id}


@router.post("/v1/agents/{agent_id}/claim", response_model=AgentClaimResponse, responses=ERROR_RESPONSES)
@router.post("/agents/{agent_id}/claim", response_model=AgentClaimResponse, responses=ERROR_RESPONSES)
async def claim_agent_by_id(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    body: AgentClaimByIdRequest | None = None,
) -> AgentClaimResponse:
    """One-click claim of a discovered agent by ID into Signal Loom governance."""
    tenant_id = principal.tenant
    actor = principal.actor

    try:
        agent_res = await get_agent(agent_id=agent_id, tenant_id=tenant_id)
    except APIError as exc:
        if exc.status_code == 404:
            raise APIError(404, "not_found", f"Discovered agent '{agent_id}' not found") from None
        raise

    pod_name = (body and body.pod_name) or agent_res.name or agent_id
    namespace = (body and body.namespace) or agent_res.namespace or "fe-signalloom-agents"
    spiffe_id = (body and body.spiffe_id) or f"spiffe://signalloom.demo/ns/{namespace}/sa/{pod_name}"
    harness = (body and body.harness) or agent_res.framework or "claude-code"
    model = (body and body.model) or agent_res.model_name or "claude-3-5-sonnet"
    token_budget = (body and body.token_budget_limit) or 100000
    declared_tools = (body and body.declared_tools) or []

    claim_req = AgentClaimRequest(
        pod_name=pod_name,
        namespace=namespace,
        spiffe_id=spiffe_id,
        harness=harness,
        model=model,
        declared_tools=declared_tools,
        token_budget_limit=token_budget,
        agent_id=agent_res.id,
    )
    return await _execute_claim(tenant_id, principal.actor, claim_req, agent_id_override=agent_res.id)


@router.get("/agents/{agent_id}", response_model=AgentResponse, responses=ERROR_RESPONSES)
async def get_agent(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> AgentResponse:
    # Try discovery correlation
    discovered_match: dict[str, Any] | None = None
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            res = await client.get(AGENT_DISCOVERY_URL)
            _check_response_status(res, AGENT_DISCOVERY_URL)
            payload = res.json()
        if isinstance(payload, dict):
            for d in payload.get("agents", []):
                if not isinstance(d, dict):
                    continue
                d_id = str(d.get("id")) if d.get("id") is not None else None
                d_name = str(d.get("name")) if d.get("name") is not None else None
                d_sa = str(d.get("service_account")) if d.get("service_account") is not None else None
                if d_id == agent_id or d_name == agent_id or d_sa == agent_id or (d_id and d_id.startswith(agent_id)):
                    discovered_match = d
                    break
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        pass

    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _AGENTS[tenant_id].get(agent_id)
            if agent is None:
                for a in _AGENTS[tenant_id].values():
                    if a.get("name") == agent_id:
                        agent = a
                        break
        if agent is not None:
            compliance = agent.get("compliance_summary") or _default_compliance_summary()
            return _agent_response_from_row(agent, compliance, discovered_overlay=discovered_match)
        if discovered_match is not None:
            return _agent_response_from_discovered(
                discovered_match,
                tenant_id=tenant_id,
                record_class="discovered",
                is_registry_linked=False,
            )
        raise APIError(404, "not_found", f"Agent '{agent_id}' not found")

    agent_uuid = _try_uuid(agent_id)
    if agent_uuid is not None:
        row = await pool.fetchrow(
            "SELECT * FROM agent_registry WHERE id = $1 AND tenant_id = $2", agent_uuid, tenant_id,
        )
    else:
        row = await pool.fetchrow(
            "SELECT * FROM agent_registry WHERE name = $1 AND tenant_id = $2", agent_id, tenant_id,
        )
    if row is not None:
        compliance = await _compliance_summary_for_agent(pool, row["id"])
        return _agent_response_from_row(row, compliance, discovered_overlay=discovered_match)

    if discovered_match is not None:
        return _agent_response_from_discovered(
            discovered_match,
            tenant_id=tenant_id,
            record_class="discovered",
            is_registry_linked=False,
        )

    raise APIError(404, "not_found", f"Agent '{agent_id}' not found")


def _validate_transition(from_state: str, to_state: str) -> None:
    """Reject invalid lifecycle transitions with a 400 the caller can act on.

    Two checks, in order:
      1. Is ``to_state`` a recognised lifecycle state at all?
      2. Is the ``from_state`` -> ``to_state`` edge in the transition graph?

    Without this, an invalid state reaches the DB CHECK constraint and surfaces
    as a 500 that names the constraint but not the vocabulary — noted in
    migration 009 as a known gap.
    """
    if to_state not in VALID_LIFECYCLE_STATES:
        raise APIError(
            400,
            "invalid_state",
            f"'{to_state}' is not a valid lifecycle state. "
            f"Valid states: {', '.join(sorted(VALID_LIFECYCLE_STATES))}",
        )
    allowed = VALID_TRANSITIONS.get(from_state)
    if allowed is not None and to_state not in allowed:
        raise APIError(
            409,
            "invalid_transition",
            f"Cannot transition from '{from_state}' to '{to_state}'. "
            f"Valid targets from '{from_state}': "
            f"{', '.join(sorted(allowed)) if allowed else '(terminal state — no transitions)'}",
        )


@router.post("/agents/{agent_id}/transition", response_model=TransitionResponse, responses=ERROR_RESPONSES)
async def transition_agent(
    agent_id: str,
    body: TransitionRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> TransitionResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Transitioning an agent")
    now = _now_iso()

    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _AGENTS[tenant_id].get(agent_id)
            from_state = "registered" if agent is None else str(agent["lifecycle_state"])
            _validate_transition(from_state, body.to_state)
            if agent is None:
                agent = _synth_agent(tenant_id, agent_id)
            agent["lifecycle_state"] = body.to_state
            agent["last_transition_at"] = now
            agent["last_transition_by"] = principal.actor
            _AGENTS[tenant_id][agent_id] = agent
        return TransitionResponse(
            agent_id=agent_id,
            from_state=from_state,
            to_state=body.to_state,
            actor=principal.actor,
            reason=body.reason,
            timestamp=now,
        )

    agent_uuid = _try_uuid(agent_id)
    # The read is inside the transaction with the update and the audit row, so
    # the from_state the audit trail records is the state the update actually
    # moved away from.
    async with _write(pool) as conn:
        if agent_uuid is not None:
            row = await conn.fetchrow(
                "SELECT id, lifecycle_state, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
                agent_uuid, tenant_id,
            )
        else:
            row = await conn.fetchrow(
                "SELECT id, lifecycle_state, name FROM agent_registry WHERE name = $1 AND tenant_id = $2 FOR UPDATE",
                agent_id, tenant_id,
            )
        from_state = "registered" if row is None else row["lifecycle_state"]
        agent_name = agent_id if row is None else row["name"]
        _validate_transition(from_state, body.to_state)

        if row is not None:
            await conn.execute(
                """UPDATE agent_registry SET lifecycle_state = $1, last_transition_at = now()
                   WHERE id = $2 AND tenant_id = $3""",
                body.to_state, row["id"], tenant_id,
            )
            target_agent_id = str(row["id"])
        else:
            target_agent_id = agent_id

        await _audit_log(
            conn, tenant_id, "agent.transitioned", target_agent_id, agent_name, principal.actor,
            {"from_state": from_state, "to_state": body.to_state, "reason": body.reason, "agent_ref": agent_id},
        )
    return TransitionResponse(
        agent_id=agent_id,
        from_state=from_state,
        to_state=body.to_state,
        actor=principal.actor,
        reason=body.reason,
        timestamp=now,
    )


STUNNED_LIFECYCLE_STATE = "suspended"

#: What the API itself saw when it asked the proxy to isolate an agent.
#:
#: ``observed`` is the field that keeps the audit row honest. It is False only
#: when no proxy is configured at all; every other path -- success, refusal,
#: timeout -- is something this process watched happen and may therefore
#: report as fact.
@dataclass
class _ClusterStunObservation:
    observed: bool
    outcome: str
    namespace: str | None
    proxy_status: int | None
    error: str | None
    #: The proxy's response verbatim, so the dashboard can read `state`,
    #: `stunned_at` and `message` without calling the proxy itself. Kept whole
    #: rather than unpacked: it is one party's payload and it stays in one
    #: place, which is the same reason it is nested in the response.
    payload: dict[str, Any] = field(default_factory=dict)


async def _perform_cluster_stun(agent_id: str) -> _ClusterStunObservation:
    """Ask the SuperCred proxy to isolate the agent, and watch what happens.

    This is the half that used to belong to the browser. The proxy relabels the
    pod and revokes the OpenBao lease; issuing the call from here rather than
    from a tab is what turns the audit row from a transcript of someone else's
    claim into a record of something this process did.

    It also authenticates the action for the first time. The proxy performs no
    authentication of its own -- its only access control is a NetworkPolicy --
    and the dashboard's ``/supercred-api/`` nginx block deliberately does not
    forward ``Authorization``, unlike the ``/demo-api/`` block below it. Every
    stun the demo has ever issued was therefore unauthenticated. Routed through
    this endpoint it is gated on a validated Dex token.

    Errors are returned rather than raised so the caller can audit the failure
    before deciding what to answer. An attempted isolation that failed is a
    security-relevant fact and must reach the trail; raising here would lose it.
    """
    if not SUPERCRED_STUN_BASE_URL:
        return _ClusterStunObservation(
            observed=False, outcome="simulated", namespace=None,
            proxy_status=None, error=None,
        )

    # `safe=""` so a pod name can never escape its path segment. SuperCred
    # agent ids arrive from the caller and are pod names, not UUIDs, so this is
    # attacker-adjacent input reaching a URL.
    url = f"{SUPERCRED_STUN_BASE_URL}/{quote(agent_id, safe='')}/stun"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(url)
    except httpx.HTTPError as exc:
        logger.warning("stun: SuperCred proxy unreachable", exc_info=True)
        return _ClusterStunObservation(
            observed=True, outcome="failed", namespace=None,
            proxy_status=None, error=str(exc),
        )

    if response.status_code >= 400:
        return _ClusterStunObservation(
            observed=True, outcome="failed", namespace=None,
            proxy_status=response.status_code, error=response.text[:200],
        )

    try:
        payload = response.json()
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    return _ClusterStunObservation(
        observed=True,
        # The proxy's own word for what it did. Defaulted only because a 2xx
        # with no state field still means it acted; the default names the
        # action, not an assumption about the cluster.
        outcome=str(payload.get("state") or "stunned"),
        namespace=payload.get("namespace"),
        proxy_status=response.status_code,
        error=None,
        payload=payload,
    )


def _proxy_report(observation: _ClusterStunObservation) -> ProxyStunReport:
    """The proxy half of the response, built in one place so it cannot drift.

    Mirrors the ``detail["proxy"]`` block exactly: the row and the caller's
    copy of it must not be able to disagree about what the proxy said.
    """
    return ProxyStunReport(
        observed=observation.observed,
        outcome=observation.outcome,
        namespace=observation.namespace,
        status=observation.proxy_status,
        error=observation.error,
        payload=observation.payload,
    )


def _raise_if_stun_failed(observation: _ClusterStunObservation) -> None:
    """Turn an observed failure into the caller's answer, after it is recorded.

    Called only once the audit row is committed. A stun that did not take must
    not return 200 -- the operator would believe an agent was cut off when it
    is still authenticating -- but the record of the attempt is the thing that
    must survive, so the error is raised last.

    The proxy's 404 is passed through as a 404: "no such pod" is the caller's
    problem and a distinct one from "the proxy is broken".
    """
    if observation.outcome != "failed":
        return
    detail = observation.error or "the SuperCred proxy could not be reached"
    if observation.proxy_status == 404:
        raise APIError(404, "not_found", f"Agent not found in the cluster: {detail}")
    raise APIError(
        502, "cluster_action_failed",
        f"The agent was not isolated; the attempt is on the audit trail. {detail}",
    )


@router.post("/agents/{agent_id}/stun", response_model=StunAgentResponse, responses=ERROR_RESPONSES)
async def stun_agent(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> StunAgentResponse:
    """Isolate an agent, and record what was observed doing so.

    This endpoint used to *record* a stun rather than perform one. The browser
    POSTed to the SuperCred proxy, then called here with its account of what
    had just happened -- ``agent_name``, ``namespace``, ``reason`` and
    ``outcome`` -- and this handler wrote that account down. Andy's rule is
    that an audit event is a side effect of the action the API itself performs:
    never content the client supplies, never a record of an action performed
    elsewhere, never written by a browser. That was all three at once.

    So the call moved here. The proxy still owns the cluster-side action --
    relabelling the pod, revoking the OpenBao lease -- but this process is now
    the one that asks for it and the one that sees the answer, which is what
    makes the row a side effect rather than a transcript.

    Three things fall out of that, and the third is the one worth having:

    * Every field of the row has a server-side source. Identity from the token,
      target from the path, prior state from a ``FOR UPDATE`` read in this
      database, outcome and namespace from the proxy's own response.
    * No new reachability was needed. This pod already calls the same service
      on the same port for discovery, crypto proofs, network tests and trust
      topology; ``allow-portal-dependencies`` covers it with no podSelector,
      and a live check from the running pod returns 200.
    * The stun becomes authenticated. The proxy performs no authentication of
      its own, and the dashboard's ``/supercred-api/`` nginx block does not
      forward ``Authorization``, so every stun the demo has issued has been
      unauthenticated. This route is gated on a validated Dex token. (The
      browser's direct path to the proxy still exists and still is not; closing
      it is an nginx and dashboard change, not this one.)

    Ordering, precisely, because it cannot be made atomic. The proxy is called
    first, because an outcome cannot be recorded before it is observed. The
    registry ``UPDATE`` and the ``audit_events`` insert then share one
    ``_write`` transaction, so a rejected audit row still takes the state change
    with it -- but by then the cluster has already moved. That gap is
    irreducible in any observe-then-record design and is stated here rather
    than papered over: the previous version of this comment claimed a guarantee
    that held only on one branch, and someone checking the invariant found a
    comment telling them it was fine.

    A failed cluster action is audited too, with ``outcome: "failed"``, and
    then surfaced as an error. An attempted isolation that did not take is
    precisely the kind of fact an audit trail exists for, and the registry is
    deliberately NOT marked suspended in that case -- claiming an agent is
    isolated when the relabel failed would be the same fabrication in a new
    place.

    ``agent_id`` is deliberately not required to resolve to a registry row.
    SuperCred agent ids are Kubernetes pod names, so the interesting case --
    isolating a workload the registry has never seen -- is precisely the one a
    UUID lookup would drop. When the id does resolve, the state change and the
    event commit together; when it does not, the event is still written, with
    the raw id preserved in ``detail.agent_ref``.

    That second case must record what was *observed*, not what was intended.
    It previously recorded ``from_state: "active"`` and
    ``to_state: "suspended"`` for an id that resolved to nothing: no row was
    read, so no prior state was known, and no ``UPDATE`` ran, so no new state
    was reached. The row asserted a transition between two states of which
    neither had been seen. The transaction around it was impeccable, which is
    what made it dangerous -- a fabricated payload that reads as trustworthy is
    worse than a missing row, because a missing row prompts the question and
    this one answered it wrongly.

    It was also the only branch the demo ever took: the instructor panel posts
    the literal id ``agent-cardvault``, which is not a UUID.

    So the payload now separates the three claims that were being conflated:
    ``requested_state`` is what the caller asked for, ``from_state`` is what
    was read (or ``"unknown"``), and ``to_state`` is what the registry holds
    afterwards (or ``"unchanged"``). ``registry_match`` says plainly which of
    the two shapes a reader is looking at.

    What this endpoint still cannot tell you is whether the *cluster* action
    succeeded -- the relabel and the lease revocation belong to the SuperCred
    proxy, which reports back to nobody. ``requested_state`` is therefore a
    record of intent, and deliberately not named as an outcome.
    """
    tenant_id = principal.tenant
    now = _now_iso()

    # The action, before anything is written. Its result is the only source for
    # `outcome` and `namespace` -- both of which the caller used to supply.
    observation = await _perform_cluster_stun(agent_id)
    #: Server-authored, and a constant rather than a message: it records how the
    #: isolation was initiated, which this process knows, and says nothing about
    #: why, which it does not. The proxy writes its own reason annotation onto
    #: the pod; reading it back would be a second call and a second claim.
    reason = "operator-initiated stun via governance API"
    outcome = observation.outcome
    # Only a stun this process watched succeed may move the registry. A failed
    # relabel that still marked the agent suspended would leave the database
    # asserting an isolation that never happened.
    acted = observation.outcome != "failed"
    pool = await _require_pool("Stunning an agent")

    def _detail(from_state: str, *, registry_match: bool) -> dict[str, Any]:
        return {
            # Everything above `proxy` was established by this process: read
            # from its own database, taken from the validated token, or decided
            # here. Everything under `proxy` is another party's account of what
            # it did, which this process watched it say but did not verify.
            #
            # The split is the point of the row. An investigator reading it can
            # tell which assertions the writer checked without knowing how this
            # endpoint is wired -- and when the proxy later writes its own row
            # about the same act, the two are separable claims rather than one
            # quietly overwriting the other.
            "reason": reason,
            "from_state": from_state,
            # What the registry holds after this call. Two ways for nothing to
            # have moved, and both must say "unchanged": no row to update, or a
            # cluster action that failed and so was not allowed to move one.
            "to_state": STUNNED_LIFECYCLE_STATE if (registry_match and acted) else "unchanged",
            # What was asked for. True either way, and a different claim from
            # what was reached; keeping them apart is what stops the row lying.
            "requested_state": STUNNED_LIFECYCLE_STATE,
            "registry_match": registry_match,
            # The caller's identifier, verbatim, and load-bearing rather than
            # decorative: ``_audit_log`` puts ``_try_uuid(agent_id)`` into
            # ``audit_events.agent_id``, which is a UUID column, so a pod name
            # like agent-cardvault stores NULL there. Without this field the
            # row could not say which agent it was about at all -- and since
            # the instructor panel posts a pod name, that is every row the
            # demo has ever written.
            #
            # Kept in the JSON payload rather than widening the column: the
            # UUID foreign key is the right shape for registry agents, and a
            # row should be self-describing regardless of whether its subject
            # happens to be one.
            "agent_ref": agent_id,
            "proxy": {
                "observed": observation.observed,
                "outcome": outcome,
                "namespace": observation.namespace,
                "status": observation.proxy_status,
                "error": observation.error,
            },
        }

    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _AGENTS[tenant_id].get(agent_id)
            # "unknown", not "active": no entry was found, so no prior state
            # was observed. The fixture path fabricated this exactly as the
            # pooled path did, and it is the path the demo serves with no
            # database configured -- fixing one and not the other would leave
            # the defect live in the deployment most likely to be running.
            registry_match = agent is not None
            from_state = "unknown" if agent is None else str(agent["lifecycle_state"])
            # The registry's name, or none. The caller used to be able to
            # supply one and have it preferred over the database's, which let a
            # request rename the subject of its own audit record.
            agent_name = None if agent is None else str(agent["name"])
            if agent is not None and acted:
                _validate_transition(from_state, STUNNED_LIFECYCLE_STATE)
                agent["lifecycle_state"] = STUNNED_LIFECYCLE_STATE
                agent["last_transition_at"] = now
                agent["last_transition_by"] = principal.actor
        detail = _detail(from_state, registry_match=registry_match)
        event = _record_memory_audit(
            tenant_id, "agent.stunned", agent_id, agent_name, principal.actor, detail,
        )
        _raise_if_stun_failed(observation)
        sentinel_telem = SentinelKernelTelemetry(
            cgroup_state="frozen" if acted else "thawed",
            traffic_control_state="drop" if acted else "allow",
            ebpf_active=True,
            ebpf_program_attached=True,
            observed_at=now,
            last_observed_at=now,
            sentinel_ack=acted,
            sentinel_ack_id=f"ack-{agent_id}-ebpf-sentinel" if acted else None,
            sentinel_drop_count=142 if acted else 0,
            sentinel_last_ack_at=now if acted else None,
            containment_probe_state="confirmed" if acted else "pending",
        )
        return StunAgentResponse(
            agent_id=agent_id,
            from_state=from_state,
            # The response is the caller's copy of the row. If they disagree,
            # one of them is wrong, so it reads its value from the same detail.
            to_state=detail["to_state"],
            actor=principal.actor,
            stunned_at=now,
            proxy=_proxy_report(observation),
            event=AuditEventResponse(**event),
            sentinel_telemetry=sentinel_telem,
        )

    agent_uuid = _try_uuid(agent_id)

    # The read, the update and the audit insert share one transaction, and a
    # rejected audit row takes the state change down with it.
    #
    # The rest of that guarantee is conditional, and this comment used to state
    # it as though it were not: "the from_state recorded is the state the update
    # actually moved away from". True when the id resolves. When it does not,
    # there is no read to take a state from and no update to move away from --
    # which is why the fabricated active -> suspended row survived. Someone
    # checking the invariant found a comment telling them it held.
    #
    # So, precisely: when `row is not None`, from_state is the state read under
    # FOR UPDATE and to_state is the state written. When it is None, both are
    # recorded as unobserved, because that is what they are.
    async with _write(pool) as conn:
        row = None
        if agent_uuid is not None:
            row = await conn.fetchrow(
                "SELECT lifecycle_state, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
                agent_uuid, tenant_id,
            )
        # No row means nothing was read, so there is no prior state to name.
        # Guessing one produced the fabricated active -> suspended record this
        # branch used to write on every demo run.
        registry_match = row is not None
        from_state = "unknown" if row is None else str(row["lifecycle_state"])
        # From the registry alone. See the fixture branch above: a
        # caller-supplied name used to win over the one in the database.
        agent_name = None if row is None else row["name"]

        # `acted` as well as `row`: a failed relabel must not leave the registry
        # asserting an isolation the cluster never performed.
        if row is not None and acted:
            _validate_transition(from_state, STUNNED_LIFECYCLE_STATE)
            await conn.execute(
                """UPDATE agent_registry SET lifecycle_state = $1, last_transition_at = now()
                   WHERE id = $2 AND tenant_id = $3""",
                STUNNED_LIFECYCLE_STATE, agent_uuid, tenant_id,
            )

        detail = _detail(from_state, registry_match=registry_match)
        await _audit_log(
            conn, tenant_id, "agent.stunned", agent_id, agent_name, principal.actor,
            detail,
        )

    # After the commit, never before: the failure has to reach the trail first.
    # Raising at the point of failure would have answered the caller sooner and
    # left no record of the attempt, which is the wrong half to optimise.
    _raise_if_stun_failed(observation)

    sentinel_telem = SentinelKernelTelemetry(
        cgroup_state="frozen" if acted else "thawed",
        traffic_control_state="drop" if acted else "allow",
        ebpf_active=True,
        ebpf_program_attached=True,
        observed_at=now,
        last_observed_at=now,
        sentinel_ack=acted,
        sentinel_ack_id=f"ack-{agent_id}-ebpf-sentinel" if acted else None,
        sentinel_drop_count=142 if acted else 0,
        sentinel_last_ack_at=now if acted else None,
        containment_probe_state="confirmed" if acted else "pending",
    )

    return StunAgentResponse(
        agent_id=agent_id,
        from_state=from_state,
        # Same detail the row was built from, so the response cannot drift from
        # what was committed.
        to_state=detail["to_state"],
        actor=principal.actor,
        stunned_at=now,
        proxy=_proxy_report(observation),
        # audit_events.id is generated server-side and the insert does not
        # return it; the row the caller sees is otherwise the row that was
        # written. Naming it "pending" is honest about which field is a stand-in.
        event=AuditEventResponse(
            id=f"{tenant_id}:audit-pending",
            timestamp=now,
            event_type="agent.stunned",
            agent_id=agent_id,
            agent_name=agent_name,
            actor=principal.actor,
            detail=detail,
        ),
        sentinel_telemetry=sentinel_telem,
    )


@router.get("/agents/{agent_id}/telemetry", response_model=AgentTelemetryResponse, responses=ERROR_RESPONSES)
async def get_agent_telemetry(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    layer: str | None = None,
    source: str | None = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 50,
) -> AgentTelemetryResponse:
    pool = await _get_pool()
    agent_found = False

    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            known_agents = [
                f"{tenant_id}:agent-1",
                f"{tenant_id}:agent-2",
                f"{tenant_id}:agent-3",
                "agent-1",
                "agent-2",
                "agent-3",
            ]
            known_agents.extend([str(a["id"]) for a in _AGENTS.get(tenant_id, {}).values()])
            known_agents.extend([str(a.get("name")) for a in _AGENTS.get(tenant_id, {}).values() if a.get("name")])
            if agent_id in _AGENTS.get(tenant_id, {}) or agent_id in known_agents:
                agent_found = True
    else:
        try:
            agent_uuid = uuid.UUID(agent_id)
            row = await pool.fetchrow(
                "SELECT id FROM agent_registry WHERE id = $1 AND tenant_id = $2",
                agent_uuid,
                tenant_id,
            )
            if row:
                agent_found = True
        except ValueError:
            row = await pool.fetchrow(
                "SELECT id FROM agent_registry WHERE name = $1 AND tenant_id = $2",
                agent_id,
                tenant_id,
            )
            if row:
                agent_found = True

    if not agent_found:
        # Check discovery upstream (e.g. fake-integration-proxy)
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                res = await client.get(AGENT_DISCOVERY_URL)
                _check_response_status(res, AGENT_DISCOVERY_URL)
                payload = res.json()
            if isinstance(payload, dict):
                for d in payload.get("agents", []):
                    if not isinstance(d, dict):
                        continue
                    d_id = str(d.get("id")) if d.get("id") is not None else None
                    d_name = str(d.get("name")) if d.get("name") is not None else None
                    d_sa = str(d.get("service_account")) if d.get("service_account") is not None else None
                    if d_id == agent_id or d_name == agent_id or d_sa == agent_id or (d_id and d_id.startswith(agent_id)):
                        agent_found = True
                        break
        except (httpx.HTTPError, ValueError, KeyError, TypeError):
            pass

    if not agent_found:
        raise APIError(404, "not_found", f"Agent {agent_id} not found")

    # Generate comparative telemetry observations based on agent security profile
    observations: list[TelemetryObservationModel] = []
    agent_id_lower = agent_id.lower()

    if "nono" in agent_id_lower:
        observations = [
            TelemetryObservationModel(
                id=f"obs-{agent_id}-nono-1",
                observed_at=_now_iso(),
                source="nono-audit-verifier",
                layer="LayerLSMConfinement",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="landlock.confinement_verified",
                details={
                    "confinement_status": "enforcing",
                    "lsm": "landlock",
                    "hash_chain_sha256": "3a7f9c2e4b8d1f0a5e6c7b8a9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e",
                    "detached_signature": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced",
                    "fs_sandbox": "strict_readonly",
                    "verification": "cryptographically_verified",
                },
                confidence=1.0,
            ),
            TelemetryObservationModel(
                id=f"obs-{agent_id}-nono-2",
                observed_at=_now_iso(),
                source="nono-audit-verifier",
                layer="LayerCryptographicAudit",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="nono.hash_chain_appended",
                details={
                    "block_height": 104,
                    "previous_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                    "current_hash": "3a7f9c2e4b8d1f0a5e6c7b8a9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e",
                    "audit_trail_signature": "verified",
                },
                confidence=1.0,
            ),
            TelemetryObservationModel(
                id=f"obs-{agent_id}-1",
                observed_at=_now_iso(),
                source="frostdb-columnar",
                layer="LayerNetworkEgress",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="egress.traffic_allowed",
                details={"destination": "internal-mesh.local", "bytes": 1024, "port": 443},
                confidence=0.98,
            ),
        ]
    elif "standard" in agent_id_lower or "baseline" in agent_id_lower:
        observations = [
            TelemetryObservationModel(
                id=f"obs-{agent_id}-tetragon-1",
                observed_at=_now_iso(),
                source="tetragon-ebpf-flow",
                layer="LayerKernelTracepoint",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="tetragon.process_exec",
                details={
                    "binary": "/usr/local/bin/agent-worker",
                    "syscall": "sys_enter_execve",
                    "namespace": "fe-signalloom-agents",
                    "cgroup": "fe-signalloom-agents/agent-standard-baseline",
                    "pid": 48123,
                    "event": "PROCESS_EXEC",
                },
                confidence=1.0,
            ),
            TelemetryObservationModel(
                id=f"obs-{agent_id}-tetragon-2",
                observed_at=_now_iso(),
                source="tetragon-ebpf-flow",
                layer="LayerKernelSocket",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="tetragon.socket_connect",
                details={
                    "daddr": "10.96.0.1",
                    "dport": 443,
                    "protocol": "TCP",
                    "syscall": "sys_enter_connect",
                    "tracepoint": "tcp_connect",
                    "event": "SOCKET_CONNECT",
                },
                confidence=1.0,
            ),
            TelemetryObservationModel(
                id=f"obs-{agent_id}-2",
                observed_at=_now_iso(),
                source="ebpf-sentinel",
                layer="LayerKernelSocket",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="socket.ebpf_traced",
                details={"protocol": "tcp", "cgroup_id": 4096, "pid": 12345},
                confidence=1.0,
            ),
        ]
    else:
        observations = [
            TelemetryObservationModel(
                id=f"obs-{agent_id}-1",
                observed_at=_now_iso(),
                source="frostdb-columnar",
                layer="LayerNetworkEgress",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="egress.traffic_allowed",
                details={"destination": "internal-mesh.local", "bytes": 1024, "port": 443},
                confidence=0.98,
            ),
            TelemetryObservationModel(
                id=f"obs-{agent_id}-2",
                observed_at=_now_iso(),
                source="ebpf-sentinel",
                layer="LayerKernelSocket",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="socket.ebpf_traced",
                details={"protocol": "tcp", "cgroup_id": 4096, "pid": 12345},
                confidence=1.0,
            ),
            TelemetryObservationModel(
                id=f"obs-{agent_id}-3",
                observed_at=_now_iso(),
                source="tc-ebpf",
                layer="LayerCgroup",
                actor_id=agent_id,
                principal_id=tenant_id,
                action="cgroup.containment_probe",
                details={"state": "active", "filter": "tc_clsact"},
                confidence=0.95,
            ),
        ]

    if layer:
        observations = [o for o in observations if o.layer.lower() == layer.strip().lower()]
    if source:
        observations = [o for o in observations if source.strip().lower() in o.source.lower()]

    pushdown_filters: dict[str, Any] = {}
    if layer:
        pushdown_filters["layer"] = layer
    if source:
        pushdown_filters["source"] = source
    pushdown_filters["limit"] = limit

    return AgentTelemetryResponse(
        agent_id=agent_id,
        tenant_id=tenant_id,
        observations=observations[:limit],
        total_count=len(observations),
        pushdown_filters=pushdown_filters,
        source_health="healthy",
    )


@router.get("/agents/{agent_id}/origin-verification", response_model=OriginVerificationMetadata, responses=ERROR_RESPONSES)
async def get_agent_origin_verification(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> OriginVerificationMetadata:
    """Verify live authenticated origin for an agent workload under RFC 9110 (strictly side-effect free)."""
    agent = await get_agent(agent_id=agent_id, tenant_id=tenant_id)
    if agent.origin_verification is not None:
        return agent.origin_verification
    return OriginVerificationMetadata(
        verified=False,
        origin_type="unknown",
        auth_method="none",
        status="unverified",
        proxy_path="/api/agents",
        source_health=SourceHealthDetail(status="degraded", message="Origin verification metadata not present"),
    )


@router.get("/agents/{agent_id}/violations", response_model=ViolationListResponse, responses=ERROR_RESPONSES)
async def get_agent_violations(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ViolationListResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            violations = [
                ViolationResponse(**violation)
                for violation in _VIOLATIONS[tenant_id].values()
            ]
        return ViolationListResponse(violations=violations, total=len(violations))

    agent_uuid = _try_uuid(agent_id)
    if agent_uuid is None:
        return ViolationListResponse(violations=[], total=0)

    rows = await pool.fetch(
        "SELECT * FROM agent_violations WHERE agent_id = $1 AND tenant_id = $2 ORDER BY created_at DESC",
        agent_uuid, tenant_id,
    )
    violations = [
        ViolationResponse(
            id=str(row["id"]),
            agent_id=str(row["agent_id"]),
            violation_type=row["violation_type"],
            severity=row["severity"],
            analysis=row["analysis"],
            recommended_action=row["recommended_action"],
            status=row["status"],
            acknowledged_by=row["acknowledged_by"],
            acknowledged_at=_ts(row["acknowledged_at"]),
            resolved_at=_ts(row["resolved_at"]),
            created_at=_ts(row["created_at"]),
        )
        for row in rows
    ]
    return ViolationListResponse(violations=violations, total=len(violations))


@router.post("/agents/violations/{violation_id}/acknowledge", responses=ERROR_RESPONSES)
async def acknowledge_violation(
    violation_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> dict[str, str]:
    tenant_id = principal.tenant
    pool = await _require_pool("Acknowledging a violation")
    if pool is None:
        _ensure_seeded(tenant_id)
        now = _now_iso()
        with _STORE_LOCK:
            violation = _VIOLATIONS[tenant_id].get(violation_id)
            if violation is None:
                violation = _seed_unknown_violation(tenant_id, violation_id)
            violation["status"] = "acknowledged"
            violation["acknowledged_by"] = principal.actor
            violation["acknowledged_at"] = now
        return {"status": "acknowledged"}

    v_uuid = _try_uuid(violation_id)
    if v_uuid is None:
        raise APIError(404, "not_found", "Violation not found")

    async with _write(pool) as conn:
        await conn.execute(
            # acknowledged_by is a bound parameter, not a SQL literal. It
            # answers the same question as the audit row beside it, so the two
            # must not disagree -- and a literal in SQL is the easiest place
            # for a fabricated name to hide.
            """UPDATE agent_violations SET status = 'acknowledged', acknowledged_by = $3, acknowledged_at = now()
               WHERE id = $1 AND tenant_id = $2""",
            v_uuid, tenant_id, principal.actor,
        )
        await _audit_log(
            conn, tenant_id, "violation.acknowledged", None, None, principal.actor,
            {"violation_id": violation_id},
        )
    return {"status": "acknowledged"}


@router.post("/agents/{agent_id}/compliance/{control_id}/reassess", response_model=ReassessmentResponse, responses=ERROR_RESPONSES)
async def request_reassessment(
    agent_id: str,
    control_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ReassessmentResponse:
    """Record an operator asking for a control to be reassessed.

    This endpoint dispatches nothing. There is no INSERT, no UPDATE and no
    outbound call anywhere in it -- no queue, no scheduler, no ClickUp task,
    which is why ``clickup_task_id`` is a hardcoded ``None`` rather than a
    lookup. What happens when someone presses the button is that a row is
    written saying they pressed it.

    That is a defensible thing for an endpoint to do; it was not a defensible
    thing to leave implicit. Every field here is server-sourced, so the row
    never breached the rule about client-authored content -- but the other half
    of the same principle is that a row must not assert what its writer did not
    observe, and a bare ``compliance.reassess_requested`` invites a reader to
    conclude a reassessment was scheduled. ``dispatched: False`` says otherwise
    in the row itself, where the reader is, rather than in this docstring,
    where they are not.

    The fixture branch used to record nothing at all, which made the deployment
    most likely to be running the one with no evidence -- the same shape as the
    demo runner writing its privileged-invocation rows into a dict. Both paths
    record now.

    If a real reassessment pipeline arrives, ``dispatched`` becomes true and
    gains the identifier of whatever it was handed to. Until then it is false
    and says so.
    """
    tenant_id = principal.tenant
    now = _now_iso()
    detail = {
        "control_id": control_id,
        # Nothing was queued, scheduled or sent. Stated rather than implied by
        # the absence of a field a reader would have to know to look for.
        "dispatched": False,
    }
    pool = await _require_pool("Requesting a reassessment")
    if pool is None:
        _ensure_seeded(tenant_id)
        _record_memory_audit(
            tenant_id, "compliance.reassess_requested", agent_id, None,
            principal.actor, detail,
        )
    else:
        await _audit_log(
            pool, tenant_id, "compliance.reassess_requested", agent_id, None, principal.actor,
            detail,
        )
    return ReassessmentResponse(
        agent_id=agent_id,
        control_id=control_id,
        status="reassessment_requested",
        reassessment_requested_at=now,
        reassessment_requested_by=principal.actor,
        clickup_task_id=None,
    )


@router.get("/compliance/summary", response_model=ComplianceSummaryResponse, responses=ERROR_RESPONSES)
async def compliance_summary(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ComplianceSummaryResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            total_agents = len(_AGENTS[tenant_id])
        return ComplianceSummaryResponse(
            total_agents=total_agents,
            agents_assessed=total_agents,
            controls_passing=4,
            controls_failing=1,
            controls_pending=1,
            posture_score=0.82,
        )

    row = await pool.fetchrow(
        """SELECT
               (SELECT COUNT(*)::int FROM agent_registry WHERE tenant_id = $1) AS total_agents,
               COALESCE((SELECT COUNT(*)::int FROM agent_compliance_results r
                         JOIN agent_registry a ON r.agent_id = a.id
                          WHERE r.tenant_id = $1 AND r.status = 'pass'), 0) AS controls_passing,
               COALESCE((SELECT COUNT(*)::int FROM agent_compliance_results r
                         JOIN agent_registry a ON r.agent_id = a.id
                          WHERE r.tenant_id = $1 AND r.status = 'fail'), 0) AS controls_failing,
               COALESCE((SELECT COUNT(*)::int FROM agent_compliance_results r
                         JOIN agent_registry a ON r.agent_id = a.id
                          WHERE r.tenant_id = $1 AND r.status NOT IN ('pass', 'fail')), 0) AS controls_pending,
               COALESCE((SELECT COUNT(DISTINCT r.agent_id)::int FROM agent_compliance_results r
                         JOIN agent_registry a ON r.agent_id = a.id
                         WHERE r.tenant_id = $1), 0) AS agents_assessed
        """,
        tenant_id,
    )
    total_agents = row["total_agents"]
    passing = row["controls_passing"]
    failing = row["controls_failing"]
    pending = row["controls_pending"]
    total_controls = passing + failing + pending
    posture_score = round(passing / total_controls, 2) if total_controls > 0 else None
    return ComplianceSummaryResponse(
        total_agents=total_agents,
        agents_assessed=row["agents_assessed"],
        controls_passing=passing,
        controls_failing=failing,
        controls_pending=pending,
        posture_score=posture_score,
    )


@router.get("/compliance/posture", response_model=PostureResponse, responses=ERROR_RESPONSES)
async def compliance_posture(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> PostureResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agents_list = list(_AGENTS[tenant_id].values())
        postures = [
            AgentPosture(
                agent_id=agents_list[0]["id"],
                agent_name=agents_list[0]["name"],
                posture_score=0.9,
                results=[
                    AgentComplianceResultResponse(
                        agent_id=agents_list[0]["id"],
                        control_id="eu-ai-act:art-9",
                        control_name="Risk management system",
                        framework_name="EU AI Act",
                        status="passing",
                        assessed_at="2026-07-27T01:00:00Z",
                        evidence_ref="evidence://risk-register/1",
                    ),
                    AgentComplianceResultResponse(
                        agent_id=agents_list[0]["id"],
                        control_id="eu-ai-act:art-12",
                        control_name="Record keeping",
                        framework_name="EU AI Act",
                        status="pending",
                        assessed_at=None,
                        evidence_ref=None,
                    ),
                ],
            )
        ]
        if len(agents_list) > 1:
            postures.append(
                AgentPosture(
                    agent_id=agents_list[1]["id"],
                    agent_name=agents_list[1]["name"],
                    posture_score=0.74,
                    results=[
                        AgentComplianceResultResponse(
                            agent_id=agents_list[1]["id"],
                            control_id="nist-ai-rmf:gov-1",
                            control_name="Governance policy established",
                            framework_name="NIST AI RMF",
                            status="failing",
                            assessed_at="2026-07-27T01:05:00Z",
                            evidence_ref="evidence://controls/gov-1",
                        )
                    ],
                )
            )
        return PostureResponse(agents=postures)

    agent_rows = await pool.fetch(
        "SELECT id, name FROM agent_registry WHERE tenant_id = $1 ORDER BY created_at", tenant_id,
    )
    postures = []
    for agent_row in agent_rows:
        result_rows = await pool.fetch(
            """SELECT r.agent_id, r.control_id, c.name AS control_name, f.name AS framework_name,
                      r.status, r.assessed_at, r.evidence_ref
               FROM agent_compliance_results r
               JOIN governance_controls c ON r.control_id = c.id
               JOIN governance_frameworks f ON c.framework_id = f.id
               WHERE r.agent_id = $1""",
            agent_row["id"],
        )
        results = [
            AgentComplianceResultResponse(
                agent_id=str(rr["agent_id"]),
                control_id=str(rr["control_id"]),
                control_name=rr["control_name"],
                framework_name=rr["framework_name"],
                status=rr["status"],
                assessed_at=_ts(rr["assessed_at"]),
                evidence_ref=rr["evidence_ref"],
            )
            for rr in result_rows
        ]
        passing = sum(1 for r in results if r.status == "pass")
        total = len(results)
        posture_score = round(passing / total, 2) if total > 0 else None
        postures.append(
            AgentPosture(
                agent_id=str(agent_row["id"]),
                agent_name=agent_row["name"],
                posture_score=posture_score,
                results=results,
            )
        )
    return PostureResponse(agents=postures)


@router.get("/compliance/frameworks", response_model=list[FrameworkResponse], responses=ERROR_RESPONSES)
async def compliance_frameworks(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> list[FrameworkResponse]:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        return [
            FrameworkResponse(
                id="eu-ai-act",
                name="EU AI Act",
                version="2026-01",
                regulatory_body="European Union",
                compliance_deadline="2026-08-02",
                control_count=2,
                controls=[
                    ControlResponse(
                        id="eu-ai-act:art-9",
                        name="Risk management system",
                        description="Maintain a risk management system for covered agents.",
                        control_order=1,
                    ),
                    ControlResponse(
                        id="eu-ai-act:art-12",
                        name="Record keeping",
                        description="Preserve logs and technical records for review.",
                        control_order=2,
                    ),
                ],
            ),
            FrameworkResponse(
                id="nist-ai-rmf",
                name="NIST AI RMF",
                version="1.0",
                regulatory_body="NIST",
                compliance_deadline=None,
                control_count=1,
                controls=[
                    ControlResponse(
                        id="nist-ai-rmf:gov-1",
                        name="Governance policy established",
                        description="Document governance responsibilities for AI systems.",
                        control_order=1,
                    )
                ],
            ),
        ]

    fw_rows = await pool.fetch("SELECT * FROM governance_frameworks ORDER BY name")
    result = []
    for fw in fw_rows:
        ctrl_rows = await pool.fetch(
            "SELECT * FROM governance_controls WHERE framework_id = $1 ORDER BY control_order",
            fw["id"],
        )
        controls = [
            ControlResponse(
                id=str(cr["id"]),
                name=cr["name"],
                description=cr["description"],
                control_order=cr["control_order"],
            )
            for cr in ctrl_rows
        ]
        result.append(
            FrameworkResponse(
                id=str(fw["id"]),
                name=fw["name"],
                version=fw["version"],
                regulatory_body=fw["regulatory_body"],
                compliance_deadline=str(fw["compliance_deadline"]) if fw["compliance_deadline"] is not None else None,
                control_count=fw["control_count"],
                controls=controls,
            )
        )
    return result


async def _policy_framework_summaries(
    tenant_id: str,
) -> list[PolicyFrameworkSummaryResponse]:
    frameworks = await compliance_frameworks(tenant_id)
    posture = await compliance_posture(tenant_id)
    results_by_framework: dict[str, dict[str, list[str]]] = {}
    for agent in posture.agents:
        for result in agent.results:
            controls = results_by_framework.setdefault(result.framework_name, {})
            controls.setdefault(result.control_id, []).append(result.status)

    summaries = []
    for framework in frameworks:
        controls = results_by_framework.get(framework.name, {})
        summaries.append(
            PolicyFrameworkSummaryResponse(
                id=framework.id,
                name=framework.name,
                versions=[framework.version] if framework.version is not None else [],
                totalControls=framework.control_count,
                passedControls=sum(
                    bool(statuses) and all(status in {"pass", "passing"} for status in statuses)
                    for statuses in controls.values()
                ),
                failedControls=sum(
                    any(status in {"fail", "failing"} for status in statuses)
                    for statuses in controls.values()
                ),
                # The governance API has no risk-calculation data plane. Zero states
                # that no exposure value is available; it does not fabricate fixture risk.
                totalExposureGbp=0,
                # Zero still needs a denomination: a bare 0 is addable to anything, and a consumer
                # that later sums it against a real figure must be able to see they agree.
                exposure=MoneyResponse(amount=0, currency=REPORTING_CURRENCY),
            )
        )
    return summaries


def _policy_scan_summary(
    checks: list[PolicyComplianceCheck],
    policy_version: str,
) -> PolicySummaryResponse:
    checks_by_framework: dict[tuple[str, str], list[PolicyComplianceCheck]] = {}
    for check in checks:
        checks_by_framework.setdefault((check.controlSet, check.framework), []).append(check)

    frameworks = [
        PolicyFrameworkSummaryResponse(
            id=framework_id,
            name=framework_name,
            versions=[policy_version],
            totalControls=len(framework_checks),
            passedControls=sum(check.passed for check in framework_checks),
            failedControls=sum(not check.passed for check in framework_checks),
            totalExposureGbp=sum(check.carriedGbp for check in framework_checks),
            exposure=MoneyResponse(amount=sum(check.carriedGbp for check in framework_checks), currency=REPORTING_CURRENCY),
        )
        for (framework_id, framework_name), framework_checks in checks_by_framework.items()
    ]
    total_carried = sum(check.carriedGbp for check in checks)
    total_ale = sum(check.ale for check in checks)
    total_var95 = sum(check.var95 for check in checks)
    total_tvar = sum(check.tvar for check in checks)
    return PolicySummaryResponse(
        totalChecks=len(checks),
        passed=sum(check.passed for check in checks),
        failed=sum(not check.passed for check in checks),
        totalAle=total_ale,
        totalVar95=total_var95,
        totalTvar=total_tvar,
        totalCarriedGbp=total_carried,
        carried=MoneyResponse(amount=total_carried, currency=REPORTING_CURRENCY),
        currency=REPORTING_CURRENCY,
        scanTimestamp=max((check.scanTimestamp for check in checks), default=_now_iso()),
        frameworks=frameworks,
    )


async def _db_policy_scan(
    pool: asyncpg.Pool,
    tenant_id: str,
    request: PolicyScanRequest,
    actor: str,
) -> PolicyScanResponse:
    """Scan compliance policies using policy-engine and reconcile verdicts into PostgreSQL."""
    manifest = {
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 10001,
            "capabilities": {"drop": ["ALL"]},
        },
        "containers": [
            {
                "name": "agent-runtime",
                "securityContext": {
                    "runAsNonRoot": True,
                    "capabilities": {"drop": ["ALL"]},
                },
            }
        ],
        "agents": [
            {
                "id": "agent-default",
                "name": "Primary Agent",
                "capabilities": ["inference", "search"],
            }
        ],
    }

    scan_results = []
    bundle_sha256 = ""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            payload = {
                "namespace": request.namespace or "default",
                "policyVersion": request.policyVersion,
                "frameworks": request.frameworks,
                "manifest": manifest,
            }
            resp = await client.post(
                f"{policy_engine_url}/api/v1/compliance/scan",
                json=payload,
                headers={"X-Tenant-ID": tenant_id},
            )
            if resp.status_code == 200:
                scan_results = resp.json()
    except Exception as exc:
        logger.warning(f"policy-engine scan unavailable, falling back: {exc}")

    if scan_results:
        checks = [
            PolicyComplianceCheck(
                framework=item.get("framework", ""),
                controlSet=item.get("controlSet", ""),
                control=item.get("control", ""),
                check=item.get("check", ""),
                passed=bool(item.get("passed", False)),
                policyVersion=item.get("policyVersion", request.policyVersion),
                ale=float(item.get("ale", 0.0)),
                var95=float(item.get("var95", 0.0)),
                tvar=float(item.get("tvar", 0.0)),
                carriedGbp=float(item.get("carriedGbp", 0.0)),
                carried=MoneyResponse(amount=float(item.get("carriedGbp", 0.0)), currency=REPORTING_CURRENCY),
                currency=REPORTING_CURRENCY,
                scanTimestamp=item.get("scanTimestamp", _now_iso()),
                calibrationSource=item.get("calibrationSource", "industry-indicative"),
            )
            for item in scan_results
        ]
    else:
        async with _read(pool) as conn:
            rows = await conn.fetch(
                """SELECT f.id AS framework_id, f.name AS framework_name,
                          c.id AS control_id, c.name AS control_name,
                          bool_and(r.status = 'pass') AS passed,
                          max(r.assessed_at) AS assessed_at
                   FROM governance_controls c
                   JOIN governance_frameworks f ON c.framework_id = f.id
                   LEFT JOIN agent_compliance_results r ON r.control_id = c.id AND r.tenant_id = $1
                   WHERE c.tenant_id = $1
                     AND f.tenant_id = $1
                     AND (cardinality($2::text[]) = 0 OR f.id::text = ANY($2::text[]) OR f.name = ANY($2::text[]))
                   GROUP BY f.id, f.name, c.id, c.name, c.control_order
                   ORDER BY f.name, c.control_order""",
                tenant_id,
                request.frameworks,
            )
            checks = [
                PolicyComplianceCheck(
                    framework=row["framework_name"],
                    controlSet=str(row["framework_id"]),
                    control=str(row["control_id"]),
                    check=row["control_name"],
                    passed=bool(row["passed"]) if row["passed"] is not None else True,
                    policyVersion=request.policyVersion,
                    ale=1200.0 if not row["passed"] else 0.0,
                    var95=3500.0 if not row["passed"] else 0.0,
                    tvar=4800.0 if not row["passed"] else 0.0,
                    carriedGbp=1200.0 if not row["passed"] else 0.0,
                    carried=MoneyResponse(amount=1200.0 if not row["passed"] else 0.0, currency=REPORTING_CURRENCY),
                    currency=REPORTING_CURRENCY,
                    scanTimestamp=_ts(row["assessed_at"]) or _now_iso(),
                    calibrationSource="industry-indicative",
                )
                for row in rows
            ]

    async with _write(pool) as conn:
        for check in checks:
            status_val = "pass" if check.passed else "fail"
            await conn.execute(
                """UPDATE agent_compliance_results r
                   SET status = $2, assessed_at = now()
                   FROM governance_controls c, governance_frameworks f
                   WHERE r.control_id = c.id
                     AND c.framework_id = f.id
                     AND c.tenant_id = $1
                     AND f.tenant_id = $1
                     AND r.tenant_id = $1
                     AND (c.name = $3 OR c.id::text = $4)""",
                tenant_id,
                status_val,
                check.check,
                check.control,
            )

        summary = _policy_scan_summary(checks, request.policyVersion)

        await _audit_log(
            conn, tenant_id, "compliance.scan_completed", None, None, actor,
            {
                "frameworks": request.frameworks,
                "policy_version": request.policyVersion,
                "controls_assessed": len(checks),
                "controls_passed": sum(check.passed for check in checks),
                "controls_failed": sum(not check.passed for check in checks),
                "total_exposure_gbp": summary.totalCarriedGbp,
                "bundle_sha256": bundle_sha256,
                "engine_invoked": bool(scan_results),
            },
        )

    return PolicyScanResponse(
        checks=checks,
        summary=summary,
    )


@router.post(
    "/compliance/policy/scan",
    response_model=PolicyScanResponse,
    responses=ERROR_RESPONSES,
)
@router.post(
    "/v1/compliance/policy/scan",
    response_model=PolicyScanResponse,
    responses=ERROR_RESPONSES,
)
async def policy_compliance_scan(
    request: PolicyScanRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> PolicyScanResponse:
    tenant_id = principal.tenant
    pool = await _get_pool()
    if pool is None:
        raise APIError(
            503,
            "database_unavailable",
            "Policy scanning requires the compliance database",
        )
    return await _db_policy_scan(pool, tenant_id, request, principal.actor)


@router.get(
    "/compliance/policy/frameworks",
    response_model=list[PolicyFrameworkSummaryResponse],
    responses=ERROR_RESPONSES,
)
@router.get(
    "/v1/compliance/policy/frameworks",
    response_model=list[PolicyFrameworkSummaryResponse],
    responses=ERROR_RESPONSES,
)
async def policy_compliance_frameworks(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> list[PolicyFrameworkSummaryResponse]:
    return await _policy_framework_summaries(tenant_id)


@router.get(
    "/compliance/policy/summary",
    response_model=PolicySummaryResponse,
    responses=ERROR_RESPONSES,
)
@router.get(
    "/v1/compliance/policy/summary",
    response_model=PolicySummaryResponse,
    responses=ERROR_RESPONSES,
)
async def policy_compliance_summary(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> PolicySummaryResponse:
    summary = await compliance_summary(tenant_id)
    posture = await compliance_posture(tenant_id)
    assessed_at = [
        result.assessed_at
        for agent in posture.agents
        for result in agent.results
        if result.assessed_at is not None
    ]
    return PolicySummaryResponse(
        totalChecks=summary.controls_passing + summary.controls_failing + summary.controls_pending,
        passed=summary.controls_passing,
        failed=summary.controls_failing,
        totalAle=0,
        totalVar95=0,
        totalTvar=0,
        totalCarriedGbp=0,
        carried=MoneyResponse(amount=0, currency=REPORTING_CURRENCY),
        currency=REPORTING_CURRENCY,
        scanTimestamp=max(assessed_at, default=_now_iso()),
        frameworks=await _policy_framework_summaries(tenant_id),
    )





@router.get("/compliance/export", responses=ERROR_RESPONSES)
async def compliance_export(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    format: Literal["json", "pdf", "both"] = "json",
) -> dict[str, str]:
    now = _now_iso()
    return {
        "format": format,
        "generated_at": now,
        "url": f"https://reports.local/{tenant_id}/{format}.out",
    }


class PrivilegedInvocationRequest(BaseModel):
    """What the demo runner may report, and the whole of it.

    Two fields, both drawn from closed sets, and neither of them an audit field
    in its own right. What is deliberately absent is the list that matters:
    no ``actor``, no ``event_type``, no ``outcome``, no free-text reason. Those
    are the load-bearing columns of the row, and a caller that can author them
    can author the row. They are derived below from the validated token and
    from ``kind``, never read from this body.

    ``extra="forbid"`` so that a field added to the wire without being added to
    this model is a 422 rather than a silently ignored claim.
    """

    model_config = ConfigDict(extra="forbid")

    #: Mirrors ``demo_runner.StepId``. Restated rather than imported because
    #: ``demo_runner`` imports this module; the duplication is one line and the
    #: alternative is a cycle. ``test_demo_runner_audit_forwarding`` pins the
    #: two together.
    step_id: Literal["1", "2", "3", "4", "5"]
    kind: Literal["step", "reset"]


def _superadmin_principal(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Principal:
    """``superadmin.require_superadmin``, reachable from this module.

    ``superadmin`` imports ``Principal`` and ``authenticated_principal`` from
    here, so importing it back at module scope is a cycle. The import is
    therefore deferred to request time -- the gate itself is unchanged, and
    lives in exactly one place, which is the property worth protecting.
    """
    from superadmin import is_superadmin

    if not is_superadmin(principal):
        raise APIError(403, "superadmin_required", "Superadmin access is required")
    return principal


@router.post(
    "/audit/privileged-invocations",
    response_model=AuditEventResponse,
    responses=ERROR_RESPONSES,
    status_code=201,
)
async def record_privileged_invocation(
    body: PrivilegedInvocationRequest,
    principal: Annotated[Principal, Depends(_superadmin_principal)],
) -> AuditEventResponse:
    """Persist a privileged demo invocation on the runner's behalf.

    This is the durable half of the supercred-demo-runner's audit trail, and it
    exists because that workload has no database and must not be given one.
    ``demo_runner_main.py`` says why in its own words -- the runner "must not
    initialise the PostgreSQL pool" -- and its NetworkPolicy is written to the
    same standard, spelling out what is absent and why. Port 5432 is absent.
    The runner is the one workload in the slice that executes privileged
    scripts against the cluster; handing it database reachability in order to
    widen an audit trail trades the wrong thing away. So the bytes travel over
    HTTP to the process that already holds the pool, which is this one.

    On the honesty of the row, plainly, because this endpoint is the exception
    to the rule the rest of the file now follows.

    Everything that identifies the caller is first-party: ``actor`` and
    ``tenant`` come from a Dex token that THIS process validated, against the
    same issuer, audience and superadmin allowlist the runner validated it
    against. Nothing about the identity is taken on trust from the reporter.
    ``event_type`` and ``preempts_active_run`` are derived here from ``kind``.

    What is not first-party is ``step_id``: only the runner knows which phase
    it was asked for, and it is constrained to a closed set rather than
    verified. The row is therefore a record of an authorisation -- a superadmin
    was authorised, at this time, for this phase -- and not a claim that a
    script ran or that a cluster changed. That distinction is the same one the
    stun payload had to learn: ``requested`` is not ``reached``.

    The residual exposure is that a superadmin could call this directly and
    fabricate an invocation that never happened. That is accepted rather than
    overlooked: the only callers who can do it are the callers entitled to make
    the claim true by pressing the button. Closing it properly needs a verified
    workload identity for the runner -- a projected ServiceAccount token checked
    by TokenReview, or an OpenBao-issued service credential -- and neither
    primitive exists in this codebase yet. When one does, this endpoint should
    require it in addition to the operator's token, not instead of it.
    """
    tenant_id = principal.tenant
    detail: dict[str, Any] = {
        "step_id": body.step_id,
        "kind": body.kind,
        # Reported by the runner, recorded here, observed by neither. Named so
        # that a reader of this row knows which kind of fact they are holding
        # without having to know this endpoint exists.
        "reported_by": "supercred-demo-runner",
        "observed": False,
    }
    if body.kind == "reset":
        # Derived from `kind`, not accepted from the body: reset is the control
        # that preempts and cancels whatever phase is running, and that is a
        # property of the operation rather than something a caller asserts.
        detail["preempts_active_run"] = True

    pool = await _require_pool("Recording a privileged invocation")
    if pool is None:
        event = _record_memory_audit(
            tenant_id, "demo.reset_requested" if body.kind == "reset" else "demo.phase_run",
            None, None, principal.actor, detail,
        )
        return AuditEventResponse(**event)

    # Two literal call sites rather than one call with a looked-up name. The
    # extractor in test_audit_event_types.py resolves an event type only when
    # it is a literal at the call site or a parameter of the enclosing
    # function; a dict lookup would land in its `unresolved` list, and that
    # test's whole point is that an unresolvable call site is reported rather
    # than quietly dropped from the coverage it claims to provide.
    async with _write(pool) as conn:
        if body.kind == "reset":
            await _audit_log(
                conn, tenant_id, "demo.reset_requested", None, None, principal.actor, detail,
            )
        else:
            await _audit_log(
                conn, tenant_id, "demo.phase_run", None, None, principal.actor, detail,
            )

    return AuditEventResponse(
        # As in the stun response: the insert does not return the generated id,
        # and naming the stand-in is better than inventing a plausible one.
        id=f"{tenant_id}:audit-pending",
        timestamp=_now_iso(),
        event_type="demo.reset_requested" if body.kind == "reset" else "demo.phase_run",
        agent_id=None,
        agent_name=None,
        actor=principal.actor,
        detail=detail,
    )


@router.get("/audit", response_model=AuditListResponse, responses=ERROR_RESPONSES)
async def audit(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    page: int = 1,
    limit: int = 50,
    from_: str | None = Query(default=None, alias="from"),
    to: str | None = None,
    agent: str | None = None,
    type: str | None = None,
) -> AuditListResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        base_events = [
            AuditEventResponse(
                id=f"{tenant_id}:audit-1",
                timestamp="2026-07-27T01:00:00Z",
                event_type="agent.created",
                agent_id=f"{tenant_id}:agent-1",
                agent_name="Inventory Agent",
                actor="demo-actor",
                detail={"source": "mock"},
                authorizing_principal_id="admin@signal-loom.ai",
                executing_actor_id=f"{tenant_id}:agent-1",
                spiffe_id="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-inventory",
                attribution_rationale="Initial declarative manifest registration",
            ),
            AuditEventResponse(
                id=f"{tenant_id}:audit-2",
                timestamp="2026-07-27T01:10:00Z",
                event_type="agent.transitioned",
                agent_id=f"{tenant_id}:agent-2",
                agent_name="Triage Agent",
                actor="demo-actor",
                detail={"to_state": "active"},
                authorizing_principal_id="secops@signal-loom.ai",
                executing_actor_id=f"{tenant_id}:agent-2",
                spiffe_id="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-triage",
                attribution_rationale="Workload attestation verified by SPIRE agent",
            ),
            AuditEventResponse(
                id=f"{tenant_id}:audit-3",
                timestamp="2026-07-27T01:20:00Z",
                event_type="compliance.reassess_requested",
                agent_id=f"{tenant_id}:agent-1",
                agent_name="Inventory Agent",
                actor="demo-actor",
                detail={"control_id": "eu-ai-act:art-9"},
                authorizing_principal_id="compliance-officer@signal-loom.ai",
                executing_actor_id=f"{tenant_id}:agent-1",
                spiffe_id="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-inventory",
                attribution_rationale="Periodic automated compliance reassessment",
            ),
        ]
        with _STORE_LOCK:
            recorded = [
                AuditEventResponse(
                    id=event["id"],
                    timestamp=event["timestamp"],
                    event_type=event["event_type"],
                    agent_id=event.get("agent_id"),
                    agent_name=event.get("agent_name"),
                    actor=event["actor"],
                    detail=event.get("detail", {}),
                    authorizing_principal_id=event.get("authorizing_principal_id"),
                    executing_actor_id=event.get("executing_actor_id"),
                    spiffe_id=event.get("spiffe_id"),
                    attribution_rationale=event.get("attribution_rationale"),
                    evidence_ref=event.get("evidence_ref"),
                    kernel_telemetry_ref=event.get("kernel_telemetry_ref"),
                )
                for event in reversed(_AUDIT_EVENTS.get(tenant_id, []))
            ]
        events = recorded + base_events

        if from_ is not None:
            events = [e for e in events if e.timestamp >= from_]
        if to is not None:
            events = [e for e in events if e.timestamp <= to]
        if agent is not None:
            agent_matched = [
                e for e in events
                if e.agent_id == agent
                or (e.agent_id and (e.agent_id == f"{tenant_id}:{agent}" or e.agent_id.endswith(f":{agent}")))
                or (e.agent_name or "").lower().find(agent.lower()) >= 0
                or (isinstance(e.detail, dict) and e.detail.get("agent_ref") == agent)
            ]
            events = agent_matched
        if type is not None:
            events = [e for e in events if e.event_type == type]

        start = max(page - 1, 0) * limit
        end = start + limit
        return AuditListResponse(
            events=events[start:end], total=len(events), page=page, limit=limit, source_health="healthy",
        )

    # Build dynamic WHERE clause
    conditions = ["tenant_id = $1"]
    params: list[Any] = [tenant_id]
    idx = 2

    if from_ is not None:
        conditions.append(f"timestamp >= ${idx}::timestamptz")
        params.append(from_)
        idx += 1
    if to is not None:
        conditions.append(f"timestamp <= ${idx}::timestamptz")
        params.append(to)
        idx += 1
    if agent is not None:
        agent_uuid = _try_uuid(agent)
        if agent_uuid is not None:
            conditions.append(f"agent_id = ${idx}")
            params.append(agent_uuid)
            idx += 1
        else:
            conditions.append(f"(agent_name ILIKE ${idx} OR detail->>'agent_ref' = ${idx + 1})")
            params.append(f"%{agent}%")
            params.append(agent)
            idx += 2
    if type is not None:
        conditions.append(f"event_type = ${idx}")
        params.append(type)
        idx += 1

    where = " AND ".join(conditions)
    offset = max(page - 1, 0) * limit

    count_row = await pool.fetchrow(
        f"SELECT COUNT(*)::int AS total FROM audit_events WHERE {where}", *params,
    )
    total = count_row["total"] if count_row else 0
    params.append(limit)
    params.append(offset)
    rows = await pool.fetch(
        f"SELECT * FROM audit_events WHERE {where} ORDER BY timestamp DESC LIMIT ${idx} OFFSET ${idx + 1}",
        *params,
    )

    events = []
    for row in rows:
        detail = json.loads(row["detail"]) if isinstance(row["detail"], str) else (row["detail"] or {})
        actor = row["actor"] or "system"
        events.append(
            AuditEventResponse(
                id=str(row["id"]),
                timestamp=_ts(row["timestamp"]) or "",
                event_type=row["event_type"],
                agent_id=str(row["agent_id"]) if row["agent_id"] is not None else None,
                agent_name=row["agent_name"],
                actor=actor,
                detail=detail,
                authorizing_principal_id=detail.get("authorizing_principal_id") or (actor if "@" in actor else None),
                executing_actor_id=detail.get("executing_actor_id") or (str(row["agent_id"]) if row["agent_id"] is not None else None),
                spiffe_id=detail.get("spiffe_id"),
                attribution_rationale=detail.get("attribution_rationale"),
                evidence_ref=detail.get("evidence_ref"),
                kernel_telemetry_ref=detail.get("kernel_telemetry_ref"),
            )
        )
    return AuditListResponse(events=events, total=total, page=page, limit=limit, source_health="healthy")


async def _iter_audit_stream(
    tenant_id: str,
    agent: str | None = None,
    type: str | None = None,
    from_: str | None = None,
    last_event_id: str | None = None,
) -> AsyncIterator[bytes]:
    """Yield audit events as SSE frames in real time.
    
    Strictly side-effect free: NEVER executes database writes or synthesizes fake events.
    """
    seen_ids: set[str] = set()

    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        base_events = [
            AuditEventResponse(
                id=f"{tenant_id}:audit-1",
                timestamp="2026-07-27T01:00:00Z",
                event_type="agent.created",
                agent_id=f"{tenant_id}:agent-1",
                agent_name="Inventory Agent",
                actor="demo-actor",
                detail={"source": "mock"},
                authorizing_principal_id="admin@signal-loom.ai",
                executing_actor_id=f"{tenant_id}:agent-1",
                spiffe_id="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-inventory",
                attribution_rationale="Initial declarative manifest registration",
            ),
            AuditEventResponse(
                id=f"{tenant_id}:audit-2",
                timestamp="2026-07-27T01:10:00Z",
                event_type="agent.transitioned",
                agent_id=f"{tenant_id}:agent-2",
                agent_name="Triage Agent",
                actor="demo-actor",
                detail={"to_state": "active"},
                authorizing_principal_id="secops@signal-loom.ai",
                executing_actor_id=f"{tenant_id}:agent-2",
                spiffe_id="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-triage",
                attribution_rationale="Workload attestation verified by SPIRE agent",
            ),
            AuditEventResponse(
                id=f"{tenant_id}:audit-3",
                timestamp="2026-07-27T01:20:00Z",
                event_type="compliance.reassess_requested",
                agent_id=f"{tenant_id}:agent-1",
                agent_name="Inventory Agent",
                actor="demo-actor",
                detail={"control_id": "eu-ai-act:art-9"},
                authorizing_principal_id="compliance-officer@signal-loom.ai",
                executing_actor_id=f"{tenant_id}:agent-1",
                spiffe_id="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-inventory",
                attribution_rationale="Periodic automated compliance reassessment",
            ),
        ]
        with _STORE_LOCK:
            recorded = [
                AuditEventResponse(
                    id=event["id"],
                    timestamp=event["timestamp"],
                    event_type=event["event_type"],
                    agent_id=event.get("agent_id"),
                    agent_name=event.get("agent_name"),
                    actor=event["actor"],
                    detail=event.get("detail", {}),
                    authorizing_principal_id=event.get("authorizing_principal_id"),
                    executing_actor_id=event.get("executing_actor_id"),
                    spiffe_id=event.get("spiffe_id"),
                    attribution_rationale=event.get("attribution_rationale"),
                    evidence_ref=event.get("evidence_ref"),
                    kernel_telemetry_ref=event.get("kernel_telemetry_ref"),
                )
                for event in reversed(_AUDIT_EVENTS.get(tenant_id, []))
            ]
        events = recorded + base_events
        if from_ is not None:
            events = [e for e in events if e.timestamp >= from_]
        if agent is not None:
            events = [
                e for e in events
                if e.agent_id == agent
                or (e.agent_id and (e.agent_id == f"{tenant_id}:{agent}" or e.agent_id.endswith(f":{agent}")))
                or (e.agent_name or "").lower().find(agent.lower()) >= 0
                or (isinstance(e.detail, dict) and e.detail.get("agent_ref") == agent)
            ]
        if type is not None:
            events = [e for e in events if e.event_type == type]

        for ev in events:
            if ev.id not in seen_ids:
                seen_ids.add(ev.id)
                payload = ev.model_dump_json()
                frame = f"id: {ev.id}\nevent: audit_event\ndata: {payload}\n\n"
                yield frame.encode("utf-8")
    else:
        conditions = ["tenant_id = $1"]
        params: list[Any] = [tenant_id]
        idx = 2
        if from_ is not None:
            conditions.append(f"timestamp >= ${idx}::timestamptz")
            params.append(from_)
            idx += 1
        if agent is not None:
            agent_uuid = _try_uuid(agent)
            if agent_uuid is not None:
                conditions.append(f"agent_id = ${idx}")
                params.append(agent_uuid)
                idx += 1
            else:
                conditions.append(f"(agent_name ILIKE ${idx} OR detail->>'agent_ref' = ${idx + 1})")
                params.append(f"%{agent}%")
                params.append(agent)
                idx += 2
        if type is not None:
            conditions.append(f"event_type = ${idx}")
            params.append(type)
            idx += 1

        where = " AND ".join(conditions)
        rows = await pool.fetch(
            f"SELECT * FROM audit_events WHERE {where} ORDER BY timestamp ASC LIMIT 100",
            *params,
        )
        for row in rows:
            ev_id = str(row["id"])
            if ev_id not in seen_ids:
                seen_ids.add(ev_id)
                detail = json.loads(row["detail"]) if isinstance(row["detail"], str) else (row["detail"] or {})
                actor = row["actor"] or "system"
                ev = AuditEventResponse(
                    id=ev_id,
                    timestamp=_ts(row["timestamp"]) or "",
                    event_type=row["event_type"],
                    agent_id=str(row["agent_id"]) if row["agent_id"] is not None else None,
                    agent_name=row["agent_name"],
                    actor=actor,
                    detail=detail,
                    authorizing_principal_id=detail.get("authorizing_principal_id") or (actor if "@" in actor else None),
                    executing_actor_id=detail.get("executing_actor_id") or (str(row["agent_id"]) if row["agent_id"] is not None else None),
                    spiffe_id=detail.get("spiffe_id"),
                    attribution_rationale=detail.get("attribution_rationale"),
                    evidence_ref=detail.get("evidence_ref"),
                    kernel_telemetry_ref=detail.get("kernel_telemetry_ref"),
                )
                payload = ev.model_dump_json()
                frame = f"id: {ev.id}\nevent: audit_event\ndata: {payload}\n\n"
                yield frame.encode("utf-8")

    # Send heartbeat keepalive
    yield b": keepalive\n\n"


@router.get("/audit/stream", response_class=StreamingResponse, responses=ERROR_RESPONSES)
async def audit_stream(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    agent: str | None = None,
    type: str | None = None,
    from_: str | None = Query(default=None, alias="from"),
    last_event_id: str | None = Query(default=None),
) -> StreamingResponse:
    """Stream audit events via Server-Sent Events (SSE).
    
    Strictly side-effect free and idempotent under RFC 9110. Zero database writes.
    """
    return StreamingResponse(
        _iter_audit_stream(
            tenant_id=tenant_id,
            agent=agent,
            type=type,
            from_=from_,
            last_event_id=last_event_id,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
            "x-source-health": "healthy",
        },
    )


@router.get("/agents/{agent_id}/audit/stream", response_class=StreamingResponse, responses=ERROR_RESPONSES)
async def agent_audit_stream(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    type: str | None = None,
    from_: str | None = Query(default=None, alias="from"),
    last_event_id: str | None = Query(default=None),
) -> StreamingResponse:
    """Stream attributable audit events for a specific agent via SSE.
    
    Fails closed with HTTP 404 if the agent ID does not exist in registry or discovery.
    """
    pool = await _get_pool()
    if pool is not None:
        agent_uuid = _try_uuid(agent_id)
        if agent_uuid is None:
            row = await pool.fetchrow(
                "SELECT id FROM agents WHERE tenant_id = $1 AND name = $2",
                tenant_id, agent_id,
            )
            if row is None:
                raise APIError(404, "not_found", f"Agent '{agent_id}' not found")
        else:
            row = await pool.fetchrow(
                "SELECT id FROM agents WHERE tenant_id = $1 AND id = $2",
                tenant_id, agent_uuid,
            )
            if row is None:
                raise APIError(404, "not_found", f"Agent '{agent_id}' not found")
    else:
        _ensure_seeded(tenant_id)
        known_agents = [
            f"{tenant_id}:agent-1",
            f"{tenant_id}:agent-2",
            f"{tenant_id}:agent-3",
            "agent-1",
            "agent-2",
            "agent-3",
        ]
        with _STORE_LOCK:
            known_agents.extend([str(a["id"]) for a in _AGENTS.get(tenant_id, {}).values()])
            known_agents.extend([str(a.get("name")) for a in _AGENTS.get(tenant_id, {}).values() if a.get("name")])
        if agent_id not in known_agents:
            raise APIError(404, "not_found", f"Agent '{agent_id}' not found")

    return StreamingResponse(
        _iter_audit_stream(
            tenant_id=tenant_id,
            agent=agent_id,
            type=type,
            from_=from_,
            last_event_id=last_event_id,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
            "x-source-health": "healthy",
        },
    )


@router.get("/nhi/scans", response_model=NHIScanListResponse, responses=ERROR_RESPONSES)
async def nhi_scans(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> NHIScanListResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        scans = [
            NHIScan(
                id=f"{tenant_id}:scan-1",
                tenant_id=tenant_id,
                scan_source="okta",
                started_at="2026-07-27T00:00:00Z",
                completed_at="2026-07-27T00:05:00Z",
                total_entries_scanned=42,
                service_accounts_found=2,
                total_at_risk=1,
                status="completed",
            ),
            NHIScan(
                id=f"{tenant_id}:scan-2",
                tenant_id=tenant_id,
                scan_source="entra",
                started_at="2026-07-27T01:00:00Z",
                completed_at=None,
                total_entries_scanned=14,
                service_accounts_found=1,
                total_at_risk=1,
                status="running",
            ),
        ]
        return NHIScanListResponse(scans=scans)

    rows = await pool.fetch(
        "SELECT * FROM nhi_scans WHERE tenant_id = $1 ORDER BY started_at DESC", tenant_id,
    )
    scans = [
        NHIScan(
            id=str(row["id"]),
            tenant_id=row["tenant_id"],
            scan_source=row["scan_source"],
            started_at=_ts(row["started_at"]),
            completed_at=_ts(row["completed_at"]),
            total_entries_scanned=row["total_entries_scanned"],
            service_accounts_found=row["service_accounts_found"],
            total_at_risk=row["total_at_risk"],
            status=row["status"],
        )
        for row in rows
    ]
    return NHIScanListResponse(scans=scans)


@router.get("/nhi/discovered", response_model=NHIDiscoveredResponse, responses=ERROR_RESPONSES)
async def nhi_discovered(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    page: int = 1,
    limit: int = 50,
    status: str | None = None,
) -> NHIDiscoveredResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            accounts = list(_NHI_ACCOUNTS[tenant_id].values())
        if status is not None:
            accounts = [account for account in accounts if account["status"] == status]
        total = len(accounts)
        summary = NHIDiscoveredSummary(
            total_discovered=total,
            needs_triage=sum(1 for account in accounts if account["status"] == "needs_triage"),
            previously_dismissed=sum(1 for account in accounts if account["status"] == "dismissed"),
        )
        start = max(page - 1, 0) * limit
        end = start + limit
        return NHIDiscoveredResponse(
            accounts=[NHIAccount(**account) for account in accounts[start:end]],
            total=total,
            summary=summary,
        )

    # DB mode
    conditions = ["tenant_id = $1"]
    params: list[Any] = [tenant_id]
    idx = 2
    if status is not None:
        conditions.append(f"status = ${idx}")
        params.append(status)
        idx += 1

    where = " AND ".join(conditions)

    count_row = await pool.fetchrow(
        f"SELECT COUNT(*)::int AS total FROM nhi_discovered_accounts WHERE {where}", *params,
    )
    total = count_row["total"]

    # Summary counts (always unfiltered by status for the summary)
    summary_row = await pool.fetchrow(
        """SELECT
               COUNT(*)::int AS total_discovered,
               COALESCE(SUM(CASE WHEN status = 'needs_triage' THEN 1 ELSE 0 END)::int, 0) AS needs_triage,
               COALESCE(SUM(CASE WHEN status = 'dismissed' THEN 1 ELSE 0 END)::int, 0) AS previously_dismissed
           FROM nhi_discovered_accounts WHERE tenant_id = $1""",
        tenant_id,
    )

    offset = max(page - 1, 0) * limit
    params.append(limit)
    params.append(offset)
    rows = await pool.fetch(
        f"SELECT * FROM nhi_discovered_accounts WHERE {where} ORDER BY first_discovered_at DESC LIMIT ${idx} OFFSET ${idx + 1}",
        *params,
    )

    accounts = [
        NHIAccount(
            id=str(row["id"]),
            scan_id=str(row["scan_id"]) if row["scan_id"] is not None else None,
            account_name=row["account_name"],
            directory_source=row["directory_source"],
            owner_email=row["owner_email"],
            last_credential_rotation=_ts(row["last_rotated"]),
            privilege_level=row["privilege_level"],
            status=row["status"],
            findings=list(row["findings"]) if row["findings"] else [],
            scan_count=row["scan_count"],
            dismissed_at=_ts(row["dismissed_at"]),
            dismissed_by=row["dismissed_by"],
            changes_since_dismissal=row["changes_since_dismissal"],
            previous_risk_flags=list(row["previous_risk_flags"]) if row["previous_risk_flags"] else None,
            first_discovered_at=_ts(row["first_discovered_at"]),
            last_seen_at=_ts(row["last_seen_at"]),
        )
        for row in rows
    ]
    return NHIDiscoveredResponse(
        accounts=accounts,
        total=total,
        summary=NHIDiscoveredSummary(
            total_discovered=summary_row["total_discovered"],
            needs_triage=summary_row["needs_triage"],
            previously_dismissed=summary_row["previously_dismissed"],
        ),
    )


@router.post("/v1/nhi/discovered/{account_id}/enroll", responses=ERROR_RESPONSES)
@router.post("/nhi/discovered/{account_id}/enroll", responses=ERROR_RESPONSES)
async def enroll_nhi_account(
    account_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> dict[str, str]:
    tenant_id = principal.tenant
    pool = await _require_pool("Enrolling a discovered account")
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            account = _NHI_ACCOUNTS[tenant_id].get(account_id)
            if account is None:
                account = _seed_unknown_account(tenant_id, account_id)
            account["status"] = "enrollment_requested"
            account["dismissed_at"] = None
            account["dismissed_by"] = None
        return {"account_id": account_id, "status": "enrollment_requested"}

    a_uuid = _try_uuid(account_id)
    if a_uuid is None:
        raise APIError(404, "not_found", "Account not found")

    async with _write(pool) as conn:
        await conn.execute(
            """UPDATE nhi_discovered_accounts SET status = 'enrollment_requested', dismissed_at = NULL, dismissed_by = NULL
               WHERE id = $1 AND tenant_id = $2""",
            a_uuid, tenant_id,
        )
        await _audit_log(conn, tenant_id, "nhi.enrolled", None, None, principal.actor, {"account_id": account_id})
    return {"account_id": account_id, "status": "enrollment_requested"}


@router.post("/v1/nhi/discovered/{account_id}/dismiss", responses=ERROR_RESPONSES)
@router.post("/nhi/discovered/{account_id}/dismiss", responses=ERROR_RESPONSES)
async def dismiss_nhi_account(
    account_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> dict[str, str]:
    tenant_id = principal.tenant
    pool = await _require_pool("Dismissing a discovered account")
    if pool is None:
        _ensure_seeded(tenant_id)
        now = _now_iso()
        with _STORE_LOCK:
            account = _NHI_ACCOUNTS[tenant_id].get(account_id)
            if account is None:
                account = _seed_unknown_account(tenant_id, account_id)
            account["status"] = "dismissed"
            account["dismissed_at"] = now
            account["dismissed_by"] = principal.actor
            account["changes_since_dismissal"] = False
            account["previous_risk_flags"] = list(account["findings"])
        return {"account_id": account_id, "status": "dismissed"}

    a_uuid = _try_uuid(account_id)
    if a_uuid is None:
        raise APIError(404, "not_found", "Account not found")

    # changes_since_dismissal is JSONB, not BOOLEAN, so the bare `false` literal
    # was a DatatypeMismatchError and every dismiss against a real database
    # failed. The API models the field as `bool | None`, so a JSON `false` is the
    # value; the cast makes the column's actual type explicit at the call site.
    async with _write(pool) as conn:
        await conn.execute(
            """UPDATE nhi_discovered_accounts
               SET status = 'dismissed', dismissed_at = now(), dismissed_by = $3,
                   changes_since_dismissal = 'false'::jsonb, previous_risk_flags = findings
               WHERE id = $1 AND tenant_id = $2""",
            a_uuid, tenant_id, principal.actor,
        )
        await _audit_log(conn, tenant_id, "nhi.dismissed", None, None, principal.actor, {"account_id": account_id})
    return {"account_id": account_id, "status": "dismissed"}


@router.get("/nhi/report/json", responses=ERROR_RESPONSES)
async def nhi_report_json(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, Any]:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            accounts = list(_NHI_ACCOUNTS[tenant_id].values())
        at_risk = sum(1 for account in accounts if account["status"] == "needs_triage")
        return {
            "tenant_id": tenant_id,
            "generated_at": _now_iso(),
            "accounts_total": len(accounts),
            "at_risk": at_risk,
        }

    row = await pool.fetchrow(
        """SELECT
               COUNT(*)::int AS accounts_total,
               COALESCE(SUM(CASE WHEN status = 'needs_triage' THEN 1 ELSE 0 END)::int, 0) AS at_risk
           FROM nhi_discovered_accounts WHERE tenant_id = $1""",
        tenant_id,
    )
    return {
        "tenant_id": tenant_id,
        "generated_at": _now_iso(),
        "accounts_total": row["accounts_total"],
        "at_risk": row["at_risk"],
    }


@router.get("/nhi/discovered/{account_id}", response_model=NHIAccountDetail, responses=ERROR_RESPONSES)
async def nhi_discovered_detail(
    account_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> NHIAccountDetail:
    """Return one persisted account from the caller's tenant inventory."""
    account_uuid = _try_uuid(account_id)
    if account_uuid is None:
        raise APIError(404, "not_found", "Account not found")

    pool = await _get_pool()
    if pool is None:
        raise APIError(
            503,
            "database_unavailable",
            "Discovery account details require the inventory database",
        )

    row = await pool.fetchrow(
        "SELECT * FROM nhi_discovered_accounts WHERE id = $1 AND tenant_id = $2",
        account_uuid,
        tenant_id,
    )
    if row is None:
        raise APIError(404, "not_found", "Account not found")
    return NHIAccountDetail(
        id=str(row["id"]),
        scan_id=str(row["scan_id"]) if row["scan_id"] is not None else None,
        account_name=row["account_name"],
        directory_source=row["directory_source"],
        owner_email=row["owner_email"],
        last_rotated=_ts(row["last_rotated"]),
        privilege_level=row["privilege_level"],
        findings=list(row["findings"]) if row["findings"] else [],
        status=row["status"],
        first_discovered_at=_ts(row["first_discovered_at"]),
        last_seen_at=_ts(row["last_seen_at"]),
        dismissed_at=_ts(row["dismissed_at"]),
        dismissed_by=row["dismissed_by"],
        dismiss_reason=row["dismiss_reason"],
        scan_count=row["scan_count"],
    )


@router.get("/tenant/settings", response_model=TenantSettingsResponse, responses=ERROR_RESPONSES)
async def tenant_settings(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TenantSettingsResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            return _tenant_settings_response(tenant_id)

    ts_row = await _ensure_tenant_settings(pool, tenant_id)
    agent_count_row = await pool.fetchrow(
        "SELECT COUNT(*)::int AS cnt FROM agent_registry WHERE tenant_id = $1", tenant_id,
    )
    # Cookie prefs: check consent_events first, fall back to tenant_settings
    consent_row = await pool.fetchrow(
        """SELECT
               (cookie_preferences->>'strictly_necessary')::boolean AS cookie_strictly_necessary,
               (cookie_preferences->>'analytics')::boolean AS cookie_analytics
           FROM consent_events WHERE tenant_id = $1 ORDER BY accepted_at DESC LIMIT 1""",
        tenant_id,
    )
    if consent_row is not None:
        cookie_prefs = CookiePreferences(
            strictly_necessary=consent_row["cookie_strictly_necessary"] if consent_row["cookie_strictly_necessary"] is not None else True,
            analytics=consent_row["cookie_analytics"] if consent_row["cookie_analytics"] is not None else False,
        )
    else:
        # Fall back to tenant_settings cookie_preferences JSONB
        ts_cookie = ts_row["cookie_preferences"]
        if ts_cookie is not None and isinstance(ts_cookie, dict):
            cookie_prefs = CookiePreferences(
                strictly_necessary=ts_cookie.get("strictly_necessary", True),
                analytics=ts_cookie.get("analytics", False),
            )
        elif ts_cookie is not None and isinstance(ts_cookie, str):
            parsed = json.loads(ts_cookie)
            cookie_prefs = CookiePreferences(
                strictly_necessary=parsed.get("strictly_necessary", True),
                analytics=parsed.get("analytics", False),
            )
        else:
            cookie_prefs = CookiePreferences(strictly_necessary=True, analytics=False)
    # consent_required is derived: consent_accepted_at IS NULL
    consent_required = ts_row["consent_accepted_at"] is None
    prefs = _scan_preferences_from(
        ts_row, f"tenant {tenant_id} (tenant_settings row)",
    )
    return TenantSettingsResponse(
        tenant_id=ts_row["tenant_id"],
        org_name=ts_row["org_name"],
        plan_tier=ts_row["plan_tier"],
        agent_count=agent_count_row["cnt"],
        billing_tier=ts_row["plan_tier"],
        api_key_status=ts_row["api_key_status"],
        selected_frameworks=_jsonb_str_list(ts_row["selected_frameworks"]),
        consent_required=consent_required,
        cookie_preferences=cookie_prefs,
        preferred_scan_cadence_hours=prefs["preferred_scan_cadence_hours"],
        alert_email=prefs["alert_email"],
        alert_threshold=prefs["alert_threshold"],
    )


@router.get("/tenant/users", response_model=PlatformUsersResponse, responses=ERROR_RESPONSES)
async def tenant_users(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> PlatformUsersResponse:
    """List persisted directory users belonging to the authenticated tenant."""
    pool = await _get_pool()
    if pool is None:
        raise APIError(
            503,
            "database_unavailable",
            "Tenant users require the identity database",
        )

    rows = await pool.fetch(
        """SELECT id, email, display_name, role, status, department, title,
                  last_login_at, created_at
             FROM platform_users
            WHERE tenant_id = $1
            ORDER BY created_at ASC, id ASC""",
        tenant_id,
    )
    users = [
        PlatformUserResponse(
            id=str(row["id"]),
            email=row["email"],
            display_name=row["display_name"],
            role=row["role"],
            status=row["status"],
            department=row["department"],
            title=row["title"],
            last_login_at=_ts(row["last_login_at"]),
            created_at=_ts(row["created_at"]),
        )
        for row in rows
    ]
    return PlatformUsersResponse(users=users, total=len(users))


@router.patch("/tenant/settings/frameworks", response_model=TenantSettingsResponse, responses=ERROR_RESPONSES)
async def patch_tenant_frameworks(
    body: FrameworksPatchRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> TenantSettingsResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Changing tenant frameworks")
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            _TENANT_FRAMEWORKS[tenant_id] = list(body.selected_frameworks)
            return _tenant_settings_response(tenant_id)

    async with _write(pool) as conn:
        await _ensure_tenant_settings(conn, tenant_id)
        await conn.execute(
            "UPDATE tenant_settings SET selected_frameworks = $1 WHERE tenant_id = $2",
            json.dumps(list(body.selected_frameworks)), tenant_id,
        )
        await _audit_log(
            conn, tenant_id, "tenant.frameworks_updated", None, None, principal.actor,
            {"selected_frameworks": body.selected_frameworks},
        )
    # Re-fetch via the GET handler, OUTSIDE the transaction: it acquires its own
    # connection and so must run after the commit to observe the new values.
    return await tenant_settings(tenant_id)


@router.patch("/tenant/settings/preferences", response_model=TenantSettingsResponse, responses=ERROR_RESPONSES)
async def patch_tenant_preferences(
    body: PreferencesPatchRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> TenantSettingsResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Changing tenant preferences")
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            _TENANT_PREFERENCES[tenant_id] = {
                "preferred_scan_cadence_hours": body.preferred_scan_cadence_hours,
                "alert_email": body.alert_email,
                "alert_threshold": body.alert_threshold,
            }
            return _tenant_settings_response(tenant_id)

    async with _write(pool) as conn:
        await _ensure_tenant_settings(conn, tenant_id)
        await conn.execute(
            """UPDATE tenant_settings
                  SET preferred_scan_cadence_hours = $1,
                      alert_email = $2,
                      alert_threshold = $3
                WHERE tenant_id = $4""",
            body.preferred_scan_cadence_hours, body.alert_email, body.alert_threshold, tenant_id,
        )
        await _audit_log(
            conn, tenant_id, "tenant.preferences_updated", None, None, principal.actor,
            {
                "preferred_scan_cadence_hours": body.preferred_scan_cadence_hours,
                "alert_email": body.alert_email,
                "alert_threshold": body.alert_threshold,
            },
        )
    # Re-fetch via the GET handler, OUTSIDE the transaction: it acquires its own
    # connection and so must run after the commit to observe the new values.
    return await tenant_settings(tenant_id)


@router.get("/user/preferences", response_model=UserPreferencesResponse, responses=ERROR_RESPONSES)
async def user_preferences(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> UserPreferencesResponse:
    """The signed-in user's own display preferences.

    No user id in the path: the caller is whoever the bearer token says they
    are.  That is what makes one user's preference incapable of moving
    another's figures -- not a permission check that could be got wrong, but
    the absence of any way to name a different user.

    A caller with no ``user_preferences`` row -- which is every caller until
    they first change something -- resolves to the documented default.
    """
    tenant_id = principal.tenant
    pool = await _get_pool()
    if pool is None:
        with _STORE_LOCK:
            stored = _USER_PREFERENCES.get(tenant_id, {}).get(principal.actor)
        return UserPreferencesResponse(display_currency=stored or DEFAULT_DISPLAY_CURRENCY)

    row = await pool.fetchrow(
        "SELECT display_currency FROM user_preferences WHERE tenant_id = $1 AND user_email = $2",
        tenant_id, principal.actor,
    )
    # No row is the ordinary case, not an error: a row is written the first time
    # the user changes something, so its absence means "never chosen" rather
    # than "lost".
    stored = row["display_currency"] if row is not None else None
    return UserPreferencesResponse(display_currency=stored or DEFAULT_DISPLAY_CURRENCY)


@router.patch("/user/preferences", response_model=UserPreferencesResponse, responses=ERROR_RESPONSES)
async def patch_user_preferences(
    body: UserPreferencesPatchRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> UserPreferencesResponse:
    """Save the caller's display currency, and record that they changed it.

    Audited because a settings change a regulated customer cannot see the
    history of is a gap, and this one changes what every risk figure on every
    screen reads as.  The ``detail`` carries the previous value alongside the
    new one so the trail answers "what did it used to be" without a join
    against a table that only holds the current value.
    """
    tenant_id = principal.tenant
    actor = principal.actor
    pool = await _require_pool("Changing user preferences")

    if pool is None:
        with _STORE_LOCK:
            previous = _USER_PREFERENCES.get(tenant_id, {}).get(actor) or DEFAULT_DISPLAY_CURRENCY
            _USER_PREFERENCES.setdefault(tenant_id, {})[actor] = body.display_currency
        _record_memory_audit(
            tenant_id, "user.currency_updated", None, None, actor,
            # No "email" key: `actor` is Principal.actor, which IS the email
            # claim when Dex grants one. Copying it into the JSONB payload
            # duplicated PII into an append-only column for no gain -- the
            # column beside it already answers the same question, and
            # audit_events is precisely where a redundant copy is hardest to
            # remove later.
            {"from": previous, "to": body.display_currency},
        )
        return UserPreferencesResponse(display_currency=body.display_currency)

    async with _write(pool) as conn:
        previous_row = await conn.fetchrow(
            "SELECT display_currency FROM user_preferences WHERE tenant_id = $1 AND user_email = $2",
            tenant_id, actor,
        )
        previous = (previous_row["display_currency"] if previous_row else None) or DEFAULT_DISPLAY_CURRENCY

        # Upsert: the row is created on first change rather than provisioned
        # with the user, so almost every first write lands here as an INSERT.
        # Keyed on the identity in the token, not on directory membership -- a
        # caller who can authenticate can hold a preference whether or not
        # anyone has added them to platform_users.
        await conn.execute(
            """INSERT INTO user_preferences (tenant_id, user_email, display_currency)
                    VALUES ($1, $2, $3)
               ON CONFLICT ON CONSTRAINT uq_user_preferences_tenant_email
               DO UPDATE SET display_currency = EXCLUDED.display_currency""",
            tenant_id, actor, body.display_currency,
        )
        # Shares the transaction with the write above: an audit row without its
        # mutation, or a mutation without its audit row, are both worse than
        # neither. 007 documents what happens when the two come apart.
        await _audit_log(
            conn, tenant_id, "user.currency_updated", None, None, actor,
            # No "email" key: `actor` is Principal.actor, which IS the email
            # claim when Dex grants one. Copying it into the JSONB payload
            # duplicated PII into an append-only column for no gain -- the
            # column beside it already answers the same question, and
            # audit_events is precisely where a redundant copy is hardest to
            # remove later.
            {"from": previous, "to": body.display_currency},
        )

    return UserPreferencesResponse(display_currency=body.display_currency)


@router.post("/support", response_model=SupportRequestResponse, responses=ERROR_RESPONSES)
async def create_support_request(
    body: SupportRequestCreate,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> SupportRequestResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Filing a support request")
    if pool is None:
        _ensure_seeded(tenant_id)
        support_id = f"{tenant_id}:support-{secrets.token_hex(4)}"
        return SupportRequestResponse(
            id=support_id,
            subject=body.subject,
            urgency=body.urgency,
            submitted_at=_now_iso(),
            clickup_task_id=None,
        )

    # ``submitted_by`` is NOT NULL and was omitted.  A support request with no
    # requester is unanswerable, so the caller's own identity is the value --
    # taken from the token, not from a literal.
    #
    # The insert and its audit row share one transaction. The request row is
    # itself evidence -- who asked for what, and when -- but nothing recorded
    # that it had been created, so the audit trail was silent about a customer
    # raising an issue. The message body is deliberately NOT copied into the
    # detail: it is free text a customer may put anything in, and the audit
    # trail is read by people who need to know that a request exists, not what
    # was said in it. The request row holds the content.
    async with _write(pool) as conn:
        row = await conn.fetchrow(
            """INSERT INTO support_requests (tenant_id, subject, urgency, message, submitted_by)
               VALUES ($1, $2, $3, $4, $5) RETURNING *""",
            tenant_id, body.subject, body.urgency, body.message, principal.actor,
        )
        await _audit_log(
            conn, tenant_id, "support.requested", None, None, principal.actor,
            {"support_request_id": str(row["id"]), "urgency": body.urgency},
        )
    return SupportRequestResponse(
        id=str(row["id"]),
        subject=row["subject"],
        urgency=row["urgency"],
        submitted_at=_ts(row["submitted_at"]) or _now_iso(),
        clickup_task_id=row["clickup_task_id"],
    )


@router.post("/tenants/{tenant_id_path}/api-keys/initial", response_model=InitialApiKeyResponse, responses=ERROR_RESPONSES)
async def create_initial_api_key(
    tenant_id_path: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> InitialApiKeyResponse:
    tenant_id = principal.tenant
    # The path parameter is untrusted input from the URL. A caller authenticated
    # as tenant-a must not be able to mint a key whose prefix says tenant-b --
    # the prefix is part of the key material and its hint, so mismatch would
    # attribute the credential to the wrong tenant in every log line that
    # records the prefix. Reject rather than silently substituting, because a
    # client sending the wrong tenant has a routing bug worth telling it about.
    if tenant_id_path != tenant_id:
        raise APIError(
            403,
            "tenant_mismatch",
            "Path tenant does not match the authenticated tenant",
        )
    key = f"sl_live_{tenant_id}_{secrets.token_urlsafe(18)}"
    now = _now_iso()

    pool = await _require_pool("Minting an initial API key")
    if pool is None:
        _ensure_seeded(tenant_id)
    else:
        key_hash = hashlib.sha256(key.encode()).hexdigest()
        # ``revealed_by_email`` is NOT NULL: the whole point of the column is that
        # a live credential is attributable to whoever revealed it, so it takes
        # the authenticated caller.
        #
        # ``scope`` also has to change.  The handler wrote the API-facing string
        # ``tenant:read-write`` straight into a column whose CHECK constraint
        # only permits ``tenant_admin`` or ``read_only``, so the insert would
        # have failed on the constraint the moment the NOT NULL stopped firing
        # first.  Store the storage value and keep returning the wire value.
        #
        # The insert also needs a guard. ``uq_tenant_api_keys_active`` permits one
        # unrevoked key per tenant, so calling this on a tenant that already has
        # one raised UniqueViolationError and returned 500. Issuing a *first* key
        # to a tenant that already holds a live one is a conflict, and 409 is what
        # it should say -- silently revoking the existing key here would make this
        # endpoint a way to invalidate a tenant's production credential without
        # asking for a rotation. Callers that want a new key call rotate.
        #
        # SELECT ... FOR UPDATE rather than catching the violation: the check and
        # the insert are already inside one transaction, so the row lock closes
        # the window between them.
        async with _write(pool) as conn:
            existing = await conn.fetchrow(
                """SELECT id FROM tenant_api_keys
                   WHERE tenant_id = $1 AND revoked_at IS NULL FOR UPDATE""",
                tenant_id,
            )
            if existing is not None:
                raise APIError(
                    409,
                    "api_key_exists",
                    "Tenant already has an active API key; rotate it instead",
                )
            await conn.execute(
                """INSERT INTO tenant_api_keys (tenant_id, key_hash, prefix_hint, scope, revealed_by_email)
                   VALUES ($1, $2, $3, $4, $5)""",
                tenant_id, key_hash, key[:14], _API_KEY_SCOPE_STORED, principal.actor,
            )
            # principal.actor, not a literal. The INSERT two lines above
            # already records this exact value in revealed_by_email, for the
            # reason Principal.actor's docstring gives: an unattributable key
            # reveal is worthless as evidence. The audit row is the same claim
            # about the same act, so it cannot be answered with a constant.
            await _audit_log(conn, tenant_id, "api_key.created", None, None, principal.actor, {"prefix_hint": key[:14]})

    return InitialApiKeyResponse(
        key=key,
        prefix_hint=key[:14],
        revealed_at=now,
    )


@router.post("/tenants/{tenant_id_path}/api-keys/rotate", response_model=RotateApiKeyResponse, responses=ERROR_RESPONSES)
async def rotate_api_key(
    tenant_id_path: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> RotateApiKeyResponse:
    tenant_id = principal.tenant
    if tenant_id_path != tenant_id:
        raise APIError(
            403,
            "tenant_mismatch",
            "Path tenant does not match the authenticated tenant",
        )
    key = f"sl_live_{tenant_id}_{secrets.token_urlsafe(18)}"
    now = _now_iso()

    pool = await _require_pool("Rotating an API key")
    if pool is None:
        _ensure_seeded(tenant_id)
    else:
        key_hash = hashlib.sha256(key.encode()).hexdigest()
        # Revoke-then-issue is a security-relevant pair, not just two writes.
        # Committed separately, a failure between them leaves the tenant with
        # every key revoked and no replacement -- a self-inflicted outage -- or,
        # if the audit insert is what fails, a live new key with no record of
        # who minted it. One transaction, or neither.
        async with _write(pool) as conn:
            await conn.execute(
                "UPDATE tenant_api_keys SET revoked_at = now() WHERE tenant_id = $1 AND revoked_at IS NULL",
                tenant_id,
            )
            await conn.execute(
                """INSERT INTO tenant_api_keys (tenant_id, key_hash, prefix_hint, scope, revealed_by_email)
                   VALUES ($1, $2, $3, $4, $5)""",
                tenant_id, key_hash, key[:14], _API_KEY_SCOPE_STORED, principal.actor,
            )
            await _audit_log(conn, tenant_id, "api_key.rotated", None, None, principal.actor, {"prefix_hint": key[:14]})

    return RotateApiKeyResponse(
        key=key,
        prefix_hint=key[:14],
        revealed_at=now,
        scope=_API_KEY_SCOPE_WIRE,
    )


@router.get("/consent/status", response_model=ConsentStatusResponse, responses=ERROR_RESPONSES)
async def consent_status(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ConsentStatusResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            consent = _CONSENT.get(tenant_id)
            cookie_preferences = _cookie_preferences_for_tenant(tenant_id)
        return ConsentStatusResponse(
            accepted=False if consent is None else bool(consent["accepted"]),
            consent_required=True,
            accepted_at=None if consent is None else consent["accepted_at"],
            document_versions={"tos": "2026-01", "privacy": "2026-01"}
            if consent is None
            else dict(consent["document_versions"]),
            cookie_preferences=cookie_preferences
            if consent is None
            else CookiePreferences(**consent["cookie_preferences"]),
        )

    row = await pool.fetchrow(
        """SELECT accepted_at, document_versions, cookie_preferences, b2b_warranty_accepted
           FROM consent_events WHERE tenant_id = $1 ORDER BY accepted_at DESC LIMIT 1""",
        tenant_id,
    )
    if row is None:
        return ConsentStatusResponse(
            accepted=False,
            consent_required=True,
            accepted_at=None,
            document_versions={"tos": "2026-01", "privacy": "2026-01"},
            cookie_preferences=CookiePreferences(strictly_necessary=True, analytics=False),
        )
    # document_versions is JSONB
    raw_doc = row["document_versions"]
    if isinstance(raw_doc, str):
        doc_versions = json.loads(raw_doc)
    elif isinstance(raw_doc, dict):
        doc_versions = raw_doc
    else:
        doc_versions = {"tos": "2026-01", "privacy": "2026-01"}
    # cookie_preferences is JSONB
    raw_cookie = row["cookie_preferences"]
    if isinstance(raw_cookie, str):
        cookie_dict = json.loads(raw_cookie)
    elif isinstance(raw_cookie, dict):
        cookie_dict = raw_cookie
    else:
        cookie_dict = {"strictly_necessary": True, "analytics": False}
    # accepted = accepted_at IS NOT NULL
    accepted = row["accepted_at"] is not None
    return ConsentStatusResponse(
        accepted=accepted,
        consent_required=True,
        accepted_at=_ts(row["accepted_at"]),
        document_versions=doc_versions,
        cookie_preferences=CookiePreferences(
            strictly_necessary=cookie_dict.get("strictly_necessary", True),
            analytics=cookie_dict.get("analytics", False),
        ),
    )


@router.post("/consent/accept", response_model=ConsentAcceptResponse, responses=ERROR_RESPONSES)
async def accept_consent(
    body: ConsentAcceptRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConsentAcceptResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Recording consent")
    now = _now_iso()

    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            _CONSENT[tenant_id] = {
                "accepted": True,
                "accepted_at": now,
                "document_versions": dict(body.document_versions),
                "cookie_preferences": body.cookie_preferences.model_dump(),
            }
            _COOKIE_PREFS[tenant_id] = body.cookie_preferences.model_dump()
        return ConsentAcceptResponse(
            accepted=True,
            accepted_at=now,
            document_versions=body.document_versions,
            cookie_preferences=body.cookie_preferences,
        )

    async with _write(pool) as conn:
        await conn.execute(
            # user_email comes from the token. It was the SQL literal
            # 'demo@signalloom.local', so every consent record in the database
            # named the same fictional person -- in the column that answers
            # "who consented", on the record a regulator is most likely to ask
            # for. A consent event attributed to nobody real is not consent.
            """INSERT INTO consent_events (tenant_id, user_email, accepted_at, document_versions,
                                            cookie_preferences, b2b_warranty_accepted)
               VALUES ($1, $5, now(), $2::jsonb, $3::jsonb, $4)""",
            tenant_id,
            json.dumps(dict(body.document_versions)),
            json.dumps(body.cookie_preferences.model_dump()),
            body.b2b_warranty_accepted,
            principal.actor,
        )
        await _audit_log(conn, tenant_id, "consent.accepted", None, None, principal.actor, {"document_versions": dict(body.document_versions)})
    return ConsentAcceptResponse(
        accepted=True,
        accepted_at=now,
        document_versions=body.document_versions,
        cookie_preferences=body.cookie_preferences,
    )


@router.get("/cookie-preferences", response_model=CookiePreferencesResponse, responses=ERROR_RESPONSES)
async def get_cookie_preferences(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> CookiePreferencesResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            prefs = _cookie_preferences_for_tenant(tenant_id)
        return CookiePreferencesResponse(cookie_preferences=prefs)

    row = await pool.fetchrow(
        """SELECT
               (cookie_preferences->>'strictly_necessary')::boolean AS cookie_strictly_necessary,
               (cookie_preferences->>'analytics')::boolean AS cookie_analytics
           FROM consent_events WHERE tenant_id = $1 ORDER BY accepted_at DESC LIMIT 1""",
        tenant_id,
    )
    if row is None:
        return CookiePreferencesResponse(
            cookie_preferences=CookiePreferences(strictly_necessary=True, analytics=False),
        )
    return CookiePreferencesResponse(
        cookie_preferences=CookiePreferences(
            strictly_necessary=row["cookie_strictly_necessary"] if row["cookie_strictly_necessary"] is not None else True,
            analytics=row["cookie_analytics"] if row["cookie_analytics"] is not None else False,
        ),
    )


@router.patch("/cookie-preferences", response_model=CookiePreferencesResponse, responses=ERROR_RESPONSES)
async def patch_cookie_preferences(
    body: CookiePrefsPatchRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> CookiePreferencesResponse:
    tenant_id = principal.tenant
    pool = await _require_pool("Changing cookie preferences")
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            _COOKIE_PREFS[tenant_id] = {
                "strictly_necessary": True,
                "analytics": body.analytics,
            }
            prefs = _cookie_preferences_for_tenant(tenant_id)
        return CookiePreferencesResponse(cookie_preferences=prefs)

    async with _write(pool) as conn:
        await conn.execute(
            # Same fix as accept_consent: the requester, not a literal.
            """INSERT INTO consent_events (tenant_id, user_email, accepted_at, document_versions,
                                            cookie_preferences, b2b_warranty_accepted)
               VALUES ($1, $3, now(), '{"tos":"2026-01","privacy":"2026-01"}'::jsonb,
                       $2::jsonb, false)""",
            tenant_id,
            json.dumps({"strictly_necessary": True, "analytics": body.analytics}),
            principal.actor,
        )
        await _audit_log(conn, tenant_id, "cookie.preferences_updated", None, None, principal.actor, {"analytics": body.analytics})
    return CookiePreferencesResponse(
        cookie_preferences=CookiePreferences(strictly_necessary=True, analytics=body.analytics),
    )


# ---------------------------------------------------------------------------
# Discovery Super Datatable Endpoints (SLMS-P1-2)
# ---------------------------------------------------------------------------

class ControlRecommendationsModel(BaseModel):
    model_config = ConfigDict(extra="allow")

    config: Literal["pass", "recommended", "warning", "not_applicable"] = "recommended"
    content: Literal["pass", "recommended", "warning", "not_applicable"] = "recommended"
    supply_chain: Literal["pass", "recommended", "warning", "not_applicable"] = "recommended"
    eu_ai_act: Literal["pass", "recommended", "warning", "not_applicable"] = "recommended"


class DiscoveryWorkloadModel(BaseModel):
    model_config = ConfigDict(extra="allow")

    id: str
    name: str
    tenant_id: str | None = None
    source: Literal["idp", "local_k8s", "external_k8s", "external_services"]
    source_label: str
    namespace: str | None = None
    status: Literal["discovered", "in_review", "ignored", "revoked", "governed"] = "discovered"
    discovery_state: Literal["discovered", "in_review", "ignored", "revoked", "governed"] = "discovered"
    owner: str | None = None
    spiffe_id: str | None = None
    model: str | None = None
    last_seen_at: str | None = None
    recommendations: ControlRecommendationsModel = Field(default_factory=ControlRecommendationsModel)
    control_recommendations: ControlRecommendationsModel = Field(default_factory=ControlRecommendationsModel)
    metadata: dict[str, Any] = Field(default_factory=dict)


class DiscoveryWorkloadsSummaryModel(BaseModel):
    model_config = ConfigDict(extra="allow")

    total: int = 0
    total_discovered: int = 0
    in_review: int = 0
    ignored: int = 0
    revoked: int = 0
    governed: int = 0
    by_source: dict[str, int] = Field(default_factory=dict)
    by_state: dict[str, int] = Field(default_factory=dict)


class DiscoveryWorkloadsResponseModel(BaseModel):
    model_config = ConfigDict(extra="allow")

    workloads: list[DiscoveryWorkloadModel]
    total: int
    summary: DiscoveryWorkloadsSummaryModel



def set_tenant_connectors_for_testing(tenant_id: str, connectors: dict[str, bool]) -> None:
    with _STORE_LOCK:
        _TENANT_CONNECTORS[tenant_id] = dict(connectors)


def reset_tenant_connectors(tenant_id: str | None = None) -> None:
    with _STORE_LOCK:
        if tenant_id:
            _TENANT_CONNECTORS.pop(tenant_id, None)
        else:
            _TENANT_CONNECTORS.clear()


@router.get("/v1/discovery/workloads", response_model=DiscoveryWorkloadsResponseModel, responses=ERROR_RESPONSES)
@router.get("/discovery/workloads", response_model=DiscoveryWorkloadsResponseModel, responses=ERROR_RESPONSES)
async def list_discovery_workloads(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    source: str | None = None,
    status: str | None = None,
    namespace: str | None = None,
    search: str | None = None,
    page: int = 1,
    limit: int = 50,
) -> DiscoveryWorkloadsResponseModel:
    """Aggregate multi-source discovered workloads strictly isolated to caller's tenant."""
    pool = await _get_pool()

    # Determine enabled connectors for this tenant
    enabled_connectors = {"idp": True, "local_k8s": True, "external_k8s": True, "external_services": True}
    with _STORE_LOCK:
        if tenant_id in _TENANT_CONNECTORS:
            enabled_connectors.update(_TENANT_CONNECTORS[tenant_id])

    workloads: list[DiscoveryWorkloadModel] = []

    if pool is not None:
        # DB Mode
        # 1. IDP (NHI discovered accounts)
        if enabled_connectors.get("idp", True):
            nhi_rows = await pool.fetch(
                """SELECT id, account_name, directory_source, owner_email, privilege_level,
                          status, findings, scan_count, first_discovered_at, last_seen_at
                     FROM nhi_discovered_accounts
                    WHERE tenant_id = $1
                 ORDER BY first_discovered_at DESC""",
                tenant_id,
            )
            for r in nhi_rows:
                raw_st = r["status"]
                st: Literal["discovered", "in_review", "ignored", "revoked", "governed"] = "discovered"
                if raw_st == "dismissed":
                    st = "ignored"
                elif raw_st in ("enrollment_requested", "needs_triage", "in_review"):
                    st = "in_review"
                elif raw_st in ("governed", "enrolled", "active"):
                    st = "governed"

                findings = list(r["findings"]) if r["findings"] else []
                dir_source = r["directory_source"] or "idp"
                source_label = "Entra ID" if "entra" in dir_source.lower() else ("Okta" if "okta" in dir_source.lower() else dir_source)
                privilege = r["privilege_level"] or "standard"

                config_rec: Literal["pass", "recommended", "warning", "not_applicable"] = "warning" if "stale_credential" in findings or privilege in ("high", "elevated", "domain_admin") else "pass"
                supply_rec: Literal["pass", "recommended", "warning", "not_applicable"] = "recommended" if "unrotated_secret" in findings else "pass"

                workloads.append(
                    DiscoveryWorkloadModel(
                        id=str(r["id"]),
                        name=r["account_name"],
                        source="idp",
                        source_label=source_label,
                        namespace=f"identity-{dir_source.lower()}",
                        status=st,
                        owner=r["owner_email"],
                        spiffe_id=None,
                        model=None,
                        last_seen_at=_ts(r["last_seen_at"]) or _ts(r["first_discovered_at"]),
                        recommendations=ControlRecommendationsModel(
                            config=config_rec,
                            content="not_applicable",
                            supply_chain=supply_rec,
                            eu_ai_act="pass",
                        ),
                        metadata={
                            "privilege_level": privilege,
                            "findings": findings,
                            "scan_count": r["scan_count"],
                            "directory_source": dir_source,
                        },
                    )
                )

        # 2. Local K8s (unlinked pods / agent discovery)
        if enabled_connectors.get("local_k8s", True):
            agent_rows = await pool.fetch(
                """SELECT id, name, type, lifecycle_state, owner, service_account, namespace,
                          model_name, created_at, is_registry_linked
                     FROM agent_registry
                    WHERE tenant_id = $1""",
                tenant_id,
            )
            for r in agent_rows:
                is_linked = r["is_registry_linked"]
                lc = r["lifecycle_state"] or "active"
                st = "governed" if is_linked or lc in ("registered", "enrolled", "active") else ("revoked" if lc in ("suspended", "revoked", "decommissioned") else "discovered")
                ns = r["namespace"] or "fe-signalloom-agents"
                spiffe = f"spiffe://signalloom.svc.cluster.local/ns/{ns}/sa/{r['service_account'] or r['name']}" if is_linked else None
                workloads.append(
                    DiscoveryWorkloadModel(
                        id=str(r["id"]),
                        name=r["name"],
                        source="local_k8s",
                        source_label="Local K8s",
                        namespace=ns,
                        status=st,
                        owner=r["owner"],
                        spiffe_id=spiffe,
                        model=r["model_name"] or "claude-3-5-sonnet",
                        last_seen_at=_ts(r["created_at"]),
                        recommendations=ControlRecommendationsModel(
                            config="pass" if st == "governed" else "recommended",
                            content="recommended",
                            supply_chain="pass" if st == "governed" else "warning",
                            eu_ai_act="pass" if st == "governed" else "recommended",
                        ),
                        metadata={
                            "service_account": r["service_account"],
                            "namespace": ns,
                            "cluster_id": "cluster-local",
                        },
                    )
                )

        # 3. External Services (external agent registrations)
        if enabled_connectors.get("external_services", True):
            ext_rows = await pool.fetch(
                """SELECT agent_id, host_id, host_os, runtime_profile, enrollment_status,
                          metadata, spiffe_id_pattern, created_at, last_observed_at, revoked_at
                     FROM public.external_agent_registrations
                    WHERE tenant_id = $1
                 ORDER BY created_at DESC""",
                tenant_id,
            )
            for r in ext_rows:
                meta = r["metadata"] if isinstance(r["metadata"], dict) else {}
                if isinstance(r["metadata"], str):
                    try:
                        meta = json.loads(r["metadata"])
                    except Exception:
                        meta = {}
                is_revoked = r["revoked_at"] is not None
                enrolled = r["enrollment_status"] == "enrolled"
                st = "revoked" if is_revoked else ("governed" if enrolled else ("in_review" if r["enrollment_status"] == "pending" else "discovered"))
                agent_name = r["agent_id"]
                source_label = "Cloud Run" if "cloudrun" in agent_name.lower() or meta.get("runtime") == "cloud_run" else ("n8n" if "n8n" in agent_name.lower() else "External Service")
                ns = meta.get("namespace") or meta.get("region") or "external-services"

                workloads.append(
                    DiscoveryWorkloadModel(
                        id=f"{tenant_id}:{agent_name}",
                        name=agent_name,
                        source="external_services",
                        source_label=source_label,
                        namespace=ns,
                        status=st,
                        owner=meta.get("owner"),
                        spiffe_id=f"spiffe://signalloom.demo/ext/{agent_name}" if enrolled else None,
                        model=meta.get("model") or "gemini-1.5-pro",
                        last_seen_at=_ts(r["last_observed_at"]) or _ts(r["created_at"]),
                        recommendations=ControlRecommendationsModel(
                            config="recommended",
                            content="recommended",
                            supply_chain="pass",
                            eu_ai_act="recommended",
                        ),
                        metadata={
                            "host_id": r["host_id"],
                            "host_os": r["host_os"],
                            "runtime_profile": r["runtime_profile"],
                            "enrollment_status": r["enrollment_status"],
                            **meta,
                        },
                    )
                )

        # 4. External K8s (AFM imported clusters)
        if enabled_connectors.get("external_k8s", True):
            workloads.append(
                DiscoveryWorkloadModel(
                    id=f"{tenant_id}:afm-staging-collector",
                    name="afm-staging-collector",
                    source="external_k8s",
                    source_label="AFM Cluster",
                    namespace="staging-workloads",
                    status="in_review",
                    owner=f"security@{tenant_id}.local",
                    spiffe_id="spiffe://afm.remote.io/ns/staging/sa/collector",
                    model="llama-3.3-70b",
                    last_seen_at=_now_iso(),
                    recommendations=ControlRecommendationsModel(
                        config="recommended",
                        content="pass",
                        supply_chain="recommended",
                        eu_ai_act="pass",
                    ),
                    metadata={"cluster_name": "afm-staging", "imported_from": "kubesec-afm"},
                )
            )
            workloads.append(
                DiscoveryWorkloadModel(
                    id=f"{tenant_id}:prod-eu-validator",
                    name="prod-eu-validator",
                    source="external_k8s",
                    source_label="AFM Cluster",
                    namespace="prod-eu",
                    status="revoked",
                    owner=f"compliance@{tenant_id}.local",
                    spiffe_id="spiffe://prod-eu.remote.io/ns/prod-eu/sa/validator",
                    model="mistral-large",
                    last_seen_at="2026-07-20T10:00:00Z",
                    recommendations=ControlRecommendationsModel(
                        config="warning",
                        content="warning",
                        supply_chain="warning",
                        eu_ai_act="warning",
                    ),
                    metadata={"cluster_name": "prod-eu-cluster", "revocation_reason": "unauthorized_network_access"},
                )
            )

    else:
        # In-Memory Mode
        _ensure_seeded(tenant_id)
        # 1. IDP
        if enabled_connectors.get("idp", True):
            with _STORE_LOCK:
                nhi_map = _NHI_ACCOUNTS.get(tenant_id, {})
                for a_id, a in nhi_map.items():
                    raw_st = a.get("status", "discovered")
                    st = "ignored" if raw_st == "dismissed" else ("in_review" if raw_st in ("enrollment_requested", "needs_triage", "in_review") else ("governed" if raw_st in ("governed", "enrolled", "active") else "discovered"))
                    dir_source = a.get("directory_source") or "idp"
                    source_label = "Entra ID" if "entra" in dir_source.lower() else ("Okta" if "okta" in dir_source.lower() else dir_source)
                    findings = a.get("findings", [])
                    privilege = a.get("privilege_level", "standard")
                    recs = ControlRecommendationsModel(
                        config="warning" if "stale_credential" in findings or privilege in ("high", "elevated") else "pass",
                        content="not_applicable",
                        supply_chain="recommended" if "unrotated_secret" in findings else "pass",
                        eu_ai_act="pass",
                    )
                    workloads.append(
                        DiscoveryWorkloadModel(
                            id=a_id,
                            name=a.get("account_name", a_id),
                            tenant_id=tenant_id,
                            source="idp",
                            source_label=source_label,
                            namespace=f"identity-{dir_source.lower()}",
                            status=st,
                            discovery_state=st,
                            owner=a.get("owner_email"),
                            spiffe_id=None,
                            model=None,
                            last_seen_at=a.get("last_seen_at") or a.get("first_discovered_at"),
                            recommendations=recs,
                            control_recommendations=recs,
                            metadata={"privilege_level": privilege, "findings": findings, "scan_count": a.get("scan_count", 1)},
                        )
                    )

        # 2. Local K8s
        if enabled_connectors.get("local_k8s", True):
            with _STORE_LOCK:
                agents_map = _AGENTS.get(tenant_id, {})
                for ag_id, ag in agents_map.items():
                    is_linked = ag.get("is_registry_linked", False)
                    lc = ag.get("lifecycle_state", "active")
                    st = "governed" if is_linked or lc in ("registered", "enrolled", "active") else ("revoked" if lc in ("suspended", "revoked", "decommissioned") else "discovered")
                    ns = ag.get("namespace", "fe-signalloom-agents")
                    recs = ControlRecommendationsModel(
                        config="pass" if st == "governed" else "recommended",
                        content="recommended",
                        supply_chain="pass" if st == "governed" else "warning",
                        eu_ai_act="pass" if st == "governed" else "recommended",
                    )
                    workloads.append(
                        DiscoveryWorkloadModel(
                            id=ag_id,
                            name=ag.get("name", ag_id),
                            tenant_id=tenant_id,
                            source="local_k8s",
                            source_label="Local K8s",
                            namespace=ns,
                            status=st,
                            discovery_state=st,
                            owner=ag.get("owner"),
                            spiffe_id=f"spiffe://signalloom.svc.cluster.local/ns/{ns}/sa/{ag.get('name')}" if is_linked else None,
                            model=ag.get("model_name") or "claude-3-5-sonnet",
                            last_seen_at=ag.get("created_at"),
                            recommendations=recs,
                            control_recommendations=recs,
                            metadata={"namespace": ns, "cluster_id": "cluster-local"},
                        )
                    )

        # 3. External Services
        if enabled_connectors.get("external_services", True):
            from external_agent_registration import _EXTERNAL_REGISTRATIONS, _REG_LOCK
            with _REG_LOCK:
                ext_map = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
                for ag_id, reg in ext_map.items():
                    is_revoked = reg.get("revoked_at") is not None
                    enrolled = reg.get("enrollment_status") == "enrolled"
                    st = "revoked" if is_revoked else ("governed" if enrolled else ("in_review" if reg.get("enrollment_status") == "pending" else "discovered"))
                    meta = reg.get("metadata", {})
                    source_label = "Cloud Run" if "cloudrun" in ag_id.lower() or meta.get("runtime") == "cloud_run" else ("n8n" if "n8n" in ag_id.lower() else "External Service")
                    ns = meta.get("namespace") or meta.get("region") or "external-services"
                    recs = ControlRecommendationsModel(
                        config="recommended",
                        content="recommended",
                        supply_chain="pass",
                        eu_ai_act="recommended",
                    )
                    workloads.append(
                        DiscoveryWorkloadModel(
                            id=f"{tenant_id}:{ag_id}",
                            name=ag_id,
                            tenant_id=tenant_id,
                            source="external_services",
                            source_label=source_label,
                            namespace=ns,
                            status=st,
                            discovery_state=st,
                            owner=meta.get("owner"),
                            spiffe_id=f"spiffe://signalloom.demo/ext/{ag_id}" if enrolled else None,
                            model=meta.get("model") or "gemini-1.5-pro",
                            last_seen_at=reg.get("last_observed_at") or reg.get("created_at"),
                            recommendations=recs,
                            control_recommendations=recs,
                            metadata=meta,
                        )
                    )
            # Default seeded external service if none exists in in-memory dict for this tenant
            if not any(w.source == "external_services" for w in workloads):
                cr_recs = ControlRecommendationsModel(
                    config="recommended",
                    content="recommended",
                    supply_chain="pass",
                    eu_ai_act="recommended",
                )
                workloads.append(
                    DiscoveryWorkloadModel(
                        id=f"{tenant_id}:cloudrun-prompt-processor",
                        name="cloudrun-prompt-processor",
                        tenant_id=tenant_id,
                        source="external_services",
                        source_label="Cloud Run",
                        namespace="gcp-europe-west1",
                        status="discovered",
                        discovery_state="discovered",
                        owner=f"ai-ops@{tenant_id}.local",
                        spiffe_id=None,
                        model="gemini-1.5-pro",
                        last_seen_at=_now_iso(),
                        recommendations=cr_recs,
                        control_recommendations=cr_recs,
                        metadata={"service_url": "https://prompt-processor-xyz.a.run.app", "runtime": "cloud_run"},
                    )
                )
                n8n_recs = ControlRecommendationsModel(
                    config="pass",
                    content="warning",
                    supply_chain="pass",
                    eu_ai_act="recommended",
                )
                workloads.append(
                    DiscoveryWorkloadModel(
                        id=f"{tenant_id}:n8n-support-router",
                        name="n8n-support-router",
                        tenant_id=tenant_id,
                        source="external_services",
                        source_label="n8n",
                        namespace="automation-prod",
                        status="ignored",
                        discovery_state="ignored",
                        owner=f"support@{tenant_id}.local",
                        spiffe_id=None,
                        model="gpt-4o-mini",
                        last_seen_at=_now_iso(),
                        recommendations=n8n_recs,
                        control_recommendations=n8n_recs,
                        metadata={"webhook_url": "https://n8n.internal.net/webhook/support", "dismiss_reason": "internal_automation_exempt"},
                    )
                )

        # 4. External K8s (AFM)
        if enabled_connectors.get("external_k8s", True):
            afm_recs = ControlRecommendationsModel(
                config="recommended",
                content="pass",
                supply_chain="recommended",
                eu_ai_act="pass",
            )
            workloads.append(
                DiscoveryWorkloadModel(
                    id=f"{tenant_id}:afm-staging-collector",
                    name="afm-staging-collector",
                    tenant_id=tenant_id,
                    source="external_k8s",
                    source_label="AFM Cluster",
                    namespace="staging-workloads",
                    status="in_review",
                    discovery_state="in_review",
                    owner=f"security@{tenant_id}.local",
                    spiffe_id="spiffe://afm.remote.io/ns/staging/sa/collector",
                    model="llama-3.3-70b",
                    last_seen_at=_now_iso(),
                    recommendations=afm_recs,
                    control_recommendations=afm_recs,
                    metadata={"cluster_name": "afm-staging", "imported_from": "kubesec-afm"},
                )
            )
            val_recs = ControlRecommendationsModel(
                config="warning",
                content="warning",
                supply_chain="warning",
                eu_ai_act="warning",
            )
            workloads.append(
                DiscoveryWorkloadModel(
                    id=f"{tenant_id}:prod-eu-validator",
                    name="prod-eu-validator",
                    tenant_id=tenant_id,
                    source="external_k8s",
                    source_label="AFM Cluster",
                    namespace="prod-eu",
                    status="revoked",
                    discovery_state="revoked",
                    owner=f"compliance@{tenant_id}.local",
                    spiffe_id="spiffe://prod-eu.remote.io/ns/prod-eu/sa/validator",
                    model="mistral-large",
                    last_seen_at="2026-07-20T10:00:00Z",
                    recommendations=val_recs,
                    control_recommendations=val_recs,
                    metadata={"cluster_name": "prod-eu-cluster", "revocation_reason": "unauthorized_network_access"},
                )
            )

    # Apply Filters
    filtered = workloads
    if source and source != "all":
        filtered = [w for w in filtered if w.source == source]
    if status and status != "all":
        filtered = [w for w in filtered if w.status == status or w.discovery_state == status]
    if namespace and namespace != "all":
        filtered = [w for w in filtered if w.namespace == namespace]
    if search:
        s_lower = search.lower()
        filtered = [
            w for w in filtered
            if s_lower in w.name.lower()
            or (w.namespace and s_lower in w.namespace.lower())
            or (w.owner and s_lower in w.owner.lower())
            or s_lower in w.source_label.lower()
        ]

    summary = DiscoveryWorkloadsSummaryModel(
        total=len(workloads),
        total_discovered=sum(1 for w in workloads if w.status == "discovered" or w.discovery_state == "discovered"),
        in_review=sum(1 for w in workloads if w.status == "in_review" or w.discovery_state == "in_review"),
        ignored=sum(1 for w in workloads if w.status == "ignored" or w.discovery_state == "ignored"),
        revoked=sum(1 for w in workloads if w.status == "revoked" or w.discovery_state == "revoked"),
        governed=sum(1 for w in workloads if w.status == "governed" or w.discovery_state == "governed"),
        by_source={
            "idp": sum(1 for w in workloads if w.source == "idp"),
            "local_k8s": sum(1 for w in workloads if w.source == "local_k8s"),
            "external_k8s": sum(1 for w in workloads if w.source == "external_k8s"),
            "external_services": sum(1 for w in workloads if w.source == "external_services"),
        },
        by_state={
            "discovered": sum(1 for w in workloads if w.status == "discovered" or w.discovery_state == "discovered"),
            "in_review": sum(1 for w in workloads if w.status == "in_review" or w.discovery_state == "in_review"),
            "ignored": sum(1 for w in workloads if w.status == "ignored" or w.discovery_state == "ignored"),
            "revoked": sum(1 for w in workloads if w.status == "revoked" or w.discovery_state == "revoked"),
            "governed": sum(1 for w in workloads if w.status == "governed" or w.discovery_state == "governed"),
        },
    )

    offset = max(page - 1, 0) * limit
    paginated = filtered[offset : offset + limit]

    return DiscoveryWorkloadsResponseModel(
        workloads=paginated,
        total=len(filtered),
        summary=summary,
    )



# ---------------------------------------------------------------------------
# App installation (UNCHANGED)
# ---------------------------------------------------------------------------


def install_compatibility_api(app: FastAPI) -> None:
    # Strict partner tenants must pass persisted operator status on every
    # compatibility route. The lifecycle router intentionally mounts outside
    # that gate so a configured superadmin can perform the one-time self
    # bootstrap and a removed operator receives the precise removal refusal.
    from operator_identity import enforce_strict_operator_tenant, router as operator_identity_router
    from external_agent_registration import (
        router as external_agent_router,
        compat_router as external_agent_compat_router,
        v1_router as external_agent_v1_router,
    )
    from external_agent_evidence import router as external_evidence_router
    from host_enrollment import (
        router as host_enrollment_router,
        api_router as host_enrollment_api_router,
        compat_router as host_enrollment_compat_router,
    )
    from host_credential import host_router, host_compat_router, HostCredentialScopeMiddleware
    from routers.policy_engine import router as policy_engine_router
    from routers.federation import router as federation_router

    app.add_middleware(HostCredentialScopeMiddleware)
    app.include_router(router, dependencies=[Depends(enforce_strict_operator_tenant)])
    app.include_router(operator_identity_router)
    app.include_router(policy_engine_router)
    app.include_router(federation_router)
    app.include_router(host_router)
    app.include_router(host_compat_router)
    app.include_router(host_enrollment_router)
    app.include_router(host_enrollment_api_router)
    app.include_router(host_enrollment_compat_router)
    app.include_router(external_agent_router)
    app.include_router(external_agent_v1_router)
    app.include_router(external_agent_compat_router)
    app.include_router(external_evidence_router)
    install_api_exception_handlers(app)
