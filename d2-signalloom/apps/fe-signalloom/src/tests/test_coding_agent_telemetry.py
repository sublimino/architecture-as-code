import httpx as _httpx
import pytest
from fastapi.testclient import TestClient

from api_compat import Principal, authenticated_principal
from main import app


@pytest.fixture()
def ingest_mock(monkeypatch):
    state = {
        "status": 200,
        "body": {"status": "ok"},
        "content": None,
        "headers": {},
        "sent": [],
    }

    def handler(request: _httpx.Request) -> _httpx.Response:
        state["sent"].append(request)
        headers = dict(state.get("headers") or {})
        content = state.get("content")
        if content is not None:
            return _httpx.Response(status_code=state["status"], content=content, headers=headers)
        body = state.get("body")
        if body is None:
            return _httpx.Response(status_code=state["status"], headers=headers)
        return _httpx.Response(status_code=state["status"], json=body, headers=headers)

    real = _httpx.AsyncClient

    class Capturing(real):
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = _httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(_httpx, "AsyncClient", Capturing)
    app.dependency_overrides[authenticated_principal] = lambda: Principal(
        tenant="tenant-demo", subject="test-user", email=None
    )
    yield state
    app.dependency_overrides.pop(authenticated_principal, None)


def test_coding_agent_telemetry_routes_mounted():
    """Assert the /api/v1/telemetry/coding-agents routes exist and are handled by FastAPI."""
    client = TestClient(app, raise_server_exceptions=False)
    # Requesting without signal-ingest running should return 502/upstream_unavailable
    # which proves the route is correctly mounted in FastAPI and forwarding upstream,
    # rather than 404 (route missing) or 405 (SPA catch-all).
    resp = client.post(
        "/api/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code in (502, 504, 200, 201, 400, 401)
    assert resp.status_code != 404
    assert resp.status_code != 405


def test_coding_agent_telemetry_aggregate_route_mounted():
    """Assert the aggregate endpoint is mounted and proxies upstream."""
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get(
        "/api/v1/telemetry/coding-agents/aggregate",
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code in (502, 504, 200, 401, 422)
    assert resp.status_code != 404
    assert resp.status_code != 405


def test_coding_agent_telemetry_v1_alias_routes_mounted():
    """Assert the /v1/telemetry/coding-agents alias routes exist and are handled by FastAPI."""
    client = TestClient(app, raise_server_exceptions=False)
    # Test POST /v1/telemetry/coding-agents
    resp = client.post(
        "/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code in (502, 504, 200, 201, 400, 401)
    assert resp.status_code != 404
    assert resp.status_code != 405

    # Test GET /v1/telemetry/coding-agents/aggregate
    resp_agg = client.get(
        "/v1/telemetry/coding-agents/aggregate",
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp_agg.status_code in (502, 504, 200, 401, 422)
    assert resp_agg.status_code != 404
    assert resp_agg.status_code != 405

    # Test POST /v1/telemetry/coding-agents/ordering
    resp_ord = client.post(
        "/v1/telemetry/coding-agents/ordering",
        json={"event_a": {}, "event_b": {}},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp_ord.status_code in (502, 504, 200, 400, 401, 422)
    assert resp_ord.status_code != 404
    assert resp_ord.status_code != 405


def test_coding_agent_telemetry_proxy_handles_204_no_content(ingest_mock):
    """204 No Content must not emit a body or artificial payload per RFC 9110 Section 15.3.5."""
    ingest_mock["status"] = 204
    ingest_mock["body"] = None
    ingest_mock["content"] = b""
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code == 204
    assert resp.content == b""
    assert resp.text == ""
    assert "raw" not in resp.text


def test_coding_agent_telemetry_proxy_handles_empty_body(ingest_mock):
    """Empty upstream responses must return empty bytes rather than synthetic JSON errors."""
    ingest_mock["status"] = 200
    ingest_mock["body"] = None
    ingest_mock["content"] = b""
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get(
        "/api/v1/telemetry/coding-agents",
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code == 200
    assert resp.content == b""
    assert resp.text == ""


def test_coding_agent_telemetry_proxy_propagates_allow_header_on_405(ingest_mock):
    """405 Method Not Allowed must preserve RFC 9110 Section 15.5.6 Allow header."""
    ingest_mock["status"] = 405
    ingest_mock["body"] = {"error": "method not allowed"}
    ingest_mock["headers"] = {"Allow": "POST"}
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code == 405
    assert resp.headers.get("allow") == "POST"
    assert resp.json() == {"error": "method not allowed"}


def test_coding_agent_telemetry_proxy_propagates_location_and_etag(ingest_mock):
    """201 Created responses must propagate Location and ETag headers."""
    ingest_mock["status"] = 201
    ingest_mock["body"] = {"id": "event-123"}
    ingest_mock["headers"] = {
        "Location": "/api/v1/telemetry/coding-agents/event-123",
        "ETag": '"etag-event-123"',
    }
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code == 201
    assert resp.headers.get("location") == "/api/v1/telemetry/coding-agents/event-123"
    assert resp.headers.get("etag") == '"etag-event-123"'
    assert resp.json() == {"id": "event-123"}


def test_coding_agent_telemetry_proxy_propagates_retry_after_and_tenant(ingest_mock):
    """Retry-After, X-Tenant-ID, and X-Request-ID headers must be forwarded."""
    ingest_mock["status"] = 429
    ingest_mock["body"] = {"error": "rate limit exceeded"}
    ingest_mock["headers"] = {
        "Retry-After": "120",
        "X-Tenant-ID": "tenant-demo",
        "X-Request-ID": "req-telemetry-77",
    }
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code == 429
    assert resp.headers.get("retry-after") == "120"
    assert resp.headers.get("x-tenant-id") == "tenant-demo"
    assert resp.headers.get("x-request-id") == "req-telemetry-77"

