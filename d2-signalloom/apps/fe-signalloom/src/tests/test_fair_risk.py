"""Tests for OpenFAIR risk API routes and proxy forwarding in fe-signalloom."""
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


class TestFairRiskEndpoints:
    """FAIR risk API routes and version metadata."""

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
