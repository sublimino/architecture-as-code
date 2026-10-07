"""Tenant-scoped feature flag repository and domain models for Signal Loom.

This module provides typed data models and asyncpg repository operations for
tenant-isolated feature flags with JSONB configuration payloads.

Architecture & Invariants:
- Strict Multi-Tenant Isolation: Every query filters by `tenant_id = $1`.
- Forward-Only & Idempotent Migrations: Backed by migration 057 (tenant_feature_flags).
- Robust JSONB Support: Arbitrary config payloads parse cleanly and round-trip.
- Default Fallbacks: Graceful evaluation when flags are not explicitly configured.
"""
from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

logger = logging.getLogger(__name__)

#: Default system-wide feature flags applied when no tenant override is present.
DEFAULT_SYSTEM_FLAGS: dict[str, bool] = {
    "core_governance": True,
    "audit": True,
    "compliance": True,
    "demos_fleet": False,
    "supercred": False,
    "rbac_analysis": False,
    "collusion_access": False,
}


class FeatureFlagConfig(BaseModel):
    """Flexible configuration payload model for feature flags."""
    model_config = ConfigDict(extra="allow")

    description: str | None = Field(default=None, description="Optional human-readable flag description")


class TenantFeatureFlag(BaseModel):
    """Representation of a tenant-scoped feature flag record."""
    model_config = ConfigDict(from_attributes=True)

    tenant_id: str = Field(..., max_length=128, description="Tenant identifier")
    flag_key: str = Field(..., max_length=128, description="Unique feature flag key")
    enabled: bool = Field(default=False, description="Flag boolean enablement state")
    config_json: dict[str, Any] = Field(default_factory=dict, description="JSONB configuration payload")
    created_at: datetime | None = Field(default=None, description="Creation timestamp")
    updated_at: datetime | None = Field(default=None, description="Last update timestamp")


class FlagEvaluationResult(BaseModel):
    """Result of evaluating a feature flag for a tenant."""
    model_config = ConfigDict(from_attributes=True)

    flag_key: str = Field(..., description="Evaluated flag key")
    enabled: bool = Field(..., description="Evaluated flag state")
    config: dict[str, Any] = Field(default_factory=dict, description="Associated configuration payload")
    tenant_id: str | None = Field(default=None, description="Evaluated tenant identifier")
    reason: str = Field(default="default", description="Evaluation decision reason")


@asynccontextmanager
async def _acquire_connection(pool_or_conn: Any) -> AsyncIterator[Any]:
    """Acquire a connection from a pool or yield an existing connection/mock."""
    if hasattr(pool_or_conn, "acquire") and callable(pool_or_conn.acquire):
        async with pool_or_conn.acquire() as conn:
            yield conn
    else:
        yield pool_or_conn


def _parse_row(row: Any) -> TenantFeatureFlag:
    """Parse an asyncpg record or dictionary into a TenantFeatureFlag instance."""
    if isinstance(row, dict):
        config = row.get("config_json", {})
        if isinstance(config, str):
            try:
                config = json.loads(config)
            except (json.JSONDecodeError, TypeError, ValueError):
                config = {}
        return TenantFeatureFlag(
            tenant_id=row["tenant_id"],
            flag_key=row["flag_key"],
            enabled=bool(row["enabled"]),
            config_json=config if isinstance(config, dict) else {},
            created_at=row.get("created_at"),
            updated_at=row.get("updated_at"),
        )

    # asyncpg Record object
    config_val = row["config_json"]
    if isinstance(config_val, str):
        try:
            config_val = json.loads(config_val)
        except (json.JSONDecodeError, TypeError, ValueError):
            config_val = {}
    elif config_val is None:
        config_val = {}

    created_at = row.get("created_at", None) if hasattr(row, "get") else dict(row).get("created_at", None)
    updated_at = row.get("updated_at", None) if hasattr(row, "get") else dict(row).get("updated_at", None)

    return TenantFeatureFlag(
        tenant_id=row["tenant_id"],
        flag_key=row["flag_key"],
        enabled=bool(row["enabled"]),
        config_json=config_val if isinstance(config_val, dict) else {},
        created_at=created_at,
        updated_at=updated_at,
    )


class FeatureFlagRepository:
    """Repository handling persistence, retrieval, and evaluation of tenant feature flags."""

    @classmethod
    async def get_tenant_flags(cls, pool_or_conn: Any, tenant_id: str) -> dict[str, bool]:
        """Fetch a dictionary of flag_key -> enabled boolean for a given tenant."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")

        async with _acquire_connection(pool_or_conn) as conn:
            rows = await conn.fetch(
                """
                SELECT flag_key, enabled
                FROM public.tenant_feature_flags
                WHERE tenant_id = $1
                ORDER BY flag_key
                """,
                tenant_id,
            )
            return {row["flag_key"]: bool(row["enabled"]) for row in rows}

    @classmethod
    async def get_tenant_flag_configs(
        cls, pool_or_conn: Any, tenant_id: str
    ) -> dict[str, dict[str, Any]]:
        """Fetch full flag records with configurations for a tenant."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")

        flags = await cls.list_flags(pool_or_conn, tenant_id)
        return {
            flag.flag_key: {
                "enabled": flag.enabled,
                "config": flag.config_json,
            }
            for flag in flags
        }

    @classmethod
    async def get_feature_flag(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        flag_key: str,
        default: bool = False,
        default_config: dict[str, Any] | None = None,
    ) -> TenantFeatureFlag:
        """Fetch a single feature flag for a tenant, falling back to defaults if not found."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")
        if not flag_key or not isinstance(flag_key, str):
            raise ValueError("flag_key must be a non-empty string")

        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                SELECT tenant_id, flag_key, enabled, config_json, created_at, updated_at
                FROM public.tenant_feature_flags
                WHERE tenant_id = $1 AND flag_key = $2
                """,
                tenant_id,
                flag_key,
            )
            if row is not None:
                return _parse_row(row)

            # Fallback to system default or supplied default
            fallback_enabled = default
            if flag_key in DEFAULT_SYSTEM_FLAGS and default is False:
                fallback_enabled = DEFAULT_SYSTEM_FLAGS[flag_key]

            return TenantFeatureFlag(
                tenant_id=tenant_id,
                flag_key=flag_key,
                enabled=fallback_enabled,
                config_json=default_config or {},
            )

    @classmethod
    async def get_flag_record(
        cls, pool_or_conn: Any, tenant_id: str, flag_key: str
    ) -> TenantFeatureFlag | None:
        """Fetch an explicit database record for a flag without applying defaults."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")
        if not flag_key or not isinstance(flag_key, str):
            raise ValueError("flag_key must be a non-empty string")

        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                SELECT tenant_id, flag_key, enabled, config_json, created_at, updated_at
                FROM public.tenant_feature_flags
                WHERE tenant_id = $1 AND flag_key = $2
                """,
                tenant_id,
                flag_key,
            )
            if row is None:
                return None
            return _parse_row(row)

    @classmethod
    async def set_feature_flag(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        flag_key: str,
        enabled: bool,
        config_json: dict[str, Any] | BaseModel | str | None = None,
    ) -> TenantFeatureFlag:
        """Create or update a tenant feature flag with ON CONFLICT DO UPDATE semantics."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")
        if not flag_key or not isinstance(flag_key, str):
            raise ValueError("flag_key must be a non-empty string")

        payload: dict[str, Any] = {}
        if isinstance(config_json, BaseModel):
            payload = config_json.model_dump()
        elif isinstance(config_json, dict):
            payload = config_json
        elif isinstance(config_json, str):
            try:
                parsed = json.loads(config_json)
                payload = parsed if isinstance(parsed, dict) else {"value": parsed}
            except (json.JSONDecodeError, TypeError, ValueError):
                payload = {"raw": config_json}
        elif config_json is not None:
            payload = {"value": config_json}

        json_str = json.dumps(payload)

        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                INSERT INTO public.tenant_feature_flags (
                    tenant_id, flag_key, enabled, config_json, updated_at
                )
                VALUES ($1, $2, $3, $4::jsonb, NOW())
                ON CONFLICT (tenant_id, flag_key) DO UPDATE
                    SET enabled = EXCLUDED.enabled,
                        config_json = EXCLUDED.config_json,
                        updated_at = NOW()
                RETURNING tenant_id, flag_key, enabled, config_json, created_at, updated_at
                """,
                tenant_id,
                flag_key,
                bool(enabled),
                json_str,
            )
            return _parse_row(row)

    @classmethod
    async def delete_feature_flag(
        cls, pool_or_conn: Any, tenant_id: str, flag_key: str
    ) -> bool:
        """Delete a tenant feature flag. Returns True if deleted, False if not found."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")
        if not flag_key or not isinstance(flag_key, str):
            raise ValueError("flag_key must be a non-empty string")

        async with _acquire_connection(pool_or_conn) as conn:
            result = await conn.execute(
                """
                DELETE FROM public.tenant_feature_flags
                WHERE tenant_id = $1 AND flag_key = $2
                """,
                tenant_id,
                flag_key,
            )
            if isinstance(result, str) and result.startswith("DELETE "):
                try:
                    count = int(result.split(" ")[1])
                    return count > 0
                except (ValueError, IndexError):
                    pass
            return bool(result)

    @classmethod
    async def list_flags(
        cls, pool_or_conn: Any, tenant_id: str
    ) -> list[TenantFeatureFlag]:
        """List all feature flag records explicitly configured for a tenant."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")

        async with _acquire_connection(pool_or_conn) as conn:
            rows = await conn.fetch(
                """
                SELECT tenant_id, flag_key, enabled, config_json, created_at, updated_at
                FROM public.tenant_feature_flags
                WHERE tenant_id = $1
                ORDER BY flag_key
                """,
                tenant_id,
            )
            return [_parse_row(r) for r in rows]

    @classmethod
    async def evaluate_flag(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        flag_key: str,
        default: bool | None = None,
    ) -> FlagEvaluationResult:
        """Evaluate a single flag for a tenant with full origin traceability."""
        flag = await cls.get_flag_record(pool_or_conn, tenant_id, flag_key)
        if flag is not None:
            return FlagEvaluationResult(
                flag_key=flag_key,
                enabled=flag.enabled,
                config=flag.config_json,
                tenant_id=tenant_id,
                reason="tenant_override",
            )

        if default is not None:
            return FlagEvaluationResult(
                flag_key=flag_key,
                enabled=default,
                config={},
                tenant_id=tenant_id,
                reason="caller_default",
            )

        if flag_key in DEFAULT_SYSTEM_FLAGS:
            return FlagEvaluationResult(
                flag_key=flag_key,
                enabled=DEFAULT_SYSTEM_FLAGS[flag_key],
                config={},
                tenant_id=tenant_id,
                reason="system_default",
            )

        return FlagEvaluationResult(
            flag_key=flag_key,
            enabled=False,
            config={},
            tenant_id=tenant_id,
            reason="default_fallback",
        )

    @classmethod
    async def evaluate_all_flags(
        cls, pool_or_conn: Any, tenant_id: str
    ) -> dict[str, bool]:
        """Evaluate all system and tenant flags into a complete boolean dictionary."""
        flags: dict[str, bool] = dict(DEFAULT_SYSTEM_FLAGS)
        tenant_overrides = await cls.get_tenant_flags(pool_or_conn, tenant_id)
        flags.update(tenant_overrides)
        return flags

    @classmethod
    async def seed_default_flags(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        flags: dict[str, bool | tuple[bool, dict[str, Any]]] | None = None,
    ) -> list[TenantFeatureFlag]:
        """Seed default or custom flags for a tenant in test/demo environments."""
        seed_data = flags if flags is not None else DEFAULT_SYSTEM_FLAGS
        results: list[TenantFeatureFlag] = []
        for key, value in seed_data.items():
            if isinstance(value, tuple) and len(value) == 2:
                enabled, config = value
            else:
                enabled, config = bool(value), {}
            saved = await cls.set_feature_flag(
                pool_or_conn,
                tenant_id=tenant_id,
                flag_key=key,
                enabled=enabled,
                config_json=config,
            )
            results.append(saved)
        return results
