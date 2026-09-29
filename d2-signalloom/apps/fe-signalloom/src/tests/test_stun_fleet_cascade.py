"""POST /api/agents/{id}/stun drives the fleet-manager containment cascade.

The stun used to ask ``fake-integration-proxy`` to relabel a pod. That proxy
wrote a hard-coded reason onto the pod and replied that credentials had been
revoked while revoking nothing. The containment cascade lives in fleet-manager
(``POST /api/v1/fleet/stun/{agentId}``), which reports one result per
enforcement plane, so this route now calls it and records what each plane did.

Unlike ``test_agent_stun.py``, nothing here stubs ``_perform_cluster_stun``.
The outbound HTTP call is intercepted with respx, so the request the API builds
(URL, body, timeout) and the way it reads fleet-manager's answer are both under
test. ``socket.connect`` is poisoned as well: a request that escaped respx
would fail loudly rather than reach a real cluster.

Every assertion about an outcome is made twice, once against the response and
once against the audit row read back through ``GET /api/audit``. The response
is the caller's copy; the row is the artefact.
"""
from __future__ import annotations

import inspect
import json
import socket
import time
from types import SimpleNamespace
from typing import Any

import httpx
import jwt
import pytest
import respx
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

TENANT = "tenant-stun-fleet"
SUBJECT = "stun-fleet"
REGISTRY_AGENT = f"{TENANT}:agent-1"
FLEET_URL = "http://fleet-manager.test:8082"
REASON = "kusari scanner flagged an exfiltration attempt"


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


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {SUBJECT: TENANT})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
    monkeypatch.setattr(api_compat, "FLEET_MANAGER_URL", FLEET_URL, raising=False)

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


_UNSET: Any = object()


def _plane(
    plane: str, outcome: str, error: str | None = None, details: Any = _UNSET,
) -> dict[str, Any]:
    """One PlaneResult as fleet-manager serialises it.

    Plane names are fleet-manager's real vocabulary
    (``freeze|bao|spire|mesh|admission|gitops``) and outcomes are its real
    words (``contained|partial|unavailable|not_found|failed``). The fixtures
    used to invent ``network/identity/credentials``, which fleet-manager never
    emits, so every test here passed against a wire that does not exist.
    """
    result: dict[str, Any] = {
        "plane": plane,
        "outcome": outcome,
        "timestamp": "2026-09-29T10:00:00Z",
        "latency_ms": 12,
        "details": {"probe": plane} if details is _UNSET else details,
    }
    if error is not None:
        result["error"] = error
    return result


def _target(agent: str, outcome: str = "contained") -> dict[str, Any]:
    """One entry of ``targets[]``: an object per agent, never a bare string."""
    return {
        "agent_id": agent,
        "operation": "stun",
        "namespace": "fe-signalloom-agents",
        "timestamp": "2026-09-29T10:00:00Z",
        "from_state": "running",
        "to_state": "stunned" if outcome == "contained" else "running",
        "outcome": outcome,
        "state_read": True,
        "credential": "revoked" if outcome == "contained" else "unchanged",
        "state_write": outcome == "contained",
    }


def _cascade(agent: str, overall: str, planes: list[dict[str, Any]]) -> dict[str, Any]:
    """A CascadeResult as fleet-manager serialises it."""
    return {
        "schema_version": "1",
        "target_agent": agent,
        "affected_agents": [agent],
        "events": [],
        "targets": [_target(agent, "contained" if overall == "contained" else "partial")],
        "planes": planes,
        "duration_ms": 41,
        "recovery_order": [agent],
        "overall_outcome": overall,
    }


FREEZE_DETAILS = {"cgroup_path": "/sys/fs/cgroup/kubepods/pod-cardvault", "frozen": True}
CONTAINED_PLANES = [
    _plane("freeze", "contained", details=FREEZE_DETAILS),
    _plane("bao", "contained"),
    _plane("spire", "contained"),
    _plane("gitops", "contained"),
]
#: fleet-manager's ``partial`` with the freeze held: bao could not revoke.
PARTIAL_PLANES = [
    _plane("freeze", "contained", details=FREEZE_DETAILS),
    _plane("bao", "partial", error="openbao lease revoke returned 503"),
    _plane("spire", "contained"),
    _plane("gitops", "contained"),
]
#: fleet-manager's ``partial`` with the bao lease revoked but the freeze failed.
#: fleet-manager calls this partial; the workload is still running.
FREEZE_FAILED_PLANES = [
    _plane("freeze", "unavailable", error="cgroup freezer not mounted on node", details=None),
    _plane("bao", "contained"),
    _plane("spire", "contained"),
    _plane("gitops", "contained"),
]


def _stun_url(agent: str) -> str:
    return f"{FLEET_URL}/api/v1/fleet/stun/{agent}"


def _post_stun(client: TestClient, agent: str, body: Any = None, **kwargs: Any) -> httpx.Response:
    if body is None and "content" not in kwargs:
        body = {"reason": REASON}
    if body is ...:
        return client.post(f"/api/agents/{agent}/stun", headers=_bearer(), **kwargs)
    return client.post(f"/api/agents/{agent}/stun", json=body, headers=_bearer(), **kwargs)


def _stun_rows(client: TestClient) -> list[dict[str, Any]]:
    """Every stun attempt's row, successful (``agent.stunned``) or not
    (``agent.stun_failed``)."""
    events: list[dict[str, Any]] = []
    for event_type in ("agent.stunned", "agent.stun_failed"):
        events += client.get(
            "/api/audit", params={"type": event_type}, headers=_bearer(),
        ).json()["events"]
    return events


# ---------------------------------------------------------------------------
# The request contract: a reason is required, and it is validated
# ---------------------------------------------------------------------------

def test_a_stun_with_no_body_is_refused_with_a_message_naming_reason(client: TestClient) -> None:
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(url__startswith=FLEET_URL)
        response = _post_stun(client, "agent-cardvault", body=...)

    assert response.status_code == 422, response.text
    assert "reason" in response.json()["error"]["message"]
    assert not route.called, "a refused request must not reach fleet-manager"
    assert _stun_rows(client) == []


@pytest.mark.parametrize(
    "reason",
    ["", "   ", "x" * 257, "line one\nline two", "nul\x00byte"],
    ids=["empty", "whitespace", "too-long", "newline", "nul"],
)
def test_an_unusable_reason_is_refused(client: TestClient, reason: str) -> None:
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(url__startswith=FLEET_URL)
        response = _post_stun(client, "agent-cardvault", body={"reason": reason})

    assert response.status_code == 422, response.text
    assert "reason" in response.json()["error"]["message"]
    assert not route.called
    assert _stun_rows(client) == []


def test_a_256_character_reason_is_the_longest_accepted(client: TestClient) -> None:
    longest = "r" * 256
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", CONTAINED_PLANES)),
        )
        response = _post_stun(client, "agent-cardvault", body={"reason": longest})

    assert response.status_code == 200, response.text
    assert response.json()["reason"] == longest
    assert _stun_rows(client)[0]["detail"]["reason"] == longest


def test_a_reason_that_is_not_a_string_is_refused(client: TestClient) -> None:
    response = _post_stun(client, "agent-cardvault", body={"reason": 42})

    assert response.status_code == 422, response.text
    assert "reason" in response.json()["error"]["message"]


def test_a_body_that_is_not_json_is_refused(client: TestClient) -> None:
    response = _post_stun(
        client, "agent-cardvault", content=b"reason=please",
        # no json= so the body really is not JSON
    )

    assert response.status_code == 422, response.text
    assert "reason" in response.json()["error"]["message"]


def test_fields_other_than_reason_are_refused_not_ignored(client: TestClient) -> None:
    """The row's outcome comes from fleet-manager, never from the caller."""
    response = _post_stun(
        client, "agent-cardvault", body={"reason": REASON, "overall_outcome": "contained"},
    )

    assert response.status_code == 422, response.text
    assert "overall_outcome" in response.json()["error"]["message"]
    assert _stun_rows(client) == []


# ---------------------------------------------------------------------------
# The outbound call: URL, body, timeout, id mapping
# ---------------------------------------------------------------------------

def test_the_route_posts_the_reason_to_fleet_manager(client: TestClient) -> None:
    with respx.mock() as mock:
        route = mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", CONTAINED_PLANES)),
        )
        _post_stun(client, "agent-cardvault")

    assert route.call_count == 1
    sent = route.calls.last.request
    assert json.loads(sent.content) == {"agent_id": "agent-cardvault", "reason": REASON}
    assert sent.headers["content-type"] == "application/json"
    # 10 s on every phase, so a hung fleet-manager cannot hang the operator.
    assert sent.extensions["timeout"] == {"connect": 10.0, "read": 10.0, "write": 10.0, "pool": 10.0}


def test_the_fake_proxy_is_no_longer_called(client: TestClient) -> None:
    with respx.mock(assert_all_called=False) as mock:
        proxy = mock.post(url__regex=r".*fake-integration-proxy.*")
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", CONTAINED_PLANES)),
        )
        _post_stun(client, "agent-cardvault")

    assert not proxy.called


@pytest.mark.parametrize(
    "caller_id",
    ["agent-cardvault", "agent-kusari-agent", "cardvault", "kusari-agent", "cardvault-7d9f8b6c4-x2k9q"],
)
def test_the_fleet_id_is_the_callers_id_unchanged(caller_id: str) -> None:
    """fleet-manager resolves pod names and stems itself; fe does not rewrite."""
    assert api_compat._fleet_agent_id(caller_id) == caller_id


def test_a_pod_name_reaches_fleet_manager_unchanged(client: TestClient) -> None:
    """The dashboard posts pod names. They used to gain an ``agent-`` prefix
    here, turning a name fleet-manager can resolve into one it cannot."""
    pod = "cardvault-7d9f8b6c4-x2k9q"
    with respx.mock() as mock:
        route = mock.post(_stun_url(pod)).mock(
            return_value=httpx.Response(200, json=_cascade(pod, "contained", CONTAINED_PLANES)),
        )
        response = _post_stun(client, pod)

    assert route.called, "the pod name was rewritten before reaching fleet-manager"
    assert json.loads(route.calls.last.request.content)["agent_id"] == pod
    row = _stun_rows(client)[0]["detail"]
    assert row["agent_ref"] == pod
    assert row["fleet_agent_id"] == pod
    assert response.json()["agent_id"] == pod


def test_a_path_segment_cannot_escape_the_fleet_url(monkeypatch: pytest.MonkeyPatch) -> None:
    """Agent ids are caller-supplied, so they are quoted into one segment.

    Driven through the URL builder rather than the route: Starlette decodes
    ``%2F`` before routing, so a route-level probe would 404 in the router and
    never exercise the quoting at all.
    """
    monkeypatch.setattr(api_compat, "FLEET_MANAGER_URL", FLEET_URL, raising=False)

    assert api_compat._fleet_stun_url("agent-a/../../reset?x=1") == (
        f"{FLEET_URL}/api/v1/fleet/stun/agent-a%2F..%2F..%2Freset%3Fx%3D1"
    )


def test_a_trailing_slash_on_the_fleet_url_is_tolerated(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(api_compat, "FLEET_MANAGER_URL", f"{FLEET_URL}/", raising=False)

    assert api_compat._fleet_stun_url("agent-x") == f"{FLEET_URL}/api/v1/fleet/stun/agent-x"


def _fleet_url_in_fresh_interpreter(env_value: str | None) -> str:
    """Import api_compat in a child process so the env default is really read.

    ``importlib.reload`` in-process would redefine ``APIError`` underneath the
    exception handler the app already registered, breaking every later test.
    """
    import os
    import subprocess
    import sys
    from pathlib import Path

    env = {k: v for k, v in os.environ.items() if k != "FLEET_MANAGER_URL"}
    if env_value is not None:
        env["FLEET_MANAGER_URL"] = env_value
    result = subprocess.run(
        [sys.executable, "-c", "import api_compat; print(repr(api_compat.FLEET_MANAGER_URL))"],
        cwd=Path(api_compat.__file__).parent, env=env, capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1]


def test_the_default_fleet_manager_url_is_the_in_cluster_service() -> None:
    assert _fleet_url_in_fresh_interpreter(None) == (
        "'http://fleet-manager.fe-signalloom.svc.cluster.local:8082'"
    )


def test_an_empty_fleet_manager_url_env_is_kept_empty() -> None:
    """Empty is the documented switch into simulated mode, not "use the default"."""
    assert _fleet_url_in_fresh_interpreter("") == "''"


def test_the_stun_path_never_reads_supercred_stun_base_url() -> None:
    source = inspect.getsource(api_compat._perform_cluster_stun) + inspect.getsource(api_compat.stun_agent)
    assert "SUPERCRED_STUN_BASE_URL" not in source


# ---------------------------------------------------------------------------
# Contained: 200 with every plane visible, in the response and in the row
# ---------------------------------------------------------------------------

def test_a_contained_cascade_returns_every_plane(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", CONTAINED_PLANES)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["reason"] == REASON
    assert body["overall_outcome"] == "contained"
    assert body["fleet_manager_status"] == 200
    assert [p["plane"] for p in body["planes"]] == ["freeze", "bao", "spire", "gitops"]
    assert {p["outcome"] for p in body["planes"]} == {"contained"}
    assert body["planes"][1] == {
        "plane": "bao", "outcome": "contained", "error": None,
        "timestamp": "2026-09-29T10:00:00Z", "latency_ms": 12, "details": {"probe": "bao"},
    }
    assert body["event"]["event_type"] == "agent.stunned"
    # Existing fields survive.
    assert {"agent_id", "from_state", "to_state", "actor", "stunned_at", "event"} <= set(body)


def test_a_contained_cascade_is_recorded_with_its_planes(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", CONTAINED_PLANES)),
        )
        _post_stun(client, "agent-cardvault")

    rows = _stun_rows(client)
    assert len(rows) == 1
    detail = rows[0]["detail"]
    assert rows[0]["actor"] == SUBJECT
    assert detail["reason"] == REASON
    assert detail["overall_outcome"] == "contained"
    assert detail["fleet_manager_status"] == 200
    assert rows[0]["event_type"] == "agent.stunned"
    assert [(p["plane"], p["outcome"]) for p in detail["planes"]] == [
        ("freeze", "contained"), ("bao", "contained"), ("spire", "contained"), ("gitops", "contained"),
    ]


def test_a_contained_registry_agent_is_suspended(client: TestClient) -> None:
    fleet_id = api_compat._fleet_agent_id(REGISTRY_AGENT)
    with respx.mock() as mock:
        mock.post(url__startswith=f"{FLEET_URL}/api/v1/fleet/stun/").mock(
            return_value=httpx.Response(200, json=_cascade(fleet_id, "contained", CONTAINED_PLANES)),
        )
        response = _post_stun(client, REGISTRY_AGENT)

    assert response.status_code == 200, response.text
    assert response.json()["from_state"] == "active"
    assert response.json()["to_state"] == "suspended"
    assert _stun_rows(client)[0]["detail"]["to_state"] == "suspended"


# ---------------------------------------------------------------------------
# Partial: 207 becomes 200, and the failing plane is not hidden
# ---------------------------------------------------------------------------

def test_a_partial_cascade_answers_200_and_names_the_failing_plane(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(207, json=_cascade("agent-cardvault", "partial", PARTIAL_PLANES)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["overall_outcome"] == "partial"
    assert body["fleet_manager_status"] == 207
    failing = [p for p in body["planes"] if p["outcome"] != "contained"]
    assert failing == [{
        "plane": "bao", "outcome": "partial", "error": "openbao lease revoke returned 503",
        "timestamp": "2026-09-29T10:00:00Z", "latency_ms": 12, "details": {"probe": "bao"},
    }]

    rows = _stun_rows(client)
    assert rows[0]["event_type"] == "agent.stunned"
    detail = rows[0]["detail"]
    assert detail["overall_outcome"] == "partial"
    assert detail["fleet_manager_status"] == 207
    assert [p["error"] for p in detail["planes"] if p["plane"] == "bao"] == [
        "openbao lease revoke returned 503",
    ]


def test_a_partial_cascade_with_the_freeze_held_suspends_a_registry_agent(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(url__startswith=f"{FLEET_URL}/api/v1/fleet/stun/").mock(
            return_value=httpx.Response(207, json=_cascade(REGISTRY_AGENT, "partial", PARTIAL_PLANES)),
        )
        response = _post_stun(client, REGISTRY_AGENT)

    assert response.status_code == 200, response.text
    assert response.json()["overall_outcome"] == "partial"
    assert response.json()["to_state"] == "suspended"
    assert [p["plane"] for p in response.json()["planes"]] == ["freeze", "bao", "spire", "gitops"]
    agent = client.get(f"/api/agents/{REGISTRY_AGENT}", headers=_bearer()).json()
    assert agent["lifecycle_state"].lower() == "suspended"


# ---------------------------------------------------------------------------
# The freeze plane decides. Credentials revoked with the workload still
# running is not an isolation, whatever fleet-manager's summary word is.
# ---------------------------------------------------------------------------

def test_a_partial_cascade_whose_freeze_failed_is_a_502(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(url__startswith=f"{FLEET_URL}/api/v1/fleet/stun/").mock(
            return_value=httpx.Response(207, json=_cascade(REGISTRY_AGENT, "partial", FREEZE_FAILED_PLANES)),
        )
        response = _post_stun(client, REGISTRY_AGENT)

    assert response.status_code == 502, response.text
    error = response.json()["error"]
    assert error["code"] == "cluster_action_failed"
    assert "freeze" in error["message"]
    assert "cgroup freezer not mounted on node" in error["message"]

    rows = _stun_rows(client)
    assert len(rows) == 1
    assert rows[0]["event_type"] == "agent.stun_failed"
    detail = rows[0]["detail"]
    assert detail["stun_attempt_id"] in error["message"]
    assert detail["overall_outcome"] == "partial", "fleet-manager's own word is kept on the row"
    assert detail["to_state"] == "unchanged"
    assert [(p["plane"], p["outcome"]) for p in detail["planes"]][0] == ("freeze", "unavailable")

    agent = client.get(f"/api/agents/{REGISTRY_AGENT}", headers=_bearer()).json()
    assert agent["lifecycle_state"].lower() != "suspended"


def test_a_contained_summary_with_a_failed_freeze_is_still_a_502(client: TestClient) -> None:
    """The summary word is not trusted over the plane that does the isolating."""
    planes = [_plane("freeze", "failed", error="freezer write EPERM"), _plane("bao", "contained")]
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", planes)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert "freezer write EPERM" in response.json()["error"]["message"]
    assert _stun_rows(client)[0]["event_type"] == "agent.stun_failed"


def test_one_failed_freeze_among_several_targets_fails_closed(client: TestClient) -> None:
    planes = [
        _plane("freeze", "contained"),
        _plane("freeze", "failed", error="second target freeze timed out"),
        _plane("bao", "contained"),
    ]
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(207, json=_cascade("agent-cardvault", "partial", planes)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert "second target freeze timed out" in response.json()["error"]["message"]


@pytest.mark.parametrize(
    "planes",
    [[], [_plane("bao", "contained"), _plane("spire", "contained"), _plane("gitops", "contained")]],
    ids=["no-planes", "no-freeze-plane"],
)
def test_a_cascade_without_a_freeze_plane_fails_closed(client: TestClient, planes: list[dict[str, Any]]) -> None:
    with respx.mock() as mock:
        mock.post(url__startswith=f"{FLEET_URL}/api/v1/fleet/stun/").mock(
            return_value=httpx.Response(200, json=_cascade(REGISTRY_AGENT, "contained", planes)),
        )
        response = _post_stun(client, REGISTRY_AGENT)

    assert response.status_code == 502, response.text
    message = response.json()["error"]["message"]
    assert "no freeze plane" in message
    row = _stun_rows(client)[0]
    assert row["event_type"] == "agent.stun_failed"
    assert row["detail"]["to_state"] == "unchanged"
    assert row["detail"]["stun_attempt_id"] in message
    agent = client.get(f"/api/agents/{REGISTRY_AGENT}", headers=_bearer()).json()
    assert agent["lifecycle_state"].lower() != "suspended"


def test_a_cascade_with_the_planes_key_missing_fails_closed(client: TestClient) -> None:
    body = _cascade("agent-cardvault", "contained", CONTAINED_PLANES)
    del body["planes"]
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(return_value=httpx.Response(200, json=body))
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert "freeze" in response.json()["error"]["message"]
    assert _stun_rows(client)[0]["event_type"] == "agent.stun_failed"


# ---------------------------------------------------------------------------
# Sentinel telemetry: reported, never invented
# ---------------------------------------------------------------------------

def test_sentinel_telemetry_is_the_freeze_planes_details_verbatim(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", CONTAINED_PLANES)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 200, response.text
    assert response.json()["sentinel_telemetry"] == {"source": "fleet-manager.freeze", **FREEZE_DETAILS}


@pytest.mark.parametrize("details", [None, {}], ids=["null", "empty"])
def test_sentinel_telemetry_without_freeze_details_says_unavailable(client: TestClient, details: Any) -> None:
    planes = [_plane("freeze", "contained", details=details), _plane("bao", "contained")]
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", planes)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 200, response.text
    assert response.json()["sentinel_telemetry"] == {"source": "unavailable"}


def test_no_fabricated_sentinel_values_survive_in_a_stun_response(client: TestClient) -> None:
    planes = [_plane("freeze", "contained", details=None), _plane("bao", "contained")]
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "contained", planes)),
        )
        response = _post_stun(client, "agent-cardvault")

    # Key names only: a numeric probe like "142" could match the random hex
    # stun_attempt_id and flake.
    for invented in ("sentinel_drop_count", "ebpf_active", "cgroup_state", "containment_probe_state", "ebpf-sentinel"):
        assert invented not in response.text, f"stun response still carries invented {invented!r}"
    assert response.json()["sentinel_telemetry"] == {"source": "unavailable"}


# ---------------------------------------------------------------------------
# Failures: recorded first, then answered, with the audit reference
# ---------------------------------------------------------------------------

def test_an_unknown_agent_is_recorded_then_answered_404(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-ghost")).mock(
            return_value=httpx.Response(404, json={"error": "agent agent-ghost not in fleet"}),
        )
        response = _post_stun(client, "agent-ghost")

    assert response.status_code == 404, response.text
    rows = _stun_rows(client)
    assert len(rows) == 1, "a refused stun left no trace"
    detail = rows[0]["detail"]
    assert detail["overall_outcome"] == "not_found"
    assert detail["fleet_manager_status"] == 404
    assert detail["reason"] == REASON
    assert detail["to_state"] == "unchanged"
    assert detail["stun_attempt_id"] in response.json()["error"]["message"]
    assert rows[0]["event_type"] == "agent.stun_failed"


def test_a_404_names_the_ids_fleet_manager_tried(client: TestClient) -> None:
    """fleet-manager's real 404 body: which candidate ids it looked up."""
    tried = ["cardvault-7d9f8b6c4-x2k9q", "agent-cardvault-7d9f8b6c4-x2k9q", "agent-cardvault"]
    with respx.mock() as mock:
        mock.post(_stun_url("cardvault-7d9f8b6c4-x2k9q")).mock(
            return_value=httpx.Response(404, json={"error": "unknown agent", "tried": tried}),
        )
        response = _post_stun(client, "cardvault-7d9f8b6c4-x2k9q")

    assert response.status_code == 404, response.text
    message = response.json()["error"]["message"]
    assert "unknown agent" in message
    for candidate in tried:
        assert candidate in message
    row = _stun_rows(client)[0]
    assert row["event_type"] == "agent.stun_failed"
    assert all(candidate in row["detail"]["fleet_manager_error"] for candidate in tried)


def test_a_fleet_manager_500_is_recorded_then_answered_502(client: TestClient) -> None:
    failed_planes = [_plane("freeze", "failed", error="cilium policy apply failed")]
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(500, json=_cascade("agent-cardvault", "error", failed_planes)),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert response.json()["error"]["code"] == "cluster_action_failed"
    detail = _stun_rows(client)[0]["detail"]
    assert detail["overall_outcome"] == "error"
    assert detail["fleet_manager_status"] == 500
    # The planes fleet-manager did report are kept, so the operator can see
    # which one broke even on the failure path.
    assert detail["planes"][0]["error"] == "cilium policy apply failed"
    assert detail["stun_attempt_id"] in response.json()["error"]["message"]
    assert _stun_rows(client)[0]["event_type"] == "agent.stun_failed"


def test_an_unreachable_fleet_manager_is_recorded_then_answered_502(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(side_effect=httpx.ConnectError("connection refused"))
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    detail = _stun_rows(client)[0]["detail"]
    assert detail["overall_outcome"] == "unreachable"
    assert detail["fleet_manager_status"] is None
    assert detail["planes"] == []
    assert "connection refused" in detail["fleet_manager_error"]
    assert detail["stun_attempt_id"] in response.json()["error"]["message"]


def test_a_timeout_is_recorded_as_unreachable(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(side_effect=httpx.ReadTimeout("read timed out"))
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert _stun_rows(client)[0]["detail"]["overall_outcome"] == "unreachable"


@pytest.mark.parametrize(
    "payload",
    [
        {"planes": []},  # no overall_outcome
        {"overall_outcome": "contained"},  # no planes
        {"overall_outcome": "contained", "planes": [{"outcome": "contained"}]},  # plane unnamed
        {"overall_outcome": "contained", "planes": "all of them"},
        ["not", "an", "object"],
    ],
    ids=["no-outcome", "no-planes", "unnamed-plane", "planes-not-list", "not-object"],
)
def test_a_malformed_cascade_is_not_trusted(client: TestClient, payload: Any) -> None:
    """A 200 whose body does not say what happened must not become a success."""
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(return_value=httpx.Response(200, json=payload))
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    detail = _stun_rows(client)[0]["detail"]
    assert detail["overall_outcome"] == "invalid_response"
    assert detail["fleet_manager_status"] == 200
    assert detail["to_state"] == "unchanged"


def test_a_non_json_200_is_not_trusted(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(return_value=httpx.Response(200, text="ok"))
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert _stun_rows(client)[0]["detail"]["overall_outcome"] == "invalid_response"


def test_a_2xx_that_reports_no_containment_is_a_failure(client: TestClient) -> None:
    """fleet-manager's own word decides, not the status code alone."""
    with respx.mock() as mock:
        mock.post(_stun_url("agent-cardvault")).mock(
            return_value=httpx.Response(200, json=_cascade("agent-cardvault", "failed", [_plane("freeze", "failed")])),
        )
        response = _post_stun(client, "agent-cardvault")

    assert response.status_code == 502, response.text
    assert _stun_rows(client)[0]["detail"]["overall_outcome"] == "failed"


def test_a_failed_cascade_leaves_a_registry_agent_unsuspended(client: TestClient) -> None:
    with respx.mock() as mock:
        mock.post(url__startswith=f"{FLEET_URL}/api/v1/fleet/stun/").mock(
            return_value=httpx.Response(500, json={"error": "boom"}),
        )
        _post_stun(client, REGISTRY_AGENT)

    agent = client.get(f"/api/agents/{REGISTRY_AGENT}", headers=_bearer()).json()
    assert agent["lifecycle_state"] in ("active", "Governed")
    assert _stun_rows(client)[0]["detail"]["to_state"] == "unchanged"


# ---------------------------------------------------------------------------
# Simulated: FLEET_MANAGER_URL="" says so rather than pretending
# ---------------------------------------------------------------------------

def test_an_empty_fleet_manager_url_is_simulated_and_says_so(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(api_compat, "FLEET_MANAGER_URL", "")
    with respx.mock(assert_all_called=False) as mock:
        anything = mock.route()
        response = _post_stun(client, "agent-cardvault")

    assert not anything.called, "simulated mode made a network call"
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["overall_outcome"] == "simulated"
    assert body["fleet_manager_status"] is None
    assert body["planes"] == []
    assert body["proxy"]["observed"] is False
    detail = _stun_rows(client)[0]["detail"]
    assert detail["overall_outcome"] == "simulated"
    assert detail["reason"] == REASON
    assert detail["planes"] == []
    # No fleet-manager was asked, so there is no telemetry source at all.
    assert body["sentinel_telemetry"] is None


# ---------------------------------------------------------------------------
# The fabricated proxy narrative is gone, and the new path is reachable
# ---------------------------------------------------------------------------

APPS_DIR = __import__("pathlib").Path(api_compat.__file__).resolve().parents[2]


def test_the_fabricated_stun_strings_are_gone() -> None:
    """The proxy's canned reason and its false claim of a credential revocation.

    Assembled from parts so this assertion is not itself a hit for a grep.
    """
    fabricated = ["credentials " + "revoked", "compliance-failure: " + "securityContext not set"]
    hits: list[str] = []
    for root in (APPS_DIR / "fe-signalloom", APPS_DIR / "fake-integration-proxy"):
        assert root.is_dir(), root
        for path in root.rglob("*"):
            if not path.is_file() or any(part in {"node_modules", "__pycache__", ".pytest_cache"} for part in path.parts):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            hits.extend(f"{path.relative_to(APPS_DIR)}: {p}" for p in fabricated if p in text)
    assert hits == []


def test_the_api_pod_may_egress_to_fleet_manager() -> None:
    """Egress half only; the ingress half lives in fleet-manager's own policy."""
    import yaml

    docs = list(yaml.safe_load_all((APPS_DIR / "fe-signalloom/base/networkpolicy.yaml").read_text(encoding="utf-8")))
    portal = next(d for d in docs if d and d["metadata"]["name"] == "allow-portal-dependencies")
    assert portal["spec"]["podSelector"]["matchLabels"] == {"bao.controlplane.io/consumer": "fe-signalloom"}
    matching = [
        rule for rule in portal["spec"]["egress"]
        if any(
            (t.get("podSelector") or {}).get("matchLabels") == {"app.kubernetes.io/name": "fleet-manager"}
            and "namespaceSelector" not in t
            for t in rule.get("to", [])
        )
        and [p.get("port") for p in rule.get("ports", [])] == [8082]
    ]
    assert len(matching) == 1, "allow-portal-dependencies needs exactly one fleet-manager:8082 egress rule"
