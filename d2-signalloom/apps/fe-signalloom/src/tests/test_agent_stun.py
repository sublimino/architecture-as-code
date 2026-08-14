"""Pressing Stun must leave a record on the audit trail.

The SuperCred proxy owns the cluster-side action -- relabel the pod, revoke the
OpenBao lease -- and holds no database. So the durable record of an operator
isolating an agent lives here, in ``POST /api/agents/{id}/stun``: the lifecycle
change and its ``audit_events`` row, written together.

Two things are asserted, and they are different claims:

* the event is *written* with everything an auditor needs -- when, which agent,
  what action, who did it, what the outcome was; and
* the event is *readable* through ``GET /api/audit``, which is the endpoint the
  Audit Trail page actually calls. An event written to a store nothing reads
  back is not a trail.

The transactional half of the guarantee -- that the state change and the audit
row commit or roll back together -- is in ``test_write_transactions.py``, which
already owns the fake Postgres that can prove it.

This file drives the in-memory (``pool is None``) path, which is what the API
serves when no database is configured, so it needs no Postgres to run.
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

# The in-memory stores are module-level and outlive individual tests, so this
# file owns a tenant no other test file writes to.
SUBJECT_TENANTS = {"stun": "tenant-stun"}
TENANT = "tenant-stun"
AGENT_ID = f"{TENANT}:agent-1"


def _bearer(subject: str = "stun") -> dict[str, str]:
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

    # The stores outlive a test; start every case from a clean tenant.
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


# ---------------------------------------------------------------------------
# The event is written
# ---------------------------------------------------------------------------

def test_stunning_an_agent_returns_the_audit_event_it_recorded(client: TestClient) -> None:
    response = _stun(client, reason="compliance-failure: securityContext not set")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["agent_id"] == AGENT_ID
    assert body["to_state"] == "suspended"
    event = body["event"]
    assert event["event_type"] == "agent.stunned"
    assert event["agent_id"] == AGENT_ID
    # The token subject, not a constant. Asserted positively: "is not
    # demo-actor" would pass against any other hardcoded string.
    assert event["actor"] == "stun"
    assert event["timestamp"]


def test_the_event_carries_the_outcome_and_the_reason(client: TestClient) -> None:
    response = _stun(
        client,
        reason="compliance-failure: securityContext not set",
        outcome="stunned",
        namespace="fe-signalloom",
    )

    detail = response.json()["event"]["detail"]
    assert detail["outcome"] == "stunned"
    assert detail["reason"] == "compliance-failure: securityContext not set"
    assert detail["namespace"] == "fe-signalloom"
    assert detail["from_state"] == "active"
    assert detail["to_state"] == "suspended"


def test_a_stun_with_no_body_still_records_an_attributable_event(client: TestClient) -> None:
    """The dashboard sends context, but an event must never depend on it."""
    response = client.post(f"/api/agents/{AGENT_ID}/stun", headers=_bearer())

    assert response.status_code == 200, response.text
    event = response.json()["event"]
    assert event["event_type"] == "agent.stunned"
    # The token subject, not a constant. Asserted positively: "is not
    # demo-actor" would pass against any other hardcoded string.
    assert event["actor"] == "stun"
    assert event["detail"]["outcome"] == "stunned"


def test_the_agent_is_left_suspended(client: TestClient) -> None:
    _stun(client)

    agent = client.get(f"/api/agents/{AGENT_ID}", headers=_bearer()).json()
    assert agent["lifecycle_state"] == "suspended"


def test_the_recorded_from_state_is_the_state_the_agent_was_actually_in(
    client: TestClient,
) -> None:
    """A from_state guessed rather than read is a fabricated audit record."""
    client.post(
        f"/api/agents/{AGENT_ID}/transition",
        json={"to_state": "registered", "reason": "test setup"},
        headers=_bearer(),
    )

    detail = _stun(client).json()["event"]["detail"]
    assert detail["from_state"] == "registered"


def test_stunning_a_pod_the_registry_does_not_know_still_records(client: TestClient) -> None:
    """SuperCred agent ids are Kubernetes pod names, not registry UUIDs.

    An enforcement action against a workload with no registry row is exactly the
    case where the trail matters most; dropping the event because the id does
    not resolve would lose it silently.
    """
    response = client.post(
        "/api/agents/agent-cardvault/stun",
        json={"agent_name": "Cardvault Agent"},
        headers=_bearer(),
    )

    assert response.status_code == 200, response.text
    event = response.json()["event"]
    assert event["event_type"] == "agent.stunned"
    assert event["agent_name"] == "Cardvault Agent"
    assert event["detail"]["agent_ref"] == "agent-cardvault"


def test_an_unresolved_pod_records_no_state_it_did_not_observe(
    client: TestClient,
) -> None:
    """The row must not name a transition that did not happen.

    ``agent-cardvault`` is a pod name, so it never resolves to a store entry.
    Nothing is read and nothing is updated -- yet the event used to record
    ``from_state: "active"`` and ``to_state: "suspended"``, asserting a
    transition between two states of which neither was observed and the second
    of which was never reached.

    That is worse than recording nothing. A missing row prompts the question;
    this row answers it wrongly, and it is the demo's headline event. The panel
    hardcodes ``agent-cardvault``, so this is the branch every run takes.

    What is true and worth recording: a stun was requested, against an id the
    registry does not hold, and the registry state is therefore unchanged.
    """
    response = client.post(
        "/api/agents/agent-cardvault/stun",
        json={"agent_name": "Cardvault Agent"},
        headers=_bearer(),
    )

    detail = response.json()["event"]["detail"]
    assert detail["from_state"] == "unknown", (
        "recorded a prior state for an agent it never read"
    )
    assert detail["to_state"] == "unchanged", (
        "claimed a transition that no update performed"
    )
    # What was asked for is still worth keeping -- it is simply not the same
    # claim as what was observed, and the two must not be conflated.
    assert detail["requested_state"] == "suspended"
    assert detail["registry_match"] is False


def test_a_resolved_agent_still_records_the_states_it_did_observe(
    client: TestClient,
) -> None:
    """The positive control for the test above.

    Making the unresolved case honest is only worth anything if the resolved
    case still records the real transition -- otherwise the fix has bought
    truthfulness by making the record useless.
    """
    detail = _stun(client).json()["event"]["detail"]

    assert detail["from_state"] == "active"
    assert detail["to_state"] == "suspended"
    assert detail["registry_match"] is True


# ---------------------------------------------------------------------------
# The event is readable on the timeline
# ---------------------------------------------------------------------------

def test_the_event_appears_on_the_audit_timeline(client: TestClient) -> None:
    before = client.get("/api/audit", headers=_bearer()).json()

    _stun(client, reason="compliance-failure")

    after = client.get("/api/audit", headers=_bearer()).json()
    assert after["total"] == before["total"] + 1
    # Newest first -- a fresh enforcement action belongs at the top.
    assert after["events"][0]["event_type"] == "agent.stunned"
    assert after["events"][0]["agent_id"] == AGENT_ID


def test_the_timeline_can_be_filtered_down_to_stuns(client: TestClient) -> None:
    _stun(client)

    filtered = client.get(
        "/api/audit", params={"type": "agent.stunned"}, headers=_bearer(),
    ).json()

    assert filtered["total"] == 1
    assert [e["event_type"] for e in filtered["events"]] == ["agent.stunned"]


def test_the_timeline_can_be_filtered_down_to_one_agent(client: TestClient) -> None:
    _stun(client)
    client.post(
        "/api/agents/agent-cardvault/stun",
        json={"agent_name": "Cardvault Agent"},
        headers=_bearer(),
    )

    filtered = client.get(
        "/api/audit", params={"agent": "agent-cardvault"}, headers=_bearer(),
    ).json()

    assert [e["agent_name"] for e in filtered["events"]] == ["Cardvault Agent"]


def test_the_seeded_history_survives_alongside_the_new_event(client: TestClient) -> None:
    _stun(client)

    types = [e["event_type"] for e in client.get("/api/audit", headers=_bearer()).json()["events"]]
    assert "agent.stunned" in types
    assert "agent.created" in types


def test_events_recorded_for_one_tenant_do_not_leak_into_another(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        settings, "api_subject_tenants", {"stun": TENANT, "other": "tenant-stun-other"},
    )
    api_compat.reset_tenant_state("tenant-stun-other")
    try:
        _stun(client)

        other = client.get("/api/audit", headers=_bearer("other")).json()
        assert [e["event_type"] for e in other["events"]].count("agent.stunned") == 0
    finally:
        api_compat.reset_tenant_state("tenant-stun-other")
