"""Unit and contract tests for Signal Loom on-demand EAP environment routing."""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from environment_routing import (
    MAX_LIFETIME_HOURS,
    EnvironmentRecord,
    EnvironmentRegistry,
    EnvironmentResponse,
    EnvironmentState,
    EnvironmentTier,
    ProvisionRequest,
    build_environment_urls,
    derive_customer_hash,
    get_eap_salt,
    normalize_company_name,
    resolve_company_to_urls,
    validate_environment_subdomain,
)
from main import app
from conftest import EAPClient

# EAPR-P2-1: the environments router is mounted behind authenticated_principal;
# every request here carries a real tenant-a token (see tests/conftest.py).
EAP_AUTHENTICATED = True
client = EAPClient(app)


# ── Baseline & Hashing Tests ───────────────────────────────────────────────


def test_harness_baseline():
    """Verify that the test harness and environment routing module load cleanly."""
    assert len(get_eap_salt()) > 0


def test_derive_customer_hash_canonical_kusari():
    """Verify the canonical customer test vector for kusari."""
    h = derive_customer_hash("kusari")
    assert len(h) == 8

    urls = build_environment_urls(h)
    assert urls["hostname"] == f"sl-eap-{h}"
    assert urls["internal_mesh_url"] == f"https://sl-eap-{h}.tailscale"
    assert urls["external_fqdn"] == f"https://sl-eap-{h}.ts.net"


def test_derive_customer_hash_case_and_whitespace_insensitivity():
    """Verify that casing and whitespace do not alter the deterministic hash."""
    expected = derive_customer_hash("kusari")
    assert derive_customer_hash("Kusari") == expected
    assert derive_customer_hash("KUSARI") == expected
    assert derive_customer_hash("  kusari  ") == expected
    assert derive_customer_hash("\tkusari\n") == expected


def test_derive_customer_hash_custom_salt():
    """Verify that custom salt parameters generate distinct, isolated hashes."""
    h_default = derive_customer_hash("kusari")
    h_custom = derive_customer_hash("kusari", salt="custom-tenant-salt")
    assert h_default != h_custom
    assert len(h_custom) == 8


def test_derive_customer_hash_invalid_input():
    """Verify ValueError on empty or invalid company names."""
    with pytest.raises(ValueError):
        derive_customer_hash("")
    with pytest.raises(ValueError):
        derive_customer_hash("   ")
    with pytest.raises(ValueError):
        derive_customer_hash(None)  # type: ignore[arg-type]


def test_validate_environment_subdomain():
    """Verify RFC 1123 and sl-eap-HASH subdomain validation rules."""
    h = derive_customer_hash("kusari")
    assert validate_environment_subdomain(f"sl-eap-{h}") is True
    assert validate_environment_subdomain("sl-eap-00000000") is True
    assert validate_environment_subdomain("sl-eap-ffffffff") is True

    # Negative cases
    assert validate_environment_subdomain(f"sl-eap-{h[:-1]}") is False  # 7 chars
    assert validate_environment_subdomain(f"sl-eap-{h}1") is False  # 9 chars
    assert validate_environment_subdomain(f"sl-eap-{h.upper()}") is False  # Uppercase
    assert validate_environment_subdomain("sl-eap-1234567g") is False  # Non-hex 'g'
    assert validate_environment_subdomain(f"other-{h}") is False  # Wrong prefix
    assert validate_environment_subdomain("") is False
    assert validate_environment_subdomain("a" * 64) is False


def test_resolve_company_to_urls_helper():
    """Verify the resolve_company_to_urls end-to-end mapping helper."""
    h = derive_customer_hash("kusari")
    res = resolve_company_to_urls("kusari")
    assert res["customer_hash"] == h
    assert res["company_name"] == "kusari"
    assert res["hostname"] == f"sl-eap-{h}"
    assert res["internal_mesh_url"] == f"https://sl-eap-{h}.tailscale"
    assert res["external_fqdn"] == f"https://sl-eap-{h}.ts.net"


# ── Data Models & Registry Tests ──────────────────────────────────────────


def test_provision_request_validation():
    """Verify Pydantic validation on ProvisionRequest."""
    req = ProvisionRequest(company_name="kusari", ttl_minutes=180)
    assert req.company_name == "kusari"
    assert req.ttl_minutes == 180
    assert req.tier == EnvironmentTier.DEMO
    assert req.enable_funnel is False

    # Short name
    with pytest.raises(Exception):
        ProvisionRequest(company_name="a")

    # Excessive TTL
    with pytest.raises(Exception):
        ProvisionRequest(company_name="kusari", ttl_minutes=10000)

    # Negative TTL
    with pytest.raises(Exception):
        ProvisionRequest(company_name="kusari", ttl_minutes=-10)


def test_registry_lifecycle_and_max_ceiling():
    """Verify EnvironmentRegistry state management and 8-hour lifetime ceiling."""
    reg = EnvironmentRegistry()
    req = ProvisionRequest(company_name="acme-corp", ttl_minutes=60)
    rec = reg.create(req)

    assert rec.company_name == "acme-corp"
    assert rec.state == EnvironmentState.READY
    assert rec.ttl_remaining_seconds > 0

    # Retrieve
    assert reg.get(rec.id) is rec
    assert reg.get_by_hash(rec.customer_hash) is rec

    # Extend within ceiling
    extended = reg.extend_ttl(rec.id, additional_minutes=120)
    assert extended.expires_at > rec.created_at + timedelta(minutes=60)

    # Extend beyond 8 hour ceiling fails
    with pytest.raises(Exception) as exc:
        reg.extend_ttl(rec.id, additional_minutes=8 * 60 + 100)
    assert "exceeds maximum lifetime ceiling" in str(exc.value)

    # Teardown
    torn_down = reg.teardown(rec.id, reason="Test finished")
    assert torn_down.state == EnvironmentState.TERMINATED
    assert torn_down.teardown_reason == "Test finished"

    # Idempotent teardown
    assert reg.teardown(rec.id).state == EnvironmentState.TERMINATED

    # Cannot extend terminated
    with pytest.raises(Exception):
        reg.extend_ttl(rec.id, 60)


def test_registry_conflict_on_active_duplicate():
    """Verify that creating two active environments for the same customer raises 409 Conflict."""
    reg = EnvironmentRegistry()
    req = ProvisionRequest(company_name="duplicate-corp")
    reg.create(req)

    with pytest.raises(Exception) as exc:
        reg.create(req)
    assert "409" in str(exc.value) or "already exists" in str(exc.value)


# ── FastAPI REST API Endpoint Tests ────────────────────────────────────────


def test_api_provision_kusari_success():
    """Verify POST /api/v1/environments/provision returns 201 Created with canonical kusari vector."""
    h = derive_customer_hash("kusari")
    resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "kusari", "ttl_minutes": 240, "tier": "demo"},
    )
    # If kusari was already created in global registry from another test, 409 might occur;
    # tear down first if exists
    if resp.status_code == 409:
        resolve_resp = client.post("/api/v1/environments/resolve-domain", json={"company_name": "kusari"})
        env_id = resolve_resp.json().get("environment_id")
        if env_id:
            client.post(f"/api/v1/environments/{env_id}/teardown")
        resp = client.post(
            "/api/v1/environments/provision",
            json={"company_name": "kusari", "ttl_minutes": 240, "tier": "demo"},
        )

    assert resp.status_code == 201
    data = resp.json()
    assert data["company_name"] == "kusari"
    assert data["customer_hash"] == h
    assert data["hostname"] == f"sl-eap-{h}"
    assert data["internal_mesh_url"] == f"https://sl-eap-{h}.tailscale"
    assert data["external_fqdn"] == f"https://sl-eap-{h}.ts.net"
    assert data["state"] == "ready"
    assert data["tier"] == "demo"
    assert "id" in data


def test_api_provision_duplicate_conflict():
    """Verify POST /api/v1/environments/provision returns 409 Conflict on duplicate active environment."""
    # Ensure active environment for kusari exists
    client.post(
        "/api/v1/environments/provision",
        json={"company_name": "kusari", "ttl_minutes": 120},
    )
    # Attempt duplicate
    resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "kusari", "ttl_minutes": 120},
    )
    assert resp.status_code == 409
    body = resp.json()
    assert "error" in body or "detail" in body


def test_api_resolve_domain():
    """Verify POST /api/v1/environments/resolve-domain by name and by hash."""
    h = derive_customer_hash("kusari")
    # Resolve by name
    resp_name = client.post(
        "/api/v1/environments/resolve-domain",
        json={"company_name": "kusari"},
    )
    assert resp_name.status_code == 200
    data_name = resp_name.json()
    assert data_name["customer_hash"] == h
    assert data_name["internal_mesh_url"] == f"https://sl-eap-{h}.tailscale"
    assert data_name["is_active"] is True

    # Resolve by hash
    resp_hash = client.post(
        "/api/v1/environments/resolve-domain",
        json={"customer_hash": h},
    )
    assert resp_hash.status_code == 200
    data_hash = resp_hash.json()
    assert data_hash["customer_hash"] == h
    assert data_hash["internal_mesh_url"] == f"https://sl-eap-{h}.tailscale"

    # Missing both fields
    resp_bad = client.post("/api/v1/environments/resolve-domain", json={})
    assert resp_bad.status_code == 400


def test_api_list_and_get():
    """Verify GET /api/v1/environments and GET /api/v1/environments/{id}."""
    resp = client.get("/api/v1/environments")
    assert resp.status_code == 200
    items = resp.json()
    assert isinstance(items, list)
    assert len(items) >= 1

    first_id = items[0]["id"]
    get_resp = client.get(f"/api/v1/environments/{first_id}")
    assert get_resp.status_code == 200
    assert get_resp.json()["id"] == first_id

    # 404 for non-existent
    bad_resp = client.get("/api/v1/environments/non-existent-uuid")
    assert bad_resp.status_code == 404


def test_api_extend_and_teardown_lifecycle():
    """Verify extending TTL and tearing down an environment via API."""
    # Provision fresh test environment
    p_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "temp-tenant", "ttl_minutes": 60},
    )
    assert p_resp.status_code == 201
    env_id = p_resp.json()["id"]

    # Extend
    ext_resp = client.post(
        f"/api/v1/environments/{env_id}/extend",
        json={"additional_minutes": 60},
    )
    assert ext_resp.status_code == 200
    assert ext_resp.json()["ttl_remaining_seconds"] > 3600

    # Teardown
    td_resp = client.post(
        f"/api/v1/environments/{env_id}/teardown",
        json={"reason": "Completed lifecycle test"},
    )
    assert td_resp.status_code == 200
    assert td_resp.json()["state"] == "terminated"

    # Repeated teardown is idempotent
    td_again = client.post(f"/api/v1/environments/{env_id}/teardown")
    assert td_again.status_code == 200
    assert td_again.json()["state"] == "terminated"
