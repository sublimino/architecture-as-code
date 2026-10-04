"""Promote: superadmin-gated, gateway key never in the browser, audited first.

The Weave's Promote button had no click handler, and the proxy it needed,
``POST /api/signals/actors/{id}/promote`` (signal_fusion.py), let any tenant
user forward an unaudited promotion. What has to hold now:

* the gate is the verified principal, not anything the client can author;
* the gateway key and the acting-tenant headers reach signal-ingest and never
  the response, and a write acts for the caller's own tenant;
* the request is audited before it is forwarded;
* signal-ingest's verdict (404 unknown or other tenant, 409 already promoted)
  is passed through, and an unreachable signal-ingest is a 502.
"""
from __future__ import annotations

from typing import Any

import httpx
import pytest

import api_compat
import signal_fusion
from ingest_client import ACTING_SUBJECT_HEADER, ACTING_TENANT_HEADER
from tests.test_agent_discovery import bearer, client_for, token_for

SUPERADMIN = "demo-user"
SUBJECTS = {"alice": "tenant-a", "bob": "tenant-b", SUPERADMIN: "tenant-demo"}
ACTOR = "actor-shadow-llm-001"
PATH = f"/api/signals/actors/{ACTOR}/promote"


class _IngestSpy:
    calls: list[dict[str, Any]] = []
    status: int = 200
    body: Any = {"id": ACTOR, "status": "promoted"}

    def __init__(self, *_a: Any, **_k: Any) -> None:
        pass

    async def __aenter__(self) -> "_IngestSpy":
        return self

    async def __aexit__(self, *_a: Any) -> bool:
        return False

    async def request(self, method: str, path: str, headers: Any = None, **_k: Any) -> httpx.Response:
        type(self).calls.append({"method": method, "path": path, "headers": dict(headers or {})})
        return httpx.Response(type(self).status, json=type(self).body)

    async def get(self, *_a: Any, **_k: Any) -> httpx.Response:
        return httpx.Response(200, json={"agents": []})


@pytest.fixture
def ingest():
    _IngestSpy.calls = []
    _IngestSpy.status = 200
    _IngestSpy.body = {"id": ACTOR, "status": "promoted"}
    return _IngestSpy


def _as_superadmin(monkeypatch):
    monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
    monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {SUPERADMIN})
    monkeypatch.setattr(api_compat.settings, "api_superadmin_emails", set())
    return bearer(token_for(SUPERADMIN))


def test_a_superadmin_promotes_and_the_write_acts_for_their_own_tenant(monkeypatch, ingest):
    with client_for(monkeypatch, ingest) as client:
        response = client.post(PATH, headers=_as_superadmin(monkeypatch))

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "promoted"
    assert len(ingest.calls) == 1
    sent = ingest.calls[0]
    assert sent["method"] == "POST" and sent["path"] == f"/api/v1/actors/{ACTOR}/promote"
    auth = sent["headers"]["Authorization"]
    assert auth.startswith("Bearer ") and len(auth) > len("Bearer ") + 31
    assert sent["headers"][ACTING_TENANT_HEADER] == "tenant-demo"  # never '*' for a write
    assert sent["headers"][ACTING_SUBJECT_HEADER] == SUPERADMIN
    assert auth.removeprefix("Bearer ") not in response.text


def test_an_ordinary_tenant_is_refused_and_nothing_is_forwarded(monkeypatch, ingest):
    with client_for(monkeypatch, ingest) as client:
        response = client.post(PATH, headers=bearer(token_for("alice")))

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "superadmin_required"
    assert ingest.calls == []


def test_an_anonymous_caller_is_refused(monkeypatch, ingest):
    with client_for(monkeypatch, ingest) as client:
        assert client.post(PATH).status_code == 401
    assert ingest.calls == []


@pytest.mark.parametrize("status,body", [(409, {"error": "actor already promoted"}), (404, {"error": "actor not found"})])
def test_signal_ingests_own_verdict_is_passed_through(monkeypatch, ingest, status, body):
    ingest.status, ingest.body = status, body
    with client_for(monkeypatch, ingest) as client:
        response = client.post(PATH, headers=_as_superadmin(monkeypatch))
    assert response.status_code == status
    assert response.json() == body


def test_the_request_is_audited_before_it_is_forwarded(monkeypatch, ingest):
    ingest.status = 500
    ingest.body = {"error": "store failed"}
    with client_for(monkeypatch, ingest) as client:
        headers = _as_superadmin(monkeypatch)
        api_compat.reset_tenant_state("tenant-demo")
        response = client.post(PATH, headers=headers)
        assert response.status_code == 500
        events = client.get("/api/audit", headers=headers).json()

    types = [e["event_type"] for e in events.get("events", events.get("data", []))]
    assert signal_fusion.EVENT_ACTOR_PROMOTE in types


def test_an_unreachable_signal_ingest_is_502(monkeypatch, ingest):
    class Unreachable(_IngestSpy):
        async def request(self, *_a: Any, **_k: Any) -> httpx.Response:
            raise httpx.ConnectError("refused")

    with client_for(monkeypatch, Unreachable) as client:
        response = client.post(PATH, headers=_as_superadmin(monkeypatch))

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_unavailable"
