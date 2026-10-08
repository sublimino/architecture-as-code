"""Unit and contract tests for design partner presets and initial superadmin seeding.

Verifies:
1. Migration 060 (060_seed_design_partner_presets.sql) is discoverable and forward-only.
2. Flag presets for Kusari tenant ('kusari') configure:
   - Enabled (True): core_governance, audit, compliance
   - Disabled (False): demos_fleet, supercred, rbac_analysis, collusion_access
3. Initial platform superadmin user is seeded with:
   - email: demo-user@signalloom.local
   - role: admin
   - status: active
   - is_superadmin: True
4. All seed operations are strictly idempotent via ON CONFLICT DO UPDATE clauses.
5. FeatureFlagRepository and Principal correctly evaluate seeded presets.
"""
from __future__ import annotations

import os
import re
import uuid
from typing import Any

import pytest

from api_compat import Principal
from db.migrate import MIGRATIONS_DIR, discover_migrations
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    FeatureFlagRepository,
    TenantFeatureFlag,
)

KUSARI_TENANT = "kusari"
SUPERADMIN_EMAIL = "demo-user@signalloom.local"

EXPECTED_KUSARI_FLAGS: dict[str, bool] = {
    "core_governance": True,
    "audit": True,
    "compliance": True,
    "demos_fleet": False,
    "supercred": False,
    "rbac_analysis": False,
    "collusion_access": False,
}


def test_migration_060_discovered_and_ordered() -> None:
    """Migration 060 must be discoverable and ordered after 059."""
    migrations = discover_migrations(MIGRATIONS_DIR)
    filenames = [m.filename for m in migrations]

    assert "060_seed_design_partner_presets.sql" in filenames
    idx_059 = filenames.index("059_user_admin_audit_event_types.sql")
    idx_060 = filenames.index("060_seed_design_partner_presets.sql")
    assert idx_060 == idx_059 + 1


def test_migration_060_sql_content_and_idempotency_structure() -> None:
    """Migration 060 must contain transaction boundaries and ON CONFLICT handling."""
    migration = next(
        m for m in discover_migrations(MIGRATIONS_DIR)
        if m.filename == "060_seed_design_partner_presets.sql"
    )
    sql = migration.read_sql()

    assert "BEGIN;" in sql
    assert "COMMIT;" in sql
    assert "INSERT INTO public.tenant_feature_flags" in sql
    assert "ON CONFLICT (tenant_id, flag_key) DO UPDATE" in sql
    assert "INSERT INTO public.platform_users" in sql
    assert "ON CONFLICT (tenant_id, email) DO UPDATE" in sql
    assert "is_superadmin" in sql


def test_kusari_preset_flags_coverage_and_values() -> None:
    """Verify all expected Kusari flags and boolean values are present in SQL."""
    migration = next(
        m for m in discover_migrations(MIGRATIONS_DIR)
        if m.filename == "060_seed_design_partner_presets.sql"
    )
    sql = migration.read_sql()

    for flag_key, enabled in EXPECTED_KUSARI_FLAGS.items():
        enabled_str = "TRUE" if enabled else "FALSE"
        # Match ('kusari', '<flag_key>', <TRUE|FALSE>
        pattern = rf"\(\s*'kusari'\s*,\s*'{flag_key}'\s*,\s*{enabled_str}\b"
        assert re.search(pattern, sql), (
            f"Expected flag ({KUSARI_TENANT}, {flag_key}, {enabled_str}) not found in migration 060"
        )


def test_superadmin_user_seed_attributes() -> None:
    """Verify initial platform superadmin user attributes in migration 060."""
    migration = next(
        m for m in discover_migrations(MIGRATIONS_DIR)
        if m.filename == "060_seed_design_partner_presets.sql"
    )
    sql = migration.read_sql()

    assert SUPERADMIN_EMAIL in sql
    assert "admin@kusari.demo" in sql
    assert "'admin'" in sql
    assert "'active'" in sql
    assert "is_superadmin" in sql



class MockConnection:
    """Mock connection to simulate feature flag repository and user queries."""

    def __init__(self, flags: dict[tuple[str, str], bool] | None = None) -> None:
        self.flags = flags or {}
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        self.statements.append((query, args))
        tenant_id = args[0] if args else None
        results = []
        for (t_id, f_key), enabled in self.flags.items():
            if tenant_id is None or t_id == tenant_id:
                results.append(
                    {
                        "tenant_id": t_id,
                        "flag_key": f_key,
                        "enabled": enabled,
                        "config_json": "{}",
                        "created_at": None,
                        "updated_at": None,
                    }
                )
        return results

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        self.statements.append((query, args))
        if len(args) >= 2:
            tenant_id, flag_key = args[0], args[1]
            if (tenant_id, flag_key) in self.flags:
                return {
                    "tenant_id": tenant_id,
                    "flag_key": flag_key,
                    "enabled": self.flags[(tenant_id, flag_key)],
                    "config_json": "{}",
                    "created_at": None,
                    "updated_at": None,
                }
        return None

    async def execute(self, query: str, *args: Any) -> str:
        self.statements.append((query, args))
        return "INSERT 0 1"


@pytest.mark.asyncio
async def test_feature_flag_repository_evaluates_kusari_presets() -> None:
    """FeatureFlagRepository must return exact seeded states for Kusari tenant."""
    seeded_flags = {
        (KUSARI_TENANT, key): val for key, val in EXPECTED_KUSARI_FLAGS.items()
    }
    conn = MockConnection(flags=seeded_flags)

    # 1. Evaluate explicit Kusari flags
    for flag_key, expected_enabled in EXPECTED_KUSARI_FLAGS.items():
        result = await FeatureFlagRepository.evaluate_flag(
            conn, tenant_id=KUSARI_TENANT, flag_key=flag_key
        )
        assert result.enabled is expected_enabled
        assert result.flag_key == flag_key

    # 2. List all flags for Kusari tenant
    kusari_flags = await FeatureFlagRepository.list_flags(conn, tenant_id=KUSARI_TENANT)
    assert len(kusari_flags) == len(EXPECTED_KUSARI_FLAGS)
    for flag in kusari_flags:
        assert flag.enabled == EXPECTED_KUSARI_FLAGS[flag.flag_key]


@pytest.mark.asyncio
async def test_feature_flag_repository_falls_back_for_unseeded_tenant() -> None:
    """Unseeded tenant must fall back to DEFAULT_SYSTEM_FLAGS without database row."""
    conn = MockConnection(flags={})

    for flag_key, default_enabled in DEFAULT_SYSTEM_FLAGS.items():
        result = await FeatureFlagRepository.evaluate_flag(
            conn, tenant_id="other-tenant", flag_key=flag_key
        )
        assert result.enabled == default_enabled


def test_principal_resolution_for_seeded_superadmin() -> None:
    """Superadmin principal must have global tenant access and administrative privileges."""
    superadmin = Principal(
        tenant="tenant-demo",
        subject="demo-user",
        email=SUPERADMIN_EMAIL,
        role="admin",
        status="active",
        is_superadmin=True,
    )

    assert superadmin.is_superadmin() is True
    assert superadmin.is_admin() is True
    assert superadmin.has_tenant_access("tenant-demo") is True
    assert superadmin.has_tenant_access("kusari") is True
    assert superadmin.has_tenant_access("any-arbitrary-tenant") is True


def test_principal_resolution_for_kusari_standard_user() -> None:
    """Standard user of Kusari tenant must be strictly scoped to Kusari."""
    kusari_operator = Principal(
        tenant=KUSARI_TENANT,
        subject="kusari-op",
        email="operator@kusari.io",
        role="admin",
        status="active",
        is_superadmin=False,
    )

    assert kusari_operator.is_superadmin() is False
    assert kusari_operator.is_admin() is True
    assert kusari_operator.has_tenant_access(KUSARI_TENANT) is True
    assert kusari_operator.has_tenant_access("tenant-demo") is False
    assert kusari_operator.has_tenant_access("other-tenant") is False
