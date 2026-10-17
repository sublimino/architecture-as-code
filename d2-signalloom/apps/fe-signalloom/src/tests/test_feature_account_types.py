"""Account types: EAP View (read-only), EAP Full, Full.

An account type is a named, exact feature-flag set plus a per-tenant record of
which one was applied. Design: docs/signalloom/feature-flag-account-types.md.

Pins, in order:
1. The exact flag set of every account type (contract test). EAP View is the
   configuration captured live from tenant-demo on 2026-10-17 and is written out
   literally here, so changing a single flag in the preset turns this red.
2. Parity with d2-signalloom/contracts/feature-account-types.json, the file the
   dashboard and the Playwright suite are tested against.
3. Deprecated aliases (eap_pilot -> eap_full, full_demo -> full) still apply.
4. Applying a type records it per tenant; a later manual toggle that leaves the
   flags off the type's set records the tenant as customised, so the page never
   claims a type the flags no longer match.
5. Only a superadmin can apply a type, and the change is audited.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
from conftest import EAP_ALICE, EAP_OPERATOR, EAP_TENANT_A, EAP_TENANT_B, EAPClient
from feature_flags import (
    ACCOUNT_TYPE_IDS,
    DEFAULT_SYSTEM_FLAGS,
    FEATURE_PRESETS,
    get_preset,
    invalidate_flag_cache,
    resolve_preset_id,
)
from main import app as main_app
from test_feature_flags import FakePool

EAP_AUTHENTICATED = True

CONTRACT = Path(__file__).resolve().parents[4] / "contracts" / "feature-account-types.json"

# Captured live from tenant-demo, 2026-10-17. Do not edit without the principal.
EAP_VIEW_SNAPSHOT: dict[str, bool] = {
    "audit": True,
    "collusion_access": False,
    "compliance": True,
    "core_governance": True,
    "demos_fleet": False,
    "page_agentmaxxing": False,
    "page_agents": True,
    "page_audit": False,
    "page_compliance": False,
    "page_credential_inventory": False,
    "page_cryptography": False,
    "page_discovery": True,
    "page_federated_services": False,
    "page_feeds": False,
    "page_network_tests": False,
    "page_policies": True,
    "page_risk": False,
    "page_signal_store": False,
    "page_signals": False,
    "page_topology": False,
    "page_weave": False,
    "rbac_analysis": False,
    "supercred": False,
}

# The former eap_pilot contents. Draft pending the principal's confirmation.
EAP_FULL_DRAFT: dict[str, bool] = {
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
}


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


# ===========================================================================
# 1. Contract: the exact flag set of every account type
# ===========================================================================


def test_account_type_ids_are_the_three_types_in_order() -> None:
    assert ACCOUNT_TYPE_IDS == ("eap_view", "eap_full", "full")


def test_eap_view_is_exactly_the_captured_snapshot() -> None:
    assert FEATURE_PRESETS["eap_view"]["flags"] == EAP_VIEW_SNAPSHOT


def test_eap_full_is_exactly_the_former_eap_pilot_set() -> None:
    assert FEATURE_PRESETS["eap_full"]["flags"] == EAP_FULL_DRAFT


def test_full_enables_every_flag() -> None:
    assert FEATURE_PRESETS["full"]["flags"] == {k: True for k in DEFAULT_SYSTEM_FLAGS}


@pytest.mark.parametrize("type_id", ["eap_view", "eap_full", "full"])
def test_every_account_type_sets_every_registered_flag(type_id: str) -> None:
    assert set(FEATURE_PRESETS[type_id]["flags"]) == set(DEFAULT_SYSTEM_FLAGS)


def test_account_type_names_and_status() -> None:
    assert FEATURE_PRESETS["eap_view"]["name"] == "EAP View (read-only)"
    assert FEATURE_PRESETS["eap_full"]["name"] == "EAP Full"
    assert FEATURE_PRESETS["full"]["name"] == "Full"
    assert FEATURE_PRESETS["eap_view"]["status"] == "confirmed"
    assert FEATURE_PRESETS["eap_full"]["status"] == "draft"
    assert FEATURE_PRESETS["full"]["status"] == "confirmed"


# ===========================================================================
# 2. Parity with the cross-language contract file
# ===========================================================================


def test_presets_match_the_contract_file() -> None:
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    assert contract["flag_keys"] == list(DEFAULT_SYSTEM_FLAGS)
    assert [t["id"] for t in contract["account_types"]] == list(ACCOUNT_TYPE_IDS)
    for entry in contract["account_types"]:
        preset = FEATURE_PRESETS[entry["id"]]
        assert preset["flags"] == entry["flags"], entry["id"]
        assert preset["name"] == entry["name"], entry["id"]
        assert preset["status"] == entry["status"], entry["id"]
        assert preset["aliases"] == entry["aliases"], entry["id"]


# ===========================================================================
# 3. Deprecated aliases keep working
# ===========================================================================


def test_aliases_resolve_to_canonical_ids() -> None:
    assert resolve_preset_id("eap_pilot") == "eap_full"
    assert resolve_preset_id("full_demo") == "full"
    assert resolve_preset_id("eap_view") == "eap_view"
    assert resolve_preset_id("minimal_governance") == "minimal_governance"
    assert resolve_preset_id("nope") is None


def test_get_preset_accepts_an_alias() -> None:
    assert get_preset("eap_pilot")["flags"] == EAP_FULL_DRAFT
    assert get_preset("full_demo")["flags"] == FEATURE_PRESETS["full"]["flags"]


def test_presets_listing_carries_account_type_metadata(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.get("/api/v1/admin/features/presets")
    assert resp.status_code == 200
    presets = {p["id"]: p for p in resp.json()["presets"]}
    # Aliases are not listed twice; they ride on their canonical entry.
    assert "eap_pilot" not in presets and "full_demo" not in presets
    assert presets["eap_view"]["kind"] == "account_type"
    assert presets["eap_full"]["kind"] == "account_type"
    assert presets["full"]["kind"] == "account_type"
    assert presets["minimal_governance"]["kind"] == "bundle"
    assert presets["eap_full"]["aliases"] == ["eap_pilot"]
    assert presets["full"]["aliases"] == ["full_demo"]
    assert presets["eap_full"]["status"] == "draft"
    assert presets["eap_view"]["flags"] == EAP_VIEW_SNAPSHOT


# ===========================================================================
# 4. Applying a type records it; manual toggles mark the tenant customised
# ===========================================================================


def _apply(client: EAPClient, tenant: str, preset: str) -> dict:
    resp = client.put("/api/v1/admin/features", json={"tenant_id": tenant, "preset": preset})
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_applying_eap_view_sets_flags_and_records_the_type(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    data = _apply(client, EAP_TENANT_B, "eap_view")

    assert {k: data["flags"][k] for k in EAP_VIEW_SNAPSHOT} == EAP_VIEW_SNAPSHOT
    assert pool.db.account_types[EAP_TENANT_B]["account_type"] == "eap_view"
    assert pool.db.account_types[EAP_TENANT_B]["customised"] is False
    assert data["account_type"] == {
        "id": "eap_view",
        "customised": False,
        "matches": "eap_view",
        "label": "EAP View (read-only)",
    }

    got = client.get(f"/api/v1/admin/features?tenant_id={EAP_TENANT_B}").json()
    assert got["account_type"]["id"] == "eap_view"
    assert got["account_type"]["customised"] is False


def test_applying_an_alias_records_the_canonical_type(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    data = _apply(client, EAP_TENANT_B, "eap_pilot")
    assert pool.db.account_types[EAP_TENANT_B]["account_type"] == "eap_full"
    assert data["account_type"]["id"] == "eap_full"
    assert data["account_type"]["label"] == "EAP Full"


def test_single_toggle_marks_custom_and_toggling_back_clears_it(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    _apply(client, EAP_TENANT_B, "eap_view")

    resp = client.put(
        f"/api/v1/admin/features/page_signals?tenant_id={EAP_TENANT_B}",
        json={"enabled": True},
    )
    assert resp.status_code == 200
    assert pool.db.account_types[EAP_TENANT_B]["customised"] is True
    assert resp.json()["account_type"] == {
        "id": "eap_view",
        "customised": True,
        "matches": None,
        "label": "Custom, based on EAP View (read-only)",
    }

    resp = client.put(
        f"/api/v1/admin/features/page_signals?tenant_id={EAP_TENANT_B}",
        json={"enabled": False},
    )
    assert pool.db.account_types[EAP_TENANT_B]["customised"] is False
    assert resp.json()["account_type"]["label"] == "EAP View (read-only)"


def test_batch_flag_update_marks_custom(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    _apply(client, EAP_TENANT_B, "eap_view")
    resp = client.put(
        "/api/v1/admin/features",
        json={"tenant_id": EAP_TENANT_B, "flags": {"page_audit": True}},
    )
    assert resp.status_code == 200
    assert pool.db.account_types[EAP_TENANT_B]["customised"] is True
    assert resp.json()["account_type"]["label"] == "Custom, based on EAP View (read-only)"


def test_preset_with_deviating_flags_in_one_request_is_custom(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.put(
        "/api/v1/admin/features",
        json={"tenant_id": EAP_TENANT_B, "preset": "full", "flags": {"supercred": False}},
    )
    assert resp.status_code == 200
    assert pool.db.account_types[EAP_TENANT_B] | {"updated_at": None} == {
        "tenant_id": EAP_TENANT_B,
        "account_type": "full",
        "customised": True,
        "updated_by": pool.db.account_types[EAP_TENANT_B]["updated_by"],
        "updated_at": None,
    }


def test_unrecorded_tenant_reports_no_type_but_names_a_matching_one(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    # Flags set by hand to exactly EAP View, with no account type ever applied:
    # the state tenant-demo was in when the snapshot was taken.
    client.put("/api/v1/admin/features", json={"tenant_id": EAP_TENANT_B, "flags": EAP_VIEW_SNAPSHOT})
    assert EAP_TENANT_B not in pool.db.account_types
    got = client.get(f"/api/v1/admin/features?tenant_id={EAP_TENANT_B}").json()
    assert got["account_type"] == {
        "id": None,
        "customised": False,
        "matches": "eap_view",
        "label": "Unassigned (flags match EAP View (read-only))",
    }


def test_never_configured_tenant_is_unassigned(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    got = client.get(f"/api/v1/admin/features?tenant_id={EAP_TENANT_B}").json()
    assert got["account_type"] == {"id": None, "customised": False, "matches": None, "label": "Unassigned"}


def test_applying_a_bundle_records_it_like_a_type(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    data = _apply(client, EAP_TENANT_B, "minimal_governance")
    assert pool.db.account_types[EAP_TENANT_B]["account_type"] == "minimal_governance"
    assert data["account_type"]["label"] == "Minimal Governance"


# ===========================================================================
# 5. Superadmin only, and audited
# ===========================================================================


def test_non_superadmin_cannot_apply_an_account_type(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.put("/api/v1/admin/features", json={"tenant_id": EAP_TENANT_A, "preset": "full"})
    assert resp.status_code == 403
    assert pool.db.account_types == {}
    assert pool.db.rows == {}


def test_non_superadmin_cannot_toggle_a_flag(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.put(
        f"/api/v1/admin/features/page_signals?tenant_id={EAP_TENANT_A}",
        json={"enabled": True},
    )
    assert resp.status_code == 403
    assert pool.db.account_types == {}


def _audit_details(pool: FakePool) -> list[dict]:
    # _audit_log args: tenant_id, event_type, agent_id, agent_name, actor, detail
    return [json.loads(args[5]) for args in pool.db.audit if args[1] == "feature_flags.updated"]


def test_applying_a_type_is_audited_with_the_type(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    _apply(client, EAP_TENANT_B, "eap_pilot")
    details = _audit_details(pool)
    assert len(details) == 1
    assert details[0]["applied_preset"] == "eap_full"
    assert details[0]["account_type"] == "eap_full"
    assert details[0]["account_type_customised"] is False


def test_toggle_audit_records_the_resulting_customisation(pool: FakePool) -> None:
    client = EAPClient(main_app, subject=EAP_OPERATOR)
    _apply(client, EAP_TENANT_B, "eap_view")
    client.put(f"/api/v1/admin/features/page_risk?tenant_id={EAP_TENANT_B}", json={"enabled": True})
    last = _audit_details(pool)[-1]
    assert last["flag_key"] == "page_risk"
    assert last["account_type"] == "eap_view"
    assert last["account_type_customised"] is True
