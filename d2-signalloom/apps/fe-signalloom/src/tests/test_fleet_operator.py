"""Recover and resume: superadmin-gated, operator key never in the browser.

fleet-manager grants ``recover`` and ``resume`` to its ``operator`` break-glass
key alone, so the dashboard's own key could not call either and the Fleet page's
**Recover** answered 403 for everybody. fe-signalloom now proxies both and
presents the operator key server-side.

What has to hold, and is asserted here:

* the gate is the verified principal, not anything the client can author;
* the operator key reaches fleet-manager and never the response;
* the request is audited *before* it is forwarded, so an attempted thaw cannot
  happen unrecorded even when fleet-manager then refuses it;
* a missing key is reported as this portal's missing key, not forwarded to
  collect a 401 that reads as the fleet refusing the operator.
"""
from __future__ import annotations

from typing import Any

import httpx
import pytest

import api_compat
import fleet_operator
from tests.test_agent_discovery import bearer, client_for, token_for

SUPERADMIN = "demo-user"
SUBJECTS = {"alice": "tenant-a", "bob": "tenant-b", SUPERADMIN: "tenant-demo"}


class _FleetManagerSpy:
    """Records what the proxy sent, and answers what the test told it to."""

    posts: list[dict[str, Any]] = []
    status: int = 200
    body: Any = {"recovered": 5}

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> "_FleetManagerSpy":
        return self

    async def __aexit__(self, *_args: Any) -> bool:
        return False

    async def post(self, url: str, json: Any = None, headers: Any = None) -> httpx.Response:
        type(self).posts.append({"url": url, "json": json, "headers": dict(headers or {})})
        return httpx.Response(type(self).status, json=type(self).body)

    async def get(self, *_args: Any, **_kwargs: Any) -> httpx.Response:
        return httpx.Response(200, json={"agents": []})


@pytest.fixture
def fleet(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv(fleet_operator.FLEET_MANAGER_OPERATOR_KEY_ENV, "operator-break-glass")
    _FleetManagerSpy.posts = []
    _FleetManagerSpy.status = 200
    _FleetManagerSpy.body = {"recovered": 5}
    return _FleetManagerSpy


def _as_superadmin(monkeypatch, client):
    monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
    return bearer(token_for(SUPERADMIN))


def test_a_superadmin_recovers_the_fleet_and_the_operator_key_is_presented(monkeypatch, fleet):
    with client_for(monkeypatch, fleet) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 200
    assert response.json() == {"recovered": 5}

    sent = [p for p in fleet.posts if p["url"].endswith("/api/v1/fleet/recover")]
    assert len(sent) == 1
    assert sent[0]["headers"]["Authorization"] == "Bearer operator-break-glass"
    # And the key is not echoed anywhere a browser could read it.
    assert "operator-break-glass" not in response.text


def test_a_superadmin_resumes_one_agent_with_its_reason_carried_through(monkeypatch, fleet):
    fleet.body = {"state": "resume_requested"}

    with client_for(monkeypatch, fleet) as client:
        response = client.post(
            "/api/v1/fleet/resume/agent-x-7d6-abc",
            json={"reason": "false positive, confirmed with the tenant"},
            headers=_as_superadmin(monkeypatch, client),
        )

    assert response.status_code == 200
    sent = [p for p in fleet.posts if "/fleet/resume/" in p["url"]]
    assert len(sent) == 1
    assert sent[0]["json"]["reason"] == "false positive, confirmed with the tenant"
    assert sent[0]["headers"]["Authorization"] == "Bearer operator-break-glass"


@pytest.mark.parametrize(
    "method,path",
    [("POST", "/api/v1/fleet/recover"), ("POST", "/api/v1/fleet/resume/demo-agent")],
)
def test_an_ordinary_tenant_is_refused_and_nothing_is_forwarded(monkeypatch, fleet, method, path):
    with client_for(monkeypatch, fleet) as client:
        response = client.request(method, path, headers=bearer(token_for("alice")))

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "superadmin_required"
    # The important half: a refused caller must not have reached fleet-manager.
    assert fleet.posts == []


@pytest.mark.parametrize("path", ["/api/v1/fleet/recover", "/api/v1/fleet/resume/demo-agent"])
def test_an_anonymous_caller_is_refused(monkeypatch, fleet, path):
    with client_for(monkeypatch, fleet) as client:
        assert client.post(path).status_code == 401
    assert fleet.posts == []


def test_superadmin_is_decided_from_the_token_not_from_the_request(monkeypatch, fleet):
    """A tenant user cannot talk its way into break-glass."""
    with client_for(monkeypatch, fleet) as client:
        token = bearer(token_for("alice"))
        attempts = [
            client.post("/api/v1/fleet/recover?superadmin=true", headers=token),
            client.post("/api/v1/fleet/recover", headers={**token, "X-Superadmin": "true"}),
            client.post("/api/v1/fleet/recover", headers={**token, "X-Forwarded-User": SUPERADMIN}),
            client.post("/api/v1/fleet/recover", json={"superadmin": True}, headers=token),
        ]

    assert [r.status_code for r in attempts] == [403, 403, 403, 403]
    assert fleet.posts == []


def test_without_an_operator_key_the_portal_says_so_rather_than_forwarding(monkeypatch, fleet):
    monkeypatch.delenv(fleet_operator.FLEET_MANAGER_OPERATOR_KEY_ENV, raising=False)

    with client_for(monkeypatch, fleet) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "fleet_operator_key_unavailable"
    # Not forwarded: a 401 from fleet-manager would read to the operator as the
    # fleet refusing them, not as this portal never having been given the key.
    assert fleet.posts == []


def test_fleet_managers_own_refusal_is_passed_through_not_flattened(monkeypatch, fleet):
    fleet.status = 404
    fleet.body = {"error": "unknown agent"}

    with client_for(monkeypatch, fleet) as client:
        response = client.post(
            "/api/v1/fleet/resume/no-such-agent", headers=_as_superadmin(monkeypatch, client)
        )

    assert response.status_code == 404
    assert response.json() == {"error": "unknown agent"}


def test_the_request_is_audited_before_it_is_forwarded(monkeypatch, fleet):
    """An attempted thaw must reach the trail even when fleet-manager refuses it."""
    fleet.status = 500
    fleet.body = {"error": "cascade failed"}

    with client_for(monkeypatch, fleet) as client:
        headers = _as_superadmin(monkeypatch, client)
        api_compat.reset_tenant_state("tenant-demo")
        response = client.post("/api/v1/fleet/recover", headers=headers)
        assert response.status_code == 500
        events = client.get("/api/audit", headers=headers).json()

    types = [e["event_type"] for e in events.get("events", events.get("data", []))]
    assert fleet_operator.EVENT_FLEET_RECOVER in types


def test_an_unreachable_fleet_manager_is_502_not_a_fabricated_success(monkeypatch, fleet):
    class Unreachable(_FleetManagerSpy):
        async def post(self, *_args: Any, **_kwargs: Any) -> httpx.Response:
            raise httpx.ConnectError("refused")

    with client_for(monkeypatch, Unreachable) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "fleet_manager_unreachable"
