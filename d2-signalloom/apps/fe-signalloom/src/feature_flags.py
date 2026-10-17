"""Tenant-scoped feature flag repository and domain models for Signal Loom.

This module provides typed data models and asyncpg repository operations for
tenant-isolated feature flags with JSONB configuration payloads, in-memory evaluation
caching, and the server-side `require_feature` route-gating dependency.

Architecture & Invariants:
- Strict Multi-Tenant Isolation: Every query filters by `tenant_id = $1`.
- Forward-Only & Idempotent Migrations: Backed by migration 057 (tenant_feature_flags).
- Robust JSONB Support: Arbitrary config payloads parse cleanly and round-trip.
- Default Fallbacks: Graceful evaluation when flags are not explicitly configured.
- Route Gating: `require_feature` raises 404 for disabled/absent flags (no info leak).
"""
from __future__ import annotations

import json
import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated, Any

from api_compat import Principal, authenticated_principal
from fastapi import Depends, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field
from superadmin import is_superadmin

logger = logging.getLogger(__name__)

#: Default system-wide feature flags applied when no tenant override is present.
DEFAULT_SYSTEM_FLAGS: dict[str, bool] = {
    # Core system flags (retained for backward-compat)
    "core_governance": True,
    "audit": True,
    "compliance": True,
    "demos_fleet": False,
    "supercred": False,
    "rbac_analysis": False,
    "collusion_access": False,
    # Granular page flags (Operational & Governance enabled by default)
    "page_discovery": True,
    "page_agents": True,
    "page_topology": True,
    "page_weave": True,
    "page_signals": True,
    "page_risk": True,
    "page_policies": True,
    "page_compliance": True,
    "page_audit": True,
    "page_federated_services": True,
    "page_cryptography": True,
    "page_credential_inventory": True,
    # Advanced & Experimental Demos (disabled by default)
    "page_signal_store": False,
    "page_feeds": False,
    "page_network_tests": False,
    "page_agentmaxxing": False,
}

#: The EAP View flag set, captured live from tenant-demo on 2026-10-17. It is the
#: early-access read-only account type: discovery, the agent registry and the
#: policy catalogue, nothing that acts or exposes raw telemetry. Pinned literally
#: by tests/test_feature_account_types.py and by
#: d2-signalloom/contracts/feature-account-types.json.
_EAP_VIEW_FLAGS: dict[str, bool] = {
    "core_governance": True,
    "audit": True,
    "compliance": True,
    "demos_fleet": False,
    "supercred": False,
    "rbac_analysis": False,
    "collusion_access": False,
    "page_discovery": True,
    "page_agents": True,
    "page_topology": False,
    "page_weave": False,
    "page_signals": False,
    "page_risk": False,
    "page_policies": True,
    "page_compliance": False,
    "page_audit": False,
    "page_federated_services": False,
    "page_cryptography": False,
    "page_credential_inventory": False,
    "page_signal_store": False,
    "page_feeds": False,
    "page_network_tests": False,
    "page_agentmaxxing": False,
}

#: Pre-packaged feature flag sets. Entries of kind "account_type" are the account
#: types a tenant is assigned (docs/signalloom/feature-flag-account-types.md);
#: "bundle" entries are other presets a superadmin may apply.
FEATURE_PRESETS: dict[str, dict[str, Any]] = {
    "eap_view": {
        "name": "EAP View (read-only)",
        "kind": "account_type",
        "status": "confirmed",
        "aliases": [],
        "description": "Early access, read-only. Discovery, the agent registry and the policy catalogue. No signals, risk, audit or compliance pages, no demos or labs.",
        "flags": dict(_EAP_VIEW_FLAGS),
    },
    "eap_full": {
        "name": "EAP Full",
        "kind": "account_type",
        "status": "confirmed",
        "aliases": ["eap_pilot"],
        "description": "Early access, full system. Adds signals, the Weave, risk, compliance, audit, cryptography and credential inventory to EAP View; demos, labs, topology and federated services stay off.",
        "flags": {
            "core_governance": True,
            "audit": True,
            "compliance": True,
            "demos_fleet": False,
            "supercred": False,
            "rbac_analysis": False,
            "collusion_access": False,
            "page_discovery": True,
            "page_agents": True,
            "page_topology": False,
            "page_weave": True,
            "page_signals": True,
            "page_risk": True,
            "page_policies": True,
            "page_compliance": True,
            "page_audit": True,
            "page_federated_services": False,
            "page_cryptography": True,
            "page_credential_inventory": True,
            "page_signal_store": False,
            "page_feeds": False,
            "page_network_tests": False,
            "page_agentmaxxing": False,
        },
    },
    "full": {
        "name": "Full",
        "kind": "account_type",
        "status": "confirmed",
        "aliases": ["full_demo"],
        "description": "Every page, demo scenario and experimental lab enabled.",
        "flags": {key: True for key in DEFAULT_SYSTEM_FLAGS},
    },
}
# "minimal_governance" (a non-account-type "bundle" preset) was retired here.
# Any tenant with that account type recorded was remapped to "eap_view" (the
# nearest supported type by flag-set Hamming distance: 4 of 23 flags differ,
# vs 9 for eap_full and 19 for full) by migration
# 075_retire_minimal_governance_account_type.sql, which also marks the row
# customised since the tenant's actual flags are untouched and no longer equal
# eap_view's set exactly. See docs/signalloom/feature-flag-account-types.md.

#: The account types, in the order the Feature Flags page offers them.
ACCOUNT_TYPE_IDS: tuple[str, ...] = tuple(
    k for k, v in FEATURE_PRESETS.items() if v["kind"] == "account_type"
)

#: Deprecated preset ids that still apply, mapped to their canonical id.
PRESET_ALIASES: dict[str, str] = {
    alias: canonical
    for canonical, preset in FEATURE_PRESETS.items()
    for alias in preset["aliases"]
}

#: Ids a custom account type (CustomAccountTypeRepository) may never take: the
#: built-in account types, their deprecated aliases, and "minimal_governance"
#: (retired, never reassignable to avoid colliding with the migration 075
#: remap target's meaning).
RESERVED_ACCOUNT_TYPE_IDS: frozenset[str] = frozenset(
    set(FEATURE_PRESETS) | set(PRESET_ALIASES) | {"minimal_governance"}
)


def resolve_preset_id(preset_name: str) -> str | None:
    """Canonical preset id for a preset id or deprecated alias; None if unknown."""
    if preset_name in FEATURE_PRESETS:
        return preset_name
    return PRESET_ALIASES.get(preset_name)


def get_preset(preset_name: str) -> dict[str, Any] | None:
    """Retrieve preset configuration by preset id or deprecated alias."""
    canonical = resolve_preset_id(preset_name)
    return FEATURE_PRESETS[canonical] if canonical else None


def list_presets() -> list[dict[str, Any]]:
    """Return the canonical presets (aliases ride on their entry) for superadmin selection."""
    return [
        {
            "id": k,
            "name": v["name"],
            "kind": v["kind"],
            "status": v["status"],
            "aliases": list(v["aliases"]),
            "description": v["description"],
            "flags": dict(v["flags"]),
        }
        for k, v in FEATURE_PRESETS.items()
    ]


class AccountTypeState(BaseModel):
    """What the Feature Flags page says about a tenant's account type.

    ``id`` is the recorded type (None when none was ever applied). ``customised``
    is true when the tenant's effective flags no longer equal that type's set.
    ``matches`` names the preset whose set the effective flags equal exactly, if
    any, so a tenant configured by hand can still be recognised.
    """

    id: str | None = Field(default=None, description="Recorded account type (canonical preset id)")
    customised: bool = Field(default=False, description="Effective flags differ from the recorded type")
    matches: str | None = Field(default=None, description="Preset whose flags equal the effective flags")
    label: str = Field(..., description="Human-readable account type, as the page shows it")


def _matching_preset(
    effective: dict[str, bool], presets: dict[str, dict[str, Any]] | None = None
) -> str | None:
    for preset_id, preset in (presets if presets is not None else FEATURE_PRESETS).items():
        if all(effective.get(k) == v for k, v in preset["flags"].items()):
            return preset_id
    return None


def describe_account_type(
    recorded: str | None,
    effective: dict[str, bool],
    presets: dict[str, dict[str, Any]] | None = None,
) -> AccountTypeState:
    """Derive the account type state from the recorded type and the effective flags.

    ``presets`` defaults to the built-in ``FEATURE_PRESETS`` but callers with a
    database handle should pass the merged built-in + custom catalogue
    (``_merged_presets``), so a tenant recorded against a custom account type
    is described correctly rather than reported "Unassigned".
    """
    catalogue = presets if presets is not None else FEATURE_PRESETS
    matches = _matching_preset(effective, catalogue)
    preset = catalogue.get(recorded) if recorded else None
    if preset is None:
        matched_name = catalogue[matches]["name"] if matches else None
        label = f"Unassigned (flags match {matched_name})" if matched_name else "Unassigned"
        return AccountTypeState(id=None, customised=False, matches=matches, label=label)
    customised = any(effective.get(k) != v for k, v in preset["flags"].items())
    label = f"Custom, based on {preset['name']}" if customised else preset["name"]
    return AccountTypeState(id=recorded, customised=customised, matches=matches, label=label)


#: In-memory evaluation cache: (tenant_id, flag_key) -> (enabled, config, timestamp)
_FLAG_CACHE_TTL_SECONDS = 10.0
_flag_cache: dict[tuple[str, str], tuple[bool, dict[str, Any], float]] = {}


def invalidate_flag_cache(tenant_id: str | None = None, flag_key: str | None = None) -> None:
    """Invalidate in-memory flag evaluation cache."""
    global _flag_cache
    if tenant_id is None and flag_key is None:
        _flag_cache.clear()
    elif tenant_id is not None and flag_key is not None:
        _flag_cache.pop((tenant_id, flag_key), None)
    elif tenant_id is not None:
        _flag_cache = {k: v for k, v in _flag_cache.items() if k[0] != tenant_id}
    elif flag_key is not None:
        _flag_cache = {k: v for k, v in _flag_cache.items() if k[1] != flag_key}


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


class FeatureFlagDetail(BaseModel):
    """Detailed feature flag evaluation state including configuration."""
    model_config = ConfigDict(extra="allow")

    enabled: bool = Field(..., description="Flag boolean enablement state")
    config: dict[str, Any] = Field(default_factory=dict, description="JSONB configuration payload")


class FeaturesResponse(BaseModel):
    """Structured payload returned by GET /api/v1/features."""
    model_config = ConfigDict(extra="allow")

    tenant_id: str = Field(..., description="Tenant identifier")
    flags: dict[str, bool] = Field(default_factory=dict, description="Flag key to boolean mapping")
    details: dict[str, FeatureFlagDetail] = Field(default_factory=dict, description="Flag key to detail configuration mapping")


class FlagEvaluationResult(BaseModel):
    """Result of evaluating a feature flag for a tenant."""
    model_config = ConfigDict(from_attributes=True)

    flag_key: str = Field(..., description="Evaluated flag key")
    enabled: bool = Field(..., description="Evaluated flag state")
    config: dict[str, Any] = Field(default_factory=dict, description="Associated configuration payload")
    tenant_id: str | None = Field(default=None, description="Evaluated tenant identifier")
    reason: str = Field(default="default", description="Evaluation decision reason")


async def _resolve_db_pool(pool: Any = None, request: Request | None = None) -> Any:
    """Resolve database pool from explicit argument, db.connection, request state, or api_compat."""
    if pool is not None and (hasattr(pool, "fetch") or hasattr(pool, "acquire")):
        return pool

    try:
        from db.connection import get_pool
        p = get_pool()
        if p is not None and (hasattr(p, "fetch") or hasattr(p, "acquire")):
            return p
    except (RuntimeError, ImportError, AttributeError):
        pass

    if request is not None:
        p = getattr(request.app.state, "pool", None)
        if p is not None and (hasattr(p, "fetch") or hasattr(p, "acquire")):
            return p

    try:
        import api_compat
        p = await api_compat._get_pool()
        if p is not None and (hasattr(p, "fetch") or hasattr(p, "acquire")):
            return p
    except (ImportError, AttributeError, Exception):
        pass

    return None


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
            invalidate_flag_cache(tenant_id, flag_key)
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
            invalidate_flag_cache(tenant_id, flag_key)
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

    @classmethod
    async def update_tenant_flags(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        flags: dict[str, bool | tuple[bool, dict[str, Any]]],
    ) -> dict[str, bool]:
        """Batch update or insert multiple feature flags for a tenant."""
        if not tenant_id or not isinstance(tenant_id, str):
            raise ValueError("tenant_id must be a non-empty string")
        if not isinstance(flags, dict):
            raise ValueError("flags must be a dictionary")

        results: dict[str, bool] = {}
        for flag_key, val in flags.items():
            if isinstance(val, tuple) and len(val) == 2:
                enabled, config = bool(val[0]), val[1]
            else:
                enabled, config = bool(val), {}
            saved = await cls.set_feature_flag(
                pool_or_conn,
                tenant_id=tenant_id,
                flag_key=flag_key,
                enabled=enabled,
                config_json=config,
            )
            results[flag_key] = saved.enabled

        invalidate_flag_cache(tenant_id)
        return results

    @classmethod
    async def apply_preset(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        preset_name: str,
        updated_by: str | None = None,
    ) -> dict[str, bool]:
        """Apply a preset -- built-in, deprecated alias, or custom -- and record
        it as the tenant's account type."""
        canonical = resolve_preset_id(preset_name)
        if canonical is not None:
            flags = FEATURE_PRESETS[canonical]["flags"]
        else:
            custom = await CustomAccountTypeRepository.get(pool_or_conn, preset_name)
            if custom is None:
                raise ValueError(f"Unknown preset: {preset_name}")
            canonical = custom["id"]
            flags = custom["flags"]
        applied = await cls.update_tenant_flags(pool_or_conn, tenant_id, flags)
        await AccountTypeRepository.record(pool_or_conn, tenant_id, canonical, False, updated_by)
        return applied


class AccountTypeRepository:
    """Per-tenant account type record (migration 074, public.tenant_account_types)."""

    @classmethod
    async def get(cls, pool_or_conn: Any, tenant_id: str) -> dict[str, Any] | None:
        """The tenant's recorded account type row, or None if none was ever applied."""
        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                SELECT tenant_id, account_type, customised, updated_by, updated_at
                FROM public.tenant_account_types
                WHERE tenant_id = $1
                """,
                tenant_id,
            )
            return dict(row) if row is not None else None

    @classmethod
    async def record(
        cls,
        pool_or_conn: Any,
        tenant_id: str,
        account_type: str,
        customised: bool,
        updated_by: str | None,
    ) -> dict[str, Any]:
        """Upsert the tenant's account type row."""
        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                INSERT INTO public.tenant_account_types (
                    tenant_id, account_type, customised, updated_by, updated_at
                )
                VALUES ($1, $2, $3, $4, NOW())
                ON CONFLICT (tenant_id) DO UPDATE
                    SET account_type = EXCLUDED.account_type,
                        customised = EXCLUDED.customised,
                        updated_by = EXCLUDED.updated_by,
                        updated_at = NOW()
                RETURNING tenant_id, account_type, customised, updated_by, updated_at
                """,
                tenant_id,
                account_type,
                bool(customised),
                updated_by,
            )
            return dict(row)

    @classmethod
    async def refresh(
        cls, pool_or_conn: Any, tenant_id: str, updated_by: str | None
    ) -> AccountTypeState:
        """Re-derive the tenant's state after a flag change and persist ``customised``."""
        record = await cls.get(pool_or_conn, tenant_id)
        effective = await FeatureFlagRepository.evaluate_all_flags(pool_or_conn, tenant_id)
        presets = await _merged_presets(pool_or_conn)
        state = describe_account_type(record["account_type"] if record else None, effective, presets)
        if record is not None and bool(record["customised"]) != state.customised:
            await cls.record(pool_or_conn, tenant_id, record["account_type"], state.customised, updated_by)
        return state


def _parse_custom_account_type_row(row: Any) -> dict[str, Any]:
    """Parse a ``public.custom_account_types`` row into a plain dict with
    boolean flags (``flags`` is stored as JSONB and may come back as a str)."""
    parsed = dict(row)
    flags = parsed.get("flags")
    if isinstance(flags, str):
        try:
            flags = json.loads(flags)
        except (json.JSONDecodeError, TypeError, ValueError):
            flags = {}
    parsed["flags"] = {k: bool(v) for k, v in (flags or {}).items()}
    return parsed


class CustomAccountTypeRepository:
    """Superadmin-defined account types (migration 076, public.custom_account_types).

    A custom account type is a named, explicit flag set a superadmin can
    create, rename and delete (api/admin_account_types.py). It is persisted
    and tenant-assignable exactly like a built-in account type --
    ``FeatureFlagRepository.apply_preset`` accepts its id -- and is listed
    alongside the built-ins by ``list_all_presets``. Built-in ids
    (``RESERVED_ACCOUNT_TYPE_IDS``) can never be used for one, and a custom
    type's flags must set exactly the registered flag keys, same as a
    built-in's.
    """

    @classmethod
    async def list(cls, pool_or_conn: Any) -> list[dict[str, Any]]:
        """Every custom account type, ordered by id for deterministic output."""
        async with _acquire_connection(pool_or_conn) as conn:
            rows = await conn.fetch(
                """
                SELECT id, name, flags, created_by, created_at, updated_by, updated_at
                FROM public.custom_account_types
                ORDER BY id
                """
            )
            return [_parse_custom_account_type_row(r) for r in rows]

    @classmethod
    async def get(cls, pool_or_conn: Any, type_id: str) -> dict[str, Any] | None:
        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                SELECT id, name, flags, created_by, created_at, updated_by, updated_at
                FROM public.custom_account_types
                WHERE id = $1
                """,
                type_id,
            )
            return _parse_custom_account_type_row(row) if row is not None else None

    @classmethod
    async def create(
        cls,
        pool_or_conn: Any,
        type_id: str,
        name: str,
        flags: dict[str, bool],
        created_by: str | None,
    ) -> dict[str, Any]:
        """Create a custom account type. Raises ``ValueError`` on any invariant
        violation (reserved id, incomplete flag set, duplicate id) rather than
        leaving the caller to translate a database error into an API response."""
        if not type_id or not isinstance(type_id, str):
            raise ValueError("id must be a non-empty string")
        if type_id in RESERVED_ACCOUNT_TYPE_IDS:
            raise ValueError(f"'{type_id}' is a built-in account type id and cannot be reused")
        if not name or not isinstance(name, str):
            raise ValueError("name must be a non-empty string")
        if set(flags) != set(DEFAULT_SYSTEM_FLAGS):
            missing = set(DEFAULT_SYSTEM_FLAGS) - set(flags)
            extra = set(flags) - set(DEFAULT_SYSTEM_FLAGS)
            raise ValueError(
                f"flags must set exactly the {len(DEFAULT_SYSTEM_FLAGS)} registered flag keys"
                f" (missing={sorted(missing)}, unknown={sorted(extra)})"
            )
        if await cls.get(pool_or_conn, type_id) is not None:
            raise ValueError(f"custom account type '{type_id}' already exists")

        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                INSERT INTO public.custom_account_types (
                    id, name, flags, created_by, updated_by, updated_at
                )
                VALUES ($1, $2, $3::jsonb, $4, $4, NOW())
                RETURNING id, name, flags, created_by, created_at, updated_by, updated_at
                """,
                type_id,
                name,
                json.dumps({k: bool(v) for k, v in flags.items()}),
                created_by,
            )
            return _parse_custom_account_type_row(row)

    @classmethod
    async def rename(
        cls, pool_or_conn: Any, type_id: str, name: str, updated_by: str | None
    ) -> dict[str, Any] | None:
        """Rename a custom account type. Returns ``None`` if ``type_id`` is not
        a known custom type (the caller decides 403 vs 404)."""
        if not name or not isinstance(name, str):
            raise ValueError("name must be a non-empty string")
        async with _acquire_connection(pool_or_conn) as conn:
            row = await conn.fetchrow(
                """
                UPDATE public.custom_account_types
                SET name = $2, updated_by = $3, updated_at = NOW()
                WHERE id = $1
                RETURNING id, name, flags, created_by, created_at, updated_by, updated_at
                """,
                type_id,
                name,
                updated_by,
            )
            return _parse_custom_account_type_row(row) if row is not None else None

    @classmethod
    async def delete(cls, pool_or_conn: Any, type_id: str) -> bool:
        """Delete a custom account type. Returns True if a row was removed."""
        async with _acquire_connection(pool_or_conn) as conn:
            result = await conn.execute(
                "DELETE FROM public.custom_account_types WHERE id = $1",
                type_id,
            )
            if isinstance(result, str) and result.startswith("DELETE "):
                try:
                    return int(result.split(" ")[1]) > 0
                except (ValueError, IndexError):
                    return False
            return bool(result)


async def _merged_presets(pool_or_conn: Any) -> dict[str, dict[str, Any]]:
    """Built-in presets plus every persisted custom account type, keyed by id.

    The single place that assembles "every account type this tenant could be
    recorded against" for ``describe_account_type``/``list_all_presets``, so a
    tenant recorded against a custom type is never mis-reported "Unassigned".
    """
    merged: dict[str, dict[str, Any]] = dict(FEATURE_PRESETS)
    for row in await CustomAccountTypeRepository.list(pool_or_conn):
        merged[row["id"]] = {
            "name": row["name"],
            "kind": "custom",
            "status": "confirmed",
            "aliases": [],
            "description": f"Custom account type, defined by {row['created_by'] or 'a superadmin'}.",
            "flags": dict(row["flags"]),
        }
    return merged


async def list_all_presets(pool_or_conn: Any) -> list[dict[str, Any]]:
    """Built-in presets plus persisted custom account types, in the shape
    ``list_presets`` returns, for GET /api/v1/admin/features/presets."""
    merged = await _merged_presets(pool_or_conn)
    return [
        {
            "id": k,
            "name": v["name"],
            "kind": v["kind"],
            "status": v["status"],
            "aliases": list(v["aliases"]),
            "description": v["description"],
            "flags": dict(v["flags"]),
        }
        for k, v in merged.items()
    ]


async def is_feature_enabled(
    pool_or_conn: Any,
    tenant_id: str,
    flag_key: str,
    use_cache: bool = True,
) -> bool:
    """Evaluate whether a feature flag is enabled for a tenant, using caching when available."""
    if not tenant_id or not flag_key:
        return False

    if use_cache:
        now = time.time()
        cached = _flag_cache.get((tenant_id, flag_key))
        if cached is not None:
            enabled, _, cached_at = cached
            if now - cached_at < _FLAG_CACHE_TTL_SECONDS:
                return enabled

    eval_result = await FeatureFlagRepository.evaluate_flag(pool_or_conn, tenant_id, flag_key)
    _flag_cache[(tenant_id, flag_key)] = (eval_result.enabled, eval_result.config, time.time())
    return eval_result.enabled


def require_feature(
    flag_key: str,
    *,
    allow_superadmin_override: bool = True,
) -> Any:
    """FastAPI dependency callable factory enforcing that a feature flag is enabled for the request tenant.

    Checks if `flag_key` is enabled for the request tenant.
    Raises HTTPException(status_code=404, detail="Feature not found or disabled") when the flag is absent or disabled.
    Supports optional superadmin override query parameter `superadmin_override=true` when principal is superadmin.
    """
    async def _feature_gate(
        request: Request,
        principal: Annotated[Principal, Depends(authenticated_principal)],
        superadmin_override: bool = Query(
            default=False,
            description="Optional superadmin override to bypass feature flag gating",
        ),
    ) -> bool:
        if allow_superadmin_override and superadmin_override and is_superadmin(principal):
            return True

        pool = await _resolve_db_pool(request=request)
        enabled = await is_feature_enabled(pool, principal.tenant, flag_key)
        if not enabled:
            raise HTTPException(
                status_code=404,
                detail="Feature not found or disabled",
            )
        return True

    return _feature_gate
