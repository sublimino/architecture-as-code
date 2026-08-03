"""Authenticated, tenant-scoped compatibility API for the local D2 dashboard."""
from __future__ import annotations

import base64
import binascii
import hashlib
import itertools
import json
import logging
import os
import secrets
import threading
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from typing import Annotated, Any, Literal

import asyncpg
import httpx
import jwt
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from starlette.exceptions import HTTPException as StarletteHTTPException

from config import settings

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


# Defined after AuditEventResponse: StunAgentResponse embeds one, and the point
# of embedding it is that the caller sees the exact row that was written rather
# than a paraphrase of it.
class StunAgentRequest(BaseModel):
    """Context the dashboard supplies when it records a stun.

    Every field is optional. The SuperCred proxy performs the cluster-side
    action and this endpoint records it; if the caller can tell us nothing about
    what it just did, an event with no context still beats no event at all.
    """

    model_config = ConfigDict(extra="forbid")

    agent_name: str | None = None
    namespace: str | None = None
    reason: str | None = None
    outcome: str | None = None


class StunAgentResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    from_state: str
    to_state: str
    actor: str
    stunned_at: str
    event: AuditEventResponse


class ComplianceSummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    total_agents: int
    agents_assessed: int
    controls_passing: int
    controls_failing: int
    controls_pending: int
    posture_score: float | None


class PolicyFrameworkSummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    versions: list[str]
    totalControls: int
    passedControls: int
    failedControls: int
    totalExposureGbp: int


class PolicySummaryResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    totalChecks: int
    passed: int
    failed: int
    totalAle: int
    totalVar95: int
    totalTvar: int
    totalCarriedGbp: int
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


# ---------------------------------------------------------------------------
# asyncpg connection pool (lazy-init, graceful fallback to fixtures)
# ---------------------------------------------------------------------------

_pool: asyncpg.Pool | None = None
_pool_init_attempted: bool = False
_pool_lock = threading.Lock()


async def _get_pool() -> asyncpg.Pool | None:
    """Return the shared asyncpg pool, or None if DB is unconfigured/unavailable."""
    global _pool, _pool_init_attempted
    if _pool is not None:
        return _pool
    if _pool_init_attempted:
        return None
    with _pool_lock:
        if _pool is not None:
            return _pool
        if _pool_init_attempted:
            return None
        _pool_init_attempted = True
        dsn = settings.database_url
        if not dsn:
            logger.info("database_url is empty; running in fixture mode")
            return None
        try:
            _pool = await asyncpg.create_pool(
                dsn, min_size=2, max_size=10, command_timeout=10,
            )
            logger.info("asyncpg pool created successfully")
            return _pool
        except (asyncpg.PostgresError, OSError, asyncio.TimeoutError) as exc:
            logger.warning("Failed to create asyncpg pool, falling back to fixtures: %s", exc)
            return None


# We need asyncio for the TimeoutError reference above
import asyncio  # noqa: E402


# ---------------------------------------------------------------------------
# DB helper utilities
# ---------------------------------------------------------------------------


def _ts(value: datetime | None) -> str | None:
    """Convert a datetime to ISO 8601 string with Z suffix, or None."""
    if value is None:
        return None
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
    await executor.execute(
        """INSERT INTO audit_events (tenant_id, event_type, agent_id, agent_name, actor, detail)
           VALUES ($1, $2, $3, $4, $5, $6::jsonb)""",
        tenant_id, event_type, agent_uuid, agent_name, actor, json.dumps(detail),
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


def _agent_response_from_row(row: asyncpg.Record, compliance: ComplianceSummaryInline) -> AgentResponse:
    """Build an AgentResponse from a DB row + pre-computed compliance summary."""
    return AgentResponse(
        id=str(row["id"]),
        name=row["name"],
        type=row["origin"],
        owner=row["owner"],
        tenant_id=row["tenant_id"],
        lifecycle_state=row["lifecycle_state"],
        last_transition_at=_ts(row["last_transition_at"]),
        last_transition_by=None,
        eu_ai_act_risk_class=row["eu_ai_act_risk_class"],
        compliance_summary=compliance,
        model_name=row["model_name"],
        created_at=_ts(row["created_at"]),
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
_COOKIE_PREFS: dict[str, dict[str, bool]] = {}
_CONSENT: dict[str, dict[str, Any]] = {}
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
) -> dict[str, Any]:
    """Fixture-path twin of ``_audit_log``. Returns the recorded event."""
    event = {
        "id": f"{tenant_id}:audit-mem-{next(_AUDIT_SEQ)}",
        "timestamp": _now_iso(),
        "event_type": event_type,
        "agent_id": agent_id,
        "agent_name": agent_name,
        "actor": actor,
        "detail": detail,
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
    with _STORE_LOCK:
        for store in (
            _AGENTS, _VIOLATIONS, _NHI_ACCOUNTS, _TENANT_FRAMEWORKS,
            _TENANT_PREFERENCES, _COOKIE_PREFS, _CONSENT, _AUDIT_EVENTS,
        ):
            store.pop(tenant_id, None)


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# Must stay in step with the DEFAULTs in migration 005_tenant_scan_preferences
# and DEFAULT_PREFERENCES in dashboard-signalloom/src/pages/OnboardingWizard.tsx.
DEFAULT_SCAN_CADENCE_HOURS = 24
DEFAULT_ALERT_THRESHOLD = 1


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
    if agent_uuid is None:
        raise APIError(404, "not_found", "Agent not found")

    row = await conn.fetchrow(
        "SELECT id, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
        agent_uuid, tenant_id,
    )
    if row is None:
        raise APIError(404, "not_found", "Agent not found")
    return agent_uuid, str(row["name"])


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
    prefs = _COOKIE_PREFS[tenant_id]
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
        agent_count=len(_AGENTS[tenant_id]),
        billing_tier="annual",
        api_key_status="active",
        selected_frameworks=list(_TENANT_FRAMEWORKS[tenant_id]),
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
    return value if value in {"passed", "failed", "error", "pending"} else "pending"


def _crypto_proof_from_payload(payload: object) -> CryptoProof | None:
    if not isinstance(payload, dict):
        return None
    name = payload.get("name")
    title = payload.get("title")
    description = payload.get("description")
    expectation = payload.get("expectation")
    evidence = payload.get("evidence")
    if not all(isinstance(field, str) and field for field in (name, title, description, expectation, evidence)):
        return None
    return CryptoProof(
        name=name,
        kind=_coerce_crypto_kind(payload.get("kind")),
        status=_coerce_crypto_status(payload.get("status")),
        title=title,
        description=description,
        expectation=expectation,
        evidence=evidence,
    )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("/agents", response_model=AgentListResponse, responses=ERROR_RESPONSES)
async def agents(tenant_id: Annotated[str, Depends(authenticated_tenant)]) -> AgentListResponse:
    # --- k8s discovery (always attempted) ---
    k8s_agents: list[AgentResponse] = []
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(AGENT_DISCOVERY_URL)
            response.raise_for_status()
            payload = response.json()
        if not isinstance(payload, dict):
            raise TypeError("agent discovery payload must be an object")
        discovered_agents = payload.get("agents", [])
        if not isinstance(discovered_agents, list):
            raise TypeError("agent discovery agents must be a list")
        for discovered in discovered_agents:
            if not isinstance(discovered, dict):
                continue
            discovered_id = discovered.get("id")
            if discovered_id is None:
                continue
            agent_id = str(discovered_id)
            k8s_agents.append(
                AgentResponse(
                    id=agent_id,
                    name=str(discovered.get("name") or agent_id),
                    type=discovered.get("type"),
                    owner=None,
                    tenant_id=tenant_id,
                    lifecycle_state=str(discovered.get("state") or "idle"),
                    last_transition_at=None,
                    last_transition_by=None,
                    eu_ai_act_risk_class=None,
                    compliance_summary=ComplianceSummaryInline(
                        total_controls=0,
                        passing=0,
                        failing=0,
                        pending=0,
                        posture_score=0,
                    ),
                    model_name=discovered.get("model"),
                    created_at=discovered.get("created_at"),
                )
            )
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        pass

    # --- DB agents ---
    pool = await _get_pool()
    if pool is None:
        # Fixture mode: return only k8s agents (original behaviour)
        return AgentListResponse(agents=k8s_agents, total=len(k8s_agents))

    db_rows = await pool.fetch(
        "SELECT * FROM agent_registry WHERE tenant_id = $1 ORDER BY created_at", tenant_id,
    )
    db_agents: list[AgentResponse] = []
    for row in db_rows:
        compliance = await _compliance_summary_for_agent(pool, row["id"])
        db_agents.append(_agent_response_from_row(row, compliance))

    merged = k8s_agents + db_agents
    return AgentListResponse(agents=merged, total=len(merged))


@router.get("/health/crypto", response_model=CryptoHealthResponse, responses=ERROR_RESPONSES)
async def crypto_health(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> CryptoHealthResponse:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(CRYPTO_HEALTH_URL)
            response.raise_for_status()
            payload = response.json()
        if not isinstance(payload, dict):
            raise TypeError("crypto health payload must be an object")
        proxy_proofs = payload.get("proofs", [])
        if not isinstance(proxy_proofs, list):
            raise TypeError("crypto health proofs must be a list")
        proofs = []
        for proxy_proof in proxy_proofs:
            proof = _crypto_proof_from_payload(proxy_proof)
            if proof is not None:
                proofs.append(proof)
        return CryptoHealthResponse(tenant_id=tenant_id, proofs=proofs)
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        return CryptoHealthResponse(tenant_id=tenant_id, proofs=[])


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
        logger.warning("network tests: fake-integration-proxy unreachable", exc_info=True)
        raise HTTPException(status_code=502, detail=f"network test results unavailable: {exc}") from exc


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
        raise HTTPException(status_code=502, detail=f"could not reach the network test runner: {exc}") from exc
    # The proxy is the source of truth for the status code — 202 started,
    # 409 already running, 502 the proxy's own upstream failed. Forwarding it
    # unchanged means the "already running" guard against double-submits
    # lives in exactly one place.
    return JSONResponse(status_code=response.status_code, content=payload)


@router.post("/agents", response_model=AgentResponse, responses=ERROR_RESPONSES)
async def create_agent(
    body: AgentCreateRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> AgentResponse:
    pool = await _get_pool()
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
    try:
        async with _write(pool) as conn:
            row = await conn.fetchrow(
                """INSERT INTO agent_registry (tenant_id, name, display_name, origin, owner, lifecycle_state, eu_ai_act_risk_class, model_name)
                   VALUES ($1, $2, $3, $4, $5, 'registered', 'limited', 'gpt-5.4-mini')
                   RETURNING *""",
                tenant_id, body.name, body.name, body.type, body.owner,
            )
            compliance = await _compliance_summary_for_agent(conn, row["id"])
            await _audit_log(conn, tenant_id, "agent.created", str(row["id"]), body.name, "demo-actor", {"source": "api"})
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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> IssueCredentialResponse:
    token = f"demo.{secrets.token_urlsafe(18)}"
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    issued_at = _now_iso()
    expires_at, expires_at_iso = _credential_expiry()
    pool = await _get_pool()
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
                conn, tenant_id, "agent.credential_issued", agent_id, name, "demo-actor",
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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> RevokeCredentialResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _fixture_agent_for_credentials(tenant_id, agent_id)
            tokens_revoked = 0
            for credential in _AGENT_CREDENTIALS[tenant_id].get(agent_id, []):
                if credential["revoked_at"] is None:
                    credential["revoked_at"] = _now_iso()
                    credential["revoked_by"] = "demo-actor"
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
            tenant_id, agent_uuid, "demo-actor",
        )
        tokens_revoked = 0 if row is None else int(row["tokens_revoked"])
        await _audit_log(
            conn, tenant_id, "agent.credential_revoked", agent_id, agent_name, "demo-actor",
            {"tokens_revoked": tokens_revoked},
        )
    return RevokeCredentialResponse(
        agent_id=agent_id,
        name=agent_name,
        tokens_revoked=tokens_revoked,
    )


@router.get("/agents/{agent_id}", response_model=AgentResponse, responses=ERROR_RESPONSES)
async def get_agent(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> AgentResponse:
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _AGENTS[tenant_id].get(agent_id)
            if agent is None:
                agent = _synth_agent(tenant_id, agent_id)
        return AgentResponse(**agent)

    agent_uuid = _try_uuid(agent_id)
    if agent_uuid is None:
        # Non-UUID id (e.g. k8s-style) -- synthesize
        return AgentResponse(**_synth_agent(tenant_id, agent_id))

    row = await pool.fetchrow(
        "SELECT * FROM agent_registry WHERE id = $1 AND tenant_id = $2", agent_uuid, tenant_id,
    )
    if row is None:
        return AgentResponse(**_synth_agent(tenant_id, agent_id))
    compliance = await _compliance_summary_for_agent(pool, row["id"])
    return _agent_response_from_row(row, compliance)


@router.post("/agents/{agent_id}/transition", response_model=TransitionResponse, responses=ERROR_RESPONSES)
async def transition_agent(
    agent_id: str,
    body: TransitionRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TransitionResponse:
    pool = await _get_pool()
    now = _now_iso()

    if pool is None:
        _ensure_seeded(tenant_id)
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

    agent_uuid = _try_uuid(agent_id)
    if agent_uuid is None:
        return TransitionResponse(
            agent_id=agent_id,
            from_state="registered",
            to_state=body.to_state,
            actor="demo-actor",
            reason=body.reason,
            timestamp=now,
        )

    # The read is inside the transaction with the update and the audit row, so
    # the from_state the audit trail records is the state the update actually
    # moved away from.
    async with _write(pool) as conn:
        row = await conn.fetchrow(
            "SELECT lifecycle_state, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
            agent_uuid, tenant_id,
        )
        from_state = "registered" if row is None else row["lifecycle_state"]
        agent_name = None if row is None else row["name"]

        if row is not None:
            await conn.execute(
                """UPDATE agent_registry SET lifecycle_state = $1, last_transition_at = now()
                   WHERE id = $2 AND tenant_id = $3""",
                body.to_state, agent_uuid, tenant_id,
            )

        await _audit_log(
            conn, tenant_id, "agent.transitioned", agent_id, agent_name, "demo-actor",
            {"from_state": from_state, "to_state": body.to_state, "reason": body.reason},
        )
    return TransitionResponse(
        agent_id=agent_id,
        from_state=from_state,
        to_state=body.to_state,
        actor="demo-actor",
        reason=body.reason,
        timestamp=now,
    )


STUNNED_LIFECYCLE_STATE = "suspended"


@router.post("/agents/{agent_id}/stun", response_model=StunAgentResponse, responses=ERROR_RESPONSES)
async def stun_agent(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    body: StunAgentRequest | None = None,
) -> StunAgentResponse:
    """Record an operator isolating an agent.

    The cluster-side action belongs to the SuperCred proxy -- it relabels the
    pod and revokes the OpenBao lease -- and that proxy has no database. So the
    durable half lives here: the lifecycle change and its ``audit_events`` row,
    written inside one ``_write`` transaction, exactly as ``transition_agent``
    and ``rotate_api_key`` do. An enforcement action that persisted with no
    matching audit row is the failure mode migration 007 and ``_write`` exist to
    rule out, and it is worse for a stun than for anything else: the agent is
    cut off and nobody can say who did it.

    ``agent_id`` is deliberately not required to resolve to a registry row.
    SuperCred agent ids are Kubernetes pod names, so the interesting case --
    isolating a workload the registry has never seen -- is precisely the one a
    UUID lookup would drop. When the id does resolve, the state change and the
    event commit together; when it does not, the event is still written, with
    the raw id preserved in ``detail.agent_ref``.
    """
    req = body or StunAgentRequest()
    reason = req.reason or "operator-initiated stun"
    outcome = req.outcome or "stunned"
    now = _now_iso()
    pool = await _get_pool()

    def _detail(from_state: str) -> dict[str, Any]:
        return {
            "outcome": outcome,
            "reason": reason,
            "namespace": req.namespace,
            "from_state": from_state,
            "to_state": STUNNED_LIFECYCLE_STATE,
            "agent_ref": agent_id,
        }

    if pool is None:
        _ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _AGENTS[tenant_id].get(agent_id)
            from_state = "active" if agent is None else str(agent["lifecycle_state"])
            agent_name = req.agent_name or (None if agent is None else str(agent["name"]))
            if agent is not None:
                agent["lifecycle_state"] = STUNNED_LIFECYCLE_STATE
                agent["last_transition_at"] = now
                agent["last_transition_by"] = "demo-actor"
        event = _record_memory_audit(
            tenant_id, "agent.stunned", agent_id, agent_name, "demo-actor", _detail(from_state),
        )
        return StunAgentResponse(
            agent_id=agent_id,
            from_state=from_state,
            to_state=STUNNED_LIFECYCLE_STATE,
            actor="demo-actor",
            stunned_at=now,
            event=AuditEventResponse(**event),
        )

    agent_uuid = _try_uuid(agent_id)

    # The read, the update and the audit insert share one transaction, so the
    # from_state recorded is the state the update actually moved away from --
    # and a rejected audit row takes the state change down with it.
    async with _write(pool) as conn:
        row = None
        if agent_uuid is not None:
            row = await conn.fetchrow(
                "SELECT lifecycle_state, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
                agent_uuid, tenant_id,
            )
        from_state = "active" if row is None else str(row["lifecycle_state"])
        agent_name = req.agent_name or (None if row is None else row["name"])

        if row is not None:
            await conn.execute(
                """UPDATE agent_registry SET lifecycle_state = $1, last_transition_at = now()
                   WHERE id = $2 AND tenant_id = $3""",
                STUNNED_LIFECYCLE_STATE, agent_uuid, tenant_id,
            )

        await _audit_log(
            conn, tenant_id, "agent.stunned", agent_id, agent_name, "demo-actor",
            _detail(from_state),
        )

    return StunAgentResponse(
        agent_id=agent_id,
        from_state=from_state,
        to_state=STUNNED_LIFECYCLE_STATE,
        actor="demo-actor",
        stunned_at=now,
        # audit_events.id is generated server-side and the insert does not
        # return it; the row the caller sees is otherwise the row that was
        # written. Naming it "pending" is honest about which field is a stand-in.
        event=AuditEventResponse(
            id=f"{tenant_id}:audit-pending",
            timestamp=now,
            event_type="agent.stunned",
            agent_id=agent_id,
            agent_name=agent_name,
            actor="demo-actor",
            detail=_detail(from_state),
        ),
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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    pool = await _get_pool()
    if pool is None:
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

    v_uuid = _try_uuid(violation_id)
    if v_uuid is None:
        raise APIError(404, "not_found", "Violation not found")

    async with _write(pool) as conn:
        await conn.execute(
            """UPDATE agent_violations SET status = 'acknowledged', acknowledged_by = 'demo-actor', acknowledged_at = now()
               WHERE id = $1 AND tenant_id = $2""",
            v_uuid, tenant_id,
        )
        await _audit_log(
            conn, tenant_id, "violation.acknowledged", None, None, "demo-actor",
            {"violation_id": violation_id},
        )
    return {"status": "acknowledged"}


@router.post("/agents/{agent_id}/compliance/{control_id}/reassess", response_model=ReassessmentResponse, responses=ERROR_RESPONSES)
async def request_reassessment(
    agent_id: str,
    control_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ReassessmentResponse:
    now = _now_iso()
    pool = await _get_pool()
    if pool is None:
        _ensure_seeded(tenant_id)
    else:
        await _audit_log(
            pool, tenant_id, "compliance.reassess_requested", agent_id, None, "demo-actor",
            {"control_id": control_id},
        )
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
            totalExposureGbp=0,
        )
        for (framework_id, framework_name), framework_checks in checks_by_framework.items()
    ]
    return PolicySummaryResponse(
        totalChecks=len(checks),
        passed=sum(check.passed for check in checks),
        failed=sum(not check.passed for check in checks),
        totalAle=0,
        totalVar95=0,
        totalTvar=0,
        totalCarriedGbp=0,
        scanTimestamp=max((check.scanTimestamp for check in checks), default=_now_iso()),
        frameworks=frameworks,
    )


async def _db_policy_scan(
    pool: asyncpg.Pool,
    tenant_id: str,
    request: PolicyScanRequest,
) -> PolicyScanResponse:
    """Refresh and project persisted tenant compliance assessments."""
    async with _write(pool) as conn:
        await conn.execute(
            """UPDATE agent_compliance_results r
               SET assessed_at = now()
               FROM governance_controls c, governance_frameworks f
               WHERE r.control_id = c.id
                 AND c.framework_id = f.id
                 AND r.tenant_id = $1
                 AND c.tenant_id = $1
                 AND f.tenant_id = $1
                 AND (cardinality($2::text[]) = 0 OR f.id::text = ANY($2::text[]))""",
            tenant_id,
            request.frameworks,
        )
        rows = await conn.fetch(
            """SELECT f.id AS framework_id, f.name AS framework_name,
                      c.id AS control_id, c.name AS control_name,
                      bool_and(r.status = 'pass') AS passed,
                      max(r.assessed_at) AS assessed_at
               FROM agent_compliance_results r
               JOIN governance_controls c ON r.control_id = c.id
               JOIN governance_frameworks f ON c.framework_id = f.id
               WHERE r.tenant_id = $1
                 AND c.tenant_id = $1
                 AND f.tenant_id = $1
                 AND (cardinality($2::text[]) = 0 OR f.id::text = ANY($2::text[]))
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
                passed=bool(row["passed"]),
                policyVersion=request.policyVersion,
                ale=0,
                var95=0,
                tvar=0,
                carriedGbp=0,
                scanTimestamp=_ts(row["assessed_at"]) or _now_iso(),
                calibrationSource="not-calculated",
            )
            for row in rows
        ]
    return PolicyScanResponse(
        checks=checks,
        summary=_policy_scan_summary(checks, request.policyVersion),
    )


@router.post(
    "/compliance/policy/scan",
    response_model=PolicyScanResponse,
    responses=ERROR_RESPONSES,
)
async def policy_compliance_scan(
    request: PolicyScanRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> PolicyScanResponse:
    pool = await _get_pool()
    if pool is None:
        raise APIError(
            503,
            "database_unavailable",
            "Policy scanning requires the compliance database",
        )
    return await _db_policy_scan(pool, tenant_id, request)


@router.get(
    "/compliance/policy/frameworks",
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
                detail={"source": "mock", "from": from_, "to": to},
            ),
            AuditEventResponse(
                id=f"{tenant_id}:audit-2",
                timestamp="2026-07-27T01:10:00Z",
                # These three used to echo the caller's `type` and `agent` back
                # into the fixture, so a filter for anything always "matched".
                # That is not a filter, and it made a real recorded event
                # indistinguishable from a fabricated one. Fixed values now, and
                # the filters below are applied for real.
                event_type="agent.transitioned",
                agent_id=f"{tenant_id}:agent-2",
                agent_name="Triage Agent",
                actor="demo-actor",
                detail={"to_state": "active"},
            ),
            AuditEventResponse(
                id=f"{tenant_id}:audit-3",
                timestamp="2026-07-27T01:20:00Z",
                event_type="compliance.reassess_requested",
                agent_id=f"{tenant_id}:agent-1",
                agent_name="Inventory Agent",
                actor="demo-actor",
                detail={"control_id": "eu-ai-act:art-9"},
            ),
        ]
        # Anything this process recorded, newest first, ahead of the seeded
        # history -- so an action taken a moment ago is at the top of the trail
        # rather than lost behind week-old fixtures.
        with _STORE_LOCK:
            recorded = [
                AuditEventResponse(**event)
                for event in reversed(_AUDIT_EVENTS.get(tenant_id, []))
            ]
        events = recorded + base_events

        if from_ is not None:
            events = [e for e in events if e.timestamp >= from_]
        if to is not None:
            events = [e for e in events if e.timestamp <= to]
        if agent is not None:
            events = [
                e for e in events
                if e.agent_id == agent or (e.agent_name or "").lower().find(agent.lower()) >= 0
            ]
        if type is not None:
            events = [e for e in events if e.event_type == type]

        start = max(page - 1, 0) * limit
        end = start + limit
        return AuditListResponse(
            events=events[start:end], total=len(events), page=page, limit=limit,
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
            conditions.append(f"agent_name ILIKE ${idx}")
            params.append(f"%{agent}%")
            idx += 1
    if type is not None:
        conditions.append(f"event_type = ${idx}")
        params.append(type)
        idx += 1

    where = " AND ".join(conditions)
    offset = max(page - 1, 0) * limit

    count_row = await pool.fetchrow(
        f"SELECT COUNT(*)::int AS total FROM audit_events WHERE {where}", *params,
    )
    total = count_row["total"]

    params.append(limit)
    params.append(offset)
    rows = await pool.fetch(
        f"SELECT * FROM audit_events WHERE {where} ORDER BY timestamp DESC LIMIT ${idx} OFFSET ${idx + 1}",
        *params,
    )

    events = [
        AuditEventResponse(
            id=str(row["id"]),
            timestamp=_ts(row["timestamp"]) or "",
            event_type=row["event_type"],
            agent_id=str(row["agent_id"]) if row["agent_id"] is not None else None,
            agent_name=row["agent_name"],
            actor=row["actor"],
            detail=json.loads(row["detail"]) if isinstance(row["detail"], str) else (row["detail"] or {}),
        )
        for row in rows
    ]
    return AuditListResponse(events=events, total=total, page=page, limit=limit)


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


@router.post("/nhi/discovered/{account_id}/enroll", responses=ERROR_RESPONSES)
async def enroll_nhi_account(
    account_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    pool = await _get_pool()
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
        await _audit_log(conn, tenant_id, "nhi.enrolled", None, None, "demo-actor", {"account_id": account_id})
    return {"account_id": account_id, "status": "enrollment_requested"}


@router.post("/nhi/discovered/{account_id}/dismiss", responses=ERROR_RESPONSES)
async def dismiss_nhi_account(
    account_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    pool = await _get_pool()
    if pool is None:
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
               SET status = 'dismissed', dismissed_at = now(), dismissed_by = 'demo-actor',
                   changes_since_dismissal = 'false'::jsonb, previous_risk_flags = findings
               WHERE id = $1 AND tenant_id = $2""",
            a_uuid, tenant_id,
        )
        await _audit_log(conn, tenant_id, "nhi.dismissed", None, None, "demo-actor", {"account_id": account_id})
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
    pool = await _get_pool()
    if pool is None:
        raise APIError(
            503,
            "database_unavailable",
            "Discovery account details require the inventory database",
        )

    account_uuid = _try_uuid(account_id)
    if account_uuid is None:
        raise APIError(404, "not_found", "Account not found")
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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TenantSettingsResponse:
    pool = await _get_pool()
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
            conn, tenant_id, "tenant.frameworks_updated", None, None, "demo-actor",
            {"selected_frameworks": body.selected_frameworks},
        )
    # Re-fetch via the GET handler, OUTSIDE the transaction: it acquires its own
    # connection and so must run after the commit to observe the new values.
    return await tenant_settings(tenant_id)


@router.patch("/tenant/settings/preferences", response_model=TenantSettingsResponse, responses=ERROR_RESPONSES)
async def patch_tenant_preferences(
    body: PreferencesPatchRequest,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> TenantSettingsResponse:
    pool = await _get_pool()
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
            conn, tenant_id, "tenant.preferences_updated", None, None, "demo-actor",
            {
                "preferred_scan_cadence_hours": body.preferred_scan_cadence_hours,
                "alert_email": body.alert_email,
                "alert_threshold": body.alert_threshold,
            },
        )
    # Re-fetch via the GET handler, OUTSIDE the transaction: it acquires its own
    # connection and so must run after the commit to observe the new values.
    return await tenant_settings(tenant_id)


@router.post("/support", response_model=SupportRequestResponse, responses=ERROR_RESPONSES)
async def create_support_request(
    body: SupportRequestCreate,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> SupportRequestResponse:
    tenant_id = principal.tenant
    pool = await _get_pool()
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
    row = await pool.fetchrow(
        """INSERT INTO support_requests (tenant_id, subject, urgency, message, submitted_by)
           VALUES ($1, $2, $3, $4, $5) RETURNING *""",
        tenant_id, body.subject, body.urgency, body.message, principal.actor,
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
    key = f"sl_live_{tenant_id_path}_{secrets.token_urlsafe(18)}"
    now = _now_iso()

    pool = await _get_pool()
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
            await _audit_log(conn, tenant_id, "api_key.created", None, None, "demo-actor", {"prefix_hint": key[:14]})

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
    key = f"sl_live_{tenant_id_path}_{secrets.token_urlsafe(18)}"
    now = _now_iso()

    pool = await _get_pool()
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
            await _audit_log(conn, tenant_id, "api_key.rotated", None, None, "demo-actor", {"prefix_hint": key[:14]})

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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ConsentAcceptResponse:
    pool = await _get_pool()
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
            """INSERT INTO consent_events (tenant_id, user_email, accepted_at, document_versions,
                                            cookie_preferences, b2b_warranty_accepted)
               VALUES ($1, 'demo@signalloom.local', now(), $2::jsonb, $3::jsonb, $4)""",
            tenant_id,
            json.dumps(dict(body.document_versions)),
            json.dumps(body.cookie_preferences.model_dump()),
            body.b2b_warranty_accepted,
        )
        await _audit_log(conn, tenant_id, "consent.accepted", None, None, "demo-actor", {"document_versions": dict(body.document_versions)})
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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> CookiePreferencesResponse:
    pool = await _get_pool()
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
            """INSERT INTO consent_events (tenant_id, user_email, accepted_at, document_versions,
                                            cookie_preferences, b2b_warranty_accepted)
               VALUES ($1, 'demo@signalloom.local', now(), '{"tos":"2026-01","privacy":"2026-01"}'::jsonb,
                       $2::jsonb, false)""",
            tenant_id,
            json.dumps({"strictly_necessary": True, "analytics": body.analytics}),
        )
        await _audit_log(conn, tenant_id, "cookie.preferences_updated", None, None, "demo-actor", {"analytics": body.analytics})
    return CookiePreferencesResponse(
        cookie_preferences=CookiePreferences(strictly_necessary=True, analytics=body.analytics),
    )


# ---------------------------------------------------------------------------
# App installation (UNCHANGED)
# ---------------------------------------------------------------------------


def install_compatibility_api(app: FastAPI) -> None:
    app.include_router(router)
    install_api_exception_handlers(app)
