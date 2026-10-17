"""API surface for custom account types (/api/v1/admin/account-types).

Every write is superadmin-only (403 otherwise), audited, and built-in types
are immutable. Repository-level validation is tests/test_custom_account_types.py;
this file is the HTTP layer: status codes, authz, and the audit trail.
"""
from __future__ import annotations

import json

import pytest
from conftest import EAP_ALICE, EAP_OPERATOR, EAPClient
from feature_flags import DEFAULT_SYSTEM_FLAGS, invalidate_flag_cache
from main import app as main_app
from test_feature_flags import FakePool

EAP_AUTHENTICATED = True

_ALL_OFF = {k: False for k in DEFAULT_SYSTEM_FLAGS}
_EU_FLAGS = {**_ALL_OFF, "core_governance": True, "audit": True, "compliance": True}


@pytest.fixture(autouse=True)
def _reset_flag_cache():
    invalidate_flag_cache()
    yield
    invalidate_flag_cache()


@pytest.fixture
def pool() -> FakePool:
    fake = FakePool()
    main_app.state.pool = fake
    return fake


def _audit_rows(pool: FakePool, event_type: str) -> list[dict]:
    # _audit_log args: tenant_id, event_type, agent_id, agent_name, actor, detail
    return [
        {"tenant_id": args[0], "actor": args[4], "detail": json.loads(args[5])}
        for args in pool.db.audit
        if args[1] == event_type
    ]


# ===========================================================================
# 1. Create
# ===========================================================================


def test_create_requires_superadmin(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.post(
        "/api/v1/admin/account-types",
        json={"id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "superadmin_required"
    assert pool.db.custom_account_types == {}


def test_create_succeeds_for_a_superadmin_and_is_audited(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.post(
        "/api/v1/admin/account-types",
        json={"id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS},
    )
    assert resp.status_code == 201, resp.text
    data = resp.json()
    assert data["id"] == "eu_regulated"
    assert data["kind"] == "custom"
    assert data["flags"] == _EU_FLAGS

    rows = _audit_rows(pool, "account_type.created")
    assert len(rows) == 1
    assert rows[0]["detail"]["account_type_id"] == "eu_regulated"


def test_create_rejects_a_builtin_id_with_400(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.post(
        "/api/v1/admin/account-types",
        json={"id": "eap_view", "name": "Shadow EAP View", "flags": _EU_FLAGS},
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "invalid_account_type"


def test_create_rejects_an_incomplete_flag_set_with_400(pool: FakePool) -> None:
    incomplete = dict(_EU_FLAGS)
    del incomplete["audit"]
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.post(
        "/api/v1/admin/account-types",
        json={"id": "eu_regulated", "name": "EU Regulated", "flags": incomplete},
    )
    assert resp.status_code == 400


def test_create_rejects_an_uppercase_id_with_422() -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.post(
        "/api/v1/admin/account-types",
        json={"id": "EU_Regulated", "name": "EU Regulated", "flags": _EU_FLAGS},
    )
    assert resp.status_code == 422


# ===========================================================================
# 2. Rename
# ===========================================================================


def test_rename_requires_superadmin(pool: FakePool) -> None:
    pool.db.custom_account_types["eu_regulated"] = {
        "id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS,
        "created_by": "root", "created_at": None, "updated_by": "root", "updated_at": None,
    }
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.patch("/api/v1/admin/account-types/eu_regulated", json={"name": "New Name"})
    assert resp.status_code == 403


def test_rename_succeeds_for_a_superadmin_and_is_audited(pool: FakePool) -> None:
    pool.db.custom_account_types["eu_regulated"] = {
        "id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS,
        "created_by": "root", "created_at": None, "updated_by": "root", "updated_at": None,
    }
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.patch("/api/v1/admin/account-types/eu_regulated", json={"name": "EU Regulated v2"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["name"] == "EU Regulated v2"
    rows = _audit_rows(pool, "account_type.renamed")
    assert len(rows) == 1
    assert rows[0]["detail"]["name"] == "EU Regulated v2"


def test_rename_of_an_unknown_custom_type_is_404(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.patch("/api/v1/admin/account-types/does_not_exist", json={"name": "X"})
    assert resp.status_code == 404


@pytest.mark.parametrize("builtin_id", ["eap_view", "eap_full", "full", "minimal_governance"])
def test_rename_of_a_builtin_type_is_403_not_404(pool: FakePool, builtin_id: str) -> None:
    """Built-in types cannot be edited -- 403, because the id names something
    real, not 404, which would say it does not exist."""
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.patch(f"/api/v1/admin/account-types/{builtin_id}", json={"name": "Hijacked"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "builtin_account_type_immutable"


# ===========================================================================
# 3. Delete
# ===========================================================================


def test_delete_requires_superadmin(pool: FakePool) -> None:
    pool.db.custom_account_types["eu_regulated"] = {
        "id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS,
        "created_by": "root", "created_at": None, "updated_by": "root", "updated_at": None,
    }
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.delete("/api/v1/admin/account-types/eu_regulated")
    assert resp.status_code == 403
    assert "eu_regulated" in pool.db.custom_account_types  # untouched


def test_delete_succeeds_for_a_superadmin_and_is_audited(pool: FakePool) -> None:
    pool.db.custom_account_types["eu_regulated"] = {
        "id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS,
        "created_by": "root", "created_at": None, "updated_by": "root", "updated_at": None,
    }
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.delete("/api/v1/admin/account-types/eu_regulated")
    assert resp.status_code == 204
    assert "eu_regulated" not in pool.db.custom_account_types
    rows = _audit_rows(pool, "account_type.deleted")
    assert len(rows) == 1
    assert rows[0]["detail"]["account_type_id"] == "eu_regulated"


def test_delete_of_an_unknown_custom_type_is_404(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.delete("/api/v1/admin/account-types/does_not_exist")
    assert resp.status_code == 404


@pytest.mark.parametrize("builtin_id", ["eap_view", "eap_full", "full", "minimal_governance"])
def test_delete_of_a_builtin_type_is_403_not_404(pool: FakePool, builtin_id: str) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.delete(f"/api/v1/admin/account-types/{builtin_id}")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "builtin_account_type_immutable"


# ===========================================================================
# 4. End-to-end: created -> listed on /presets -> assignable to a tenant
# ===========================================================================


def test_a_created_custom_type_is_listed_on_presets_and_assignable(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    create_resp = client.post(
        "/api/v1/admin/account-types",
        json={"id": "eu_regulated", "name": "EU Regulated", "flags": _EU_FLAGS},
    )
    assert create_resp.status_code == 201

    presets_resp = client.get("/api/v1/admin/features/presets")
    presets = {p["id"]: p for p in presets_resp.json()["presets"]}
    assert presets["eu_regulated"]["kind"] == "custom"

    apply_resp = client.put(
        "/api/v1/admin/features",
        json={"tenant_id": "tenant-eu", "preset": "eu_regulated"},
    )
    assert apply_resp.status_code == 200, apply_resp.text
    data = apply_resp.json()
    assert data["account_type"]["id"] == "eu_regulated"
    assert data["account_type"]["label"] == "EU Regulated"
    assert data["flags"]["core_governance"] is True
    assert data["flags"]["demos_fleet"] is False
