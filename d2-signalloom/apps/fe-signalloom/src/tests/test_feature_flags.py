"""Tests for Tenant Feature Flag repository, domain models, and multi-tenant isolation.

Validates CRUD operations, JSONB serialization, default fallback resolution,
strict multi-tenant isolation, and seed helpers.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

import pytest
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    FeatureFlagConfig,
    FeatureFlagRepository,
    FlagEvaluationResult,
    TenantFeatureFlag,
)
from pydantic import BaseModel


class MockDatabase:
    """In-memory simulated PostgreSQL table for tenant_feature_flags."""

    def __init__(self) -> None:
        # Key: (tenant_id, flag_key) -> dict
        self.rows: dict[tuple[str, str], dict[str, Any]] = {}
        # tenant_account_types (migration 074): tenant_id -> row
        self.account_types: dict[str, dict[str, Any]] = {}
        # custom_account_types (migration 076): id -> row
        self.custom_account_types: dict[str, dict[str, Any]] = {}
        # audit_events inserts, as the positional args the handler passed
        self.audit: list[tuple[Any, ...]] = []

    def insert_or_update(
        self, tenant_id: str, flag_key: str, enabled: bool, config_json_str: str
    ) -> dict[str, Any]:
        now = datetime.now(timezone.utc)
        key = (tenant_id, flag_key)
        created_at = self.rows[key]["created_at"] if key in self.rows else now
        parsed_config = json.loads(config_json_str) if isinstance(config_json_str, str) else config_json_str
        row = {
            "tenant_id": tenant_id,
            "flag_key": flag_key,
            "enabled": enabled,
            "config_json": parsed_config,
            "created_at": created_at,
            "updated_at": now,
        }
        self.rows[key] = row
        return dict(row)

    def select_one(self, tenant_id: str, flag_key: str) -> dict[str, Any] | None:
        key = (tenant_id, flag_key)
        if key in self.rows:
            return dict(self.rows[key])
        return None

    def select_all_for_tenant(self, tenant_id: str) -> list[dict[str, Any]]:
        results = [
            dict(row) for (t_id, _), row in self.rows.items() if t_id == tenant_id
        ]
        return sorted(results, key=lambda r: r["flag_key"])

    def delete(self, tenant_id: str, flag_key: str) -> bool:
        key = (tenant_id, flag_key)
        if key in self.rows:
            del self.rows[key]
            return True
        return False


class FakeConnection:
    """Fake asyncpg connection routing queries to MockDatabase."""

    def __init__(self, db: MockDatabase) -> None:
        self.db = db

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        if "WHERE tenant_id = $1" in query and "ORDER BY flag_key" in query:
            tenant_id = args[0]
            return self.db.select_all_for_tenant(tenant_id)
        if "FROM public.custom_account_types" in query and "ORDER BY id" in query:
            return [dict(self.db.custom_account_types[k]) for k in sorted(self.db.custom_account_types)]
        raise NotImplementedError(f"Unhandled fetch query: {query}")

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        if "INSERT INTO public.tenant_account_types" in query:
            tenant_id, account_type, customised, updated_by = args[0], args[1], args[2], args[3]
            row = {
                "tenant_id": tenant_id,
                "account_type": account_type,
                "customised": bool(customised),
                "updated_by": updated_by,
                "updated_at": datetime.now(timezone.utc),
            }
            self.db.account_types[tenant_id] = row
            return dict(row)
        if "FROM public.tenant_account_types" in query:
            row = self.db.account_types.get(args[0])
            return dict(row) if row is not None else None
        if "INSERT INTO public.custom_account_types" in query:
            type_id, name, flags_json, created_by = args[0], args[1], args[2], args[3]
            now = datetime.now(timezone.utc)
            flags = json.loads(flags_json) if isinstance(flags_json, str) else flags_json
            row = {
                "id": type_id,
                "name": name,
                "flags": flags,
                "created_by": created_by,
                "created_at": now,
                "updated_by": created_by,
                "updated_at": now,
            }
            self.db.custom_account_types[type_id] = row
            return dict(row)
        if "UPDATE public.custom_account_types" in query:
            type_id, name, updated_by = args[0], args[1], args[2]
            existing = self.db.custom_account_types.get(type_id)
            if existing is None:
                return None
            existing = dict(existing)
            existing["name"] = name
            existing["updated_by"] = updated_by
            existing["updated_at"] = datetime.now(timezone.utc)
            self.db.custom_account_types[type_id] = existing
            return dict(existing)
        if "FROM public.custom_account_types" in query:
            row = self.db.custom_account_types.get(args[0])
            return dict(row) if row is not None else None
        if "INSERT INTO public.tenant_feature_flags" in query:
            tenant_id, flag_key, enabled, config_json_str = args[0], args[1], args[2], args[3]
            return self.db.insert_or_update(tenant_id, flag_key, enabled, config_json_str)
        if "SELECT tenant_id, flag_key, enabled, config_json" in query:
            tenant_id, flag_key = args[0], args[1]
            return self.db.select_one(tenant_id, flag_key)
        raise NotImplementedError(f"Unhandled fetchrow query: {query}")

    async def execute(self, query: str, *args: Any) -> str:
        if "DELETE FROM public.tenant_feature_flags" in query:
            tenant_id, flag_key = args[0], args[1]
            deleted = self.db.delete(tenant_id, flag_key)
            return "DELETE 1" if deleted else "DELETE 0"
        if "DELETE FROM public.custom_account_types" in query:
            type_id = args[0]
            existed = type_id in self.db.custom_account_types
            self.db.custom_account_types.pop(type_id, None)
            return "DELETE 1" if existed else "DELETE 0"
        if "audit_events" in query:
            self.db.audit.append(args)
            return "INSERT 0 1"
        if "INSERT INTO" in query:
            return "INSERT 0 1"
        raise NotImplementedError(f"Unhandled execute query: {query}")


class FakePool:
    """Fake asyncpg Pool managing FakeConnection instances."""

    def __init__(self, db: MockDatabase | None = None) -> None:
        self.db = db or MockDatabase()

    def acquire(self) -> _FakePoolContext:
        return _FakePoolContext(FakeConnection(self.db))

    async def execute(self, query: str, *args: Any) -> str:
        async with self.acquire() as conn:
            return await conn.execute(query, *args)

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        async with self.acquire() as conn:
            return await conn.fetch(query, *args)

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        async with self.acquire() as conn:
            return await conn.fetchrow(query, *args)


class _FakePoolContext:
    def __init__(self, conn: FakeConnection) -> None:
        self.conn = conn

    async def __aenter__(self) -> FakeConnection:
        return self.conn

    async def __aexit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        pass


@pytest.fixture
def fake_pool() -> FakePool:
    return FakePool()


# ===========================================================================
# 1. Model & Schema Validation Tests
# ===========================================================================

def test_tenant_feature_flag_model_instantiation() -> None:
    flag = TenantFeatureFlag(
        tenant_id="tenant-alpha",
        flag_key="demos_fleet",
        enabled=True,
        config_json={"max_vms": 5, "nested": {"tier": "gold"}},
    )
    assert flag.tenant_id == "tenant-alpha"
    assert flag.flag_key == "demos_fleet"
    assert flag.enabled is True
    assert flag.config_json["max_vms"] == 5
    assert flag.config_json["nested"]["tier"] == "gold"


def test_feature_flag_config_extra_fields() -> None:
    config = FeatureFlagConfig(description="Fleet gating", max_concurrency=10, canary=True)
    dumped = config.model_dump()
    assert dumped["description"] == "Fleet gating"
    assert dumped["max_concurrency"] == 10
    assert dumped["canary"] is True


def test_flag_evaluation_result_model() -> None:
    res = FlagEvaluationResult(
        flag_key="supercred",
        enabled=False,
        config={"fallback": True},
        tenant_id="tenant-beta",
        reason="system_default",
    )
    assert res.flag_key == "supercred"
    assert res.enabled is False
    assert res.reason == "system_default"
    assert res.tenant_id == "tenant-beta"


# ===========================================================================
# 2. Repository CRUD Operations
# ===========================================================================

@pytest.mark.asyncio
async def test_set_and_get_feature_flag(fake_pool: FakePool) -> None:
    saved = await FeatureFlagRepository.set_feature_flag(
        fake_pool,
        tenant_id="tenant-1",
        flag_key="supercred",
        enabled=True,
        config_json={"env": "staging"},
    )
    assert saved.tenant_id == "tenant-1"
    assert saved.flag_key == "supercred"
    assert saved.enabled is True
    assert saved.config_json == {"env": "staging"}
    assert saved.created_at is not None

    fetched = await FeatureFlagRepository.get_feature_flag(
        fake_pool, tenant_id="tenant-1", flag_key="supercred"
    )
    assert fetched.tenant_id == "tenant-1"
    assert fetched.flag_key == "supercred"
    assert fetched.enabled is True
    assert fetched.config_json == {"env": "staging"}


@pytest.mark.asyncio
async def test_set_feature_flag_update_existing(fake_pool: FakePool) -> None:
    # First set
    await FeatureFlagRepository.set_feature_flag(
        fake_pool,
        tenant_id="tenant-1",
        flag_key="demos_fleet",
        enabled=False,
        config_json={"version": 1},
    )

    # Update (ON CONFLICT DO UPDATE)
    updated = await FeatureFlagRepository.set_feature_flag(
        fake_pool,
        tenant_id="tenant-1",
        flag_key="demos_fleet",
        enabled=True,
        config_json={"version": 2, "active": True},
    )

    assert updated.enabled is True
    assert updated.config_json == {"version": 2, "active": True}

    record = await FeatureFlagRepository.get_flag_record(
        fake_pool, tenant_id="tenant-1", flag_key="demos_fleet"
    )
    assert record is not None
    assert record.enabled is True
    assert record.config_json["version"] == 2


@pytest.mark.asyncio
async def test_get_tenant_flags_dict(fake_pool: FakePool) -> None:
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "flag_a", True
    )
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "flag_b", False
    )

    flags = await FeatureFlagRepository.get_tenant_flags(fake_pool, "tenant-1")
    assert flags == {"flag_a": True, "flag_b": False}


@pytest.mark.asyncio
async def test_get_tenant_flag_configs(fake_pool: FakePool) -> None:
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "flag_a", True, config_json={"limit": 50}
    )
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "flag_b", False, config_json={"reason": "maintenance"}
    )

    configs = await FeatureFlagRepository.get_tenant_flag_configs(fake_pool, "tenant-1")
    assert configs == {
        "flag_a": {"enabled": True, "config": {"limit": 50}},
        "flag_b": {"enabled": False, "config": {"reason": "maintenance"}},
    }


@pytest.mark.asyncio
async def test_list_flags(fake_pool: FakePool) -> None:
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "flag_z", True
    )
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "flag_a", False
    )

    flags = await FeatureFlagRepository.list_flags(fake_pool, "tenant-1")
    assert len(flags) == 2
    assert [f.flag_key for f in flags] == ["flag_a", "flag_z"]


@pytest.mark.asyncio
async def test_delete_feature_flag(fake_pool: FakePool) -> None:
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "temp_flag", True
    )

    # Delete existing
    deleted = await FeatureFlagRepository.delete_feature_flag(
        fake_pool, "tenant-1", "temp_flag"
    )
    assert deleted is True

    # Confirm record gone
    record = await FeatureFlagRepository.get_flag_record(
        fake_pool, "tenant-1", "temp_flag"
    )
    assert record is None

    # Delete non-existing returns False
    deleted_again = await FeatureFlagRepository.delete_feature_flag(
        fake_pool, "tenant-1", "temp_flag"
    )
    assert deleted_again is False


# ===========================================================================
# 3. Default Fallbacks & System Defaults
# ===========================================================================

@pytest.mark.asyncio
async def test_get_feature_flag_fallback_defaults(fake_pool: FakePool) -> None:
    # Known system default flag
    flag = await FeatureFlagRepository.get_feature_flag(
        fake_pool, "tenant-empty", "core_governance"
    )
    assert flag.enabled is True  # DEFAULT_SYSTEM_FLAGS['core_governance'] == True

    flag_fleet = await FeatureFlagRepository.get_feature_flag(
        fake_pool, "tenant-empty", "demos_fleet"
    )
    assert flag_fleet.enabled is False  # DEFAULT_SYSTEM_FLAGS['demos_fleet'] == False

    # Unknown flag falls back to default argument (False)
    unknown_flag = await FeatureFlagRepository.get_feature_flag(
        fake_pool, "tenant-empty", "nonexistent_flag"
    )
    assert unknown_flag.enabled is False

    # Explicit default override
    custom_fallback = await FeatureFlagRepository.get_feature_flag(
        fake_pool, "tenant-empty", "nonexistent_flag", default=True
    )
    assert custom_fallback.enabled is True


@pytest.mark.asyncio
async def test_evaluate_flag_origin_reasons(fake_pool: FakePool) -> None:
    # 1. System default
    eval_system = await FeatureFlagRepository.evaluate_flag(
        fake_pool, "tenant-1", "compliance"
    )
    assert eval_system.enabled is True
    assert eval_system.reason == "system_default"

    # 2. Tenant override in DB
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "compliance", False
    )
    eval_override = await FeatureFlagRepository.evaluate_flag(
        fake_pool, "tenant-1", "compliance"
    )
    assert eval_override.enabled is False
    assert eval_override.reason == "tenant_override"

    # 3. Caller default for unconfigured custom flag
    eval_caller = await FeatureFlagRepository.evaluate_flag(
        fake_pool, "tenant-1", "custom_beta_feature", default=True
    )
    assert eval_caller.enabled is True
    assert eval_caller.reason == "caller_default"

    # 4. Unknown flag fallback
    eval_unknown = await FeatureFlagRepository.evaluate_flag(
        fake_pool, "tenant-1", "unknown_xyz"
    )
    assert eval_unknown.enabled is False
    assert eval_unknown.reason == "default_fallback"


@pytest.mark.asyncio
async def test_evaluate_all_flags_merging(fake_pool: FakePool) -> None:
    # Override one system flag and add one custom flag
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "demos_fleet", True
    )
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, "tenant-1", "custom_feature", True
    )

    all_flags = await FeatureFlagRepository.evaluate_all_flags(fake_pool, "tenant-1")

    # Inherited system defaults
    assert all_flags["core_governance"] is True
    assert all_flags["audit"] is True
    assert all_flags["supercred"] is False

    # Tenant overrides
    assert all_flags["demos_fleet"] is True
    assert all_flags["custom_feature"] is True


# ===========================================================================
# 4. JSONB Parsing & Complex Config Payloads
# ===========================================================================

@pytest.mark.asyncio
async def test_jsonb_parsing(fake_pool: FakePool) -> None:
    complex_config = {
        "allowed_clusters": ["eks-prod", "gke-stage"],
        "rate_limits": {"rps": 100, "burst": 250},
        "score_threshold": 0.85,
        "active": True,
        "metadata": {"author": "secops", "tags": ["pilot", "kusari"]},
    }

    saved = await FeatureFlagRepository.set_feature_flag(
        fake_pool,
        tenant_id="tenant-json",
        flag_key="complex_gate",
        enabled=True,
        config_json=complex_config,
    )
    assert saved.config_json == complex_config

    fetched = await FeatureFlagRepository.get_feature_flag(
        fake_pool, "tenant-json", "complex_gate"
    )
    assert fetched.config_json == complex_config
    assert fetched.config_json["allowed_clusters"] == ["eks-prod", "gke-stage"]
    assert fetched.config_json["rate_limits"]["rps"] == 100


@pytest.mark.asyncio
async def test_jsonb_parsing_pydantic_model_and_raw_string(fake_pool: FakePool) -> None:
    class CustomPayload(BaseModel):
        max_agents: int
        label: str

    # Pass Pydantic model
    saved_model = await FeatureFlagRepository.set_feature_flag(
        fake_pool,
        "tenant-json",
        "model_gate",
        True,
        config_json=CustomPayload(max_agents=42, label="governed"),
    )
    assert saved_model.config_json == {"max_agents": 42, "label": "governed"}

    # Pass raw JSON string
    saved_str = await FeatureFlagRepository.set_feature_flag(
        fake_pool,
        "tenant-json",
        "string_gate",
        False,
        config_json='{"retries": 3, "timeout_seconds": 15}',
    )
    assert saved_str.config_json == {"retries": 3, "timeout_seconds": 15}


# ===========================================================================
# 5. Multi-Tenant Isolation
# ===========================================================================

@pytest.mark.asyncio
async def test_multi_tenant_isolation(fake_pool: FakePool) -> None:
    tenant_a = "tenant-kusari"
    tenant_b = "tenant-other"

    # Set differing flag states for same flag key across tenants
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, tenant_a, "demos_fleet", True, config_json={"profile": "kusari"}
    )
    await FeatureFlagRepository.set_feature_flag(
        fake_pool, tenant_b, "demos_fleet", False, config_json={"profile": "standard"}
    )

    # Tenant A evaluation
    flag_a = await FeatureFlagRepository.get_feature_flag(
        fake_pool, tenant_a, "demos_fleet"
    )
    assert flag_a.enabled is True
    assert flag_a.config_json["profile"] == "kusari"

    # Tenant B evaluation
    flag_b = await FeatureFlagRepository.get_feature_flag(
        fake_pool, tenant_b, "demos_fleet"
    )
    assert flag_b.enabled is False
    assert flag_b.config_json["profile"] == "standard"

    # Delete for Tenant A does NOT delete Tenant B
    await FeatureFlagRepository.delete_feature_flag(fake_pool, tenant_a, "demos_fleet")

    # Tenant A reverts to default (False for demos_fleet)
    flag_a_after = await FeatureFlagRepository.get_feature_flag(
        fake_pool, tenant_a, "demos_fleet"
    )
    assert flag_a_after.enabled is False
    assert flag_a_after.config_json == {}

    # Tenant B remains intact with its explicit record
    flag_b_after = await FeatureFlagRepository.get_feature_flag(
        fake_pool, tenant_b, "demos_fleet"
    )
    assert flag_b_after.enabled is False
    assert flag_b_after.config_json["profile"] == "standard"


# ===========================================================================
# 6. Database Seed Helper
# ===========================================================================

@pytest.mark.asyncio
async def test_seed_default_flags(fake_pool: FakePool) -> None:
    seeded = await FeatureFlagRepository.seed_default_flags(fake_pool, "tenant-fresh")
    assert len(seeded) == len(DEFAULT_SYSTEM_FLAGS)

    stored = await FeatureFlagRepository.get_tenant_flags(fake_pool, "tenant-fresh")
    assert stored == DEFAULT_SYSTEM_FLAGS


@pytest.mark.asyncio
async def test_seed_custom_flags(fake_pool: FakePool) -> None:
    custom_seeds = {
        "core_governance": True,
        "demos_fleet": (True, {"cluster": "local"}),
        "supercred": False,
    }
    seeded = await FeatureFlagRepository.seed_default_flags(
        fake_pool, "tenant-custom", flags=custom_seeds
    )
    assert len(seeded) == 3

    record = await FeatureFlagRepository.get_feature_flag(
        fake_pool, "tenant-custom", "demos_fleet"
    )
    assert record.enabled is True
    assert record.config_json == {"cluster": "local"}


# ===========================================================================
# 7. Error Handling & Validation
# ===========================================================================

@pytest.mark.asyncio
async def test_invalid_arguments_raise(fake_pool: FakePool) -> None:
    with pytest.raises(ValueError, match="tenant_id must be a non-empty string"):
        await FeatureFlagRepository.get_tenant_flags(fake_pool, "")

    with pytest.raises(ValueError, match="flag_key must be a non-empty string"):
        await FeatureFlagRepository.get_feature_flag(fake_pool, "tenant-1", "")

    with pytest.raises(ValueError, match="tenant_id must be a non-empty string"):
        await FeatureFlagRepository.set_feature_flag(fake_pool, "", "flag_key", True)

    with pytest.raises(ValueError, match="flag_key must be a non-empty string"):
        await FeatureFlagRepository.delete_feature_flag(fake_pool, "tenant-1", "")


# ===========================================================================
# 8. Design Partner Presets (Kusari Pilot Profile)
# ===========================================================================

@pytest.mark.asyncio
async def test_kusari_design_partner_presets_evaluation(fake_pool: FakePool) -> None:
    """Verify Kusari design partner tenant retrieves expected preset flags."""
    kusari_presets = {
        "core_governance": True,
        "audit": True,
        "compliance": True,
        "demos_fleet": False,
        "supercred": False,
        "rbac_analysis": False,
        "collusion_access": False,
    }

    # Seed Kusari presets into fake database
    for flag_key, enabled in kusari_presets.items():
        await FeatureFlagRepository.set_feature_flag(
            fake_pool,
            tenant_id="kusari",
            flag_key=flag_key,
            enabled=enabled,
            config_json={"preset": "kusari_pilot"},
        )

    # 1. Verify Kusari tenant retrieves all expected flags
    flags = await FeatureFlagRepository.get_tenant_flags(fake_pool, "kusari")
    for key, expected_val in kusari_presets.items():
        assert flags.get(key) is expected_val, f"Kusari flag {key} mismatch"

    # 2. Verify individual evaluations return tenant_override reason
    for key, expected_val in kusari_presets.items():
        eval_res = await FeatureFlagRepository.evaluate_flag(fake_pool, "kusari", key)
        assert eval_res.enabled is expected_val
        assert eval_res.reason == "tenant_override"

    # 3. Verify unseeded/default tenant falls back to system defaults
    unseeded_eval = await FeatureFlagRepository.evaluate_flag(fake_pool, "unseeded-tenant", "core_governance")
    assert unseeded_eval.enabled is True
    assert unseeded_eval.reason == "system_default"

    unseeded_demos = await FeatureFlagRepository.evaluate_flag(fake_pool, "unseeded-tenant", "demos_fleet")
    assert unseeded_demos.enabled is False
    assert unseeded_demos.reason == "system_default"

