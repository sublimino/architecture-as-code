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


# ── Degradation: unreachable is an outage, malformed is a bug ────────────────
#
# These cover the merge of two competing designs for this route. One proxied to
# the collector and 502'd on any failure -- honest, but the demo died whenever
# the proxy was down. The other always answered from derived tenant state, but
# could not express which situation produced the answer.
#
# The schema can express all three outcomes, so the route now distinguishes
# them. The malformed case above already asserts the third.

def _client_raising(exc):
    class Client:
        def __init__(self, **_kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
        async def get(self, _url): raise exc
    return Client


def test_unreachable_collector_degrades_to_a_labelled_derived_topology(monkeypatch):
    """An outage must not blank the page, and must not claim to be observed."""
    with client_for(monkeypatch, _client_raising(httpx.ConnectError("refused"))) as client:
        response = client.get("/api/trust-topology", headers=bearer(token_for()))

    assert response.status_code == 200
    body = response.json()
    assert body["collectors"]["kubernetes"]["status"] == "unavailable"
    assert "unreachable" in body["collectors"]["kubernetes"]["reason"]
    # The whole point: nothing derived may present itself as runtime evidence.
    assert body["nodes"], "a degraded response still has to describe the tenant"
    for item in body["nodes"] + body["edges"]:
        assert item["evidence_state"] == "modeled"
        assert item["assurance"] == "modeled"
    # And the gap is stated explicitly rather than left for the reader to infer.
    assert any(gap["id"] == "gap-live-collector" for gap in body["modeled_gaps"])


def test_collector_reporting_unavailable_is_treated_as_an_outage_not_as_data(monkeypatch):
    """Reachable and well-formed, but honestly reporting it collected nothing."""
    payload = {**SNAPSHOT, "collectors": {"kubernetes": {
        "status": "unavailable", "observed_at": "2026-08-11T16:00:00Z", "reason": "RBAC denied"}}}

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

    assert response.status_code == 200
    body = response.json()
    assert body["collectors"]["kubernetes"]["status"] == "unavailable"
    # The collector's own reason is carried through, not replaced by a guess.
    assert "RBAC denied" in body["collectors"]["kubernetes"]["reason"]


def test_empty_live_collector_is_returned_empty_and_not_back_filled(monkeypatch):
    """An empty estate is a real answer. Back-filling it would be fabrication."""
    class Response:
        def raise_for_status(self): pass
        def json(self): return SNAPSHOT  # collector ok, zero nodes

    class Client:
        def __init__(self, **_kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
        async def get(self, _url): return Response()

    with client_for(monkeypatch, Client) as client:
        response = client.get("/api/trust-topology", headers=bearer(token_for()))

    assert response.status_code == 200
    body = response.json()
    assert body["collectors"]["kubernetes"]["status"] == "ok"
    assert body["nodes"] == [] and body["edges"] == []
