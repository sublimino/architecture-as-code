"""Authenticated, tenant-scoped compatibility API for the local D2 dashboard."""
from __future__ import annotations

import base64
import binascii
import itertools
import json
import logging
import secrets
import threading
from datetime import datetime, timezone
from functools import lru_cache
from typing import Annotated, Any, Literal

import jwt
from fastapi import APIRouter, Depends, FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict
from starlette.exceptions import HTTPException as StarletteHTTPException

from config import settings

logger = logging.getLogger(__name__)


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


class IssueCredentialResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    name: str
    identity_token: str
    token_expires_at: str
    token_note: str


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


class AuditListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    events: list[AuditEventResponse]
    total: int
    page: int
    limit: int


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


class CookiePrefsPatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    analytics: bool


class APIError(Exception):
    def __init__(self, status_code: int, code: str, message: str):
        self.status_code = status_code
        self.code = code
        self.message = message


class JWTValidationError(ValueError):
    """An intentionally opaque JWT validation failure."""


def _error_response(status_code: int, code: str, message: str) -> JSONResponse:
    body = ErrorResponse(error=ErrorDetail(code=code, message=message))
    return JSONResponse(status_code=status_code, content=body.model_dump())


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


def authenticated_tenant(
    authorization: Annotated[str | None, Header()] = None,
) -> str:
    if authorization is None:
        raise APIError(401, "authentication_required", "Bearer authentication is required")
    scheme, separator, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not separator or not token or " " in token:
        raise APIError(401, "invalid_token", "Bearer token is invalid")
    try:
        claims = validate_jwt(token)
    except JWTValidationError:
        raise APIError(401, "invalid_token", "Bearer token is invalid") from None

    tenant = settings.api_subject_tenants.get(claims["sub"])
    if tenant is None:
        raise APIError(403, "tenant_forbidden", "Subject has no tenant access")
    return tenant


_STORE_LOCK = threading.Lock()
_AGENTS: dict[str, dict[str, dict[str, Any]]] = {}
_VIOLATIONS: dict[str, dict[str, dict[str, Any]]] = {}
_NHI_ACCOUNTS: dict[str, dict[str, dict[str, Any]]] = {}
_TENANT_FRAMEWORKS: dict[str, list[str]] = {}
_COOKIE_PREFS: dict[str, dict[str, bool]] = {}
_CONSENT: dict[str, dict[str, Any]] = {}
_AGENT_SEQ = itertools.count(1)


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _default_compliance_summary() -> dict[str, Any]:
    return {
        "total_controls": 6,
        "passing": 4,
        "failing": 1,
        "pending": 1,
        "posture_score": 0.82,
    }


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
        }
        _NHI_ACCOUNTS[tenant_id][f"{tenant_id}:nhi-2"]["dismissed_at"] = "2026-07-27T01:30:00Z"
        _NHI_ACCOUNTS[tenant_id][f"{tenant_id}:nhi-2"]["dismissed_by"] = "demo-actor"
        _TENANT_FRAMEWORKS[tenant_id] = ["eu-ai-act"]
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
    prefs = _COOKIE_PREFS[tenant_id]
    return CookiePreferences(**prefs)


def _tenant_settings_response(tenant_id: str) -> TenantSettingsResponse:
    return TenantSettingsResponse(
        tenant_id=tenant_id,
        org_name=f"{tenant_id} Org",
        plan_tier="enterprise",
        agent_count=len(_AGENTS[tenant_id]),
        billing_tier="annual",
        api_key_status="active",
        selected_frameworks=list(_TENANT_FRAMEWORKS[tenant_id]),
        consent_required=True,
        cookie_preferences=_cookie_preferences_for_tenant(tenant_id),
    )


router = APIRouter(prefix="/api", tags=["compatibility"])
ERROR_RESPONSES = {
    401: {"model": ErrorResponse},
    403: {"model": ErrorResponse},
    405: {"model": ErrorResponse},
    422: {"model": ErrorResponse},
    500: {"model": ErrorResponse},
    503: {"model": ErrorResponse},
}


@router.get("/agents", response_model=AgentListResponse, responses=ERROR_RESPONSES)
async def agents(tenant_id: Annotated[str, Depends(authenticated_tenant)]) -> AgentListResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        items = [AgentResponse(**agent) for agent in _AGENTS[tenant_id].values()]
    return AgentListResponse(agents=items, total=len(items))


@router.post("/agents", response_model=AgentResponse, responses=ERROR_RESPONSES)
async def create_agent(
    body: AgentCreateRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> AgentResponse:
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


@router.post("/agents/{agent_id}/credentials", response_model=IssueCredentialResponse, responses=ERROR_RESPONSES)
async def issue_agent_credential(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> IssueCredentialResponse:
    _ensure_seeded(tenant_id)
    now = _now_iso()
    token = f"demo.{secrets.token_urlsafe(18)}"
    return IssueCredentialResponse(
        agent_id=agent_id,
        name=f"{agent_id.split(':')[-1]} credential",
        identity_token=token,
        token_expires_at="2026-08-26T00:00:00Z",
        token_note=f"Issued for tenant {tenant_id} at {now}",
    )


@router.get("/agents/{agent_id}", response_model=AgentResponse, responses=ERROR_RESPONSES)
async def get_agent(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> AgentResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        agent = _AGENTS[tenant_id].get(agent_id)
        if agent is None:
            agent = _synth_agent(tenant_id, agent_id)
    return AgentResponse(**agent)


@router.post("/agents/{agent_id}/transition", response_model=TransitionResponse, responses=ERROR_RESPONSES)
async def transition_agent(
    agent_id: str,
    body: TransitionRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TransitionResponse:
    _ensure_seeded(tenant_id)
    now = _now_iso()
    with _STORE_LOCK:
        agent = _AGENTS[tenant_id].get(agent_id)
        from_state = "registered" if agent is None else str(agent["lifecycle_state"])
        if agent is None:
            agent = _synth_agent(tenant_id, agent_id)
        agent["lifecycle_state"] = body.to_state
        agent["last_transition_at"] = now
        agent["last_transition_by"] = "demo-actor"
        _AGENTS[tenant_id][agent_id] = agent
    return TransitionResponse(
        agent_id=agent_id,
        from_state=from_state,
        to_state=body.to_state,
        actor="demo-actor",
        reason=body.reason,
        timestamp=now,
    )


@router.get("/agents/{agent_id}/violations", response_model=ViolationListResponse, responses=ERROR_RESPONSES)
async def get_agent_violations(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ViolationListResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        violations = [
            ViolationResponse(**violation)
            for violation in _VIOLATIONS[tenant_id].values()
        ]
    return ViolationListResponse(violations=violations, total=len(violations))


@router.post("/agents/violations/{violation_id}/acknowledge", responses=ERROR_RESPONSES)
async def acknowledge_violation(
    violation_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    _ensure_seeded(tenant_id)
    now = _now_iso()
    with _STORE_LOCK:
        violation = _VIOLATIONS[tenant_id].get(violation_id)
        if violation is None:
            violation = _seed_unknown_violation(tenant_id, violation_id)
        violation["status"] = "acknowledged"
        violation["acknowledged_by"] = "demo-actor"
        violation["acknowledged_at"] = now
    return {"status": "acknowledged"}


@router.post("/agents/{agent_id}/compliance/{control_id}/reassess", response_model=ReassessmentResponse, responses=ERROR_RESPONSES)
async def request_reassessment(
    agent_id: str,
    control_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ReassessmentResponse:
    _ensure_seeded(tenant_id)
    now = _now_iso()
    return ReassessmentResponse(
        agent_id=agent_id,
        control_id=control_id,
        status="reassessment_requested",
        reassessment_requested_at=now,
        reassessment_requested_by="demo-actor",
        clickup_task_id=None,
    )


@router.get("/compliance/summary", response_model=ComplianceSummaryResponse, responses=ERROR_RESPONSES)
async def compliance_summary(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ComplianceSummaryResponse:
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


@router.get("/compliance/posture", response_model=PostureResponse, responses=ERROR_RESPONSES)
async def compliance_posture(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> PostureResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        agents = list(_AGENTS[tenant_id].values())
    postures = [
        AgentPosture(
            agent_id=agents[0]["id"],
            agent_name=agents[0]["name"],
            posture_score=0.9,
            results=[
                AgentComplianceResultResponse(
                    agent_id=agents[0]["id"],
                    control_id="eu-ai-act:art-9",
                    control_name="Risk management system",
                    framework_name="EU AI Act",
                    status="passing",
                    assessed_at="2026-07-27T01:00:00Z",
                    evidence_ref="evidence://risk-register/1",
                ),
                AgentComplianceResultResponse(
                    agent_id=agents[0]["id"],
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
    if len(agents) > 1:
        postures.append(
            AgentPosture(
                agent_id=agents[1]["id"],
                agent_name=agents[1]["name"],
                posture_score=0.74,
                results=[
                    AgentComplianceResultResponse(
                        agent_id=agents[1]["id"],
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


@router.get("/compliance/frameworks", response_model=list[FrameworkResponse], responses=ERROR_RESPONSES)
async def compliance_frameworks(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> list[FrameworkResponse]:
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


@router.get("/compliance/export", responses=ERROR_RESPONSES)
async def compliance_export(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    format: Literal["json", "pdf", "both"] = "json",
) -> dict[str, str]:
    _ensure_seeded(tenant_id)
    now = _now_iso()
    return {
        "format": format,
        "generated_at": now,
        "url": f"https://reports.local/{tenant_id}/{format}.out",
    }


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
    _ensure_seeded(tenant_id)
    base_events = [
        AuditEventResponse(
            id=f"{tenant_id}:audit-1",
            timestamp="2026-07-27T01:00:00Z",
            event_type="agent.created",
            agent_id=f"{tenant_id}:agent-1",
            agent_name="Inventory Agent",
            actor="demo-actor",
            detail={"source": "mock", "from": from_, "to": to},
        ),
        AuditEventResponse(
            id=f"{tenant_id}:audit-2",
            timestamp="2026-07-27T01:10:00Z",
            event_type=type or "agent.transitioned",
            agent_id=agent or f"{tenant_id}:agent-2",
            agent_name="Triage Agent",
            actor="demo-actor",
            detail={"to_state": "active", "filter_agent": agent},
        ),
        AuditEventResponse(
            id=f"{tenant_id}:audit-3",
            timestamp="2026-07-27T01:20:00Z",
            event_type="compliance.reassess_requested",
            agent_id=f"{tenant_id}:agent-1",
            agent_name="Inventory Agent",
            actor="demo-actor",
            detail={"control_id": "eu-ai-act:art-9", "query_type": type},
        ),
    ]
    start = max(page - 1, 0) * limit
    end = start + limit
    return AuditListResponse(events=base_events[start:end], total=3, page=page, limit=limit)


@router.get("/nhi/scans", response_model=NHIScanListResponse, responses=ERROR_RESPONSES)
async def nhi_scans(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> NHIScanListResponse:
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


@router.get("/nhi/discovered", response_model=NHIDiscoveredResponse, responses=ERROR_RESPONSES)
async def nhi_discovered(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    page: int = 1,
    limit: int = 50,
    status: str | None = None,
) -> NHIDiscoveredResponse:
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


@router.post("/nhi/discovered/{account_id}/enroll", responses=ERROR_RESPONSES)
async def enroll_nhi_account(
    account_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        account = _NHI_ACCOUNTS[tenant_id].get(account_id)
        if account is None:
            account = _seed_unknown_account(tenant_id, account_id)
        account["status"] = "enrollment_requested"
        account["dismissed_at"] = None
        account["dismissed_by"] = None
    return {"account_id": account_id, "status": "enrollment_requested"}


@router.post("/nhi/discovered/{account_id}/dismiss", responses=ERROR_RESPONSES)
async def dismiss_nhi_account(
    account_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    _ensure_seeded(tenant_id)
    now = _now_iso()
    with _STORE_LOCK:
        account = _NHI_ACCOUNTS[tenant_id].get(account_id)
        if account is None:
            account = _seed_unknown_account(tenant_id, account_id)
        account["status"] = "dismissed"
        account["dismissed_at"] = now
        account["dismissed_by"] = "demo-actor"
        account["changes_since_dismissal"] = False
        account["previous_risk_flags"] = list(account["findings"])
    return {"account_id": account_id, "status": "dismissed"}


@router.get("/nhi/report/json", responses=ERROR_RESPONSES)
async def nhi_report_json(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, Any]:
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


@router.get("/tenant/settings", response_model=TenantSettingsResponse, responses=ERROR_RESPONSES)
async def tenant_settings(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TenantSettingsResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        return _tenant_settings_response(tenant_id)


@router.patch("/tenant/settings/frameworks", response_model=TenantSettingsResponse, responses=ERROR_RESPONSES)
async def patch_tenant_frameworks(
    body: FrameworksPatchRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TenantSettingsResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        _TENANT_FRAMEWORKS[tenant_id] = list(body.selected_frameworks)
        return _tenant_settings_response(tenant_id)


@router.post("/support", response_model=SupportRequestResponse, responses=ERROR_RESPONSES)
async def create_support_request(
    body: SupportRequestCreate,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> SupportRequestResponse:
    _ensure_seeded(tenant_id)
    support_id = f"{tenant_id}:support-{secrets.token_hex(4)}"
    return SupportRequestResponse(
        id=support_id,
        subject=body.subject,
        urgency=body.urgency,
        submitted_at=_now_iso(),
        clickup_task_id=None,
    )


@router.post("/tenants/{tenant_id_path}/api-keys/initial", response_model=InitialApiKeyResponse, responses=ERROR_RESPONSES)
async def create_initial_api_key(
    tenant_id_path: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> InitialApiKeyResponse:
    _ensure_seeded(tenant_id)
    key = f"sl_live_{tenant_id_path}_{secrets.token_urlsafe(18)}"
    return InitialApiKeyResponse(
        key=key,
        prefix_hint=key[:14],
        revealed_at=_now_iso(),
    )


@router.post("/tenants/{tenant_id_path}/api-keys/rotate", response_model=RotateApiKeyResponse, responses=ERROR_RESPONSES)
async def rotate_api_key(
    tenant_id_path: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> RotateApiKeyResponse:
    _ensure_seeded(tenant_id)
    key = f"sl_live_{tenant_id_path}_{secrets.token_urlsafe(18)}"
    return RotateApiKeyResponse(
        key=key,
        prefix_hint=key[:14],
        revealed_at=_now_iso(),
        scope="tenant:read-write",
    )


@router.get("/consent/status", response_model=ConsentStatusResponse, responses=ERROR_RESPONSES)
async def consent_status(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ConsentStatusResponse:
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


@router.post("/consent/accept", response_model=ConsentAcceptResponse, responses=ERROR_RESPONSES)
async def accept_consent(
    body: ConsentAcceptRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ConsentAcceptResponse:
    _ensure_seeded(tenant_id)
    now = _now_iso()
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


@router.get("/cookie-preferences", response_model=CookiePreferencesResponse, responses=ERROR_RESPONSES)
async def get_cookie_preferences(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> CookiePreferencesResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        prefs = _cookie_preferences_for_tenant(tenant_id)
    return CookiePreferencesResponse(cookie_preferences=prefs)


@router.patch("/cookie-preferences", response_model=CookiePreferencesResponse, responses=ERROR_RESPONSES)
async def patch_cookie_preferences(
    body: CookiePrefsPatchRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> CookiePreferencesResponse:
    _ensure_seeded(tenant_id)
    with _STORE_LOCK:
        _COOKIE_PREFS[tenant_id] = {
            "strictly_necessary": True,
            "analytics": body.analytics,
        }
        prefs = _cookie_preferences_for_tenant(tenant_id)
    return CookiePreferencesResponse(cookie_preferences=prefs)


def install_compatibility_api(app: FastAPI) -> None:
    app.include_router(router)

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
        logger.exception("compatibility API request failed", exc_info=exc)
        return _error_response(500, "internal_error", "Internal server error")
