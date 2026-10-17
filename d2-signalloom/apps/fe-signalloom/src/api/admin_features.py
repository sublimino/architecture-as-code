"""Feature flag administration API router for Signal Loom.

Provides superadmin endpoints for managing tenant-scoped feature flags,
batch-updating page visibilities, and applying pre-packaged presets (e.g. EAP Pilot)
with strict multi-tenant isolation, authorization controls, and audit event logging.
"""
from __future__ import annotations

import logging
from typing import Annotated, Any

from api_compat import (
    ERROR_RESPONSES,
    APIError,
    Principal,
    _audit_log,
)
from cross_tenant_audit import audit_cross_tenant_read
from fastapi import APIRouter, Depends, Query, Request, status
from feature_flags import (
    AccountTypeRepository,
    AccountTypeState,
    FeatureFlagDetail,
    FeatureFlagRepository,
    FeaturesResponse,
    describe_account_type,
    invalidate_flag_cache,
    list_presets,
    resolve_preset_id,
)
from pydantic import BaseModel, ConfigDict, Field
from superadmin import is_superadmin, require_admin_or_superadmin, require_superadmin

logger = logging.getLogger("signalloom.admin_features")

router = APIRouter(prefix="/api/v1/admin/features", tags=["admin-features"])


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
        import api_compat
        pool = await api_compat._get_pool()
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


async def _admin_features(
    pool: Any, tenant_id: str, account_type: AccountTypeState | None = None
) -> AdminFeaturesResponse:
    """Effective flags, per-flag details and account type state for a tenant."""
    all_flags = await FeatureFlagRepository.evaluate_all_flags(pool, tenant_id)
    flag_records = await FeatureFlagRepository.list_flags(pool, tenant_id)
    details: dict[str, FeatureFlagDetail] = {
        key: FeatureFlagDetail(enabled=val, config={}) for key, val in all_flags.items()
    }
    for r in flag_records:
        details[r.flag_key] = FeatureFlagDetail(enabled=r.enabled, config=r.config_json)
    if account_type is None:
        record = await AccountTypeRepository.get(pool, tenant_id)
        account_type = describe_account_type(record["account_type"] if record else None, all_flags)
    return AdminFeaturesResponse(
        tenant_id=tenant_id, flags=all_flags, details=details, account_type=account_type
    )


class PresetSummary(BaseModel):
    """Preset summary model describing a pre-configured feature bundle."""
    model_config = ConfigDict(extra="allow")

    id: str = Field(..., description="Preset machine identifier")
    name: str = Field(..., description="Human-readable preset name")
    kind: str = Field(..., description="'account_type' (assignable account type) or 'bundle'")
    status: str = Field(..., description="'confirmed', or 'draft' while its contents await sign-off")
    aliases: list[str] = Field(default_factory=list, description="Deprecated ids that still apply this preset")
    description: str = Field(..., description="Detailed description of target profile")
    flags: dict[str, bool] = Field(..., description="Flag key to boolean mapping")


class AdminFeaturesResponse(FeaturesResponse):
    """Admin view of a tenant's flags, with its account type."""

    account_type: AccountTypeState = Field(..., description="Recorded account type and whether the flags still match it")


class PresetsResponse(BaseModel):
    """List of available feature flag preset bundles."""
    presets: list[PresetSummary] = Field(default_factory=list, description="Available preset bundles")


class UpdateTenantFeaturesRequest(BaseModel):
    """Payload for batch-updating feature flags or applying a preset to a tenant."""
    model_config = ConfigDict(extra="forbid")

    tenant_id: str = Field(..., min_length=1, max_length=128, description="Target tenant identifier")
    flags: dict[str, bool] | None = Field(default=None, description="Optional map of flag keys to boolean enablement")
    preset: str | None = Field(default=None, description="Optional preset or account type id (e.g. 'eap_view', 'eap_full', 'full'; deprecated 'eap_pilot', 'full_demo')")


class UpdateSingleFeatureRequest(BaseModel):
    """Payload for mutating an individual tenant feature flag."""
    model_config = ConfigDict(extra="forbid")

    enabled: bool = Field(..., description="Flag boolean enablement state")
    config_json: dict[str, Any] | None = Field(default=None, description="Optional JSONB configuration metadata")


@router.get(
    "/presets",
    response_model=PresetsResponse,
    responses=ERROR_RESPONSES,
    summary="List available feature flag presets",
)
async def get_presets(
    _principal: Annotated[Principal, Depends(require_admin_or_superadmin)],
) -> PresetsResponse:
    """Return all catalogued feature presets (e.g. EAP Pilot, Full Demo, Minimal Governance)."""
    presets = [PresetSummary(**p) for p in list_presets()]
    return PresetsResponse(presets=presets)


@router.get(
    "",
    response_model=AdminFeaturesResponse,
    responses=ERROR_RESPONSES,
    summary="Get tenant feature flags (admin view)",
)
@router.get(
    "/",
    response_model=AdminFeaturesResponse,
    responses=ERROR_RESPONSES,
    include_in_schema=False,
)
async def get_admin_features(
    request: Request,
    principal: Annotated[Principal, Depends(require_admin_or_superadmin)],
    tenant_id: str | None = Query(
        default=None,
        description="Target tenant ID (superadmins can inspect any tenant; tenant admins must match their own)",
    ),
) -> AdminFeaturesResponse:
    """Fetch feature flag status and configuration for a given tenant."""
    target_tenant = tenant_id or principal.tenant
    if target_tenant != principal.tenant:
        if not is_superadmin(principal):
            raise APIError(
                403,
                "cross_tenant_forbidden",
                "Superadmin privilege required to view features of other tenants",
            )
    pool = await _require_db_pool(request, "fetching admin feature flags")
    response = await _admin_features(pool, target_tenant)

    if target_tenant != principal.tenant and is_superadmin(principal):
        await audit_cross_tenant_read(
            principal,
            "GET /api/v1/admin/features",
            response.flags,
            what="Fetching admin feature flags cross-tenant",
        )
    return response


@router.put(
    "",
    response_model=AdminFeaturesResponse,
    responses=ERROR_RESPONSES,
    summary="Batch update tenant feature flags or apply preset",
)
@router.put(
    "/",
    response_model=AdminFeaturesResponse,
    responses=ERROR_RESPONSES,
    include_in_schema=False,
)
async def update_tenant_features(
    request: Request,
    body: UpdateTenantFeaturesRequest,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> AdminFeaturesResponse:
    """Batch-update tenant feature flags or apply a pre-configured bundle preset.

    Enforces platform superadmin privilege (`is_superadmin = true`).
    Emits structured audit event for state tracking.
    """
    target_tenant = body.tenant_id.strip()
    if not target_tenant:
        raise APIError(400, "invalid_tenant", "tenant_id cannot be blank")

    if not body.flags and not body.preset:
        raise APIError(400, "missing_payload", "Either 'flags' or 'preset' must be provided")

    pool = await _require_db_pool(request, "updating tenant feature flags")

    applied_preset: str | None = None
    if body.preset:
        applied_preset = resolve_preset_id(body.preset)
        if applied_preset is None:
            raise APIError(400, "unknown_preset", f"Preset '{body.preset}' is not recognized")
        await FeatureFlagRepository.apply_preset(
            pool, target_tenant, applied_preset, updated_by=principal.actor
        )

    if body.flags:
        await FeatureFlagRepository.update_tenant_flags(pool, target_tenant, body.flags)

    invalidate_flag_cache(target_tenant)

    # A flag set that no longer equals the recorded type marks the tenant custom.
    account_type = await AccountTypeRepository.refresh(pool, target_tenant, principal.actor)
    response = await _admin_features(pool, target_tenant, account_type)
    all_flags = response.flags

    # Emit audit event
    await _audit_log(
        pool,
        target_tenant,
        "feature_flags.updated",
        None,
        None,
        principal.actor,
        {
            "target_tenant": target_tenant,
            "applied_preset": applied_preset,
            "explicit_flags_count": len(body.flags) if body.flags else 0,
            "total_active_flags": len(all_flags),
            "account_type": account_type.id,
            "account_type_customised": account_type.customised,
        },
    )

    logger.info(
        "Tenant feature flags updated: actor=%s, tenant=%s, preset=%s, flags=%d",
        principal.actor,
        target_tenant,
        applied_preset,
        len(body.flags) if body.flags else 0,
    )

    return response


@router.put(
    "/{flag_key}",
    response_model=AdminFeaturesResponse,
    responses=ERROR_RESPONSES,
    summary="Update single tenant feature flag",
)
async def update_single_tenant_feature(
    request: Request,
    flag_key: str,
    body: UpdateSingleFeatureRequest,
    principal: Annotated[Principal, Depends(require_superadmin)],
    tenant_id: str = Query(..., min_length=1, description="Target tenant ID"),
) -> AdminFeaturesResponse:
    """Set or toggle an individual feature flag for a tenant.

    Enforces platform superadmin privilege (`is_superadmin = true`).
    """
    target_tenant = tenant_id.strip()
    if not target_tenant:
        raise APIError(400, "invalid_tenant", "tenant_id cannot be blank")

    key = flag_key.strip()
    if not key:
        raise APIError(400, "invalid_flag_key", "flag_key cannot be blank")

    pool = await _require_db_pool(request, f"updating feature flag '{key}'")
    await FeatureFlagRepository.set_feature_flag(
        pool,
        tenant_id=target_tenant,
        flag_key=key,
        enabled=body.enabled,
        config_json=body.config_json or {},
    )
    invalidate_flag_cache(target_tenant, key)

    account_type = await AccountTypeRepository.refresh(pool, target_tenant, principal.actor)
    response = await _admin_features(pool, target_tenant, account_type)

    # Emit audit event
    await _audit_log(
        pool,
        target_tenant,
        "feature_flags.updated",
        None,
        None,
        principal.actor,
        {
            "target_tenant": target_tenant,
            "flag_key": key,
            "enabled": body.enabled,
            "account_type": account_type.id,
            "account_type_customised": account_type.customised,
        },
    )

    return response


def install_admin_features_api(app: Any) -> None:
    """Mount the admin features router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is get_presets:
            return
    app.include_router(router)


__all__ = [
    "AdminFeaturesResponse",
    "PresetSummary",
    "PresetsResponse",
    "UpdateSingleFeatureRequest",
    "UpdateTenantFeaturesRequest",
    "get_admin_features",
    "get_presets",
    "install_admin_features_api",
    "router",
    "update_single_tenant_feature",
    "update_tenant_features",
]
