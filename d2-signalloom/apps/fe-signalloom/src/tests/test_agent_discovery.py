import socket
import time
from contextlib import contextmanager
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing


class ReadyPool:
    async def close(self):
        pass


TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def token_for(
    subject: str = "alice",
    *,
    issuer: str = "https://issuer.test/dex",
    audience: str = "signalloom-api",
    authorized_party: str = "signalloom-dashboard",
) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": issuer,
            "aud": audience,
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": authorized_party,
            "sub": subject,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@contextmanager
def client_for(monkeypatch: pytest.MonkeyPatch, async_client_cls=None):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a", "bob": "tenant-b"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: TestJWKClient())
    if async_client_cls:
        monkeypatch.setattr(api_compat.httpx, "AsyncClient", async_client_cls)

    async def _no_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    def reject_external_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in agent discovery tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    api_compat.reset_tenant_state("tenant-a")
    api_compat.reset_tenant_state("tenant-b")
    set_pool_for_testing(ReadyPool())

    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state("tenant-a")
        api_compat.reset_tenant_state("tenant-b")


class FakeDiscoveryResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self):
        return self._payload


def test_agent_discovery_maps_proxy_payload_to_compat_response(monkeypatch):
    requested_urls: list[str] = []

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            assert kwargs["timeout"] == 5.0

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str) -> FakeDiscoveryResponse:
            requested_urls.append(url)
            return FakeDiscoveryResponse(
                {
                    "agents": [
                        {
                            "id": "pod-inventory-agent",
                            "name": "Inventory Agent",
                            "type": "service",
                            "state": "ready",
                            "model": "gpt-5.4-mini",
                            "created_at": "2026-07-27T10:00:00Z",
                        },
                        {"name": "missing id"},
                        "skip-non-object",
                    ],
                    "namespace": "fe-signalloom-agents",
                    "managed_by": "flux",
                    "reconciled": True,
                }
            )

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.get("/api/agents", headers=bearer(token_for()))

    assert requested_urls == [api_compat.AGENT_DISCOVERY_URL]
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 1
    assert len(body["agents"]) == 1
    agent = body["agents"][0]
    assert agent["id"] == "pod-inventory-agent"
    assert agent["name"] == "Inventory Agent"
    assert agent["type"] == "service"
    assert agent["owner"] is None
    assert agent["tenant_id"] == "tenant-a"
    assert agent["lifecycle_state"] == "ready"
    assert agent["last_transition_at"] is None
    assert agent["last_transition_by"] is None
    assert agent["eu_ai_act_risk_class"] is None
    assert agent["model_name"] == "gpt-5.4-mini"
    assert agent["created_at"] == "2026-07-27T10:00:00Z"
    assert agent["compliance_summary"]["total_controls"] == 0
    assert agent["compliance_summary"]["passing"] == 0
    assert agent["compliance_summary"]["failing"] == 0
    assert agent["compliance_summary"]["pending"] == 0
    assert agent["compliance_summary"]["posture_score"] is None


def test_agent_discovery_returns_empty_list_when_proxy_fails(monkeypatch):
    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            assert kwargs["timeout"] == 5.0

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            raise httpx.ConnectError("proxy unavailable", request=httpx.Request("GET", url))

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.get("/api/agents", headers=bearer(token_for()))

    assert response.status_code == 200
    assert response.headers["source_health"] == "unavailable"
    body = response.json()
    assert body["agents"] == []
    assert body["total"] == 0
    assert body["source_health"] == "unavailable"


def test_get_discovery_workloads_all_sources_and_states(monkeypatch):
    with client_for(monkeypatch) as client:
        response = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice")))

    assert response.status_code == 200, response.text
    data = response.json()
    assert "workloads" in data
    assert "total" in data
    assert "summary" in data

    sources = {w["source"] for w in data["workloads"]}
    assert "idp" in sources
    assert "local_k8s" in sources
    assert "external_k8s" in sources
    assert "external_services" in sources

    states = {w["discovery_state"] for w in data["workloads"]}
    assert "discovered" in states
    assert "in_review" in states
    assert "ignored" in states
    assert "revoked" in states

    summary = data["summary"]
    assert "by_source" in summary
    assert "by_state" in summary
    assert summary["total"] == data["total"]
    assert summary["by_source"]["idp"] >= 1
    assert summary["by_source"]["local_k8s"] >= 1
    assert summary["by_source"]["external_k8s"] >= 1
    assert summary["by_source"]["external_services"] >= 1

    for w in data["workloads"]:
        assert "id" in w
        assert "name" in w
        assert "source" in w
        assert "discovery_state" in w
        assert "control_recommendations" in w
        recs = w["control_recommendations"]
        assert "config" in recs
        assert "content" in recs
        assert "supply_chain" in recs
        assert "eu_ai_act" in recs


def test_discovery_workloads_tenant_isolation(monkeypatch):
    with client_for(monkeypatch) as client:
        res_a = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice")))
        res_b = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("bob")))

    assert res_a.status_code == 200
    assert res_b.status_code == 200
    workloads_a = res_a.json()["workloads"]
    workloads_b = res_b.json()["workloads"]

    for w in workloads_a:
        assert w["tenant_id"] == "tenant-a"

    for w in workloads_b:
        assert w["tenant_id"] == "tenant-b"


def test_discovery_workloads_connector_filtering(monkeypatch):
    with client_for(monkeypatch) as client:
        api_compat.set_tenant_connectors_for_testing("tenant-a", {
            "idp": False,
            "local_k8s": True,
            "external_k8s": False,
            "external_services": True,
        })
        response = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice")))

    assert response.status_code == 200
    data = response.json()
    sources = {w["source"] for w in data["workloads"]}
    assert "idp" not in sources
    assert "external_k8s" not in sources
    assert "local_k8s" in sources
    assert "external_services" in sources
    assert data["summary"]["by_source"]["idp"] == 0
    assert data["summary"]["by_source"]["external_k8s"] == 0
    assert data["summary"]["by_source"]["local_k8s"] > 0
    assert data["summary"]["by_source"]["external_services"] > 0



def test_autoclaim_discovered_by_namespace(monkeypatch):
    with client_for(monkeypatch) as client:
        # Before autoclaim, check local_k8s workloads state
        before_res = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice")))
        assert before_res.status_code == 200
        unclaimed = [
            w for w in before_res.json()["workloads"]
            if w["source"] == "local_k8s" and w["namespace"] == "fe-signalloom-agents"
        ]
        assert len(unclaimed) > 0

        # Run autoclaim for specific namespace
        claim_res = client.post(
            "/api/v1/agents/autoclaim-discovered",
            json={"namespace": "fe-signalloom-agents"},
            headers=bearer(token_for("alice")),
        )
        assert claim_res.status_code == 200, claim_res.text
        claim_data = claim_res.json()
        assert claim_data["total_claimed"] >= 1
        for c in claim_data["claimed"]:
            assert c["namespace"] == "fe-signalloom-agents"
            assert c["spiffe_id"].startswith("spiffe://")
            assert c["status"] == "granted"

        # After autoclaim, workloads in that namespace should transition to governed
        after_res = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice")))
        assert after_res.status_code == 200
        claimed_after = [
            w for w in after_res.json()["workloads"]
            if w["source"] == "local_k8s" and w["namespace"] == "fe-signalloom-agents"
        ]
        for w in claimed_after:
            assert w["discovery_state"] == "governed"


def test_discovery_nhi_enroll_and_dismiss_lifecycle(monkeypatch):
    with client_for(monkeypatch) as client:
        initial = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice"))).json()
        idp_discovered = next(
            w for w in initial["workloads"]
            if w["source"] == "idp" and w["discovery_state"] == "discovered"
        )
        target_id = idp_discovered["id"]

        # Enroll workload -> in_review
        enroll_res = client.post(f"/api/v1/nhi/discovered/{target_id}/enroll", headers=bearer(token_for("alice")))
        assert enroll_res.status_code == 200

        after_enroll = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice"))).json()
        enrolled_w = next(w for w in after_enroll["workloads"] if w["id"] == target_id)
        assert enrolled_w["discovery_state"] == "in_review"

        # Dismiss workload -> ignored
        dismiss_res = client.post(f"/api/v1/nhi/discovered/{target_id}/dismiss", headers=bearer(token_for("alice")))
        assert dismiss_res.status_code == 200

        after_dismiss = client.get("/api/v1/discovery/workloads", headers=bearer(token_for("alice"))).json()
        dismissed_w = next(w for w in after_dismiss["workloads"] if w["id"] == target_id)
        assert dismissed_w["discovery_state"] == "ignored"

