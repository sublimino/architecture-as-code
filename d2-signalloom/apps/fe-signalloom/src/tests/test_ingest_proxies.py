"""Every fe-signalloom route that calls signal-ingest presents the gateway key and the verified
user's tenant — and nothing a client wrote can change which tenant that is.

The outbound requests are captured at the httpx transport, so these assert what actually leaves
fe-signalloom, not what a helper returned.
"""
from __future__ import annotations

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from api_compat import Principal, authenticated_principal
from db.connection import set_pool_for_testing
from main import app

GATEWAY_KEY = "gWk7x2Lq9pN4cR8tY1kD6hF3jS5aZ0mE7uB2oG9iX4w"
USER = Principal(tenant="kusari", subject="alice", email="alice@kusari.example")
ADMIN = Principal(tenant="tenant-demo", subject="root", email="root@signalloom.local")

# (method, fe path, signal-ingest path, acts for the user's own tenant even for a superadmin)
SIGNAL_ROUTES = [
    ("GET", "/api/signals/observations", "/api/v1/observations", False),
    ("GET", "/api/signals/actors", "/api/v1/actors", False),
    ("GET", "/api/signals/actors/actor-1", "/api/v1/actors/actor-1", False),
    ("GET", "/api/signals/actors/actor-1/authorization", "/api/v1/actors/actor-1/authorization", False),
    ("GET", "/api/signals/authorization", "/api/v1/authorization", False),
    ("POST", "/api/signals/actors/actor-1/promote", "/api/v1/actors/actor-1/promote", False),
    ("GET", "/api/signals/coverage", "/api/v1/coverage", False),
    ("POST", "/api/signals/correlate", "/api/v1/correlate", False),
    ("GET", "/api/signals/store/stats", "/api/v1/store/stats", False),
    ("POST", "/api/signals/collectors/seed", "/api/v1/collectors/seed", True),
    ("GET", "/api/v1/risk/agents/agent-1", "/api/v1/risk/agents/agent-1", False),
    ("GET", "/api/v1/risk/fleet", "/api/v1/risk/fleet", False),
    ("POST", "/api/v1/telemetry/coding-agents", "/api/v1/telemetry/coding-agents", True),
    ("GET", "/api/v1/telemetry/coding-agents", "/api/v1/telemetry/coding-agents", True),
    ("GET", "/api/v1/telemetry/coding-agents/aggregate", "/api/v1/telemetry/coding-agents/aggregate", True),
    ("POST", "/api/v1/telemetry/coding-agents/ordering", "/api/v1/telemetry/coding-agents/ordering", True),
]


@pytest.fixture(autouse=True)
def _env(tmp_path, monkeypatch):
    set_pool_for_testing(None)
    key = tmp_path / "token"
    key.write_text(GATEWAY_KEY)
    monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(key))
    import superadmin

    monkeypatch.setattr(superadmin.settings, "api_superadmin_emails", ["root@signalloom.local"], raising=False)
    monkeypatch.setattr(superadmin.settings, "api_superadmin_subjects", ["root"], raising=False)
    yield
    app.dependency_overrides.pop(authenticated_principal, None)


@pytest.fixture()
def outbound(monkeypatch):
    """Capture every request fe-signalloom sends through httpx.AsyncClient."""
    sent: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(request)
        if request.url.path.endswith("/stream"):
            return httpx.Response(200, content=b"event: connected\ndata: {}\n\n", headers={"content-type": "text/event-stream"})
        return httpx.Response(200, json={})

    real = httpx.AsyncClient

    class Capturing(real):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", Capturing)
    return sent


def call(principal, method, path, headers=None):
    app.dependency_overrides[authenticated_principal] = lambda: principal
    client = TestClient(app, raise_server_exceptions=False)
    body = json.dumps({"event": "x"}) if method == "POST" else None
    return client.request(method, path, headers={"Authorization": "Bearer user-dex-token", **(headers or {})}, content=body)


def only(sent, path):
    matching = [r for r in sent if r.url.path == path]
    assert len(matching) == 1, f"expected one request to {path}, saw {[r.url.path for r in sent]}"
    return matching[0]


@pytest.mark.parametrize("method,path,upstream,own_tenant", SIGNAL_ROUTES)
def test_every_proxy_sends_the_gateway_key_and_the_users_tenant(outbound, method, path, upstream, own_tenant):
    resp = call(USER, method, path)
    assert resp.status_code == 200, resp.text
    req = only(outbound, upstream)
    assert req.headers["authorization"] == f"Bearer {GATEWAY_KEY}"
    assert req.headers["x-signalloom-acting-tenant"] == "kusari"
    assert req.headers["x-signalloom-acting-subject"] == "alice"
    # The user's own token is for fe-signalloom; signal-ingest never sees it.
    assert "user-dex-token" not in str(req.headers)


@pytest.mark.parametrize("method,path,upstream,own_tenant", SIGNAL_ROUTES)
def test_a_superadmin_reads_across_tenants_but_writes_as_its_own(outbound, method, path, upstream, own_tenant):
    assert call(ADMIN, method, path).status_code == 200
    expected = "tenant-demo" if own_tenant else "*"
    assert only(outbound, upstream).headers["x-signalloom-acting-tenant"] == expected


@pytest.mark.parametrize("method,path,upstream,own_tenant", SIGNAL_ROUTES)
def test_client_written_tenant_headers_change_nothing(outbound, method, path, upstream, own_tenant):
    forged = {"X-SignalLoom-Acting-Tenant": "*", "X-SignalLoom-Acting-Subject": "root", "X-Tenant-ID": "tenant-b"}
    assert call(USER, method, path, headers=forged).status_code == 200
    req = only(outbound, upstream)
    assert req.headers["x-signalloom-acting-tenant"] == "kusari"
    assert req.headers["x-signalloom-acting-subject"] == "alice"
    assert req.headers.get("x-tenant-id") in (None, "kusari")


def test_the_observation_stream_sends_the_gateway_key(outbound):
    resp = call(USER, "GET", "/api/signals/observations/stream")
    assert resp.status_code == 200
    req = only(outbound, "/api/v1/observations/stream")
    assert req.headers["authorization"] == f"Bearer {GATEWAY_KEY}"
    assert req.headers["x-signalloom-acting-tenant"] == "kusari"


def test_no_key_mounted_is_a_503_and_nothing_is_sent(outbound, monkeypatch, tmp_path):
    monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(tmp_path / "absent"))
    resp = call(USER, "GET", "/api/signals/observations")
    assert resp.status_code == 503
    assert outbound == []


def test_an_unauthenticated_caller_is_401_and_nothing_is_sent(outbound):
    client = TestClient(app, raise_server_exceptions=False)
    assert client.get("/api/signals/observations").status_code == 401
    assert client.get("/api/v1/telemetry/coding-agents").status_code == 401
    assert outbound == []


def test_the_federation_proxy_never_forwards_a_client_written_acting_tenant(outbound):
    forged = {"X-SignalLoom-Acting-Tenant": "*", "X-SignalLoom-Acting-Subject": "root"}
    call(USER, "GET", "/api/v1/federation/peers", headers=forged)
    req = only(outbound, "/api/v1/federation/peers")
    assert "x-signalloom-acting-tenant" not in req.headers
    assert "x-signalloom-acting-subject" not in req.headers


# The claim flows sync delegation edges into signal-ingest outside any request handler, so they name
# the claiming tenant explicitly. Without one they send nothing rather than an unscoped write.
import asyncio  # noqa: E402

import agent_claim  # noqa: E402


@pytest.fixture()
def ingest_url(monkeypatch):
    monkeypatch.setattr(agent_claim, "SIGNAL_INGEST_URL", "http://signal-ingest:8082")


def test_a_claim_delegation_acts_for_the_claiming_tenant(outbound, ingest_url):
    assert asyncio.run(agent_claim.sync_claim_delegation_to_spine("agent-1", "op-1", "claim-1", tenant="kusari", subject="alice"))
    assert asyncio.run(agent_claim.clamp_claim_delegation_in_spine("agent-1", "claim-1", tenant="kusari", subject="alice"))
    for path in ("/api/v1/delegations", "/api/v1/delegations/clamp"):
        req = only(outbound, path)
        assert req.headers["authorization"] == f"Bearer {GATEWAY_KEY}"
        assert req.headers["x-signalloom-acting-tenant"] == "kusari"


@pytest.mark.parametrize("tenant", [None, "", "*", "kusarі"])
def test_a_claim_delegation_without_a_usable_tenant_sends_nothing(outbound, ingest_url, tenant):
    assert not asyncio.run(agent_claim.sync_claim_delegation_to_spine("agent-1", "op-1", "claim-1", tenant=tenant))
    assert not asyncio.run(agent_claim.clamp_claim_delegation_in_spine("agent-1", "claim-1", tenant=tenant))
    assert outbound == []
