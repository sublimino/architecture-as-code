"""GET /api/v1/auth/check: the dashboard nginx gate for /fleet-api/.

Exact status for every caller class, against the real JWT validation and the
real superadmin allowlist. Nothing here reaches the network.
"""

from __future__ import annotations

import time
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ADMIN = "fleet-operator"
VIEWER = "viewer"


def _token(subject: str, key: Any = KEY, exp_in: int = 300, aud: str = "signalloom-api") -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": "https://issuer.test/dex", "aud": aud, "iat": now, "nbf": now, "exp": now + exp_in,
         "azp": "signalloom-dashboard", "sub": subject},
        key, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"},
    )


class _ReadyPool:
    async def close(self) -> None:
        pass


class _JWKs:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        return SimpleNamespace(key=KEY.public_key())


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {ADMIN: "tenant-demo", VIEWER: "tenant-demo"})
    monkeypatch.setattr(settings, "api_superadmin_subjects", {ADMIN})
    monkeypatch.setattr(settings, "api_superadmin_emails", set())
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWKs())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        set_pool_for_testing(None)


def _check(client: TestClient, *auth: str) -> int:
    headers = [("authorization", a) for a in auth]
    return client.get("/api/v1/auth/check", headers=headers).status_code


def test_a_superadmin_token_passes_with_204(client: TestClient) -> None:
    response = client.get("/api/v1/auth/check", headers={"Authorization": f"Bearer {_token(ADMIN)}"})
    assert response.status_code == 204
    assert response.content == b""


def test_a_valid_non_superadmin_is_403(client: TestClient) -> None:
    assert _check(client, f"Bearer {_token(VIEWER)}") == 403


@pytest.mark.parametrize("auth", [
    (),
    ("Bearer ",),
    ("Basic Zm9vOmJhcg==",),
    ("Bearer not-a-jwt",),
], ids=["no-header", "empty-bearer", "basic", "garbage"])
def test_no_valid_token_is_401(client: TestClient, auth: tuple[str, ...]) -> None:
    assert _check(client, *auth) == 401


def test_a_forged_superadmin_token_is_401(client: TestClient) -> None:
    assert _check(client, f"Bearer {_token(ADMIN, key=OTHER_KEY)}") == 401


def test_an_expired_superadmin_token_is_401(client: TestClient) -> None:
    assert _check(client, f"Bearer {_token(ADMIN, exp_in=-60)}") == 401


def test_a_superadmin_token_for_another_audience_is_401(client: TestClient) -> None:
    assert _check(client, f"Bearer {_token(ADMIN, aud='some-other-api')}") == 401


def test_the_gate_answers_get_only(client: TestClient) -> None:
    response = client.post("/api/v1/auth/check", headers={"Authorization": f"Bearer {_token(ADMIN)}"})
    assert response.status_code == 405
