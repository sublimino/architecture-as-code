"""A reassessment request must not imply a reassessment was queued.

``POST /agents/{id}/compliance/{control_id}/reassess`` performs no state change
of any kind -- no INSERT, no UPDATE, no outbound call. It writes
``compliance.reassess_requested`` and returns ``status:
"reassessment_requested"`` with ``clickup_task_id: None``. Nothing was
requested of anything.

Its audit fields were all server-sourced, so it never breached the
no-client-authored-fields rule. The problem is the other half of the same
principle: a row must not assert what its writer did not observe. The writer
observed an operator asking. It did not observe anything being scheduled,
because nothing was.

Two fixes, neither of which invents a queue that does not exist:

* The row now says plainly that nothing was dispatched, so a reader is not left
  to infer it from the absence of a field.
* It is written on the fixture path too. Previously the no-database branch
  recorded nothing at all, so the deployment most likely to be running was the
  one with no record -- the same shape as the demo runner's defect.
"""
from __future__ import annotations

import socket
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

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

SUBJECT_TENANTS = {"reassess": "tenant-reassess"}
TENANT = "tenant-reassess"
AGENT_ID = f"{TENANT}:agent-1"
ENDPOINT = f"/api/agents/{AGENT_ID}/compliance/eu-ai-act:art-9/reassess"


def _bearer() -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": "reassess",
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

    api_compat.reset_tenant_state(TENANT)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT)


def _reassess_events(client: TestClient) -> list[dict[str, Any]]:
    events = client.get("/api/audit", headers=_bearer()).json()["events"]
    # Filtered on the actor, because the tenant seed already contains a
    # `compliance.reassess_requested` fixture attributed to "demo-actor".
    # Matching on event_type alone counts the seed and passes before the fix.
    return [e for e in events if e["event_type"] == "compliance.reassess_requested"
            and e["actor"] == "reassess"]


def test_the_request_is_recorded_without_a_database(client: TestClient) -> None:
    """The fixture path recorded nothing at all.

    That is the deployment most likely to be running, so the branch with no
    record was the branch in use -- the same shape as the demo runner's defect
    one service over.
    """
    response = client.post(ENDPOINT, headers=_bearer())

    assert response.status_code == 200, response.text
    assert len(_reassess_events(client)) == 1, "no record of the request"


def test_the_row_says_nothing_was_dispatched(client: TestClient) -> None:
    """Stated, not left to be inferred from a missing field.

    Nothing is queued, scheduled or sent. A reader of this row should not have
    to know that to avoid concluding the opposite.
    """
    client.post(ENDPOINT, headers=_bearer())

    detail = _reassess_events(client)[0]["detail"]
    assert detail["dispatched"] is False
    assert detail["control_id"] == "eu-ai-act:art-9"


def test_the_actor_is_the_token_subject(client: TestClient) -> None:
    client.post(ENDPOINT, headers=_bearer())

    assert _reassess_events(client)[0]["actor"] == "reassess"
