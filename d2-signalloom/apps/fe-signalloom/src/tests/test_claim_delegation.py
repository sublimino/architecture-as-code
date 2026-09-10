"""Tests for Operator Claim Delegation Synchronization to Signal Ingest Spine.

Validates SFAS-P1-3:
1. Claims with operator, capabilities, and containment claims synchronize to the spine.
2. Nono agent claims automatically acquire containment:landlock claims.
3. Releasing an active claim clamps the delegation edge in the spine.
4. HTTP failures or unreachable spine gracefully degrade without breaking claim responses.
5. Integration with POST /api/v1/agents/claim and DELETE /api/v1/agents/claim/{claim_id}.
"""
from __future__ import annotations

import asyncio
import socket
import time
from typing import Any
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from agent_claim import clamp_claim_delegation_in_spine, sync_claim_delegation_to_spine
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE_SUB = "alice-operator"
ALICE_EMAIL = "alice-operator@signalloom.test"
TENANT_A = "tenant-claim-a"
SUBJECT_TENANTS = {
    ALICE_SUB: TENANT_A,
}


def _bearer(subject: str = ALICE_SUB) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
            "email": f"{subject}@signalloom.test",
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


class _ReadyPool:
    async def close(self) -> None:
        pass


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    api_compat.reset_tenant_state(TENANT_A)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT_A)


def test_sync_claim_delegation_success() -> None:
    captured_requests = []

    def handle_request(request: httpx.Request) -> httpx.Response:
        captured_requests.append(request)
        return httpx.Response(201, json={"status": "created", "delegation_id": "del-123"})

    transport = httpx.MockTransport(handle_request)
    with patch("httpx.AsyncClient", return_value=httpx.AsyncClient(transport=transport)):
        ok = asyncio.run(
            sync_claim_delegation_to_spine(
                agent_id="agent-007",
                operator_id="human-operator-1",
                claim_id="claim-abc",
                capabilities=["agent:operate", "agent:inspect"],
                containment_claims=["containment:landlock"],
            )
        )
    assert ok is True
    assert len(captured_requests) == 1
    req = captured_requests[0]
    assert req.url.path == "/api/v1/delegations"
    data = httpx.Response(200, content=req.content).json()
    assert data["delegate_actor_id"] == "agent-007"
    assert data["principal_actor_id"] == "human-operator-1"
    assert data["authz_ref"] == "claim-abc"
    assert data["capabilities"] == ["agent:operate", "agent:inspect"]
    assert data["containment_claims"] == ["containment:landlock"]


def test_sync_claim_delegation_nono_auto_landlock() -> None:
    captured_requests = []

    def handle_request(request: httpx.Request) -> httpx.Response:
        captured_requests.append(request)
        return httpx.Response(200, json={"status": "ok"})

    transport = httpx.MockTransport(handle_request)
    with patch("httpx.AsyncClient", return_value=httpx.AsyncClient(transport=transport)):
        ok = asyncio.run(
            sync_claim_delegation_to_spine(
                agent_id="agent-nono-worker-01",
                operator_id="human-operator-1",
                claim_id="claim-nono",
            )
        )
    assert ok is True
    assert len(captured_requests) == 1
    data = httpx.Response(200, content=captured_requests[0].content).json()
    assert data["containment_claims"] == ["containment:landlock"]


def test_sync_claim_delegation_graceful_failure() -> None:
    def handle_request(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "spine db down"})

    transport = httpx.MockTransport(handle_request)
    with patch("httpx.AsyncClient", return_value=httpx.AsyncClient(transport=transport)):
        ok = asyncio.run(
            sync_claim_delegation_to_spine(
                agent_id="agent-007",
                operator_id="human-operator-1",
                claim_id="claim-abc",
            )
        )
    assert ok is False


def test_clamp_claim_delegation_success() -> None:
    captured_requests = []

    def handle_request(request: httpx.Request) -> httpx.Response:
        captured_requests.append(request)
        return httpx.Response(200, json={"status": "clamped"})

    transport = httpx.MockTransport(handle_request)
    with patch("httpx.AsyncClient", return_value=httpx.AsyncClient(transport=transport)):
        ok = asyncio.run(
            clamp_claim_delegation_in_spine(
                agent_id="agent-007",
                claim_id="claim-abc",
            )
        )
    assert ok is True
    assert len(captured_requests) == 1
    req = captured_requests[0]
    assert req.url.path == "/api/v1/delegations/clamp"
    data = httpx.Response(200, content=req.content).json()
    assert data["delegate_actor_id"] == "agent-007"
    assert data["authz_ref"] == "claim-abc"


def test_api_claim_delegation_roundtrip(client: TestClient) -> None:
    # 1. Unauthenticated claim fails 401
    payload = {
        "pod_name": "agent-worker-42",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-worker-42",
        "capabilities": ["agent:operate"],
    }
    unauth_resp = client.post("/api/v1/agents/claim", json=payload)
    assert unauth_resp.status_code == 401

    # 2. Authenticated claim triggers spine sync with caller principal actor
    sync_mock = AsyncMock(return_value=True)
    clamp_mock = AsyncMock(return_value=True)

    with patch("api_compat.sync_claim_delegation_to_spine", sync_mock), \
         patch("api_compat.clamp_claim_delegation_in_spine", clamp_mock):
        resp = client.post("/api/v1/agents/claim", json=payload, headers=_bearer())
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "granted"
        claim_id = data["claim_id"]
        agent_id = data["agent_id"]

        sync_mock.assert_awaited_once()
        call_kwargs = sync_mock.await_args.kwargs
        assert call_kwargs["agent_id"] == agent_id
        assert call_kwargs["operator_id"] == ALICE_EMAIL
        assert call_kwargs["claim_id"] == claim_id
        assert call_kwargs["capabilities"] == ["agent:operate"]

        # 3. Release claim triggers spine clamp
        del_resp = client.delete(f"/api/v1/agents/claim/{claim_id}", headers=_bearer())
        assert del_resp.status_code == 200
        assert del_resp.json()["status"] == "released"

        clamp_mock.assert_awaited_once()
        clamp_kwargs = clamp_mock.await_args.kwargs
        assert clamp_kwargs["agent_id"] == agent_id
        assert clamp_kwargs["claim_id"] == claim_id


def test_api_claim_delegation_explicit_operator(client: TestClient) -> None:
    sync_mock = AsyncMock(return_value=True)

    payload = {
        "pod_name": "agent-worker-custom",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-worker-custom",
        "operator_id": "custom-operator-principal",
        "capabilities": ["agent:operate", "agent:read"],
        "containment_claims": ["containment:landlock"],
    }

    with patch("api_compat.sync_claim_delegation_to_spine", sync_mock):
        resp = client.post("/api/v1/agents/claim", json=payload, headers=_bearer())
        assert resp.status_code == 200
        data = resp.json()
        claim_id = data["claim_id"]
        agent_id = data["agent_id"]

        sync_mock.assert_awaited_once()
        call_kwargs = sync_mock.await_args.kwargs
        assert call_kwargs["agent_id"] == agent_id
        assert call_kwargs["operator_id"] == "custom-operator-principal"
        assert call_kwargs["claim_id"] == claim_id
        assert call_kwargs["capabilities"] == ["agent:operate", "agent:read"]
        assert call_kwargs["containment_claims"] == ["containment:landlock"]
