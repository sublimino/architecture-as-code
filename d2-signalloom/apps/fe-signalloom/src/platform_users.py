"""Attributable operator and platform user lifecycle for Signal Loom.

This module provides the platform user and operator identity endpoints,
re-exporting and integrating the attributable operator identity models,
lifecycle operations, authorization matrix, and tenant scope enforcement,
alongside the authoritative PlatformUser domain model, superadmin flag serialization,
and PlatformUserRepository database queries.
"""
from __future__ import annotations

import logging
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Literal

from operator_identity import (
    AUTHORIZATION_MATRIX,
    OperatorIdentitiesResponse,
    OperatorIdentityCreateRequest,
    OperatorIdentityRemovalRequest,
    OperatorIdentityResponse,
    OperatorPrincipal,
    OperatorRemovalResponse,
    OperatorSessionResponse,
    create_operator_identity,
    enforce_strict_operator_tenant,
    ensure_active_operator,
    list_operator_identities,
    operator_from_row,
    operator_session,
    remove_operator_identity,
    router,
)
from pydantic import BaseModel, ConfigDict, Field, field_validator

logger = logging.getLogger(__name__)


@asynccontextmanager
async def _acquire_connection(pool_or_conn: Any) -> AsyncIterator[Any]:
    """Acquire a connection from a pool or yield an existing connection/mock."""
    if hasattr(pool_or_conn, "acquire") and callable(pool_or_conn.acquire):
        async with pool_or_conn.acquire() as conn:
            yield conn
    else:
        yield pool_or_conn


def _normalize_email(value: str) -> str:
    """Normalize email address to lowercase and trimmed string."""
    normalized = value.strip().lower()
    local, separator, domain = normalized.partition("@")
    if not separator or not local or not domain or "@" in domain or any(c.isspace() for c in normalized):
        raise ValueError("email must be one individual mailbox address")
    return normalized


class PlatformUser(BaseModel):
    """Domain model representing a directory user in public.platform_users."""
    model_config = ConfigDict(from_attributes=True, extra="ignore")

    id: str
    tenant_id: str = "tenant-demo"
    email: str
    display_name: str
    role: Literal["admin", "editor", "viewer"] = "viewer"
    status: Literal["active", "invited", "suspended", "deactivated"] = "active"
    is_superadmin: bool = Field(
        default=False, description="Whether the user possesses platform superadmin privileges"
    )
    avatar_url: str | None = None
    department: str | None = None
    title: str | None = None
    last_login_at: str | None = None
    created_at: str | None = None
    updated_at: str | None = None

    @field_validator("id", mode="before")
    @classmethod
    def serialize_id(cls, v: Any) -> str:
        return str(v)

    @field_validator("email")
    @classmethod
    def normalize_user_email(cls, v: str) -> str:
        return _normalize_email(v)

    @field_validator("last_login_at", "created_at", "updated_at", mode="before")
    @classmethod
    def serialize_datetime(cls, v: Any) -> str | None:
        if v is None:
            return None
        if isinstance(v, datetime):
            return v.isoformat()
        return str(v)


class PlatformUserResponse(BaseModel):
    """Response model for tenant user listings."""
    model_config = ConfigDict(extra="forbid")

    id: str
    email: str
    display_name: str
    role: Literal["admin", "editor", "viewer"]
    status: Literal["active", "invited", "suspended", "deactivated"]
    department: str | None = None
    title: str | None = None
    last_login_at: str | None = None
    created_at: str
    is_superadmin: bool = False


class PlatformUsersResponse(BaseModel):
    """Response model for listing platform users."""
    model_config = ConfigDict(extra="forbid")

    users: list[PlatformUserResponse]
    total: int


def platform_user_from_row(row: Any) -> PlatformUser:
    """Parse an asyncpg Record or dictionary into a PlatformUser domain model."""
    if isinstance(row, dict):
        return PlatformUser(
            id=str(row["id"]),
            tenant_id=row.get("tenant_id", "tenant-demo"),
            email=row["email"],
            display_name=row.get("display_name", ""),
            role=row.get("role", "viewer"),
            status=row.get("status", "active"),
            is_superadmin=bool(row.get("is_superadmin", False)),
            avatar_url=row.get("avatar_url"),
            department=row.get("department"),
            title=row.get("title"),
            last_login_at=row.get("last_login_at"),
            created_at=row.get("created_at"),
            updated_at=row.get("updated_at"),
        )

    row_dict = dict(row) if hasattr(row, "keys") else {}
    return PlatformUser(
        id=str(row["id"]),
        tenant_id=row_dict.get("tenant_id", "tenant-demo")
        if "tenant_id" in row_dict
        else getattr(row, "tenant_id", "tenant-demo"),
        email=row["email"],
        display_name=row_dict.get("display_name", "")
        if "display_name" in row_dict
        else getattr(row, "display_name", ""),
        role=row_dict.get("role", "viewer")
        if "role" in row_dict
        else getattr(row, "role", "viewer"),
        status=row_dict.get("status", "active")
        if "status" in row_dict
        else getattr(row, "status", "active"),
        is_superadmin=bool(row_dict.get("is_superadmin", False))
        if "is_superadmin" in row_dict
        else False,
        avatar_url=row_dict.get("avatar_url", None),
        department=row_dict.get("department", None),
        title=row_dict.get("title", None),
        last_login_at=row_dict.get("last_login_at", None),
        created_at=row_dict.get("created_at", None),
        updated_at=row_dict.get("updated_at", None),
    )


_PLATFORM_USER_COLUMNS = """
    id, tenant_id, email, display_name, role, status, is_superadmin,
    avatar_url, department, title, last_login_at, created_at, updated_at
"""


class PlatformUserRepository:
    """Repository handling persistence and retrieval of platform users."""

    @classmethod
    async def get_by_email(
        cls, pool_or_conn: Any, email: str, tenant_id: str | None = None
    ) -> PlatformUser | None:
        """Fetch a platform user by email (case-insensitive normalized), optionally scoped by tenant."""
        normalized = _normalize_email(email)
        async with _acquire_connection(pool_or_conn) as conn:
            if tenant_id is not None:
                row = await conn.fetchrow(
                    f"""
                    SELECT {_PLATFORM_USER_COLUMNS}
                      FROM public.platform_users
                     WHERE LOWER(email) = $1 AND tenant_id = $2
                     LIMIT 1
                    """,
                    normalized,
                    tenant_id,
                )
            else:
                row = await conn.fetchrow(
                    f"""
                    SELECT {_PLATFORM_USER_COLUMNS}
                      FROM public.platform_users
                     WHERE LOWER(email) = $1
                     ORDER BY is_superadmin DESC, created_at ASC
                     LIMIT 1
                    """,
                    normalized,
                )
            return platform_user_from_row(row) if row is not None else None

    @classmethod
    async def get_by_id(
        cls, pool_or_conn: Any, user_id: uuid.UUID | str, tenant_id: str | None = None
    ) -> PlatformUser | None:
        """Fetch a platform user by unique ID, optionally scoped by tenant."""
        uid = uuid.UUID(str(user_id)) if not isinstance(user_id, uuid.UUID) else user_id
        async with _acquire_connection(pool_or_conn) as conn:
            if tenant_id is not None:
                row = await conn.fetchrow(
                    f"""
                    SELECT {_PLATFORM_USER_COLUMNS}
                      FROM public.platform_users
                     WHERE id = $1 AND tenant_id = $2
                     LIMIT 1
                    """,
                    uid,
                    tenant_id,
                )
            else:
                row = await conn.fetchrow(
                    f"""
                    SELECT {_PLATFORM_USER_COLUMNS}
                      FROM public.platform_users
                     WHERE id = $1
                     LIMIT 1
                    """,
                    uid,
                )
            return platform_user_from_row(row) if row is not None else None

    @classmethod
    async def list_users(
        cls, pool_or_conn: Any, tenant_id: str | None = None
    ) -> list[PlatformUser]:
        """List platform users, optionally filtered by tenant."""
        async with _acquire_connection(pool_or_conn) as conn:
            if tenant_id is not None:
                rows = await conn.fetch(
                    f"""
                    SELECT {_PLATFORM_USER_COLUMNS}
                      FROM public.platform_users
                     WHERE tenant_id = $1
                     ORDER BY created_at ASC, id ASC
                    """,
                    tenant_id,
                )
            else:
                rows = await conn.fetch(
                    f"""
                    SELECT {_PLATFORM_USER_COLUMNS}
                      FROM public.platform_users
                     ORDER BY tenant_id ASC, created_at ASC, id ASC
                    """
                )
            return [platform_user_from_row(row) for row in rows]

    @classmethod
    async def create_user(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        email: str,
        display_name: str,
        role: Literal["admin", "editor", "viewer"] = "viewer",
        status: Literal["active", "invited", "suspended", "deactivated"] = "active",
        is_superadmin: bool = False,
        avatar_url: str | None = None,
        department: str | None = None,
        title: str | None = None,
    ) -> PlatformUser:
        """Create and persist a new platform user."""
        normalized = _normalize_email(email)
        user_id = uuid.uuid4()
        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                f"""
                INSERT INTO public.platform_users (
                    id, tenant_id, email, display_name, role, status,
                    is_superadmin, avatar_url, department, title
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                RETURNING {_PLATFORM_USER_COLUMNS}
                """,
                user_id,
                tenant_id,
                normalized,
                display_name,
                role,
                status,
                is_superadmin,
                avatar_url,
                department,
                title,
            )
            return platform_user_from_row(row)

    @classmethod
    async def update_user(
        cls,
        pool_or_conn: Any,
        user_id: uuid.UUID | str,
        tenant_id: str | None = None,
        email: str | None = None,
        display_name: str | None = None,
        role: Literal["admin", "editor", "viewer"] | None = None,
        status: Literal["active", "invited", "suspended", "deactivated"] | None = None,
        is_superadmin: bool | None = None,
        avatar_url: str | None = None,
        department: str | None = None,
        title: str | None = None,
    ) -> PlatformUser | None:
        """Update fields on an existing platform user record."""
        uid = uuid.UUID(str(user_id)) if not isinstance(user_id, uuid.UUID) else user_id
        set_clauses: list[str] = []
        params: list[Any] = [uid]
        param_idx = 2

        if email is not None:
            set_clauses.append(f"email = ${param_idx}")
            params.append(_normalize_email(email))
            param_idx += 1

        if display_name is not None:
            set_clauses.append(f"display_name = ${param_idx}")
            params.append(display_name)
            param_idx += 1

        if role is not None:
            set_clauses.append(f"role = ${param_idx}")
            params.append(role)
            param_idx += 1

        if status is not None:
            set_clauses.append(f"status = ${param_idx}")
            params.append(status)
            param_idx += 1

        if is_superadmin is not None:
            set_clauses.append(f"is_superadmin = ${param_idx}")
            params.append(is_superadmin)
            param_idx += 1

        if avatar_url is not None:
            set_clauses.append(f"avatar_url = ${param_idx}")
            params.append(avatar_url)
            param_idx += 1

        if department is not None:
            set_clauses.append(f"department = ${param_idx}")
            params.append(department)
            param_idx += 1

        if title is not None:
            set_clauses.append(f"title = ${param_idx}")
            params.append(title)
            param_idx += 1

        if not set_clauses:
            return await cls.get_by_id(pool_or_conn, uid, tenant_id=tenant_id)

        set_clauses.append("updated_at = NOW()")
        where_clause = "WHERE id = $1"
        if tenant_id is not None:
            where_clause += f" AND tenant_id = ${param_idx}"
            params.append(tenant_id)
            param_idx += 1

        query = f"""
            UPDATE public.platform_users
               SET {', '.join(set_clauses)}
            {where_clause}
            RETURNING {_PLATFORM_USER_COLUMNS}
        """

        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(query, *params)
            return platform_user_from_row(row) if row is not None else None

    @classmethod
    async def delete_user(
        cls,
        pool_or_conn: Any,
        user_id: uuid.UUID | str,
        tenant_id: str | None = None,
        soft: bool = True,
    ) -> PlatformUser | None:
        """Deactivate (soft delete) or remove a platform user."""
        uid = uuid.UUID(str(user_id)) if not isinstance(user_id, uuid.UUID) else user_id
        async with _acquire_connection(pool_or_conn) as conn:
            if soft:
                if tenant_id is not None:
                    row = await conn.fetchrow(
                        f"""
                        UPDATE public.platform_users
                           SET status = 'deactivated', updated_at = NOW()
                         WHERE id = $1 AND tenant_id = $2
                        RETURNING {_PLATFORM_USER_COLUMNS}
                        """,
                        uid,
                        tenant_id,
                    )
                else:
                    row = await conn.fetchrow(
                        f"""
                        UPDATE public.platform_users
                           SET status = 'deactivated', updated_at = NOW()
                         WHERE id = $1
                        RETURNING {_PLATFORM_USER_COLUMNS}
                        """,
                        uid,
                    )
            else:
                if tenant_id is not None:
                    row = await conn.fetchrow(
                        f"""
                        DELETE FROM public.platform_users
                         WHERE id = $1 AND tenant_id = $2
                        RETURNING {_PLATFORM_USER_COLUMNS}
                        """,
                        uid,
                        tenant_id,
                    )
                else:
                    row = await conn.fetchrow(
                        f"""
                        DELETE FROM public.platform_users
                         WHERE id = $1
                        RETURNING {_PLATFORM_USER_COLUMNS}
                        """,
                        uid,
                    )
            return platform_user_from_row(row) if row is not None else None

    @classmethod
    async def count_active_superadmins(
        cls,
        pool_or_conn: Any,
        exclude_user_id: uuid.UUID | str | None = None,
    ) -> int:
        """Count active platform superadmins, optionally excluding one user ID."""
        async with _acquire_connection(pool_or_conn) as conn:
            if exclude_user_id is not None:
                uid = uuid.UUID(str(exclude_user_id)) if not isinstance(exclude_user_id, uuid.UUID) else exclude_user_id
                count = await conn.fetchval(
                    """
                    SELECT COUNT(*)::int
                      FROM public.platform_users
                     WHERE is_superadmin = TRUE
                       AND status = 'active'
                       AND id != $1
                    """,
                    uid,
                )
            else:
                count = await conn.fetchval(
                    """
                    SELECT COUNT(*)::int
                      FROM public.platform_users
                     WHERE is_superadmin = TRUE
                       AND status = 'active'
                    """
                )
            return int(count or 0)


get_platform_user_by_email = PlatformUserRepository.get_by_email
get_platform_user_by_id = PlatformUserRepository.get_by_id
list_platform_users = PlatformUserRepository.list_users
create_platform_user = PlatformUserRepository.create_user
update_platform_user = PlatformUserRepository.update_user
delete_platform_user = PlatformUserRepository.delete_user
count_active_superadmins = PlatformUserRepository.count_active_superadmins

__all__ = [
    "AUTHORIZATION_MATRIX",
    "OperatorIdentitiesResponse",
    "OperatorIdentityCreateRequest",
    "OperatorIdentityRemovalRequest",
    "OperatorIdentityResponse",
    "OperatorPrincipal",
    "OperatorRemovalResponse",
    "OperatorSessionResponse",
    "PlatformUser",
    "PlatformUserRepository",
    "PlatformUserResponse",
    "PlatformUsersResponse",
    "count_active_superadmins",
    "create_operator_identity",
    "create_platform_user",
    "delete_platform_user",
    "enforce_strict_operator_tenant",
    "ensure_active_operator",
    "get_platform_user_by_email",
    "get_platform_user_by_id",
    "list_operator_identities",
    "list_platform_users",
    "operator_from_row",
    "operator_session",
    "platform_user_from_row",
    "remove_operator_identity",
    "router",
    "update_platform_user",
]
