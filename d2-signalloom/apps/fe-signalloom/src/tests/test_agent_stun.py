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
import uuid
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


class _FakeProxy:
    """The SuperCred proxy, stubbed at the seam the API calls it through.

    The endpoint performs the cluster action now rather than being told about
    it, so every test in this file drives an outbound call. Stubbing
    ``_perform_cluster_stun`` keeps that call off the network -- ``socket``
    is poisoned below, and a test that reached for a real proxy would fail
    with a DNS error rather than anything about audit records.

    Defaults to the payload the real proxy returns on success, so a test that
    does not care about the cluster half gets the ordinary case.
    """

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.observation = api_compat._ClusterStunObservation(
            observed=True, outcome="stunned", namespace="fe-signalloom",
            proxy_status=200, error=None,
        )

    async def __call__(self, agent_id: str) -> Any:
        self.calls.append(agent_id)
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


def test_the_outcome_and_namespace_come_from_the_proxy(
    client: TestClient, proxy: _FakeProxy,
) -> None:
    """Both used to be supplied by the browser and copied through.

    They are now read off the response to the call this API made itself, which
    is the difference between a record and a transcript. The values here are
    distinctive so the assertion cannot pass against a hardcoded default.
    """
    proxy.observation = api_compat._ClusterStunObservation(
        observed=True, outcome="stunned", namespace="fe-signalloom-agents",
        proxy_status=200, error=None,
    )

    detail = _stun(client).json()["event"]["detail"]

    assert detail["proxy"]["outcome"] == "stunned"
    assert detail["proxy"]["namespace"] == "fe-signalloom-agents"
    assert detail["proxy"]["observed"] is True
    assert detail["from_state"] == "active"
    assert detail["to_state"] == "suspended"


def test_the_reason_is_server_authored(client: TestClient) -> None:
    """``reason`` was the narrative field the caller filled in.

    It survives because how an isolation was initiated is worth recording, but
    the value is now this API's own and says only what this API knows.
    """
    detail = _stun(client, reason="whatever the caller would like it to say").json()["event"]["detail"]

    assert detail["reason"] == "operator-initiated stun via governance API"


def test_a_stun_records_an_attributable_event(client: TestClient) -> None:
    response = client.post(f"/api/agents/{AGENT_ID}/stun", headers=_bearer())

    assert response.status_code == 200, response.text
    event = response.json()["event"]
    assert event["event_type"] == "agent.stunned"
    # The token subject, not a constant. Asserted positively: "is not
    # demo-actor" would pass against any other hardcoded string.
    assert event["actor"] == "stun"
    assert event["detail"]["proxy"]["outcome"] == "stunned"


# ---------------------------------------------------------------------------
# The API performs the action it audits
# ---------------------------------------------------------------------------

def test_the_proxys_account_is_nested_and_not_flattened(
    client: TestClient, proxy: _FakeProxy,
) -> None:
    """The contract the dashboard codes against, pinned.

    Flattening would merge what this API established with what the proxy said
    into one namespace, and nothing downstream could separate them again --
    which is the property that deleting the client's ``reason`` and ``outcome``
    was meant to restore.

    Asserted as a test because the failure mode is silent: a dashboard reading
    a flat field that moved under ``proxy`` renders ``undefined`` in display
    text and nothing raises. A 422 at least shouts; this would not.
    """
    proxy.observation = api_compat._ClusterStunObservation(
        observed=True, outcome="stunned", namespace="fe-signalloom",
        proxy_status=200, error=None,
        payload={"state": "stunned", "stunned_at": "2026-01-01T00:00:00Z",
                 "message": "credentials revoked"},
    )

    body = _stun(client).json()

    # First-party: established here, from the token, the path and this database.
    assert set(body) >= {"agent_id", "from_state", "to_state", "actor", "stunned_at"}
    # Second-hand: everything the proxy said, in one place and only there.
    assert body["proxy"]["payload"]["message"] == "credentials revoked"
    assert body["proxy"]["observed"] is True
    for leaked in ("outcome", "namespace", "state", "message", "cluster_action_observed"):
        assert leaked not in body, f"{leaked} leaked out of the proxy namespace"


def test_the_audit_detail_splits_provenance_the_same_way(
    client: TestClient,
) -> None:
    """The row and the response make the same distinction, for the same reason.

    An investigator reading a stored row should be able to tell which
    assertions the writer checked without knowing how this endpoint is wired.
    """
    detail = _stun(client).json()["event"]["detail"]

    # Established by this process.
    assert detail["from_state"] == "active"
    assert detail["registry_match"] is True
    assert detail["reason"] == "operator-initiated stun via governance API"
    # Reported to it.
    assert detail["proxy"]["outcome"] == "stunned"
    for leaked in ("outcome", "namespace", "cluster_action_observed", "proxy_status"):
        assert leaked not in detail, f"{leaked} sits outside the proxy namespace"


def test_the_api_calls_the_proxy_itself(client: TestClient, proxy: _FakeProxy) -> None:
    """The whole point of the redesign, stated once and directly.

    If this API does not make the call, then whatever it writes down is an
    account of someone else's action and the rest of this file is testing the
    formatting of a rumour.
    """
    _stun(client)

    assert proxy.calls == [AGENT_ID]


def test_a_failed_cluster_action_is_recorded_and_then_reported(
    client: TestClient, proxy: _FakeProxy,
) -> None:
    """An isolation that did not take is exactly what a trail is for.

    Recorded first, answered second. Raising at the point of failure would
    reach the operator sooner and leave nothing behind, which is the wrong
    half to optimise.
    """
    proxy.observation = api_compat._ClusterStunObservation(
        observed=True, outcome="failed", namespace=None,
        proxy_status=502, error="upstream refused",
    )

    response = _stun(client)

    assert response.status_code == 502, response.text
    assert response.json()["error"]["code"] == "cluster_action_failed"

    recorded = client.get(
        "/api/audit", params={"type": "agent.stunned"}, headers=_bearer(),
    ).json()["events"]
    assert len(recorded) == 1, "a failed isolation left no trace"
    assert recorded[0]["detail"]["proxy"]["outcome"] == "failed"
    assert recorded[0]["detail"]["proxy"]["status"] == 502


def test_a_failed_cluster_action_leaves_the_agent_unsuspended(
    client: TestClient, proxy: _FakeProxy,
) -> None:
    """The registry must not assert an isolation the cluster never performed.

    This is the same defect as the fabricated ``active -> suspended`` row, one
    table across: a database saying an agent is cut off when it is still
    authenticating is worse than one that says nothing.
    """
    proxy.observation = api_compat._ClusterStunObservation(
        observed=True, outcome="failed", namespace=None,
        proxy_status=502, error="upstream refused",
    )

    _stun(client)

    agent = client.get(f"/api/agents/{AGENT_ID}", headers=_bearer()).json()
    assert agent["lifecycle_state"] == "active"
    recorded = client.get(
        "/api/audit", params={"type": "agent.stunned"}, headers=_bearer(),
    ).json()["events"][0]
    assert recorded["detail"]["to_state"] == "unchanged"


def test_a_proxy_404_is_passed_through_as_a_404(
    client: TestClient, proxy: _FakeProxy,
) -> None:
    """"No such pod" is the caller's problem; "the proxy is broken" is ours."""
    proxy.observation = api_compat._ClusterStunObservation(
        observed=True, outcome="failed", namespace=None,
        proxy_status=404, error="agent nope not found",
    )

    assert _stun(client).status_code == 404


def test_a_deployment_with_no_proxy_records_that_nothing_was_watched(
    client: TestClient, proxy: _FakeProxy,
) -> None:
    """The laptop demo, and the one case where the outcome is not observed.

    It is marked rather than hidden: a reader can tell a simulated row from a
    watched one without knowing which deployment produced it.
    """
    proxy.observation = api_compat._ClusterStunObservation(
        observed=False, outcome="simulated", namespace=None,
        proxy_status=None, error=None,
    )

    response = _stun(client)

    assert response.status_code == 200, response.text
    detail = response.json()["event"]["detail"]
    assert detail["proxy"]["outcome"] == "simulated"
    assert detail["proxy"]["observed"] is False


def test_the_agent_is_left_suspended(client: TestClient) -> None:
    _stun(client)

    agent = client.get(f"/api/agents/{AGENT_ID}", headers=_bearer()).json()
    assert agent["lifecycle_state"] == "suspended"


def test_the_recorded_from_state_is_the_state_the_agent_was_actually_in(
    client: TestClient,
) -> None:
    """A from_state guessed rather than read is a fabricated audit record."""
    # A FRESH agent, not a transition. VALID_TRANSITIONS makes `registered` an
    # INITIAL state with no inbound edges, so the `active -> registered` this
    # test used to attempt is a 409 -- and it ignored the status code, so the
    # agent stayed `active`, the stun correctly recorded from_state="active",
    # and the test failed asserting the product FABRICATES AUDIT RECORDS. An
    # unasserted precondition producing the most alarming reading available.
    #
    # Nor can the pre-state be reached any other way: from `active` the only
    # targets are suspended (which is where the stun itself goes, so stunning
    # again yields no event) and the two terminal states. The agent has to
    # START in `registered`, which is exactly what creating one does.
    created = client.post(
        "/api/agents",
        json={
            "name": f"from-state-probe-{uuid.uuid4().hex[:8]}",
            "type": "custom",
            "owner": "probe@signalloom.local",
        },
        headers=_bearer(),
    )
    # Assert the precondition. A test whose setup can fail silently reports the
    # setup's failure as a defect in the thing under test -- which is the whole
    # reason this test needed rewriting.
    assert created.status_code in (200, 201), f"agent create failed: {created.status_code} {created.text}"
    probe_id = created.json()["id"]
    assert created.json()["lifecycle_state"] == "registered", created.text

    response = client.post(
        f"/api/agents/{probe_id}/stun",
        json={"reason": "from-state probe"},
        headers=_bearer(),
    )
    assert response.status_code == 200, response.text

    detail = response.json()["event"]["detail"]
    assert detail["from_state"] == "registered"


def test_stunning_a_pod_the_registry_does_not_know_still_records(client: TestClient) -> None:
    """SuperCred agent ids are Kubernetes pod names, not registry UUIDs.

    An enforcement action against a workload with no registry row is exactly the
    case where the trail matters most; dropping the event because the id does
    not resolve would lose it silently.
    """
    response = client.post("/api/agents/agent-cardvault/stun", headers=_bearer())

    assert response.status_code == 200, response.text
    event = response.json()["event"]
    assert event["event_type"] == "agent.stunned"
    # No name, and that is the honest answer. The registry has no row, so the
    # server knows of no display name; the caller used to supply one and have
    # it preferred over the database's. `agent_ref` carries the pod name, which
    # for an unregistered workload IS its human-readable identifier.
    assert event["agent_name"] is None
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
    response = client.post("/api/agents/agent-cardvault/stun", headers=_bearer())

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
    client.post("/api/agents/agent-cardvault/stun", headers=_bearer())

    filtered = client.get(
        "/api/audit", params={"agent": "agent-cardvault"}, headers=_bearer(),
    ).json()

    # Asserted on agent_ref rather than agent_name: an unregistered pod has no
    # registry name to record, and the filter is about which workload the row
    # is about, which agent_ref is now the only truthful answer to.
    assert [e["detail"]["agent_ref"] for e in filtered["events"]] == ["agent-cardvault"]


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
