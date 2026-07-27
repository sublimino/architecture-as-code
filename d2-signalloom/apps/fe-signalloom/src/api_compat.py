"""Authenticated, tenant-scoped compatibility API for the local D2 dashboard."""
from __future__ import annotations

import base64
import binascii
import json
import logging
from functools import lru_cache
from typing import Annotated, Any, Literal

import jwt
from fastapi import APIRouter, Depends, FastAPI, Header, Request
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


class AgentSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    status: Literal["ready", "offline"]


class AgentsResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str
    agents: list[AgentSummary]


class ComplianceControl(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    status: Literal["passing", "failing"]
    evidence: str


class ComplianceResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str
    controls: list[ComplianceControl]


class AuditEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    event_type: str
    occurred_at: str
    actor: str


class AuditResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str
    events: list[AuditEvent]


class SettingItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    key: str
    value: str


class SettingsResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tenant_id: str
    settings: list[SettingItem]


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
        if header.get("alg") != "RS256" or header.get("typ") != "JWT":
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


def build_agents_response(tenant_id: str) -> AgentsResponse:
    return AgentsResponse(
        tenant_id=tenant_id,
        agents=[
            AgentSummary(
                id=f"{tenant_id}:inventory-agent",
                name="Inventory Agent",
                status="ready",
            )
        ],
    )


def build_compliance_response(tenant_id: str) -> ComplianceResponse:
    return ComplianceResponse(
        tenant_id=tenant_id,
        controls=[
            ComplianceControl(
                id=f"{tenant_id}:access-boundary",
                status="passing",
                evidence="Local tenant boundary validated",
            )
        ],
    )


def build_audit_response(tenant_id: str) -> AuditResponse:
    return AuditResponse(
        tenant_id=tenant_id,
        events=[
            AuditEvent(
                id=f"{tenant_id}:baseline-ready",
                event_type="baseline.ready",
                occurred_at="2026-07-27T00:00:00Z",
                actor="signalloom-local",
            )
        ],
    )


def build_settings_response(tenant_id: str) -> SettingsResponse:
    return SettingsResponse(
        tenant_id=tenant_id,
        settings=[SettingItem(key="environment", value=settings.environment)],
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


@router.get("/agents", response_model=AgentsResponse, responses=ERROR_RESPONSES)
async def agents(tenant_id: Annotated[str, Depends(authenticated_tenant)]) -> AgentsResponse:
    return build_agents_response(tenant_id)


@router.get("/compliance", response_model=ComplianceResponse, responses=ERROR_RESPONSES)
async def compliance(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ComplianceResponse:
    return build_compliance_response(tenant_id)


@router.get("/audit", response_model=AuditResponse, responses=ERROR_RESPONSES)
async def audit(tenant_id: Annotated[str, Depends(authenticated_tenant)]) -> AuditResponse:
    return build_audit_response(tenant_id)


@router.get("/settings", response_model=SettingsResponse, responses=ERROR_RESPONSES)
async def dashboard_settings(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> SettingsResponse:
    return build_settings_response(tenant_id)


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
