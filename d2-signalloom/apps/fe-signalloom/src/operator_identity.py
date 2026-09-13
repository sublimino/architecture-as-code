"""Attributable, tenant-bound operator identity lifecycle for AMXO-P1-1.

The OIDC token proves an issuer/subject pair. This module binds that pair to a
persisted individual directory user, makes persisted role/status authoritative,
and writes the accepted or denied lifecycle outcome from the server boundary.
No route accepts a tenant, actor, timestamp, or audit outcome from the caller.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any, Literal
import json
import uuid

import asyncpg
from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field, field_validator

import api_compat


router = APIRouter(prefix="/api/operator-identities", tags=["operator-identities"])

AUTHORIZATION_MATRIX: dict[str, frozenset[str]] = {
    "admin": frozenset(
        {"operator:create", "operator:list", "operator:remove", "operator:sign-in"}
    ),
    "editor": frozenset({"operator:sign-in"}),
    "viewer": frozenset({"operator:sign-in"}),
}

_AUTH_ERROR_RESPONSES = {
    401: {
        "model": api_compat.ErrorResponse,
        "description": "An authenticated OIDC principal is required",
    },
    403: {
        "model": api_compat.ErrorResponse,
        "description": "The principal is not an active authorized operator",
    },
    503: {
        "model": api_compat.ErrorResponse,
        "description": "The identity database is unavailable",
    },
}

_OPERATOR_SELECT = """
    SELECT oi.id AS identity_id,
           oi.platform_user_id,
           oi.tenant_id,
           oi.issuer,
           oi.subject,
           oi.identity_kind,
           oi.status AS identity_status,
           oi.removed_at,
           oi.removed_by_user_id,
           oi.removal_reason,
           pu.email,
           pu.display_name,
           pu.role,
           pu.status AS user_status,
           pu.last_login_at,
           oi.created_at
      FROM public.operator_identities oi
      JOIN public.platform_users pu
        ON pu.id = oi.platform_user_id
       AND pu.tenant_id = oi.tenant_id
"""


def _normalize_email(value: str) -> str:
    normalized = value.strip().lower()
    local, separator, domain = normalized.partition("@")
    if not separator or not local or not domain or "@" in domain or any(c.isspace() for c in normalized):
        raise ValueError("email must be one individual mailbox address")
    return normalized


class OperatorIdentityCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider_subject: str = Field(min_length=1, max_length=255)
    email: str = Field(min_length=3, max_length=320)
    display_name: str = Field(min_length=2, max_length=120)
    role: Literal["admin", "editor", "viewer"] = "editor"
    identity_kind: Literal["individual"] = "individual"

    @field_validator("provider_subject", "display_name")
    @classmethod
    def nonempty_trimmed(cls, value: str) -> str:
        trimmed = value.strip()
        if not trimmed:
            raise ValueError("value must not be blank")
        return trimmed

    @field_validator("email")
    @classmethod
    def individual_email(cls, value: str) -> str:
        return _normalize_email(value)


class OperatorIdentityRemovalRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason: str = Field(min_length=3, max_length=500)

    @field_validator("reason")
    @classmethod
    def meaningful_reason(cls, value: str) -> str:
        trimmed = value.strip()
        if len(trimmed) < 3:
            raise ValueError("removal reason must contain at least three characters")
        return trimmed


class OperatorIdentityResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    platform_user_id: str
    tenant_id: str
    identity_source: Literal["oidc"] = "oidc"
    issuer: str
    provider_subject: str
    identity_kind: Literal["individual"]
    email: str
    display_name: str
    role: Literal["admin", "editor", "viewer"]
    status: Literal["active", "removed"]
    last_login_at: str | None
    created_at: str
    removed_at: str | None
    removed_by_user_id: str | None
    removal_reason: str | None


class OperatorIdentitiesResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operators: list[OperatorIdentityResponse]
    total: int


class OperatorSessionResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    authenticated: Literal[True] = True
    operator: OperatorIdentityResponse
    allowed_actions: list[str]


class OperatorRemovalResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    changed: bool
    operator: OperatorIdentityResponse


@dataclass(frozen=True)
class OperatorPrincipal:
    identity_id: uuid.UUID
    user_id: uuid.UUID
    tenant_id: str
    issuer: str
    subject: str
    email: str
    display_name: str
    role: Literal["admin", "editor", "viewer"]

    @property
    def allowed_actions(self) -> frozenset[str]:
        return AUTHORIZATION_MATRIX[self.role]


def _as_uuid(value: Any) -> uuid.UUID:
    return value if isinstance(value, uuid.UUID) else uuid.UUID(str(value))


def _timestamp(value: datetime | str | None) -> str | None:
    return api_compat._ts(value)


def _response(row: Any) -> OperatorIdentityResponse:
    return OperatorIdentityResponse(
        id=str(row["identity_id"]),
        platform_user_id=str(row["platform_user_id"]),
        tenant_id=row["tenant_id"],
        issuer=row["issuer"],
        provider_subject=row["subject"],
        identity_kind=row["identity_kind"],
        email=row["email"],
        display_name=row["display_name"],
        role=row["role"],
        status=row["identity_status"],
        last_login_at=_timestamp(row["last_login_at"]),
        created_at=_timestamp(row["created_at"]) or "",
        removed_at=_timestamp(row["removed_at"]),
        removed_by_user_id=(
            str(row["removed_by_user_id"]) if row["removed_by_user_id"] is not None else None
        ),
        removal_reason=row["removal_reason"],
    )


def operator_from_row(principal: api_compat.Principal, row: Any) -> OperatorPrincipal:
    """Turn a persisted binding into an authorized operator, or fail closed."""
    if not principal.subject or not principal.subject.strip():
        raise api_compat.APIError(
            401, "anonymous_operator_forbidden", "An attributable operator identity is required"
        )
    if row["tenant_id"] != principal.tenant:
        raise api_compat.APIError(403, "operator_tenant_mismatch", "Operator tenant access is denied")
    if row["issuer"] != api_compat.settings.api_jwt_issuer or row["subject"] != principal.subject:
        raise api_compat.APIError(403, "operator_identity_mismatch", "Operator identity access is denied")
    if row["identity_kind"] != "individual":
        raise api_compat.APIError(
            403, "shared_identity_forbidden", "Shared operator identities are forbidden"
        )
    if row["identity_status"] == "removed" or row["user_status"] == "deactivated":
        raise api_compat.APIError(403, "operator_removed", "Operator access has been removed")
    if row["identity_status"] != "active" or row["user_status"] != "active":
        raise api_compat.APIError(403, "operator_inactive", "Operator access is inactive")
    role = row["role"]
    if role not in AUTHORIZATION_MATRIX:
        raise api_compat.APIError(403, "operator_role_forbidden", "Operator role is not approved")
    return OperatorPrincipal(
        identity_id=_as_uuid(row["identity_id"]),
        user_id=_as_uuid(row["platform_user_id"]),
        tenant_id=row["tenant_id"],
        issuer=row["issuer"],
        subject=row["subject"],
        email=row["email"],
        display_name=row["display_name"],
        role=role,
    )


async def _load_operator(executor: Any, principal: api_compat.Principal, *, lock: bool = False) -> Any:
    suffix = " FOR UPDATE OF oi, pu" if lock else ""
    return await executor.fetchrow(
        _OPERATOR_SELECT
        + " WHERE oi.tenant_id = $1 AND oi.issuer = $2 AND oi.subject = $3"
        + suffix,
        principal.tenant,
        api_compat.settings.api_jwt_issuer,
        principal.subject,
    )


async def _load_operator_by_id(
    executor: Any, tenant_id: str, identity_id: uuid.UUID, *, lock: bool = False
) -> Any:
    suffix = " FOR UPDATE OF oi, pu" if lock else ""
    return await executor.fetchrow(
        _OPERATOR_SELECT + " WHERE oi.id = $1 AND oi.tenant_id = $2" + suffix,
        identity_id,
        tenant_id,
    )


def _identity_error(principal: api_compat.Principal, row: Any | None) -> api_compat.APIError:
    if row is None:
        return api_compat.APIError(
            403, "operator_not_registered", "An active individual operator identity is required"
        )
    try:
        operator_from_row(principal, row)
    except api_compat.APIError as error:
        return error
    raise RuntimeError("active operator unexpectedly classified as an identity error")


async def _audit_log(
    executor: Any,
    tenant_id: str,
    event_type: str,
    agent_id: str | None,
    agent_name: str | None,
    actor: str,
    detail: dict[str, Any],
) -> None:
    """Write the house audit shape plus immutable operator attribution.

    The signature deliberately matches ``api_compat._audit_log`` so repository
    audit-provenance guards inspect these call sites rather than treating this
    security boundary as an unrecognised private writer.
    """
    actor_user_value = detail.get("actor_user_id")
    actor_user_id = _as_uuid(actor_user_value) if actor_user_value else None
    actor_issuer = detail.get("actor_issuer")
    actor_subject = detail.get("actor_subject")
    clean_detail = dict(detail)
    clean_detail["actor_user_id"] = str(actor_user_id) if actor_user_id else None
    await executor.execute(
        """INSERT INTO public.audit_events
                  (tenant_id, event_type, agent_id, agent_name, actor,
                   actor_user_id, actor_issuer, actor_subject, detail)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)""",
        tenant_id,
        event_type,
        api_compat._try_uuid(agent_id) if agent_id else None,
        agent_name,
        actor,
        actor_user_id,
        actor_issuer,
        actor_subject,
        json.dumps(clean_detail, sort_keys=True),
    )


def _audit_detail(
    principal: api_compat.Principal,
    *,
    action: str,
    outcome: Literal["allowed", "denied", "completed"],
    actor_user_id: uuid.UUID | None,
    target_user_id: uuid.UUID | None = None,
    target_identity_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    return {
        "operator_action": action,
        "outcome": outcome,
        "actor_user_id": actor_user_id,
        "actor_issuer": api_compat.settings.api_jwt_issuer,
        "actor_subject": principal.subject,
        "target_operator_user_id": str(target_user_id) if target_user_id else None,
        "target_operator_identity_id": str(target_identity_id) if target_identity_id else None,
        "identity_source": "oidc",
    }


def _require_admin(operator: OperatorPrincipal) -> None:
    if "operator:list" not in operator.allowed_actions:
        raise api_compat.APIError(
            403, "operator_admin_required", "Operator administrator access is required"
        )


def _require_managed_tenant(principal: api_compat.Principal) -> None:
    if principal.tenant not in api_compat.settings.api_attributable_operator_tenants:
        raise api_compat.APIError(
            403,
            "operator_tenant_not_managed",
            "Operator identity lifecycle is not enabled for this tenant",
        )


async def _lock_operator_administration(conn: Any, tenant_id: str) -> None:
    """Serialize bootstrap and administrator removal decisions per tenant."""
    await conn.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended('operator-identities:' || $1, 0))",
        tenant_id,
    )


async def ensure_active_operator(principal: api_compat.Principal) -> OperatorPrincipal:
    """Global strict-tenant gate used by the compatibility router."""
    pool = await api_compat._require_pool("Attributable operator authentication")
    if pool is None:
        raise api_compat.APIError(
            503, "identity_database_required", "Operator authentication requires the identity database"
        )
    row = await _load_operator(pool, principal)
    if row is None:
        raise _identity_error(principal, None)
    return operator_from_row(principal, row)


async def enforce_strict_operator_tenant(
    principal: Annotated[api_compat.Principal, Depends(api_compat.authenticated_principal)],
) -> None:
    """Enforce persisted membership only for configured attributable tenants."""
    if principal.tenant in api_compat.settings.api_attributable_operator_tenants:
        await ensure_active_operator(principal)


@router.get(
    "/session", response_model=OperatorSessionResponse, responses=_AUTH_ERROR_RESPONSES
)
async def operator_session(
    principal: Annotated[api_compat.Principal, Depends(api_compat.authenticated_principal)],
) -> OperatorSessionResponse:
    _require_managed_tenant(principal)
    pool = await api_compat._require_pool("Operator sign-in")
    if pool is None:
        raise api_compat.APIError(
            503, "identity_database_required", "Operator sign-in requires the identity database"
        )

    response: OperatorSessionResponse | None = None
    refusal: api_compat.APIError | None = None
    async with api_compat._write(pool) as conn:
        row = await _load_operator(conn, principal, lock=True)
        if row is None:
            refusal = _identity_error(principal, None)
            await _audit_log(
                conn,
                principal.tenant,
                "operator.sign_in_denied",
                None,
                None,
                principal.actor,
                _audit_detail(
                    principal,
                    action="operator.sign_in",
                    outcome="denied",
                    actor_user_id=None,
                ),
            )
        else:
            try:
                operator = operator_from_row(principal, row)
            except api_compat.APIError as error:
                refusal = error
                await _audit_log(
                    conn,
                    principal.tenant,
                    "operator.sign_in_denied",
                    None,
                    None,
                    principal.actor,
                    _audit_detail(
                        principal,
                        action="operator.sign_in",
                        outcome="denied",
                        actor_user_id=_as_uuid(row["platform_user_id"]),
                        target_user_id=_as_uuid(row["platform_user_id"]),
                        target_identity_id=_as_uuid(row["identity_id"]),
                    ),
                )
            else:
                last_login_at = await conn.fetchval(
                    """UPDATE public.platform_users
                          SET last_login_at = NOW()
                        WHERE id = $1 AND tenant_id = $2
                    RETURNING last_login_at""",
                    operator.user_id,
                    principal.tenant,
                )
                await _audit_log(
                    conn,
                    principal.tenant,
                    "operator.sign_in_succeeded",
                    None,
                    None,
                    principal.actor,
                    _audit_detail(
                        principal,
                        action="operator.sign_in",
                        outcome="allowed",
                        actor_user_id=operator.user_id,
                        target_user_id=operator.user_id,
                        target_identity_id=operator.identity_id,
                    ),
                )
                updated_row = dict(row)
                updated_row["last_login_at"] = last_login_at
                response = OperatorSessionResponse(
                    operator=_response(updated_row), allowed_actions=sorted(operator.allowed_actions)
                )

    if refusal is not None:
        raise refusal
    if response is None:
        raise RuntimeError("operator sign-in produced neither response nor refusal")
    return response


async def _admin_or_bootstrap(
    conn: Any,
    principal: api_compat.Principal,
    body: OperatorIdentityCreateRequest | None = None,
) -> OperatorPrincipal | None:
    row = await _load_operator(conn, principal, lock=True)
    if row is not None:
        operator = operator_from_row(principal, row)
        _require_admin(operator)
        return operator

    from superadmin import is_superadmin

    active_admins = await conn.fetchval(
        """SELECT COUNT(*)::int
             FROM public.operator_identities oi
             JOIN public.platform_users pu
               ON pu.id = oi.platform_user_id AND pu.tenant_id = oi.tenant_id
            WHERE oi.tenant_id = $1
              AND oi.status = 'active'
              AND pu.status = 'active'
              AND pu.role = 'admin'""",
        principal.tenant,
    )
    if not is_superadmin(principal) or active_admins != 0 or body is None:
        raise api_compat.APIError(
            403, "operator_admin_required", "Operator administrator access is required"
        )
    principal_email = _normalize_email(principal.email) if principal.email else None
    if (
        body.provider_subject != principal.subject
        or body.email != principal_email
        or body.role != "admin"
    ):
        raise api_compat.APIError(
            403,
            "operator_bootstrap_self_only",
            "The initial administrator must provision its own individual identity",
        )
    return None


@router.post(
    "",
    response_model=OperatorIdentityResponse,
    status_code=201,
    responses={
        **_AUTH_ERROR_RESPONSES,
        409: {"model": api_compat.ErrorResponse, "description": "Identity already exists"},
    },
)
async def create_operator_identity(
    body: OperatorIdentityCreateRequest,
    principal: Annotated[api_compat.Principal, Depends(api_compat.authenticated_principal)],
) -> OperatorIdentityResponse:
    _require_managed_tenant(principal)
    pool = await api_compat._require_pool("Creating an operator identity")
    if pool is None:
        raise api_compat.APIError(
            503, "identity_database_required", "Operator provisioning requires the identity database"
        )

    generated_user_id = uuid.uuid4()
    identity_id = uuid.uuid4()
    try:
        async with api_compat._write(pool) as conn:
            await _lock_operator_administration(conn, principal.tenant)
            await _admin_or_bootstrap(conn, principal, body)
            await conn.fetchrow(
                """INSERT INTO public.platform_users
                          (id, tenant_id, email, display_name, role, status)
                     VALUES ($1, $2, $3, $4, $5, 'active')
                  RETURNING id""",
                generated_user_id,
                principal.tenant,
                body.email,
                body.display_name,
                body.role,
            )
            await conn.fetchrow(
                """INSERT INTO public.operator_identities
                          (id, platform_user_id, tenant_id, issuer, subject, identity_kind)
                     VALUES ($1, $2, $3, $4, $5, 'individual')
                  RETURNING id""",
                identity_id,
                generated_user_id,
                principal.tenant,
                api_compat.settings.api_jwt_issuer,
                body.provider_subject,
            )
            created = await _load_operator_by_id(conn, principal.tenant, identity_id)
            actor_user_id = await conn.fetchval(
                """SELECT platform_user_id
                     FROM public.operator_identities
                    WHERE tenant_id = $1 AND issuer = $2 AND subject = $3""",
                principal.tenant,
                api_compat.settings.api_jwt_issuer,
                principal.subject,
            )
            await _audit_log(
                conn,
                principal.tenant,
                "operator.created",
                None,
                None,
                principal.actor,
                _audit_detail(
                    principal,
                    action="operator.create",
                    outcome="completed",
                    actor_user_id=actor_user_id,
                    target_user_id=generated_user_id,
                    target_identity_id=identity_id,
                ),
            )
    except asyncpg.UniqueViolationError as error:
        raise api_compat.APIError(
            409, "operator_identity_exists", "Operator identity already exists"
        ) from error
    if created is None:
        raise RuntimeError("created operator identity could not be read back")
    return _response(created)


@router.get("", response_model=OperatorIdentitiesResponse, responses=_AUTH_ERROR_RESPONSES)
async def list_operator_identities(
    principal: Annotated[api_compat.Principal, Depends(api_compat.authenticated_principal)],
) -> OperatorIdentitiesResponse:
    _require_managed_tenant(principal)
    pool = await api_compat._require_pool("Listing operator identities")
    if pool is None:
        raise api_compat.APIError(
            503, "identity_database_required", "Operator listing requires the identity database"
        )
    actor_row = await _load_operator(pool, principal)
    if actor_row is None:
        raise _identity_error(principal, None)
    _require_admin(operator_from_row(principal, actor_row))
    rows = await pool.fetch(
        _OPERATOR_SELECT + " WHERE oi.tenant_id = $1 ORDER BY oi.created_at, oi.id",
        principal.tenant,
    )
    operators = [_response(row) for row in rows]
    return OperatorIdentitiesResponse(operators=operators, total=len(operators))


@router.post(
    "/{identity_id}/remove",
    response_model=OperatorRemovalResponse,
    responses={
        **_AUTH_ERROR_RESPONSES,
        404: {
            "model": api_compat.ErrorResponse,
            "description": "Operator identity not found",
        },
        409: {
            "model": api_compat.ErrorResponse,
            "description": "Final administrator cannot be removed",
        },
    },
)
async def remove_operator_identity(
    identity_id: uuid.UUID,
    body: OperatorIdentityRemovalRequest,
    principal: Annotated[api_compat.Principal, Depends(api_compat.authenticated_principal)],
) -> OperatorRemovalResponse:
    _require_managed_tenant(principal)
    pool = await api_compat._require_pool("Removing an operator identity")
    if pool is None:
        raise api_compat.APIError(
            503, "identity_database_required", "Operator removal requires the identity database"
        )

    result: OperatorRemovalResponse | None = None
    async with api_compat._write(pool) as conn:
        await _lock_operator_administration(conn, principal.tenant)
        actor_row = await _load_operator(conn, principal, lock=True)
        if actor_row is None:
            raise _identity_error(principal, None)
        actor = operator_from_row(principal, actor_row)
        _require_admin(actor)

        target = await _load_operator_by_id(conn, principal.tenant, identity_id, lock=True)
        if target is None:
            raise api_compat.APIError(404, "operator_not_found", "Operator identity was not found")
        if target["identity_status"] == "removed":
            result = OperatorRemovalResponse(changed=False, operator=_response(target))
        else:
            if target["role"] == "admin":
                other_admins = await conn.fetchval(
                    """SELECT COUNT(*)::int
                         FROM public.operator_identities oi
                         JOIN public.platform_users pu
                           ON pu.id = oi.platform_user_id AND pu.tenant_id = oi.tenant_id
                        WHERE oi.tenant_id = $1
                          AND oi.id <> $2
                          AND oi.status = 'active'
                          AND pu.status = 'active'
                          AND pu.role = 'admin'""",
                    principal.tenant,
                    identity_id,
                )
                if other_admins == 0:
                    raise api_compat.APIError(
                        409,
                        "last_operator_admin",
                        "The final active operator administrator cannot be removed",
                    )

            await conn.execute(
                """UPDATE public.operator_identities
                      SET status = 'removed',
                          removed_at = NOW(),
                          removed_by_user_id = $1,
                          removal_reason = $2
                    WHERE id = $3 AND tenant_id = $4 AND status = 'active'""",
                actor.user_id,
                body.reason,
                identity_id,
                principal.tenant,
            )
            await conn.execute(
                """UPDATE public.platform_users
                      SET status = 'deactivated'
                    WHERE id = $1 AND tenant_id = $2""",
                _as_uuid(target["platform_user_id"]),
                principal.tenant,
            )
            removed = await _load_operator_by_id(conn, principal.tenant, identity_id)
            if removed is None:
                raise RuntimeError("removed operator identity could not be read back")
            await _audit_log(
                conn,
                principal.tenant,
                "operator.removed",
                None,
                None,
                principal.actor,
                _audit_detail(
                    principal,
                    action="operator.remove",
                    outcome="completed",
                    actor_user_id=actor.user_id,
                    target_user_id=_as_uuid(target["platform_user_id"]),
                    target_identity_id=identity_id,
                ),
            )
            result = OperatorRemovalResponse(changed=True, operator=_response(removed))

    if result is None:
        raise RuntimeError("operator removal produced no result")
    return result
