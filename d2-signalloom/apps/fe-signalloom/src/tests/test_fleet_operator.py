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
    content: bytes | None = None
    headers: dict[str, str] = {}

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> "_FleetManagerSpy":
        return self

    async def __aexit__(self, *_args: Any) -> bool:
        return False

    async def post(self, url: str, json: Any = None, headers: Any = None) -> httpx.Response:
        type(self).posts.append({"url": url, "json": json, "headers": dict(headers or {})})
        resp_headers = dict(type(self).headers)
        if type(self).content is not None:
            return httpx.Response(type(self).status, content=type(self).content, headers=resp_headers)
        if type(self).body is not None:
            return httpx.Response(type(self).status, json=type(self).body, headers=resp_headers)
        return httpx.Response(type(self).status, headers=resp_headers)

    async def get(self, *_args: Any, **_kwargs: Any) -> httpx.Response:
        return httpx.Response(200, json={"agents": []})


@pytest.fixture
def fleet(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv(fleet_operator.FLEET_MANAGER_OPERATOR_KEY_ENV, "operator-break-glass")
    _FleetManagerSpy.posts = []
    _FleetManagerSpy.status = 200
    _FleetManagerSpy.body = {"recovered": 5}
    _FleetManagerSpy.content = None
    _FleetManagerSpy.headers = {}
    return _FleetManagerSpy


def _as_superadmin(monkeypatch, client):
    monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
    # Stated explicitly, not inherited: tests/test_eap_anonymous_surface.py
    # assigns settings.api_superadmin_emails/subjects directly rather than
    # through monkeypatch, so those defaults are gone for every module that runs
    # after it in a full session. A test that needs a superadmin has to name one.
    monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {SUPERADMIN})
    monkeypatch.setattr(api_compat.settings, "api_superadmin_emails", set())
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


_SIGNED_TOKEN = {
    "schema_version": "sler.signalloom.io/v1alpha1",
    "token_id": "rt-0123456789abcdef01234567",
    "alg": "ed25519",
    "agent_id": "remote-api-0",
    "namespace": "tenant-a",
    "audience": "signalloom-fleet/local",
    "operator_id": "spiffe://signalloom.io/operator/alice",
    "governance_approval_ref": "CHG-2026-10-04-0007",
    "issued_at": "2026-10-04T12:00:00Z",
    "expires_at": "2026-10-04T12:10:00Z",
    "nonce": "cmVzdW1lLXRva2VuLWNsaS1jb21wYXQtbm9uY2U=",
    "trust_root_id": "signalloom-operator-root/2026-q3",
    "required_signatures": 2,
    "signature": "QUxJQ0UtU0lHTkFUVVJFLUJZVEVT",
    "signatures": [
        {
            "operator_id": "spiffe://signalloom.io/operator/alice",
            "key_id": "sha256:aa",
            "alg": "ed25519",
            "signed_at": "2026-10-04T12:00:10Z",
            "signature": "QUxJQ0UtU0lHTkFUVVJFLUJZVEVT",
        },
        {
            "operator_id": "spiffe://signalloom.io/operator/bob",
            "key_id": "sha256:bb",
            "alg": "ed25519",
            "signed_at": "2026-10-04T12:00:20Z",
            "signature": "Qk9CLVNJR05BVFVSRS1CWVRFUw==",
        },
    ],
}


def test_the_resume_token_and_idempotency_key_pass_through_unchanged(monkeypatch, fleet):
    """The signatures cover the token's bytes, so the proxy must not touch them."""
    fleet.status = 202
    fleet.body = {"state": "resume_requested"}

    with client_for(monkeypatch, fleet) as client:
        headers = _as_superadmin(monkeypatch, client)
        api_compat.reset_tenant_state("tenant-demo")
        response = client.post(
            "/api/v1/fleet/resume/remote-api-0",
            json={"token": _SIGNED_TOKEN, "idempotency_key": "resume-remote-api-0-rt-0123"},
            headers=headers,
        )
        assert response.status_code == 202
        events = client.get("/api/audit", headers=headers).json()

    sent = [p for p in fleet.posts if "/fleet/resume/" in p["url"]]
    assert len(sent) == 1
    assert sent[0]["json"]["token"] == _SIGNED_TOKEN
    assert sent[0]["json"]["idempotency_key"] == "resume-remote-api-0-rt-0123"
    assert sent[0]["json"]["agent_id"] == "remote-api-0"
    assert "reason" not in sent[0]["json"]

    # Audited by token id and operator ids, never by signature bytes.
    resumes = [
        e for e in events.get("events", events.get("data", []))
        if e["event_type"] == fleet_operator.EVENT_FLEET_RESUME
    ]
    assert len(resumes) == 1
    detail = resumes[0]["detail"]
    assert detail["token_id"] == "rt-0123456789abcdef01234567"
    assert detail["operator_ids"] == [
        "spiffe://signalloom.io/operator/alice",
        "spiffe://signalloom.io/operator/bob",
    ]
    assert detail["idempotency_key"] == "resume-remote-api-0-rt-0123"
    serialised = str(detail)
    assert "QUxJQ0UtU0lHTkFUVVJFLUJZVEVT" not in serialised
    assert "Qk9CLVNJR05BVFVSRS1CWVRFUw==" not in serialised


def test_a_resume_without_a_token_forwards_no_token_field(monkeypatch, fleet):
    """fleet-manager decides what a tokenless resume means; the proxy invents nothing."""
    fleet.status = 403
    fleet.body = {"error": "a dual-signed resume token is required to resume a remote workload"}

    with client_for(monkeypatch, fleet) as client:
        response = client.post(
            "/api/v1/fleet/resume/remote-api-0", json={}, headers=_as_superadmin(monkeypatch, client)
        )

    assert response.status_code == 403
    sent = [p for p in fleet.posts if "/fleet/resume/" in p["url"]]
    assert len(sent) == 1
    assert sent[0]["json"] == {"agent_id": "remote-api-0"}


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


def test_fleet_operator_proxy_handles_204_no_content(monkeypatch, fleet):
    """204 No Content must not emit a body or error payload per RFC 9110 Section 15.3.5."""
    fleet.status = 204
    fleet.content = b""
    fleet.body = None

    with client_for(monkeypatch, fleet) as client:
        # Test recover
        resp_recover = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))
        assert resp_recover.status_code == 204
        assert resp_recover.content == b""
        assert resp_recover.text == ""

        # Test resume
        resp_resume = client.post(
            "/api/v1/fleet/resume/demo-agent",
            json={"reason": "test-204"},
            headers=_as_superadmin(monkeypatch, client),
        )
        assert resp_resume.status_code == 204
        assert resp_resume.content == b""
        assert resp_resume.text == ""


def test_fleet_operator_proxy_handles_empty_body(monkeypatch, fleet):
    """Empty upstream response bodies must pass through without synthesizing fake detail payload."""
    fleet.status = 200
    fleet.content = b""
    fleet.body = None

    with client_for(monkeypatch, fleet) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 200
    assert response.content == b""
    assert response.text == ""
    assert "detail" not in response.text


def test_fleet_operator_proxy_propagates_allow_header_on_405(monkeypatch, fleet):
    """405 Method Not Allowed responses must preserve RFC 9110 Section 15.5.6 Allow header."""
    fleet.status = 405
    fleet.body = {"error": "method not allowed"}
    fleet.headers = {"Allow": "POST"}

    with client_for(monkeypatch, fleet) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 405
    assert response.headers.get("allow") == "POST"
    assert response.json() == {"error": "method not allowed"}


def test_fleet_operator_proxy_propagates_location_and_etag_headers(monkeypatch, fleet):
    """201 Created responses must propagate Location and ETag headers."""
    fleet.status = 201
    fleet.body = {"task_id": "task-recover-99"}
    fleet.headers = {"Location": "/api/v1/fleet/tasks/task-recover-99", "ETag": '"tag-fleet-99"'}

    with client_for(monkeypatch, fleet) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 201
    assert response.headers.get("location") == "/api/v1/fleet/tasks/task-recover-99"
    assert response.headers.get("etag") == '"tag-fleet-99"'
    assert response.json() == {"task_id": "task-recover-99"}


def test_fleet_operator_proxy_propagates_retry_after_and_tenant_headers(monkeypatch, fleet):
    """Retry-After, X-Tenant-ID, and X-Request-ID headers must be forwarded."""
    fleet.status = 429
    fleet.body = {"error": "rate limit exceeded"}
    fleet.headers = {
        "Retry-After": "45",
        "X-Tenant-ID": "tenant-prod-1",
        "X-Request-ID": "req-op-xyz",
    }

    with client_for(monkeypatch, fleet) as client:
        response = client.post("/api/v1/fleet/recover", headers=_as_superadmin(monkeypatch, client))

    assert response.status_code == 429
    assert response.headers.get("retry-after") == "45"
    assert response.headers.get("x-tenant-id") == "tenant-prod-1"
    assert response.headers.get("x-request-id") == "req-op-xyz"

