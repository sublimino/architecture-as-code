"""Custom account type administration API router for Signal Loom.

Superadmins can create, rename and delete *custom* account types: a named,
explicit feature-flag set that behaves exactly like a built-in account type
(EAP View, EAP Full, Full) for assignment purposes -- PUT /api/v1/admin/features
accepts a custom type's id as ``preset`` (feature_flags.FeatureFlagRepository.
apply_preset) and GET /api/v1/admin/features/presets lists it alongside the
built-ins (feature_flags.list_all_presets).

Built-in account types, their deprecated aliases, and the retired
"minimal_governance" id (feature_flags.RESERVED_ACCOUNT_TYPE_IDS) can never be
created, renamed or deleted here -- that set is a platform constant, not
per-tenant data, so there is nothing to tenant-scope on these routes; every
write is superadmin-only and audited. Design: docs/signalloom/feature-flag-account-types.md.
"""
from __future__ import annotations

import logging
from typing import Annotated, Any

from api_compat import ERROR_RESPONSES, APIError, Principal, _audit_log
from fastapi import APIRouter, Depends, Request, Response, status
from feature_flags import DEFAULT_SYSTEM_FLAGS, CustomAccountTypeRepository, RESERVED_ACCOUNT_TYPE_IDS
from pydantic import BaseModel, ConfigDict, Field, field_validator
from superadmin import require_superadmin

logger = logging.getLogger("signalloom.admin_account_types")

router = APIRouter(prefix="/api/v1/admin/account-types", tags=["admin-account-types"])


async def _resolve_db_pool(request: Request) -> Any:
    """Resolve active database pool from test context, app state, or api_compat."""
    try:
        from db.connection import get_pool
        pool = get_pool()
        if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
            return pool
    except (RuntimeError, ImportError, AttributeError):
        pass

    pool = getattr(request.app.state, "pool", None)
    if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
        return pool

    try:
        import api_compat
        pool = await api_compat._get_pool()
        if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
            return pool
    except (ImportError, AttributeError, Exception):
        pass

    return None


async def _require_db_pool(request: Request, operation: str) -> Any:
    pool = await _resolve_db_pool(request)
    if pool is None:
        raise APIError(503, "database_unavailable", f"Database connection is required for {operation}")
    return pool


class CustomAccountTypeResponse(BaseModel):
    """A custom account type, in the shape the Feature Flags page renders."""
    model_config = ConfigDict(extra="allow")

    id: str = Field(..., description="Custom account type machine identifier")
    name: str = Field(..., description="Human-readable name")
    kind: str = Field(default="custom", description="Always 'custom'")
    flags: dict[str, bool] = Field(..., description="The exact flag set this type applies")
    created_by: str | None = Field(default=None)
    updated_by: str | None = Field(default=None)


class CreateCustomAccountTypeRequest(BaseModel):
    """Payload for creating a custom account type."""
    model_config = ConfigDict(extra="forbid")

    id: str = Field(..., min_length=1, max_length=64, description="Machine identifier, e.g. 'eu_regulated'")
    name: str = Field(..., min_length=1, max_length=256, description="Human-readable name")
    flags: dict[str, bool] = Field(..., description="Must set exactly the registered flag keys")

    @field_validator("id")
    @classmethod
    def _id_shape(cls, value: str) -> str:
        stripped = value.strip()
        if not stripped:
            raise ValueError("id cannot be blank")
        if not all(c.islower() or c.isdigit() or c == "_" for c in stripped):
            raise ValueError("id must be lowercase letters, digits and underscores only")
        if not (stripped[0].isalpha()):
            raise ValueError("id must start with a letter")
        return stripped


class RenameCustomAccountTypeRequest(BaseModel):
    """Payload for renaming a custom account type."""
    model_config = ConfigDict(extra="forbid")

    name: str = Field(..., min_length=1, max_length=256, description="New human-readable name")


def _to_response(row: dict[str, Any]) -> CustomAccountTypeResponse:
    return CustomAccountTypeResponse(
        id=row["id"],
        name=row["name"],
        kind="custom",
        flags=row["flags"],
        created_by=row.get("created_by"),
        updated_by=row.get("updated_by"),
    )


@router.post(
    "",
    response_model=CustomAccountTypeResponse,
    status_code=status.HTTP_201_CREATED,
    responses=ERROR_RESPONSES,
    summary="Create a custom account type",
)
async def create_custom_account_type(
    request: Request,
    body: CreateCustomAccountTypeRequest,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> CustomAccountTypeResponse:
    """Create a named, explicit flag set. Superadmin only; audited."""
    pool = await _require_db_pool(request, "creating a custom account type")
    try:
        row = await CustomAccountTypeRepository.create(
            pool, body.id, body.name, body.flags, created_by=principal.actor
        )
    except ValueError as error:
        raise APIError(400, "invalid_account_type", str(error)) from error

    await _audit_log(
        pool,
        principal.tenant,
        "account_type.created",
        None,
        None,
        principal.actor,
        {"account_type_id": row["id"], "name": row["name"]},
    )
    logger.info("Custom account type created: actor=%s, id=%s", principal.actor, row["id"])
    return _to_response(row)


@router.patch(
    "/{type_id}",
    response_model=CustomAccountTypeResponse,
    responses=ERROR_RESPONSES,
    summary="Rename a custom account type",
)
async def rename_custom_account_type(
    request: Request,
    type_id: str,
    body: RenameCustomAccountTypeRequest,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> CustomAccountTypeResponse:
    """Rename a custom account type. Superadmin only; audited. Built-in types
    cannot be renamed -- 403, not 404, because the id does name something real."""
    if type_id in RESERVED_ACCOUNT_TYPE_IDS:
        raise APIError(
            403, "builtin_account_type_immutable",
            f"'{type_id}' is a built-in account type and cannot be edited",
        )
    pool = await _require_db_pool(request, f"renaming account type '{type_id}'")
    row = await CustomAccountTypeRepository.rename(pool, type_id, body.name, updated_by=principal.actor)
    if row is None:
        raise APIError(404, "account_type_not_found", f"No custom account type '{type_id}'")

    await _audit_log(
        pool,
        principal.tenant,
        "account_type.renamed",
        None,
        None,
        principal.actor,
        {"account_type_id": type_id, "name": row["name"]},
    )
    return _to_response(row)


@router.delete(
    "/{type_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    responses=ERROR_RESPONSES,
    summary="Delete a custom account type",
)
async def delete_custom_account_type(
    request: Request,
    type_id: str,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> Response:
    """Delete a custom account type. Superadmin only; audited. Built-in types
    cannot be deleted -- 403, not 404."""
    if type_id in RESERVED_ACCOUNT_TYPE_IDS:
        raise APIError(
            403, "builtin_account_type_immutable",
            f"'{type_id}' is a built-in account type and cannot be deleted",
        )
    pool = await _require_db_pool(request, f"deleting account type '{type_id}'")
    deleted = await CustomAccountTypeRepository.delete(pool, type_id)
    if not deleted:
        raise APIError(404, "account_type_not_found", f"No custom account type '{type_id}'")

    await _audit_log(
        pool,
        principal.tenant,
        "account_type.deleted",
        None,
        None,
        principal.actor,
        {"account_type_id": type_id},
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def install_admin_account_types_api(app: Any) -> None:
    """Mount the admin account types router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is create_custom_account_type:
            return
    app.include_router(router)


__all__ = [
    "CreateCustomAccountTypeRequest",
    "CustomAccountTypeResponse",
    "RenameCustomAccountTypeRequest",
    "create_custom_account_type",
    "delete_custom_account_type",
    "install_admin_account_types_api",
    "rename_custom_account_type",
    "router",
]
