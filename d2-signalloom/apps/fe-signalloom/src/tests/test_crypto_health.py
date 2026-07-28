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
def client_for(monkeypatch: pytest.MonkeyPatch, async_client_cls):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: TestJWKClient())
    monkeypatch.setattr(api_compat.httpx, "AsyncClient", async_client_cls)

    def reject_external_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in crypto health tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(ReadyPool())

    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


class FakeCryptoHealthResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self):
        return self._payload


def test_crypto_health_maps_proxy_payload_to_compat_response(monkeypatch):
    requested_urls: list[str] = []
    positive_proof = {
        "name": "rekor-inclusion",
        "kind": "positive",
        "status": "passed",
        "title": "Rekor inclusion proof",
        "description": "Transparency entry exists",
        "expectation": "Proof should verify against Rekor",
        "evidence": "uuid=1234",
    }
    negative_proof = {
        "name": "signature-freshness",
        "kind": "negative",
        "status": "failed",
        "title": "Signature freshness window",
        "description": "Signature exceeded freshness threshold",
        "expectation": "Signature should be recent",
        "evidence": "age=49h",
    }

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            assert kwargs["timeout"] == 5.0

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str) -> FakeCryptoHealthResponse:
            requested_urls.append(url)
            return FakeCryptoHealthResponse(
                {
                    "proofs": [positive_proof, negative_proof],
                    "namespace": "fe-signalloom",
                }
            )

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.get("/api/health/crypto", headers=bearer(token_for()))

    assert requested_urls == [api_compat.CRYPTO_HEALTH_URL]
    assert response.status_code == 200
    body = response.json()
    assert body["tenant_id"] == "tenant-a"
    assert len(body["proofs"]) == 2
    proof = body["proofs"][0]
    assert proof["name"] == positive_proof["name"]
    assert proof["kind"] == positive_proof["kind"]
    assert proof["status"] == positive_proof["status"]
    assert proof["title"] == positive_proof["title"]
    assert proof["description"] == positive_proof["description"]
    assert proof["expectation"] == positive_proof["expectation"]
    assert proof["evidence"] == positive_proof["evidence"]


def test_crypto_health_returns_empty_list_when_proxy_fails(monkeypatch):
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
        response = client.get("/api/health/crypto", headers=bearer(token_for()))

    assert response.status_code == 200
    assert response.json() == {"tenant_id": "tenant-a", "proofs": []}
