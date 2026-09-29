"""Tests for OpenFAIR risk API routes in fe-signalloom.

Validates:
1. Router mounts /api/v1/risk/agents/{agent_id} and /api/v1/risk/fleet (and /v1/risk/* aliases).
2. Proxy forwards requests to signal-ingest and propagates responses.
3. Proxy errors (502/504) are handled gracefully.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient

from api_compat import authenticated_tenant
from db.connection import set_pool_for_testing
from main import app


@pytest.fixture(autouse=True)
def _no_pool():
    set_pool_for_testing(None)


@pytest.fixture(autouse=True)
def _auth_override():
    app.dependency_overrides[authenticated_tenant] = lambda: "tenant-demo"
    yield
    app.dependency_overrides.pop(authenticated_tenant, None)


@pytest.fixture()
def client():
    return TestClient(app, raise_server_exceptions=False)


class TestRiskRouterMounting:
    """The OpenFAIR risk routes are registered in the FastAPI app."""

    def test_risk_routes_registered(self):
        route_paths = {r.path for r in app.routes if hasattr(r, "path")}
        expected = {
            "/api/v1/risk/agents/{agent_id:path}",
            "/api/v1/risk/fleet",
            "/v1/risk/agents/{agent_id:path}",
            "/v1/risk/fleet",
            "/api/v1/fair/versions",
            "/v1/fair/versions",
        }
        missing = expected - route_paths
        assert not missing, f"Missing risk routes: {missing}"

    def test_fair_versions_route(self, client: TestClient):
        resp = client.get("/api/v1/fair/versions")
        assert resp.status_code == 200
        data = resp.json()
        assert isinstance(data, list)
        assert len(data) > 0
        assert any(item.get("status") == "active" for item in data)


class TestRiskProxyBehavior:
    """Risk proxy handles responses and errors properly."""

    def test_get_agent_risk_proxied(self, client: TestClient):
        mock_resp = httpx.Response(
            200,
            json={
                "agentId": "kagent-incident-responder",
                "currency": "GBP",
                "ale": 12500.0,
                "pml": 45000.0,
                "tier": "monitored",
                "source": "riskctl",
            },
            request=httpx.Request("GET", "http://signal-ingest:8082/api/v1/risk/agents/kagent-incident-responder"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.get("/api/v1/risk/agents/kagent-incident-responder")
            assert resp.status_code == 200
            data = resp.json()
            assert data["agentId"] == "kagent-incident-responder"
            assert data["source"] == "riskctl"
            assert data["ale"] == 12500.0

    def test_get_agent_risk_404(self, client: TestClient):
        mock_resp = httpx.Response(
            404,
            json={"error": "agent not found"},
            request=httpx.Request("GET", "http://signal-ingest:8082/api/v1/risk/agents/non-existent-agent"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.get("/api/v1/risk/agents/non-existent-agent")
            assert resp.status_code == 404
            assert resp.json()["error"] == "agent not found"

    def test_get_fleet_risk_proxied(self, client: TestClient):
        mock_resp = httpx.Response(
            200,
            json={
                "currency": "GBP",
                "agentCount": 50,
                "exposure": {"ale": {"amount": 500000.0, "currency": "GBP"}},
                "source": "riskctl",
            },
            request=httpx.Request("GET", "http://signal-ingest:8082/api/v1/risk/fleet"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.get("/api/v1/risk/fleet")
            assert resp.status_code == 200
            data = resp.json()
            assert data["agentCount"] == 50
            assert data["source"] == "riskctl"

    def test_risk_service_unreachable(self, client: TestClient):
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.side_effect = httpx.ConnectError("Connection refused")
            resp = client.get("/api/v1/risk/agents/kagent-incident-responder")
            assert resp.status_code == 502
            assert resp.json()["error"]["code"] == "upstream_unavailable"


class TestRiskAuthentication:
    """Risk endpoints enforce Bearer authentication and tenant isolation."""

    def test_unauthenticated_agent_risk_returns_401(self, client: TestClient):
        app.dependency_overrides.pop(authenticated_tenant, None)
        try:
            resp = client.get("/api/v1/risk/agents/kagent-incident-responder")
            assert resp.status_code == 401
            resp_alias = client.get("/v1/risk/agents/kagent-incident-responder")
            assert resp_alias.status_code == 401
        finally:
            app.dependency_overrides[authenticated_tenant] = lambda: "tenant-demo"

    def test_unauthenticated_fleet_risk_returns_401(self, client: TestClient):
        app.dependency_overrides.pop(authenticated_tenant, None)
        try:
            resp = client.get("/api/v1/risk/fleet")
            assert resp.status_code == 401
            resp_alias = client.get("/v1/risk/fleet")
            assert resp_alias.status_code == 401
        finally:
            app.dependency_overrides[authenticated_tenant] = lambda: "tenant-demo"
