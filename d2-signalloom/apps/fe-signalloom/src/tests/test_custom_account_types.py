"""Custom account types: superadmin-defined, persisted, tenant-assignable.

Decision 3 of docs/signalloom/feature-flag-account-types.md: a superadmin can
create, rename and delete a named account type with an explicit flag set.
Custom types are persisted (migration 076, public.custom_account_types),
tenant-assignable like the built-ins (FeatureFlagRepository.apply_preset),
and shown on GET /api/v1/admin/features/presets (feature_flags.list_all_presets).
Built-in types cannot be deleted or edited -- there is no row for them to
mutate, and RESERVED_ACCOUNT_TYPE_IDS refuses a custom type that tries to
reuse their id. API-level authz/audit coverage is
tests/test_admin_account_types_api.py; this file is the repository layer.
"""
from __future__ import annotations

import pytest
from feature_flags import (
    ACCOUNT_TYPE_IDS,
    DEFAULT_SYSTEM_FLAGS,
    FEATURE_PRESETS,
    RESERVED_ACCOUNT_TYPE_IDS,
    AccountTypeRepository,
    CustomAccountTypeRepository,
    FeatureFlagRepository,
    _merged_presets,
    describe_account_type,
    invalidate_flag_cache,
    list_all_presets,
)
from test_feature_flags import FakePool

_ALL_OFF = {k: False for k in DEFAULT_SYSTEM_FLAGS}
_EU_FLAGS = {**_ALL_OFF, "core_governance": True, "audit": True, "compliance": True}


@pytest.fixture(autouse=True)
def _reset_flag_cache():
    invalidate_flag_cache()
    yield
    invalidate_flag_cache()


@pytest.fixture
def pool() -> FakePool:
    return FakePool()


# ===========================================================================
# 1. Reserved ids
# ===========================================================================


def test_every_built_in_id_and_alias_is_reserved() -> None:
    assert set(ACCOUNT_TYPE_IDS) <= RESERVED_ACCOUNT_TYPE_IDS
    assert "eap_pilot" in RESERVED_ACCOUNT_TYPE_IDS
    assert "full_demo" in RESERVED_ACCOUNT_TYPE_IDS
    assert "minimal_governance" in RESERVED_ACCOUNT_TYPE_IDS  # retired, never reusable


# ===========================================================================
# 2. Create: validation
# ===========================================================================


@pytest.mark.asyncio
async def test_create_rejects_a_reserved_id(pool: FakePool) -> None:
    for reserved in ("eap_view", "eap_full", "full", "eap_pilot", "full_demo", "minimal_governance"):
        with pytest.raises(ValueError, match="built-in"):
            await CustomAccountTypeRepository.create(pool, reserved, "Whatever", _EU_FLAGS, "root")


@pytest.mark.asyncio
async def test_create_rejects_an_incomplete_flag_set(pool: FakePool) -> None:
    incomplete = dict(_EU_FLAGS)
    del incomplete["audit"]
    with pytest.raises(ValueError, match="registered flag keys"):
        await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", incomplete, "root")


@pytest.mark.asyncio
async def test_create_rejects_an_unknown_flag_key(pool: FakePool) -> None:
    extra = {**_EU_FLAGS, "made_up_flag": True}
    with pytest.raises(ValueError, match="registered flag keys"):
        await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", extra, "root")


@pytest.mark.asyncio
async def test_create_rejects_a_duplicate_id(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    with pytest.raises(ValueError, match="already exists"):
        await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated v2", _EU_FLAGS, "root")


# ===========================================================================
# 3. Create / get / list
# ===========================================================================


@pytest.mark.asyncio
async def test_create_then_get_round_trips(pool: FakePool) -> None:
    created = await CustomAccountTypeRepository.create(
        pool, "eu_regulated", "EU Regulated", _EU_FLAGS, created_by="root@test"
    )
    assert created["id"] == "eu_regulated"
    assert created["name"] == "EU Regulated"
    assert created["flags"] == _EU_FLAGS
    assert created["created_by"] == "root@test"

    fetched = await CustomAccountTypeRepository.get(pool, "eu_regulated")
    assert fetched == created


@pytest.mark.asyncio
async def test_get_of_an_unknown_id_is_none(pool: FakePool) -> None:
    assert await CustomAccountTypeRepository.get(pool, "nope") is None


@pytest.mark.asyncio
async def test_list_is_sorted_by_id(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "zzz_type", "ZZZ", _EU_FLAGS, "root")
    await CustomAccountTypeRepository.create(pool, "aaa_type", "AAA", _EU_FLAGS, "root")
    listed = await CustomAccountTypeRepository.list(pool)
    assert [row["id"] for row in listed] == ["aaa_type", "zzz_type"]


# ===========================================================================
# 4. Rename / delete
# ===========================================================================


@pytest.mark.asyncio
async def test_rename_updates_the_name_and_updated_by(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    renamed = await CustomAccountTypeRepository.rename(pool, "eu_regulated", "EU Regulated v2", "someone-else")
    assert renamed is not None
    assert renamed["name"] == "EU Regulated v2"
    assert renamed["updated_by"] == "someone-else"
    assert renamed["flags"] == _EU_FLAGS  # rename never touches the flag set


@pytest.mark.asyncio
async def test_rename_of_an_unknown_id_returns_none(pool: FakePool) -> None:
    assert await CustomAccountTypeRepository.rename(pool, "nope", "New Name", "root") is None


@pytest.mark.asyncio
async def test_delete_removes_the_row_and_reports_true(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    assert await CustomAccountTypeRepository.delete(pool, "eu_regulated") is True
    assert await CustomAccountTypeRepository.get(pool, "eu_regulated") is None


@pytest.mark.asyncio
async def test_delete_of_an_unknown_id_reports_false(pool: FakePool) -> None:
    assert await CustomAccountTypeRepository.delete(pool, "nope") is False


# ===========================================================================
# 5. Merged catalogue: custom types ride alongside the built-ins
# ===========================================================================


@pytest.mark.asyncio
async def test_merged_presets_includes_custom_types_as_kind_custom(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    merged = await _merged_presets(pool)
    assert set(FEATURE_PRESETS) <= set(merged)
    assert merged["eu_regulated"]["kind"] == "custom"
    assert merged["eu_regulated"]["flags"] == _EU_FLAGS


@pytest.mark.asyncio
async def test_list_all_presets_lists_built_ins_then_custom_types(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    all_presets = {p["id"]: p for p in await list_all_presets(pool)}
    assert set(ACCOUNT_TYPE_IDS) <= set(all_presets)
    assert all_presets["eu_regulated"]["kind"] == "custom"
    assert all_presets["eu_regulated"]["status"] == "confirmed"


@pytest.mark.asyncio
async def test_a_tenant_recorded_against_a_custom_type_is_described_correctly(pool: FakePool) -> None:
    """Without the merged catalogue this would report 'Unassigned': the whole
    point of _merged_presets flowing into describe_account_type."""
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    presets = await _merged_presets(pool)
    state = describe_account_type("eu_regulated", _EU_FLAGS, presets)
    assert state.id == "eu_regulated"
    assert state.customised is False
    assert state.label == "EU Regulated"

    drifted = {**_EU_FLAGS, "page_signals": True}
    state2 = describe_account_type("eu_regulated", drifted, presets)
    assert state2.customised is True
    assert state2.label == "Custom, based on EU Regulated"


# ===========================================================================
# 6. Tenant assignment: apply_preset resolves a custom id too
# ===========================================================================


@pytest.mark.asyncio
async def test_apply_preset_accepts_a_custom_account_type_id(pool: FakePool) -> None:
    await CustomAccountTypeRepository.create(pool, "eu_regulated", "EU Regulated", _EU_FLAGS, "root")
    applied = await FeatureFlagRepository.apply_preset(pool, "tenant-x", "eu_regulated", updated_by="root")
    assert applied["core_governance"] is True
    assert applied["demos_fleet"] is False
    record = await AccountTypeRepository.get(pool, "tenant-x")
    assert record["account_type"] == "eu_regulated"
    assert record["customised"] is False


@pytest.mark.asyncio
async def test_apply_preset_still_rejects_a_genuinely_unknown_id(pool: FakePool) -> None:
    with pytest.raises(ValueError, match="Unknown preset"):
        await FeatureFlagRepository.apply_preset(pool, "tenant-x", "does_not_exist", updated_by="root")
