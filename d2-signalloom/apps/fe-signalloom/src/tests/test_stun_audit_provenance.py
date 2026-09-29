"""No field of a stun's audit row may originate from the client -- except ``reason``.

``test_agent_stun.py`` asserts that the row is written, attributable and
readable. This file asserts something narrower and, for an audit trail, prior:
where each field came from.

The stun endpoint was once shaped as a recording service. The browser supplied
``agent_name``, ``reason`` and the ``outcome`` itself, which the handler copied
into ``detail`` and returned as though the server had established them. An
audit row assembled from the narrative of the party being audited is not
evidence of anything.

One field has since come back, deliberately. The stun now drives
fleet-manager's containment cascade, which needs the operator's justification,
so ``{"reason": "..."}`` is a required body. It is recorded as exactly what it
is -- a statement by the authenticated ``actor`` under ``detail.reason`` -- and
nowhere else. Every other field a caller might author is refused with a 422 and
leaves no row, which is asserted directly rather than inferred from absence.
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

# Own tenant: the in-memory stores are module-level and outlive a single test.
SUBJECT_TENANTS = {"stun-provenance": "tenant-stun-provenance"}
TENANT = "tenant-stun-provenance"
SUBJECT = "stun-provenance"
AGENT_ID = f"{TENANT}:agent-1"


def _bearer(subject: str = SUBJECT) -> dict[str, str]:
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


class _FakeProxy:
    """A SuperCred proxy that succeeds, so a row actually gets written.

    Load-bearing rather than scaffolding. Without it the endpoint's outbound
    call fails DNS, the stun answers 502 and records nothing -- at which point
    every "the client's value is not in the row" assertion below passes because
    there is no row, which is the most comfortable way for this whole file to
    be worthless. ``test_a_row_was_written_at_all`` is the control that catches
    that, and the values here are deliberately unlike the ones the tests send.
    """

    def __init__(self) -> None:
        self.observation = api_compat._ClusterStunObservation(
            observed=True,
            overall_outcome="contained",
            fleet_agent_id="agent-under-test",
            fleet_manager_status=200,
            error=None,
        )

    async def __call__(self, agent_id: str, reason: str) -> Any:
        return self.observation


@pytest.fixture
def proxy() -> _FakeProxy:
    return _FakeProxy()


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch, proxy: _FakeProxy) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    monkeypatch.setattr(api_compat, "_perform_cluster_stun", proxy)

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


STUN_REASON = "operator isolated the agent pending review"


def _stun(client: TestClient, **body: Any) -> Any:
    body.setdefault("reason", STUN_REASON)
    return client.post(f"/api/agents/{AGENT_ID}/stun", json=body, headers=_bearer())


def _recorded_stuns(client: TestClient) -> list[dict[str, Any]]:
    """What the audit trail actually holds, not what the response claimed.

    Read back through ``GET /api/audit`` rather than trusting the stun
    response body, because the response is a courtesy copy and the row is the
    artefact. A regression that sanitised one and not the other would pass an
    assertion made against the response alone.
    """
    events = client.get("/api/audit", headers=_bearer()).json()["events"]
    return [e for e in events if e["event_type"] == "agent.stunned"]


def _persisted_text(client: TestClient) -> str:
    """Every stun row flattened to a string, for "appears nowhere" assertions.

    Blunt on purpose. A client value that survives into some field nobody
    thought to name is the failure this file exists to catch, so the assertion
    does not depend on guessing which field that would be.
    """
    return repr(_recorded_stuns(client))


CLIENT_AUTHORED = "client-authored-value-that-must-not-be-recorded"


def test_a_row_was_written_at_all(client: TestClient) -> None:
    """The control for every "appears nowhere" assertion in this file.

    "The client's value is not in the row" is trivially true when there is no
    row. If this test fails, the rest of the file is not testing provenance --
    it is testing that a stun failed -- and its passes mean nothing.
    """
    response = _stun(client)

    assert response.status_code == 200, response.text
    assert len(_recorded_stuns(client)) == 1


def test_the_client_supplied_reason_is_recorded_only_as_reason(client: TestClient) -> None:
    """The operator's justification lands in ``reason`` and nowhere else.

    If it leaked into ``agent_name``, ``actor`` or an outcome field, the caller
    would be authoring a finding rather than stating a reason.
    """
    response = _stun(client, reason=CLIENT_AUTHORED)

    assert response.status_code == 200, response.text
    row = _recorded_stuns(client)[0]
    assert row["detail"]["reason"] == CLIENT_AUTHORED
    assert row["actor"] == SUBJECT
    without_reason = dict(row, detail={k: v for k, v in row["detail"].items() if k != "reason"})
    assert CLIENT_AUTHORED not in repr(without_reason)


@pytest.mark.parametrize("field", ["outcome", "overall_outcome", "agent_name", "namespace", "actor", "planes"])
def test_any_other_client_field_is_refused_and_leaves_no_row(client: TestClient, field: str) -> None:
    """Refused, not silently dropped, so a client learns its field is not taken.

    ``outcome`` is the worst of these: the client stating the result of the
    action. ``agent_name`` would let a request rename the subject of its own
    record; ``actor`` would let it claim someone else did it.
    """
    response = _stun(client, **{field: CLIENT_AUTHORED})

    assert response.status_code == 422, response.text
    assert field in response.json()["error"]["message"]
    assert _recorded_stuns(client) == []
    assert CLIENT_AUTHORED not in _persisted_text(client)


def test_the_actor_is_the_token_subject(client: TestClient) -> None:
    """Asserted positively: "is not the client's value" passes against any
    other hardcoded string, including a ``demo-actor`` constant."""
    response = _stun(client)

    assert response.status_code == 200, response.text
    recorded = _recorded_stuns(client)
    assert recorded, "the stun recorded nothing at all"
    assert recorded[0]["actor"] == SUBJECT


def test_a_stun_with_no_body_is_refused_and_leaves_no_row(client: TestClient) -> None:
    bare = client.post(f"/api/agents/{AGENT_ID}/stun", headers=_bearer())

    assert bare.status_code == 422, bare.text
    assert "reason" in bare.json()["error"]["message"]
    assert _recorded_stuns(client) == []


def test_the_reason_does_not_change_which_fields_the_row_carries(client: TestClient) -> None:
    """The row must not be shaped by what the caller chose to say."""
    _stun(client, reason="first reason")
    first_keys = set(_recorded_stuns(client)[0]["detail"])

    api_compat.reset_tenant_state(TENANT)
    _stun(client, reason="a completely different and much longer second reason")
    second_keys = set(_recorded_stuns(client)[0]["detail"])

    assert first_keys == second_keys
