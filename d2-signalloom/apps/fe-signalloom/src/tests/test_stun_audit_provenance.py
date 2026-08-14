"""No field of a stun's audit row may originate from the client.

``test_agent_stun.py`` asserts that the row is written, attributable and
readable. This file asserts something narrower and, for an audit trail, prior:
where each field came from.

The stun endpoint was shaped as a recording service. Its request model said so
in its own docstring -- "context the dashboard supplies when it records a stun"
-- and the browser duly supplied ``agent_name``, ``reason`` and the ``outcome``
itself, which the handler copied into ``detail`` and returned as though the
server had established them. An audit row assembled from the narrative of the
party being audited is not evidence of anything; it is that party's account,
stored somewhere authoritative-looking. The transaction around it was
impeccable, which is what made it dangerous.

These assertions are deliberately written to hold whichever way the endpoint
is reshaped -- whether it performs the cluster action itself and audits what it
observed, or records only what it can verify and drops the narrative. In both
designs the client-supplied value must not appear in the row. So each test
sends a value a caller could author and asserts it is nowhere in what was
persisted, rather than asserting a particular rejection mechanism. A 422 and a
silent drop both satisfy the invariant; a value that survives satisfies
neither.
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
            observed=True, outcome="stunned", namespace="fe-signalloom",
            proxy_status=200, error=None,
        )

    async def __call__(self, agent_id: str) -> Any:
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


def _stun(client: TestClient, **body: Any) -> Any:
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
    response = _stun(client, reason=CLIENT_AUTHORED)

    assert response.status_code == 200, response.text
    assert len(_recorded_stuns(client)) == 1


def test_a_client_supplied_reason_never_reaches_the_row(client: TestClient) -> None:
    """``reason`` was the narrative field, defaulted to a server string.

    The handler read ``req.reason or "operator-initiated stun"``, so the row's
    account of *why* an agent was cut off came from the caller whenever the
    caller cared to supply one.
    """
    _stun(client, reason=CLIENT_AUTHORED)

    assert CLIENT_AUTHORED not in _persisted_text(client)


def test_a_client_supplied_outcome_never_reaches_the_row(client: TestClient) -> None:
    """The worst of the four: the client stating the result of the action.

    Nothing server-side ever checked it. A caller could report a successful
    stun of an agent that was never touched, and the row would carry it under
    a field named ``outcome``.
    """
    _stun(client, outcome=CLIENT_AUTHORED)

    assert CLIENT_AUTHORED not in _persisted_text(client)


def test_a_client_supplied_agent_name_never_reaches_the_row(client: TestClient) -> None:
    """The registry knows the agent's name; the caller merely asserts one.

    ``req.agent_name or (row and row["name"])`` preferred the caller's value
    over the database's, so a request could rename the subject of its own
    audit record.
    """
    _stun(client, agent_name=CLIENT_AUTHORED)

    assert CLIENT_AUTHORED not in _persisted_text(client)


def test_a_client_supplied_namespace_never_reaches_the_row(client: TestClient) -> None:
    """Where the workload lives is observable server-side or not at all."""
    _stun(client, namespace=CLIENT_AUTHORED)

    assert CLIENT_AUTHORED not in _persisted_text(client)


def test_the_actor_is_the_token_subject(client: TestClient) -> None:
    """Asserted positively, and the positive control for the test below.

    "actor is not the client's value" passes against any other hardcoded
    string, including the ``demo-actor`` constant that makes several fixture
    rows unattributable.
    """
    response = client.post(f"/api/agents/{AGENT_ID}/stun", headers=_bearer())

    assert response.status_code == 200, response.text
    recorded = _recorded_stuns(client)
    assert recorded, "the stun recorded nothing at all"
    assert recorded[0]["actor"] == SUBJECT


def test_a_body_that_names_an_actor_cannot_set_one(client: TestClient) -> None:
    """The identity field, which no request has ever been allowed to author.

    Stated as "appears nowhere persisted" rather than as a status code, so it
    holds whether the endpoint refuses the field or ignores it.
    """
    _stun(client, actor=CLIENT_AUTHORED)

    assert CLIENT_AUTHORED not in _persisted_text(client)


def test_a_stun_with_no_body_records_the_same_fields_as_one_with_a_body(
    client: TestClient,
) -> None:
    """The row must not be shaped by what the caller chose to say.

    If a body changes which fields the row carries, then the body is still
    steering the record even when none of its values survive verbatim.
    """
    bare = client.post(f"/api/agents/{AGENT_ID}/stun", headers=_bearer())
    assert bare.status_code == 200, bare.text
    bare_keys = set(_recorded_stuns(client)[0]["detail"])

    api_compat.reset_tenant_state(TENANT)
    _stun(client, reason=CLIENT_AUTHORED, outcome=CLIENT_AUTHORED)
    with_body_keys = set(_recorded_stuns(client)[0]["detail"])

    assert bare_keys == with_body_keys
