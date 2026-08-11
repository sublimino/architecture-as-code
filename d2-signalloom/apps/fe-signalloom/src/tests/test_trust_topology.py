from contextlib import contextmanager

import httpx
import pytest

import api_compat
from test_crypto_health import bearer, client_for, token_for


SNAPSHOT = {"generated_at": "2026-08-11T16:00:00Z", "version": "v1", "collectors": {"kubernetes": {"status": "ok", "observed_at": "2026-08-11T16:00:00Z", "reason": "fixed namespaces collected"}}, "nodes": [], "edges": [], "modeled_gaps": []}


def test_trust_topology_requires_bearer_auth(monkeypatch):
    class Client:
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
    with client_for(monkeypatch, Client) as client:
        response = client.get("/api/trust-topology")
    assert response.status_code == 401


def test_trust_topology_proxies_strict_schema_with_five_second_timeout(monkeypatch):
    class Response:
        def raise_for_status(self): pass
        def json(self): return SNAPSHOT
    class Client:
        def __init__(self, *, timeout): assert timeout == 5.0
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
        async def get(self, url):
            assert url == api_compat.TRUST_TOPOLOGY_URL
            return Response()
    with client_for(monkeypatch, Client) as client:
        response = client.get("/api/trust-topology", headers=bearer(token_for()))
    assert response.status_code == 200
    assert response.json()["version"] == "v1"


@pytest.mark.parametrize("payload", [{}, {**SNAPSHOT, "unexpected": True}])
def test_trust_topology_rejects_failed_or_malformed_proxy_payload(monkeypatch, payload):
    class Response:
        def raise_for_status(self): pass
        def json(self): return payload
    class Client:
        def __init__(self, **_kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
        async def get(self, _url): return Response()
    with client_for(monkeypatch, Client) as client:
        response = client.get("/api/trust-topology", headers=bearer(token_for()))
    assert response.status_code == 502
