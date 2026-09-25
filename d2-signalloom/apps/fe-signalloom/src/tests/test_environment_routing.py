"""Unit and contract tests for Signal Loom on-demand EAP environment routing."""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
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
from environment_teardown import StageOutcome, StageResult, TeardownStage
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


def test_registry_idempotent_provision():
    """Verify that provisioning an existing active environment is idempotent (returns 200, same record, refreshed heartbeat)."""
    reg = EnvironmentRegistry()
    req = ProvisionRequest(company_name="idempotent-corp", ttl_minutes=120)
    rec1, is_created1 = reg.provision(req)
    assert is_created1 is True
    assert rec1.state == EnvironmentState.READY
    initial_heartbeat = rec1.last_heartbeat_at

    # Second provision returns same record with refreshed heartbeat
    rec2, is_created2 = reg.provision(req)
    assert is_created2 is False
    assert rec2.id == rec1.id
    assert rec2.customer_hash == rec1.customer_hash
    assert rec2.last_heartbeat_at >= initial_heartbeat
    assert rec2.version > rec1.version or rec2.version >= 2


def test_registry_conflict_on_different_company_same_hash(monkeypatch):
    """Verify that a hash collision with different company name raises 409 Conflict."""
    reg = EnvironmentRegistry()
    req1 = ProvisionRequest(company_name="alpha-corp")
    rec1 = reg.create(req1)

    # Simulate hash collision with beta-corp
    def fake_derive(name, salt=None):
        return rec1.customer_hash

    monkeypatch.setattr("environment_routing.derive_customer_hash", fake_derive)

    req2 = ProvisionRequest(company_name="beta-corp")
    with pytest.raises(HTTPException) as exc:
        reg.provision(req2)
    assert exc.value.status_code == 409
    assert "conflicting company name" in str(exc.value.detail) or "already exists" in str(exc.value.detail)


def test_ordered_staged_teardown_recorded():
    """Verify that teardown executes the 5 stages in order and transitions to TERMINATED only after completion."""
    reg = EnvironmentRegistry()
    req = ProvisionRequest(company_name="staged-teardown-corp")
    rec = reg.create(req)

    recorder = []
    reg.teardown(rec.id, recorder=recorder)

    assert recorder == [
        TeardownStage.DRAIN_ROUTES,
        TeardownStage.SHRED_OPENBAO,
        TeardownStage.REVOKE_SVID,
        TeardownStage.EVICT_TAILSCALE,
        TeardownStage.DELETE_NAMESPACE,
    ]
    assert rec.state == EnvironmentState.TERMINATED


def test_teardown_stage_failure_sets_teardown_failed():
    """Verify that a stage failure stops execution and leaves the record in TEARDOWN_FAILED, not ACTIVE or TERMINATED."""
    reg = EnvironmentRegistry()
    req = ProvisionRequest(company_name="failing-teardown-corp")
    rec = reg.create(req)

    class FailingShredClient:
        def shred(self, h):
            raise RuntimeError("Vault shred connection refused")

    recorder = []
    with pytest.raises(HTTPException) as exc:
        reg.teardown(
            rec.id,
            recorder=recorder,
            stage_kwargs={
                TeardownStage.SHRED_OPENBAO: {"client": FailingShredClient()}
            },
        )

    assert exc.value.status_code == 500
    assert "Vault shred connection refused" in str(exc.value.detail)
    # Failure stopped stages after shred_openbao
    assert recorder == [TeardownStage.DRAIN_ROUTES, TeardownStage.SHRED_OPENBAO]
    assert rec.state == EnvironmentState.TEARDOWN_FAILED


# ── FastAPI REST API Endpoint Tests ────────────────────────────────────────


def test_api_provision_kusari_success_and_idempotence():
    """Verify POST /api/v1/environments/provision returns 201 on create, and 200 on second call with same ID."""
    h = derive_customer_hash("kusari")
    # Clean up any leftover active kusari environment
    resolve_resp = client.post("/api/v1/environments/resolve-domain", json={"company_name": "kusari"})
    env_id = resolve_resp.json().get("environment_id")
    if env_id:
        client.post(f"/api/v1/environments/{env_id}/teardown")

    # 1. Initial provision returns 201 Created
    resp1 = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "kusari", "ttl_minutes": 240, "tier": "demo"},
    )
    assert resp1.status_code == 201
    data1 = resp1.json()
    assert data1["company_name"] == "kusari"
    assert data1["customer_hash"] == h
    assert data1["hostname"] == f"sl-eap-{h}"
    assert data1["internal_mesh_url"] == f"https://sl-eap-{h}.tailscale"
    assert data1["external_fqdn"] == f"https://sl-eap-{h}.ts.net"
    assert data1["state"] == "ready"
    assert "id" in data1
    created_id = data1["id"]

    # 2. Second provision of the same tenant returns 200 OK with same ID and heartbeat refreshed
    resp2 = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "kusari", "ttl_minutes": 240, "tier": "demo"},
    )
    assert resp2.status_code == 200
    data2 = resp2.json()
    assert data2["id"] == created_id
    assert data2["customer_hash"] == h
    assert data2["company_name"] == "kusari"


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
    assert p_resp.status_code in (200, 201)
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
