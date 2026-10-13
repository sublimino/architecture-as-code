"""Tests verifying RFC 9110 Section 6.4.1 and Section 9.3.2 HEAD response body suppression,
GET/HEAD router dispatch parity, and HTTP method gates on fe-signalloom and demo-runner.
"""
import asyncio
import pytest
from fastapi.testclient import TestClient

from main import app
from demo_runner_main import app as runner_app


def test_head_body_suppression_on_health():
    client = TestClient(app)
    for path in ("/api/health", "/health", "/healthz", "/livez"):
        resp = client.head(path)
        assert resp.status_code == 200
        assert resp.content == b""
        assert resp.headers.get("content-type") == "application/json"


def test_head_body_suppression_on_404():
    client = TestClient(app)
    resp = client.head("/nonexistent/endpoint/path")
    assert resp.status_code == 404
    assert resp.content == b""
    assert "content-length" in resp.headers


def test_head_body_suppression_and_get_parity_on_main_routers():
    """Verify router-mounted read routes achieve GET/HEAD parity per RFC 9110 Section 9.3.2.

    When called with HEAD, status code and headers must match GET, with 0 response body bytes.
    """
    client = TestClient(app)
    read_routes = (
        "/api/v1/agents",
        "/api/v1/policies",
        "/api/v1/policies/validate",
        "/api/v1/policies/evaluate",
        "/api/v1/connectors/providers",
        "/api/v1/connectors/status",
        "/api/v1/connectors",
        "/api/features",
    )
    for route in read_routes:
        resp_get = client.get(route)
        resp_head = client.head(route)
        assert resp_head.status_code == resp_get.status_code, (
            f"HEAD {route} status {resp_head.status_code} != GET {resp_get.status_code}"
        )
        assert resp_head.headers.get("content-type") == resp_get.headers.get("content-type"), (
            f"HEAD {route} content-type mismatch"
        )
        assert resp_head.content == b"", f"HEAD {route} leaked body bytes: {resp_head.content!r}"


def test_post_only_routes_reject_non_post_and_suppress_head_body():
    """Verify POST-only endpoints reject GET, HEAD, PUT, DELETE, PATCH with 405 and Allow header,
    with 0 body bytes on HEAD and non-empty error body on other verbs.
    """
    client = TestClient(app)
    post_routes = (
        "/api/v1/agents/test-agent/transition",
        "/api/v1/connectors/conn-1/toggle",
        "/api/v1/connectors/conn-1/test",
    )
    for route in post_routes:
        # HEAD on POST-only route -> 405 Method Not Allowed, Allow: POST, 0 body bytes
        resp_head = client.head(route)
        assert resp_head.status_code == 405, f"HEAD {route} status {resp_head.status_code} != 405"
        assert resp_head.content == b"", f"HEAD {route} leaked body bytes: {resp_head.content!r}"
        assert "POST" in resp_head.headers.get("allow", ""), f"HEAD {route} missing Allow: POST"

        # GET on POST-only route -> 405 with error payload
        resp_get = client.get(route)
        assert resp_get.status_code == 405
        assert len(resp_get.content) > 0
        assert "POST" in resp_get.headers.get("allow", "")

        # Non-conforming mutating verbs -> 405 with error payload
        for method in ("PUT", "DELETE", "PATCH"):
            if route == "/api/v1/connectors/conn-1/toggle" and method == "DELETE":
                continue  # /connectors/{id} has a DELETE handler
            resp_m = client.request(method, route)
            assert resp_m.status_code == 405, f"{method} {route} status {resp_m.status_code} != 405"
            assert len(resp_m.content) > 0


def test_get_only_routes_reject_unsupported_methods_with_allow_header():
    """Verify GET-only routes reject mutating methods with 405 and Allow header."""
    client = TestClient(app)
    for method in ("POST", "PUT", "DELETE", "PATCH"):
        resp = client.request(method, "/api/health")
        assert resp.status_code == 405
        assert len(resp.content) > 0
        allow = resp.headers.get("allow", "")
        assert "GET" in allow


def test_demo_runner_main_head_body_suppression_and_get_parity():
    """Verify demo-runner main app enforces GET/HEAD parity and HEAD body suppression."""
    client = TestClient(runner_app)
    for path in ("/health", "/healthz"):
        resp = client.head(path)
        assert resp.status_code == 200
        assert resp.content == b""

    resp_ready = client.head("/readyz")
    assert resp_ready.status_code in (200, 503)
    assert resp_ready.content == b""

    resp_404 = client.head("/api/nonexistent")
    assert resp_404.status_code == 404
    assert resp_404.content == b""

    # Router read routes
    demo_read_routes = (
        "/api/demo/supercred/steps",
        "/api/demo/supercred/evidence",
        "/api/demo/supercred/status",
        "/api/demo/signalfusion/steps",
    )
    for route in demo_read_routes:
        resp_get = client.get(route)
        resp_head = client.head(route)
        assert resp_head.status_code == resp_get.status_code, (
            f"HEAD {route} status {resp_head.status_code} != GET {resp_get.status_code}"
        )
        assert resp_head.content == b"", f"HEAD {route} leaked body bytes: {resp_head.content!r}"

    # Demo runner POST-only routes
    demo_post_routes = (
        "/api/demo/supercred/runs",
        "/api/demo/supercred/reset",
        "/api/demo/signalfusion/runs",
    )
    for route in demo_post_routes:
        resp_head = client.head(route)
        assert resp_head.status_code == 405
        assert resp_head.content == b""
        assert "POST" in resp_head.headers.get("allow", "")

        resp_get = client.get(route)
        assert resp_get.status_code == 405
        assert len(resp_get.content) > 0

        for method in ("PUT", "DELETE", "PATCH"):
            resp_m = client.request(method, route)
            assert resp_m.status_code == 405
            assert len(resp_m.content) > 0


@pytest.mark.anyio
async def test_asgi_raw_head_body_suppression_across_statuses():
    """Verify ASGI messages directly to ensure uvicorn receives empty body on HEAD across status codes."""
    test_cases = [
        ("/api/health", 200),
        ("/api/v1/agents", 401),
        ("/api/v1/nonexistent", 404),
        ("/api/v1/agents/test-agent/transition", 405),
    ]

    for path, expected_status in test_cases:
        messages = []
        scope = {
            "type": "http",
            "method": "HEAD",
            "path": path,
            "raw_path": path.encode(),
            "headers": [],
            "query_string": b"",
        }

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            messages.append(message)

        await app(scope, receive, send)

        start_messages = [m for m in messages if m["type"] == "http.response.start"]
        assert len(start_messages) == 1
        assert start_messages[0]["status"] == expected_status, (
            f"HEAD {path} expected status {expected_status}, got {start_messages[0]['status']}"
        )

        body_messages = [m for m in messages if m["type"] == "http.response.body"]
        assert len(body_messages) >= 1
        for bm in body_messages:
            assert bm.get("body", b"") == b"", f"leaked body bytes on HEAD {path}: {bm}"


@pytest.mark.anyio
async def test_demo_runner_main_asgi_raw_head_body_suppression():
    messages = []
    scope = {
        "type": "http",
        "method": "HEAD",
        "path": "/api/nonexistent",
        "raw_path": b"/api/nonexistent",
        "headers": [],
        "query_string": b"",
    }

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        messages.append(message)

    await runner_app(scope, receive, send)

    body_messages = [m for m in messages if m["type"] == "http.response.body"]
    assert len(body_messages) >= 1
    for bm in body_messages:
        assert bm.get("body", b"") == b"", f"leaked body bytes on HEAD: {bm}"
