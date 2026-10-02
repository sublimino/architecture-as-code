"""No record or list entry carries a model the agent never declared.

Class sweep, same class as the claim fix. A model or provider literal used as a
default ends up written into agent_registry or agent_claims, or shown in the
discovery list, as if it had been observed. An agent with no declared model is
recorded as unknown: ``model_name`` NULL/None, and ``agent_claims.model`` (NOT
NULL) as ``claim_tenancy.UNDECLARED_MODEL``. The database branches are covered
by the Tier 2 suite tests/test_claim_registry_integration.py.
"""
from __future__ import annotations

import socket
from typing import Any

import pytest
from fastapi.testclient import TestClient

import api_compat
import claim_tenancy
from external_agent_registration import ExternalAgentClaimRequest, reset_external_agent_state
from db.connection import set_pool_for_testing
from main import app

TENANT = "tenant-noinvent"
PRINCIPAL = api_compat.Principal(tenant=TENANT, subject="op-noinvent", email="op@noinvent.test")


class _ReadyPool:
    async def close(self) -> None:
        pass


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch):
    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    # The memory branch only: with DATABASE_URL set, writes require the database.
    monkeypatch.setattr(api_compat.settings, "database_url", "")

    def _no_network(*_a: Any, **_k: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", _no_network)
    api_compat.reset_tenant_state(TENANT)
    reset_external_agent_state()
    app.dependency_overrides[api_compat.authenticated_principal] = lambda: PRINCIPAL
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        set_pool_for_testing(None)
        app.dependency_overrides.pop(api_compat.authenticated_principal, None)
        api_compat.reset_tenant_state(TENANT)
        reset_external_agent_state()


def _workloads(client: TestClient) -> dict[str, Any]:
    res = client.get("/api/v1/discovery/workloads")
    assert res.status_code == 200, res.text
    return {w["name"]: w for w in res.json()["workloads"]}


def _stored_claim_models() -> dict[str, str]:
    # Read from the claim store itself: GET /agents/claims cannot list an
    # external claim today (a separate defect, pinned in test_claim_list_*).
    with api_compat._STORE_LOCK:
        return {c["pod_name"]: c["model"] for c in api_compat._CLAIMS.get(TENANT, {}).values()}


def test_the_agent_factory_defaults_to_no_model() -> None:
    agent = api_compat._make_agent(TENANT, "a-1", "n", "service", None, "active", "2026-10-02T00:00:00Z")
    assert agent["model_name"] is None


def test_a_created_agent_declares_no_model_so_none_is_recorded(client: TestClient) -> None:
    res = client.post("/api/agents", json={"name": "made-by-hand", "type": "service"})
    assert res.status_code == 200, res.text
    assert res.json()["model_name"] is None


def test_the_discovery_list_shows_an_undeclared_model_as_unknown(client: TestClient) -> None:
    assert client.post("/api/agents", json={"name": "no-model-agent", "type": "service"}).status_code == 200
    assert _workloads(client)["no-model-agent"]["model"] is None


def test_an_external_registration_without_a_model_is_listed_as_unknown(client: TestClient) -> None:
    res = client.post("/api/v1/external-agents/registrations",
                      json={"agent_id": "ext-no-model", "host_id": "host-no-model"})
    assert res.status_code == 201, res.text
    assert _workloads(client)["ext-no-model"]["model"] is None


def test_an_external_claim_request_has_no_default_model() -> None:
    assert ExternalAgentClaimRequest().model is None


def test_an_external_claim_without_a_model_is_recorded_undeclared(client: TestClient) -> None:
    assert client.post("/api/v1/external-agents/registrations",
                       json={"agent_id": "ext-claim-a", "host_id": "host-claim-a"}).status_code == 201
    res = client.post("/api/v1/external-agents/registrations/ext-claim-a/claim", json={})
    assert res.status_code == 200, res.text
    claims = _stored_claim_models()
    assert claims["ext-claim-a"] == claim_tenancy.UNDECLARED_MODEL


def test_an_external_claim_with_a_model_records_that_model(client: TestClient) -> None:
    assert client.post("/api/v1/external-agents/registrations",
                       json={"agent_id": "ext-claim-b", "host_id": "host-claim-b"}).status_code == 201
    res = client.post("/api/v1/external-agents/registrations/ext-claim-b/claim", json={"model": "llama-3.1-8b"})
    assert res.status_code == 200, res.text
    claims = _stored_claim_models()
    assert claims["ext-claim-b"] == "llama-3.1-8b"
