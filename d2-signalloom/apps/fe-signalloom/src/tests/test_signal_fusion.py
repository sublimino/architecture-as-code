"""Tests for the signal fusion API routes and migration SQL.

Three concerns:
1. The router mounts and its routes are reachable.
2. Proxy calls handle connection errors gracefully (502/504, not 500).
3. The migration SQL is syntactically coherent (parsed for structural checks).
"""
from __future__ import annotations

import re
import urllib.parse
import textwrap
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from db.connection import set_pool_for_testing
from main import app

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

_MIGRATION_DIR = Path(__file__).resolve().parent.parent / "db" / "migrations"
_MIGRATION_FILE = _MIGRATION_DIR / "031_signal_fusion_provisional_actors.sql"


@pytest.fixture(autouse=True)
def _no_pool():
    """Run every test without a database pool."""
    set_pool_for_testing(None)


@pytest.fixture()
def client():
    return TestClient(app, raise_server_exceptions=False)


# ---------------------------------------------------------------------------
# 1. Router mounting
# ---------------------------------------------------------------------------


class TestRouterMounting:
    """The signal fusion router is reachable on the expected paths."""

    def test_signal_routes_registered(self):
        route_paths = set()
        for r in app.routes:
            if hasattr(r, "path"):
                route_paths.add(r.path)
            elif hasattr(r, "routes"):
                route_paths.update(sub.path for sub in r.routes if hasattr(sub, "path"))
            elif hasattr(r, "original_router") and hasattr(r.original_router, "routes"):
                route_paths.update(sub.path for sub in r.original_router.routes if hasattr(sub, "path"))
        expected = {
            "/api/signals/observations",
            "/api/signals/actors",
            "/api/signals/actors/{actor_id}",
            "/api/signals/actors/{actor_id}/promote",
            "/api/signals/coverage",
            "/api/signals/correlate",
            "/api/signals/collectors/seed",
        }
        missing = expected - route_paths
        assert not missing, f"Missing routes: {missing}"

    def test_unauthenticated_returns_401(self, client):
        """Signal routes require authentication like every other API route."""
        resp = client.get("/api/signals/observations")
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# 2. Proxy error handling
# ---------------------------------------------------------------------------


class TestProxyErrorHandling:
    """Connection failures to the Go service return 502/504, not 500."""

    @patch("signal_fusion.httpx.AsyncClient")
    def test_connect_error_returns_502(self, mock_client_cls, client):
        """An unreachable signal-ingest service returns 502."""
        import httpx as _httpx

        mock_instance = AsyncMock()
        mock_instance.request = AsyncMock(
            side_effect=_httpx.ConnectError("connection refused")
        )
        mock_instance.__aenter__ = AsyncMock(return_value=mock_instance)
        mock_instance.__aexit__ = AsyncMock(return_value=False)
        mock_client_cls.return_value = mock_instance

        # Bypass auth by patching the dependency
        from api_compat import Principal, authenticated_principal

        app.dependency_overrides[authenticated_principal] = lambda: Principal(tenant="tenant-demo", subject="test-user", email=None)
        try:
            resp = client.get("/api/signals/observations")
            assert resp.status_code == 502
            body = resp.json()
            assert body["error"]["code"] == "upstream_unavailable"
            assert "unreachable" in body["error"]["message"]
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)

    @patch("signal_fusion.httpx.AsyncClient")
    def test_timeout_returns_504(self, mock_client_cls, client):
        """A timed-out signal-ingest request returns 504."""
        import httpx as _httpx

        mock_instance = AsyncMock()
        mock_instance.request = AsyncMock(
            side_effect=_httpx.TimeoutException("read timeout")
        )
        mock_instance.__aenter__ = AsyncMock(return_value=mock_instance)
        mock_instance.__aexit__ = AsyncMock(return_value=False)
        mock_client_cls.return_value = mock_instance

        from api_compat import Principal, authenticated_principal

        app.dependency_overrides[authenticated_principal] = lambda: Principal(tenant="tenant-demo", subject="test-user", email=None)
        try:
            resp = client.get("/api/signals/observations")
            assert resp.status_code == 504
            body = resp.json()
            assert body["error"]["code"] == "upstream_timeout"
            assert "timed out" in body["error"]["message"]
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)

    def test_ingest_disconnect_returns_502_saying_so(self, client, monkeypatch, tmp_path):
        """signal-ingest dying mid-request (OOM-killed under /feeds polling, 2026-10-06) is a 502
        whose body says the service dropped the connection, not an opaque "proxy error"."""
        import httpx as _httpx

        from api_compat import Principal, authenticated_principal

        key = tmp_path / "token"
        key.write_text("k" * 43)
        monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(key))

        def handler(request: _httpx.Request) -> _httpx.Response:
            raise _httpx.RemoteProtocolError("Server disconnected without sending a response.", request=request)

        real = _httpx.AsyncClient

        class Dropping(real):  # type: ignore[misc, valid-type]
            def __init__(self, *args, **kwargs):
                kwargs["transport"] = _httpx.MockTransport(handler)
                super().__init__(*args, **kwargs)

        monkeypatch.setattr(_httpx, "AsyncClient", Dropping)
        app.dependency_overrides[authenticated_principal] = lambda: Principal(tenant="tenant-demo", subject="test-user", email=None)
        try:
            for path in ("/api/signals/store/stats", "/api/signals/observations"):
                resp = client.get(path)
                assert resp.status_code == 502, path
                err = resp.json()["error"]
                assert err["code"] == "upstream_unavailable", path
                assert "closed the connection" in err["message"], err
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)


class TestSeedProxy:
    """POST /api/signals/collectors/seed passes signal-ingest's answer through unchanged."""

    @pytest.fixture()
    def ingest(self, monkeypatch, tmp_path):
        import httpx as _httpx

        key = tmp_path / "token"
        key.write_text("k" * 43)
        monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(key))
        state: dict = {"status": 201, "body": {"seeded": 42}, "content": None, "headers": {}, "sent": []}

        def handler(request: _httpx.Request) -> _httpx.Response:
            state["sent"].append(request)
            resp_headers = dict(state.get("headers", {}))
            if state.get("content") is not None:
                return _httpx.Response(state["status"], content=state["content"], headers=resp_headers)
            if state.get("body") is not None:
                return _httpx.Response(state["status"], json=state["body"], headers=resp_headers)
            return _httpx.Response(state["status"], headers=resp_headers)

        real = _httpx.AsyncClient

        class Capturing(real):  # type: ignore[misc, valid-type]
            def __init__(self, *args, **kwargs):
                kwargs["transport"] = _httpx.MockTransport(handler)
                super().__init__(*args, **kwargs)

        monkeypatch.setattr(_httpx, "AsyncClient", Capturing)
        from api_compat import Principal, authenticated_principal

        app.dependency_overrides[authenticated_principal] = lambda: Principal(tenant="tenant-demo", subject="test-user", email=None)
        yield state
        app.dependency_overrides.pop(authenticated_principal, None)

    def test_seed_forwards_post_and_returns_created(self, client, ingest):
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 201
        assert resp.json() == {"seeded": 42}
        assert len(ingest["sent"]) == 1
        sent = ingest["sent"][0]
        assert sent.method == "POST"
        assert sent.url.path == "/api/v1/collectors/seed"

    def test_observations_forwards_after_and_before(self, client, ingest):
        resp = client.get("/api/signals/observations?after=2026-10-06T00:00:00Z&before=2026-10-06T23:59:59Z&layer=network_egress&limit=50")
        assert resp.status_code == 201
        assert len(ingest["sent"]) == 1
        req = ingest["sent"][0]
        assert req.method == "GET"
        assert "/api/v1/observations" in str(req.url)
        assert req.url.params["after"] == "2026-10-06T00:00:00Z"
        assert req.url.params["before"] == "2026-10-06T23:59:59Z"
        assert req.url.params["layer"] == "network_egress"
        assert req.url.params["limit"] == "50"

    def test_seed_failure_status_and_body_pass_through(self, client, ingest):
        """The live defect (ingest 500 "failed to seed fixtures") reaches the browser as itself."""
        ingest["status"] = 500
        ingest["body"] = {"error": "failed to seed fixtures"}
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 500
        assert resp.json() == {"error": "failed to seed fixtures"}

    def test_proxy_handles_204_no_content(self, client, ingest):
        """204 No Content must not emit a body or error payload per RFC 9110 Section 15.3.5."""
        ingest["status"] = 204
        ingest["body"] = None
        ingest["content"] = b""
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 204
        assert resp.content == b""
        assert resp.text == ""

    def test_proxy_handles_head_request(self, client, ingest):
        """HEAD requests must return empty body and suppress body emission."""
        ingest["status"] = 200
        ingest["body"] = [{"id": "obs-1", "layer": "network"}]
        ingest["content"] = None
        ingest["headers"] = {"Content-Type": "application/json"}
        resp = client.head("/api/signals/observations")
        assert resp.status_code == 200
        assert resp.content == b""
        assert resp.text == ""
        assert resp.headers.get("content-type") == "application/json"

    def test_proxy_propagates_allow_header_on_405(self, client, ingest):
        """405 Method Not Allowed must preserve RFC 9110 Section 15.5.6 Allow header."""
        ingest["status"] = 405
        ingest["body"] = {"error": "method not allowed"}
        ingest["headers"] = {"Allow": "POST"}
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 405
        assert resp.headers.get("allow") == "POST"
        assert resp.json() == {"error": "method not allowed"}

    def test_proxy_propagates_location_and_etag_headers(self, client, ingest):
        """201 Created responses must propagate Location and ETag headers."""
        ingest["status"] = 201
        ingest["body"] = {"seeded": 42}
        ingest["headers"] = {"Location": "/api/v1/collectors/seed/1", "ETag": '"etag-seed-1"'}
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 201
        assert resp.headers.get("location") == "/api/v1/collectors/seed/1"
        assert resp.headers.get("etag") == '"etag-seed-1"'
        assert resp.json() == {"seeded": 42}

    def test_proxy_propagates_retry_after_and_tenant_headers(self, client, ingest):
        """Retry-After, X-Tenant-ID, and X-Request-ID headers must be forwarded."""
        ingest["status"] = 429
        ingest["body"] = {"error": "rate limit exceeded"}
        ingest["headers"] = {
            "Retry-After": "30",
            "X-Tenant-ID": "tenant-prod-2",
            "X-Request-ID": "req-sig-44",
        }
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 429
        assert resp.headers.get("retry-after") == "30"
        assert resp.headers.get("x-tenant-id") == "tenant-prod-2"
        assert resp.headers.get("x-request-id") == "req-sig-44"

    def test_observations_forwards_cursor_and_relays_paging_headers(self, client, ingest):
        """GET /api/signals/observations forwards cursor param and relays X-Next-Cursor, Link, X-Result-Truncated."""
        ingest["status"] = 200
        ingest["body"] = [{"id": "obs-1", "timestamp": "2026-10-06T12:00:00Z"}]
        ingest["headers"] = {
            "x-next-cursor": "eyJ2IjoxLCJ0IjoiMjAyNi0xMC0wNlQxMjowMDowMFoiLCJpZCI6Im9icy0xIiwic2NvcGUiOiJhYmMifQ",
            "link": '<http://signal-ingest:8082/api/v1/observations?cursor=eyJ2Ijox...>; rel="next"',
            "x-result-truncated": "true",
        }
        resp = client.get("/api/signals/observations?limit=50&cursor=custom-cursor-123&layer=network")
        assert resp.status_code == 200
        assert resp.json() == [{"id": "obs-1", "timestamp": "2026-10-06T12:00:00Z"}]
        assert len(ingest["sent"]) == 1
        sent = ingest["sent"][0]
        assert sent.method == "GET"
        assert sent.url.path == "/api/v1/observations"
        assert sent.url.params["limit"] == "50"
        assert sent.url.params["cursor"] == "custom-cursor-123"
        assert sent.url.params["layer"] == "network"
        assert resp.headers.get("x-next-cursor") == ingest["headers"]["x-next-cursor"]
        assert resp.headers.get("x-result-truncated") == "true"

    def test_observations_link_points_at_the_gateway_not_signal_ingest(self, client, ingest):
        """The relayed Link must be followable through this gateway: signal-ingest's own Link
        names its internal path (/api/v1/observations), which the dashboard cannot reach."""
        next_cursor = "eyJ2IjoxLCJpZCI6Im9icy0yIn0"
        ingest["status"] = 200
        ingest["body"] = [{"id": "obs-1"}]
        ingest["headers"] = {
            "x-next-cursor": next_cursor,
            "link": f'</api/v1/observations?cursor={next_cursor}&limit=50>; rel="next"',
        }
        resp = client.get("/api/signals/observations?limit=50&cursor=old-cursor&layer=network")
        link = resp.headers.get("link")
        assert link is not None
        assert link.endswith('>; rel="next"')
        target = urllib.parse.urlsplit(link[1 : link.index(">")])
        assert target.path == "/api/signals/observations"
        assert urllib.parse.parse_qs(target.query) == {
            "limit": ["50"], "layer": ["network"], "cursor": [next_cursor],
        }

    def test_observations_last_page_carries_no_link(self, client, ingest):
        """No X-Next-Cursor means no next page, so no Link even if upstream sent one."""
        ingest["status"] = 200
        ingest["body"] = []
        ingest["headers"] = {
            "link": '</api/v1/observations?cursor=stale>; rel="next"',
            "x-result-truncated": "false",
        }
        resp = client.get("/api/signals/observations?limit=50")
        assert resp.headers.get("link") is None
        assert resp.headers.get("x-result-truncated") == "false"


# ---------------------------------------------------------------------------
# 3. Migration SQL structural checks
# ---------------------------------------------------------------------------


class TestMigrationSQL:
    """The migration file exists and is structurally sound."""

    def test_migration_file_exists(self):
        assert _MIGRATION_FILE.exists(), f"Missing: {_MIGRATION_FILE}"

    def test_migration_begins_and_commits(self):
        """The migration is wrapped in BEGIN/COMMIT."""
        sql = _MIGRATION_FILE.read_text()
        assert "BEGIN;" in sql
        assert "COMMIT;" in sql

    def test_creates_three_tables(self):
        """Three tables are created: provisional_actors, actor_evidence, signal_audit_trail."""
        sql = _MIGRATION_FILE.read_text()
        tables = re.findall(
            r"CREATE TABLE IF NOT EXISTS public\.(\w+)", sql
        )
        assert "provisional_actors" in tables
        assert "actor_evidence" in tables
        assert "signal_audit_trail" in tables
        assert len(tables) == 3

    def test_idempotent_create_statements(self):
        """Every CREATE TABLE uses IF NOT EXISTS."""
        sql = _MIGRATION_FILE.read_text()
        bare_creates = re.findall(r"CREATE TABLE(?! IF NOT EXISTS)", sql)
        assert not bare_creates, (
            f"Non-idempotent CREATE TABLE found: {bare_creates}"
        )

    def test_indexes_are_idempotent(self):
        """Every CREATE INDEX uses IF NOT EXISTS."""
        sql = _MIGRATION_FILE.read_text()
        bare_indexes = re.findall(r"CREATE INDEX(?! IF NOT EXISTS)", sql)
        assert not bare_indexes, (
            f"Non-idempotent CREATE INDEX found: {bare_indexes}"
        )

    def test_provisional_actors_references_agent_registry(self):
        """The FK from provisional_actors to agent_registry is present."""
        sql = _MIGRATION_FILE.read_text()
        assert "REFERENCES public.agent_registry(id)" in sql

    def test_actor_evidence_cascades_on_delete(self):
        """Deleting a provisional actor cascades to its evidence rows."""
        sql = _MIGRATION_FILE.read_text()
        assert "ON DELETE CASCADE" in sql

    def test_signal_audit_trail_event_types(self):
        """The signal_audit_trail CHECK constraint lists all expected event types."""
        sql = _MIGRATION_FILE.read_text()
        expected_types = {
            "observation_ingested",
            "correlation_run",
            "actor_created",
            "actor_updated",
            "actor_promoted",
            "actor_dismissed",
            "collector_run",
            "partition_dropped",
        }
        for event_type in expected_types:
            assert f"'{event_type}'" in sql, f"Missing event type: {event_type}"

    def test_bootstrap_contains_migration(self):
        """The bootstrap SQL includes the 031 migration markers."""
        bootstrap = (
            Path(__file__).resolve().parent.parent.parent.parent.parent
            / "contracts"
            / "discovery-portal-bootstrap.sql"
        )
        if not bootstrap.exists():
            pytest.skip("bootstrap SQL not found at expected path")
        content = bootstrap.read_text()
        assert "-- BEGIN 031_signal_fusion_provisional_actors.sql" in content
        assert "-- END 031_signal_fusion_provisional_actors.sql" in content
