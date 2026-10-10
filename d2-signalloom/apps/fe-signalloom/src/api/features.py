"""Feature flags API router for Signal Loom.

Provides tenant-scoped feature flag configuration dictionaries for client evaluation
and frontend OpenFeature provider synchronization.
"""
from __future__ import annotations

import logging
from typing import Annotated, Any

import asyncpg
from api_compat import (
    ERROR_RESPONSES,
    APIError,
    Principal,
    authenticated_principal,
)
from fastapi import APIRouter, Depends, Query, Request
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    FeatureFlagDetail,
    FeatureFlagRepository,
    FeaturesResponse,
    require_feature,
)
from superadmin import is_superadmin

logger = logging.getLogger("signalloom.features")

router = APIRouter(prefix="/api/v1/features", tags=["features"])


async def _resolve_db_pool(request: Request) -> Any:
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


@router.get(
    "",
    response_model=FeaturesResponse,
    responses=ERROR_RESPONSES,
    summary="Get tenant feature flags",
)
@router.get(
    "/",
    response_model=FeaturesResponse,
    responses=ERROR_RESPONSES,
    include_in_schema=False,
)
async def get_features(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    tenant_id: str | None = Query(
        default=None,
        description="Optional tenant ID override for superadmins",
    ),
) -> FeaturesResponse:
    """Return dictionary of active flag keys to boolean/config values for the authenticated tenant.

    Strict Tenant Isolation:
    - Standard principals only evaluate flags for their own tenant (`principal.tenant`).
    - Superadmin principals may evaluate flags for any tenant via the `tenant_id` query parameter.
    - Non-superadmin requests with a differing `tenant_id` parameter are rejected with 403 Forbidden.
    """
    target_tenant = principal.tenant
    if tenant_id is not None and tenant_id != principal.tenant:
        if not is_superadmin(principal):
            raise APIError(
                403,
                "cross_tenant_forbidden",
                "Superadmin privilege required to query flags for other tenants",
            )
        target_tenant = tenant_id

    pool = await _resolve_db_pool(request)

    # 1. Base system defaults
    flags: dict[str, bool] = dict(DEFAULT_SYSTEM_FLAGS)
    details: dict[str, FeatureFlagDetail] = {
        key: FeatureFlagDetail(enabled=val, config={})
        for key, val in DEFAULT_SYSTEM_FLAGS.items()
    }

    # 2. Database tenant overrides (if database is available)
    if pool is not None:
        try:
            tenant_flags = await FeatureFlagRepository.list_flags(pool, target_tenant)
            for flag in tenant_flags:
                flags[flag.flag_key] = flag.enabled
                details[flag.flag_key] = FeatureFlagDetail(
                    enabled=flag.enabled,
                    config=flag.config_json,
                )
        except (asyncpg.PostgresError, OSError, RuntimeError, ValueError, AttributeError) as exc:
            logger.warning(
                "Failed to fetch tenant feature flags from database for tenant %s: %s",
                target_tenant,
                exc,
            )

    return FeaturesResponse(
        tenant_id=target_tenant,
        flags=flags,
        details=details,
    )


def install_features_api(app: Any) -> None:
    """Mount the features router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is get_features:
            return
    app.include_router(router)


__all__ = [
    "FeatureFlagDetail",
    "FeaturesResponse",
    "get_features",
    "install_features_api",
    "require_feature",
    "router",
]
