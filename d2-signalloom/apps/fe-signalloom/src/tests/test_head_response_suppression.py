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
