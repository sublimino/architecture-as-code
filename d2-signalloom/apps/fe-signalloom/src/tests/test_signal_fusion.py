"""Tests for the signal fusion API routes and migration SQL.

Three concerns:
1. The router mounts and its routes are reachable.
2. Proxy calls handle connection errors gracefully (502/504, not 500).
3. The migration SQL is syntactically coherent (parsed for structural checks).
"""
from __future__ import annotations

import re
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
        state: dict = {"status": 201, "body": {"seeded": 42}, "sent": []}

        def handler(request: _httpx.Request) -> _httpx.Response:
            state["sent"].append(request)
            return _httpx.Response(state["status"], json=state["body"])

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

    def test_seed_failure_status_and_body_pass_through(self, client, ingest):
        """The live defect (ingest 500 "failed to seed fixtures") reaches the browser as itself."""
        ingest["status"] = 500
        ingest["body"] = {"error": "failed to seed fixtures"}
        resp = client.post("/api/signals/collectors/seed")
        assert resp.status_code == 500
        assert resp.json() == {"error": "failed to seed fixtures"}


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
