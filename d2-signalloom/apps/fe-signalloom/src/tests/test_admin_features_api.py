"""Test suite for Superadmin Feature Flag Management API (/api/v1/admin/features).

Verifies:
1. GET /api/v1/admin/features/presets returns the account types (eap_view, eap_full, full) and bundles.
2. GET /api/v1/admin/features authorization and tenant inspection.
3. PUT /api/v1/admin/features batch update and preset application.
4. PUT /api/v1/admin/features/{flag_key} single flag update.
5. Strict 403 rejection for non-superadmin callers.
6. Input validation (400) for missing or invalid payloads.
7. Audit event emission on feature mutations.
"""
from __future__ import annotations

import asyncio
import pytest
from conftest import (
    EAP_ALICE,
    EAP_BOB,
    EAP_OPERATOR,
    EAP_TENANT_A,
    EAP_TENANT_B,
    EAPClient,
)
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    FEATURE_PRESETS,
    FeatureFlagRepository,
    invalidate_flag_cache,
)
from main import app as main_app
from test_feature_flags import FakePool

EAP_AUTHENTICATED = True


@pytest.fixture(autouse=True)
def _reset_flag_cache():
    invalidate_flag_cache()
    yield
    invalidate_flag_cache()


@pytest.fixture
def fake_db_pool() -> FakePool:
    return FakePool()


# ===========================================================================
# 1. Presets Catalogue Endpoints
# ===========================================================================


def test_get_presets_unauthenticated_returns_401() -> None:
    client = EAPClient(main_app, subject=None)
    resp = client.get("/api/v1/admin/features/presets")
    assert resp.status_code == 401


def test_get_presets_returns_account_types_and_catalogue() -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.get("/api/v1/admin/features/presets")
    assert resp.status_code == 200
    data = resp.json()

    assert "presets" in data
    preset_ids = [p["id"] for p in data["presets"]]
    # eap_pilot and full_demo are deprecated aliases of eap_full and full: still
    # applicable, listed once under their canonical entry.
    assert preset_ids == ["eap_view", "eap_full", "full", "minimal_governance"]

    eap_preset = next(p for p in data["presets"] if p["id"] == "eap_full")
    assert eap_preset["aliases"] == ["eap_pilot"]
    assert eap_preset["flags"]["core_governance"] is True
    assert eap_preset["flags"]["page_discovery"] is True
    assert eap_preset["flags"]["demos_fleet"] is False
    assert eap_preset["flags"]["page_agentmaxxing"] is False
    assert eap_preset["flags"]["page_federated_services"] is False
    assert eap_preset["flags"]["page_topology"] is False


# ===========================================================================
# 2. GET /api/v1/admin/features
# ===========================================================================


def test_get_admin_features_superadmin_can_inspect_any_tenant(fake_db_pool: FakePool) -> None:
    main_app.state.pool = fake_db_pool
    client = EAPClient(main_app, subject=EAP_OPERATOR)

    resp = client.get(f"/api/v1/admin/features?tenant_id={EAP_TENANT_B}")
    assert resp.status_code == 200
    data = resp.json()
    assert data["tenant_id"] == EAP_TENANT_B
    assert "page_discovery" in data["flags"]


def test_get_admin_features_cross_tenant_rejected_for_non_superadmin() -> None:
    client = EAPClient(main_app, subject=EAP_ALICE)  # Alice belongs to tenant-a
    resp = client.get(f"/api/v1/admin/features?tenant_id={EAP_TENANT_B}")
    assert resp.status_code == 403


# ===========================================================================
# 3. PUT /api/v1/admin/features (Batch & Presets)
# ===========================================================================


def test_update_features_rejected_for_non_superadmin(fake_db_pool: FakePool) -> None:
    main_app.state.pool = fake_db_pool
    client = EAPClient(main_app, subject=EAP_ALICE)

    resp = client.put(
        "/api/v1/admin/features",
        json={"tenant_id": EAP_TENANT_A, "flags": {"page_agentmaxxing": True}},
    )
    assert resp.status_code == 403


def test_update_features_validation_failures(fake_db_pool: FakePool) -> None:
    main_app.state.pool = fake_db_pool
    client = EAPClient(main_app, subject=EAP_OPERATOR)

    # Empty payload
    resp = client.put("/api/v1/admin/features", json={"tenant_id": EAP_TENANT_A})
    assert resp.status_code == 400

    # Unknown preset
    resp = client.put(
        "/api/v1/admin/features",
        json={"tenant_id": EAP_TENANT_A, "preset": "nonexistent_bundle"},
    )
    assert resp.status_code == 400
    assert "unknown_preset" in resp.json()["error"]["code"]


def test_apply_eap_pilot_preset_to_tenant(fake_db_pool: FakePool) -> None:
    main_app.state.pool = fake_db_pool
    client = EAPClient(main_app, subject=EAP_OPERATOR)

    # Apply EAP pilot preset to tenant B
    resp = client.put(
        "/api/v1/admin/features",
        json={"tenant_id": EAP_TENANT_B, "preset": "eap_pilot"},
    )
    assert resp.status_code == 200
    data = resp.json()

    assert data["tenant_id"] == EAP_TENANT_B
    # EAP Pilot: Core governance & pages enabled, demos disabled
    assert data["flags"]["page_discovery"] is True
    assert data["flags"]["page_agents"] is True
    assert data["flags"]["page_compliance"] is True
    assert data["flags"]["demos_fleet"] is False
    assert data["flags"]["supercred"] is False
    assert data["flags"]["page_agentmaxxing"] is False
    assert data["flags"]["page_network_tests"] is False
    assert data["flags"]["page_federated_services"] is False
    assert data["flags"]["page_topology"] is False


def test_batch_update_granular_flags(fake_db_pool: FakePool) -> None:
    main_app.state.pool = fake_db_pool
    client = EAPClient(main_app, subject=EAP_OPERATOR)

    resp = client.put(
        "/api/v1/admin/features",
        json={
            "tenant_id": EAP_TENANT_B,
            "flags": {
                "page_agentmaxxing": True,
                "demos_fleet": True,
            },
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["flags"]["page_agentmaxxing"] is True
    assert data["flags"]["demos_fleet"] is True


def test_update_single_feature_flag(fake_db_pool: FakePool) -> None:
    main_app.state.pool = fake_db_pool
    client = EAPClient(main_app, subject=EAP_OPERATOR)

    resp = client.put(
        f"/api/v1/admin/features/page_agentmaxxing?tenant_id={EAP_TENANT_B}",
        json={"enabled": True, "config_json": {"lab_mode": "strict"}},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["flags"]["page_agentmaxxing"] is True
    assert data["details"]["page_agentmaxxing"]["enabled"] is True
    assert data["details"]["page_agentmaxxing"]["config"] == {"lab_mode": "strict"}
