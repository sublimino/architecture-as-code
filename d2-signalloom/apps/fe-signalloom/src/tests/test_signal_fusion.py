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
        """All signal fusion routes appear in the app's route table."""
        route_paths = {r.path for r in app.routes if hasattr(r, "path")}
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
        from api_compat import authenticated_tenant

        app.dependency_overrides[authenticated_tenant] = lambda: "tenant-demo"
        try:
            resp = client.get("/api/signals/observations")
            assert resp.status_code == 502
            body = resp.json()
            assert body["error"]["code"] == "upstream_unavailable"
            assert "unreachable" in body["error"]["message"]
        finally:
            app.dependency_overrides.pop(authenticated_tenant, None)

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

        from api_compat import authenticated_tenant

        app.dependency_overrides[authenticated_tenant] = lambda: "tenant-demo"
        try:
            resp = client.get("/api/signals/observations")
            assert resp.status_code == 504
            body = resp.json()
            assert body["error"]["code"] == "upstream_timeout"
            assert "timed out" in body["error"]["message"]
        finally:
            app.dependency_overrides.pop(authenticated_tenant, None)


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
