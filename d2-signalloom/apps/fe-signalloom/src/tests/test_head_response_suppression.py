"""Tests verifying RFC 9110 Section 6.4.1 HEAD response body suppression on fe-signalloom."""
import asyncio
import pytest
from fastapi.testclient import TestClient

from main import app


def test_head_body_suppression_on_health():
    client = TestClient(app)
    resp = client.head("/api/health")
    assert resp.status_code == 200
    assert resp.content == b""


def test_head_body_suppression_on_404():
    client = TestClient(app)
    resp = client.head("/nonexistent/endpoint/path")
    assert resp.status_code == 404
    assert resp.content == b""
    assert "content-length" in resp.headers


@pytest.mark.anyio
async def test_asgi_raw_head_body_suppression():
    """Verify ASGI messages directly to ensure uvicorn receives empty body on HEAD."""
    messages = []

    scope = {
        "type": "http",
        "method": "HEAD",
        "path": "/api/v1/nonexistent",
        "raw_path": b"/api/v1/nonexistent",
        "headers": [],
        "query_string": b"",
    }

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        messages.append(message)

    await app(scope, receive, send)

    body_messages = [m for m in messages if m["type"] == "http.response.body"]
    assert len(body_messages) >= 1
    for bm in body_messages:
        assert bm.get("body", b"") == b"", f"leaked body bytes on HEAD: {bm}"


def test_demo_runner_main_head_body_suppression():
    from demo_runner_main import app as runner_app
    client = TestClient(runner_app)
    for path in ("/health", "/healthz"):
        resp = client.head(path)
        assert resp.status_code == 200
        assert resp.content == b""

    resp_ready = client.head("/readyz")
    assert resp_ready.status_code in (200, 503)
    assert resp_ready.content == b""

    resp_404 = client.head("/api/agents")
    assert resp_404.status_code == 404
    assert resp_404.content == b""


@pytest.mark.anyio
async def test_demo_runner_main_asgi_raw_head_body_suppression():
    from demo_runner_main import app as runner_app
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

