"""Platform user and directory administration API router for Signal Loom.

Provides administrative CRUD endpoints for managing directory users, issuing
invitations, updating roles and lifecycle states, and deactivating accounts
under strict tenant isolation and superadmin multi-tenancy.
"""
from __future__ import annotations

import logging
from typing import Annotated, Any, Literal

from api_compat import (
    ERROR_RESPONSES,
    APIError,
    Principal,
    _audit_log,
    invalidate_user_resolution_cache,
)
from cross_tenant_audit import audit_cross_tenant_read
from fastapi import APIRouter, Depends, Query, Request, status
from platform_users import (
    PlatformUser,
    PlatformUserRepository,
    _normalize_email,
)
from pydantic import BaseModel, ConfigDict, Field, field_validator
from superadmin import is_superadmin, require_admin_or_superadmin

logger = logging.getLogger("signalloom.admin_users")

router = APIRouter(prefix="/api/v1/admin/users", tags=["admin-users"])


async def _resolve_db_pool(request: Request) -> Any:
    """Resolve active database pool from test context, app state, or api_compat."""
    # 1. Check test/runtime db.connection pool if set
    try:
        from db.connection import get_pool
        pool = get_pool()
        if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
            return pool
    except (RuntimeError, ImportError, AttributeError):
        pass

    # 2. Check app.state.pool
    pool = getattr(request.app.state, "pool", None)
    if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
        return pool

    # 3. Check api_compat._get_pool()
    try:
        from api_compat import _get_pool
        pool = await _get_pool()
        if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
            return pool
    except (ImportError, AttributeError, Exception):
        pass

    return None


async def _require_db_pool(request: Request, operation: str) -> Any:
    """Resolve database pool or raise 503 if unavailable."""
    pool = await _resolve_db_pool(request)
    if pool is None:
        raise APIError(
            503,
            "database_unavailable",
            f"Database connection is required for {operation}",
        )
    return pool


# ==============================================================================
# Pydantic Schemas
# ==============================================================================


class UserResponse(BaseModel):
    """Response representation of a directory platform user."""
    model_config = ConfigDict(from_attributes=True, extra="forbid")

    id: str
    tenant_id: str
    email: str
    display_name: str
    role: Literal["admin", "editor", "viewer"]
    status: Literal["active", "invited", "suspended", "deactivated"]
    is_superadmin: bool = False
    avatar_url: str | None = None
    department: str | None = None
    title: str | None = None
    last_login_at: str | None = None
    created_at: str
    updated_at: str | None = None


class UsersListResponse(BaseModel):
    """Response model for listing platform users."""
    model_config = ConfigDict(extra="forbid")

    users: list[UserResponse]
    total: int


class InviteUserRequest(BaseModel):
    """Payload for inviting or provisioning a new directory user."""
    model_config = ConfigDict(extra="forbid")

    email: str = Field(..., description="Unique email address for user login and identity matching")
    display_name: str = Field(..., min_length=1, max_length=128, description="Human-readable display name")
    role: Literal["admin", "editor", "viewer"] = Field(default="viewer", description="Tenant-scoped role")
    tenant_id: str | None = Field(default=None, description="Target tenant ID (superadmin only override)")
    is_superadmin: bool = Field(default=False, description="Whether to grant global superadmin privileges")
    department: str | None = Field(default=None, max_length=128)
    title: str | None = Field(default=None, max_length=128)
    avatar_url: str | None = Field(default=None, max_length=512)

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _normalize_email(v)


class UpdateUserRequest(BaseModel):
    """Payload for updating an existing platform user's properties."""
    model_config = ConfigDict(extra="forbid")

    email: str | None = Field(default=None, description="Updated normalized email address")
    display_name: str | None = Field(default=None, min_length=1, max_length=128)
    role: Literal["admin", "editor", "viewer"] | None = Field(default=None)
    status: Literal["active", "invited", "suspended", "deactivated"] | None = Field(default=None)
    is_superadmin: bool | None = Field(default=None, description="Superadmin privilege toggle")
    department: str | None = Field(default=None, max_length=128)
    title: str | None = Field(default=None, max_length=128)
    avatar_url: str | None = Field(default=None, max_length=512)

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str | None) -> str | None:
        if v is None:
            return None
        return _normalize_email(v)


def _user_to_response(user: PlatformUser) -> UserResponse:
    """Map domain PlatformUser to API UserResponse model."""
    return UserResponse(
        id=str(user.id),
        tenant_id=user.tenant_id,
        email=user.email,
        display_name=user.display_name,
        role=user.role,
        status=user.status,
        is_superadmin=user.is_superadmin,
        avatar_url=user.avatar_url,
        department=user.department,
        title=user.title,
        last_login_at=user.last_login_at,
        created_at=user.created_at or "",
        updated_at=user.updated_at,
    )


# ==============================================================================
# Endpoints
# ==============================================================================


@router.get(
    "",
    response_model=UsersListResponse,
    responses=ERROR_RESPONSES,
    summary="List platform users",
)
@router.get(
    "/",
    response_model=UsersListResponse,
    responses=ERROR_RESPONSES,
    include_in_schema=False,
)
async def list_users(
    request: Request,
    principal: Annotated[Principal, Depends(require_admin_or_superadmin)],
    tenant_id: str | None = Query(
        default=None,
        description="Optional tenant ID filter. Non-superadmins may only query their own tenant.",
    ),
) -> UsersListResponse:
    """List directory platform users.

    - Tenant administrators only receive users from their own tenant (`principal.tenant`).
    - Superadministrators can query across all tenants or filter by a specific `tenant_id`.
    - Non-superadmins specifying a foreign `tenant_id` are rejected with HTTP 403.
    """
    pool = await _require_db_pool(request, "listing users")

    if not is_superadmin(principal):
        if tenant_id is not None and tenant_id != principal.tenant:
            raise APIError(
                403,
                "cross_tenant_forbidden",
                "Superadmin privilege required to query users for other tenants",
            )
        target_tenant = principal.tenant
    else:
        target_tenant = tenant_id

    users = await PlatformUserRepository.list_users(pool, tenant_id=target_tenant)
    user_responses = [_user_to_response(u) for u in users]

    # Superadmin cross-tenant read audit
    if is_superadmin(principal) and (target_tenant is None or target_tenant != principal.tenant):
        await audit_cross_tenant_read(
            principal,
            "GET /api/v1/admin/users",
            [u.model_dump() for u in user_responses],
            what="Listing platform users cross-tenant",
        )

    return UsersListResponse(
        users=user_responses,
        total=len(user_responses),
    )


@router.post(
    "/invite",
    response_model=UserResponse,
    responses=ERROR_RESPONSES,
    status_code=status.HTTP_201_CREATED,
    summary="Invite or provision a platform user",
)
@router.post(
    "/invite/",
    response_model=UserResponse,
    responses=ERROR_RESPONSES,
    status_code=status.HTTP_201_CREATED,
    include_in_schema=False,
)
async def invite_user(
    request: Request,
    body: InviteUserRequest,
    principal: Annotated[Principal, Depends(require_admin_or_superadmin)],
) -> UserResponse:
    """Invite a new platform user into a tenant with designated role and permissions.

    - Tenant administrators can only invite users into their own tenant.
    - Tenant administrators cannot grant superadmin privileges (`is_superadmin=True`).
    - Duplicate email invitations in the same tenant return HTTP 409 Conflict.
    - Emits `user.invited` audit event to platform audit log.
    """
    pool = await _require_db_pool(request, "inviting user")

    # 1. Tenancy and privilege validation
    if not is_superadmin(principal):
        if body.tenant_id is not None and body.tenant_id != principal.tenant:
            raise APIError(
                403,
                "cross_tenant_forbidden",
                "Tenant admin cannot invite users into other tenants",
            )
        if body.is_superadmin:
            raise APIError(
                403,
                "forbidden",
                "Tenant admin cannot grant superadmin privileges",
            )
        target_tenant = principal.tenant
    else:
        target_tenant = body.tenant_id or principal.tenant

    # 2. Check for duplicate email within tenant (or globally)
    existing_in_tenant = await PlatformUserRepository.get_by_email(pool, body.email, tenant_id=target_tenant)
    if existing_in_tenant is not None:
        raise APIError(
            409,
            "user_already_exists",
            f"User with email '{body.email}' already exists in tenant '{target_tenant}'",
        )

    # 3. Create user in database with status='invited'
    user = await PlatformUserRepository.create_user(
        pool,
        tenant_id=target_tenant,
        email=body.email,
        display_name=body.display_name,
        role=body.role,
        status="invited",
        is_superadmin=body.is_superadmin,
        avatar_url=body.avatar_url,
        department=body.department,
        title=body.title,
    )

    # 4. Invalidate auth resolution cache
    invalidate_user_resolution_cache(body.email)

    # 5. Emit audit event
    await _audit_log(
        pool,
        target_tenant,
        "user.invited",
        None,
        None,
        principal.actor,
        {
            "user_id": str(user.id),
            "email": user.email,
            "tenant_id": target_tenant,
            "role": user.role,
            "status": user.status,
            "is_superadmin": user.is_superadmin,
            "display_name": user.display_name,
        },
    )

    return _user_to_response(user)


@router.patch(
    "/{user_id}",
    response_model=UserResponse,
    responses=ERROR_RESPONSES,
    summary="Update platform user role, status, or attributes",
)
async def update_user(
    request: Request,
    user_id: str,
    body: UpdateUserRequest,
    principal: Annotated[Principal, Depends(require_admin_or_superadmin)],
) -> UserResponse:
    """Update role, lifecycle status, display name, or attributes of an existing user.

    - Tenant administrators can only update users within their own tenant.
    - Tenant administrators cannot modify superadmin accounts or change `is_superadmin`.
    - Demoting or suspending the last active platform superadmin is blocked (HTTP 400).
    - Email updates are checked for conflicts across platform users (HTTP 409).
    - Emits `user.updated`, `user.role_updated`, and/or `user.status_updated` audit events.
    """
    pool = await _require_db_pool(request, "updating user")

    # 1. Fetch target user
    target_user = await PlatformUserRepository.get_by_id(pool, user_id)
    if target_user is None:
        raise APIError(404, "user_not_found", f"User '{user_id}' not found")

    # 2. RBAC & Cross-tenant checks
    if not is_superadmin(principal):
        if target_user.tenant_id != principal.tenant:
            raise APIError(
                403,
                "cross_tenant_forbidden",
                "Tenant admin cannot modify users from other tenants",
            )
        if target_user.is_superadmin:
            raise APIError(
                403,
                "forbidden",
                "Tenant admin cannot modify a superadmin user",
            )
        if body.is_superadmin is not None:
            raise APIError(
                403,
                "forbidden",
                "Tenant admin cannot modify superadmin privileges",
            )

    # 3. Last active superadmin protection
    if target_user.is_superadmin:
        demoting = (body.is_superadmin is False)
        suspending = (body.status in ("suspended", "deactivated"))
        if demoting or suspending:
            other_active = await PlatformUserRepository.count_active_superadmins(
                pool, exclude_user_id=target_user.id
            )
            if other_active == 0:
                raise APIError(
                    400,
                    "last_superadmin_protected",
                    "Cannot demote or deactivate the last platform superadmin",
                )

    # 4. Email conflict check
    if body.email is not None and body.email.lower() != target_user.email.lower():
        conflict = await PlatformUserRepository.get_by_email(pool, body.email)
        if conflict is not None and str(conflict.id) != str(target_user.id):
            raise APIError(
                409,
                "email_conflict",
                f"Email '{body.email}' is already registered to another user",
            )

    # 5. Apply database updates
    updated = await PlatformUserRepository.update_user(
        pool,
        user_id=target_user.id,
        email=body.email,
        display_name=body.display_name,
        role=body.role,
        status=body.status,
        is_superadmin=body.is_superadmin,
        avatar_url=body.avatar_url,
        department=body.department,
        title=body.title,
    )
    if updated is None:
        raise APIError(500, "update_failed", "Failed to update user record")

    # 6. Invalidate resolution cache for old and new email
    invalidate_user_resolution_cache(target_user.email)
    if body.email is not None:
        invalidate_user_resolution_cache(body.email)

    # 7. Emit audit events for state mutations
    audit_detail: dict[str, Any] = {
        "user_id": str(updated.id),
        "email": updated.email,
        "tenant_id": updated.tenant_id,
    }

    if body.role is not None and body.role != target_user.role:
        audit_detail["old_role"] = target_user.role
        audit_detail["new_role"] = body.role
        await _audit_log(
            pool,
            updated.tenant_id,
            "user.role_updated",
            None,
            None,
            principal.actor,
            {**audit_detail, "mutation": "role_change"},
        )

    if body.status is not None and body.status != target_user.status:
        audit_detail["old_status"] = target_user.status
        audit_detail["new_status"] = body.status
        await _audit_log(
            pool,
            updated.tenant_id,
            "user.status_updated",
            None,
            None,
            principal.actor,
            {**audit_detail, "mutation": "status_change"},
        )

    await _audit_log(
        pool,
        updated.tenant_id,
        "user.updated",
        None,
        None,
        principal.actor,
        {
            **audit_detail,
            "display_name": updated.display_name,
            "is_superadmin": updated.is_superadmin,
        },
    )

    return _user_to_response(updated)


@router.delete(
    "/{user_id}",
    response_model=UserResponse,
    responses=ERROR_RESPONSES,
    summary="Deactivate/delete platform user",
)
async def delete_user(
    request: Request,
    user_id: str,
    principal: Annotated[Principal, Depends(require_admin_or_superadmin)],
) -> UserResponse:
    """Soft delete (deactivate) an existing platform user.

    - Tenant administrators can only delete users from their own tenant.
    - Tenant administrators cannot delete superadmin users.
    - Deleting the last active platform superadmin is prevented (HTTP 400).
    - Emits `user.deleted` audit event to platform audit log.
    """
    pool = await _require_db_pool(request, "deleting user")

    # 1. Fetch target user
    target_user = await PlatformUserRepository.get_by_id(pool, user_id)
    if target_user is None:
        raise APIError(404, "user_not_found", f"User '{user_id}' not found")

    # 2. RBAC & Cross-tenant checks
    if not is_superadmin(principal):
        if target_user.tenant_id != principal.tenant:
            raise APIError(
                403,
                "cross_tenant_forbidden",
                "Tenant admin cannot delete users from other tenants",
            )
        if target_user.is_superadmin:
            raise APIError(
                403,
                "forbidden",
                "Tenant admin cannot delete a superadmin user",
            )

    # 3. Last active superadmin protection
    if target_user.is_superadmin and target_user.status == "active":
        other_active = await PlatformUserRepository.count_active_superadmins(
            pool, exclude_user_id=target_user.id
        )
        if other_active == 0:
            raise APIError(
                400,
                "last_superadmin_protected",
                "Cannot delete or deactivate the last platform superadmin",
            )

    # 4. Soft delete (status='deactivated')
    deleted = await PlatformUserRepository.delete_user(pool, user_id=target_user.id, soft=True)
    if deleted is None:
        raise APIError(500, "delete_failed", "Failed to deactivate user record")

    # 5. Invalidate auth resolution cache
    invalidate_user_resolution_cache(target_user.email)

    # 6. Emit audit event
    await _audit_log(
        pool,
        target_user.tenant_id,
        "user.deleted",
        None,
        None,
        principal.actor,
        {
            "user_id": str(target_user.id),
            "email": target_user.email,
            "tenant_id": target_user.tenant_id,
            "status": "deactivated",
        },
    )

    return _user_to_response(deleted)


def install_admin_users_api(app: Any) -> None:
    """Mount the admin users router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is list_users:
            return
    app.include_router(router)


__all__ = [
    "InviteUserRequest",
    "UpdateUserRequest",
    "UserResponse",
    "UsersListResponse",
    "delete_user",
    "install_admin_users_api",
    "invite_user",
    "list_users",
    "require_admin_or_superadmin",
    "router",
    "update_user",
]
