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
        raise AssertionError("external network access is forbidden in network test tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(ReadyPool())

    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


class FakeJsonResponse:
    def __init__(self, payload, status_code: int = 200):
        self._payload = payload
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise httpx.HTTPStatusError("error", request=httpx.Request("GET", "http://test"), response=self)  # type: ignore[arg-type]

    def json(self):
        return self._payload


ONE_TEST = {
    "name": "dashboard-to-api-allowed",
    "expectedExit": 0,
    "targetPort": 8000,
    "src": {"namespace": "fe-signalloom", "name": "dashboard-signalloom"},
    "dst": {"namespace": "fe-signalloom", "name": "fe-signalloom"},
    "description": "Dashboard to API backend (nginx /api proxy)",
    "result": "pass",
    "evidence": "netassert TAP: ok - dashboard-to-api-allowed",
    "lastRun": "2026-08-02T10:00:00Z",
}


def test_network_tests_proxies_the_proxy_payload(monkeypatch):
    requested_urls: list[str] = []

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            assert kwargs["timeout"] == 5.0

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str) -> FakeJsonResponse:
            requested_urls.append(url)
            return FakeJsonResponse(
                {
                    "tests": [ONE_TEST],
                    "scanStatus": "complete",
                    "job": {"name": "netassert-run"},
                }
            )

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.get("/api/network-tests", headers=bearer(token_for()))

    assert requested_urls == [api_compat.NETWORK_TESTS_URL]
    assert response.status_code == 200
    body = response.json()
    assert body["scanStatus"] == "complete"
    assert body["job"] == {"name": "netassert-run"}
    assert body["tests"][0]["name"] == "dashboard-to-api-allowed"
    assert body["tests"][0]["result"] == "pass"


def test_network_tests_returns_502_rather_than_an_empty_board_when_the_proxy_is_unreachable(monkeypatch):
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
        response = client.get("/api/network-tests", headers=bearer(token_for()))

    # 502, not a 200 with an empty list — an unreachable runner must not read
    # the same as "zero network tests configured".
    assert response.status_code == 502


def test_network_tests_scan_forwards_the_202_and_job_name(monkeypatch):
    requested_urls: list[str] = []

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            assert kwargs["timeout"] == 10.0

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def post(self, url: str) -> FakeJsonResponse:
            requested_urls.append(url)
            return FakeJsonResponse({"job": "netassert-run", "status": "started"}, status_code=202)

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.post("/api/network-tests/scan", headers=bearer(token_for()))

    assert requested_urls == [api_compat.NETWORK_TESTS_SCAN_URL]
    assert response.status_code == 202
    assert response.json() == {"job": "netassert-run", "status": "started"}


def test_network_tests_scan_forwards_a_409_when_a_scan_is_already_running(monkeypatch):
    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def post(self, url: str) -> FakeJsonResponse:
            return FakeJsonResponse({"error": "a network test scan is already running"}, status_code=409)

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.post("/api/network-tests/scan", headers=bearer(token_for()))

    assert response.status_code == 409
    assert "already running" in response.json()["error"]


def test_network_tests_scan_ignores_client_input_entirely(monkeypatch):
    """The dashboard route takes no body; confirm the compat layer never
    forwards request data to the runner (there is nothing to forward)."""
    calls: list[tuple] = []

    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def post(self, url: str) -> FakeJsonResponse:
            calls.append((url,))
            return FakeJsonResponse({"job": "netassert-run", "status": "started"}, status_code=202)

    with client_for(monkeypatch, FakeAsyncClient) as client:
        response = client.post(
            "/api/network-tests/scan",
            headers=bearer(token_for()),
            json={"target": "10.0.0.1", "namespace": "kube-system"},
        )

    assert response.status_code == 202
    assert calls == [(api_compat.NETWORK_TESTS_SCAN_URL,)]
