"""Tests for agent compliance scanning, PostgreSQL reconciliation, and audit trail."""
import pytest
from httpx import AsyncClient, ASGITransport
import respx
import httpx

import api_compat
from main import app
from config import settings
from conftest import eap_bearer, EAP_ALICE, EAP_TENANT_A

EAP_AUTHENTICATED = True


class MockConnection:
    def __init__(self):
        self.executions = []

    async def fetch(self, query, *args):
        return [
            {
                "id": "agent-1",
                "name": "Sentinel Agent",
                "capabilities": ["inference"],
                "config": {"model": "claude-3-5-sonnet"},
                "policies_applied": ["nist-800-53", "eu-ai-act"],
                "framework_id": "nist-800-53",
                "framework_name": "NIST SP 800-53",
                "control_id": "c-1",
                "control_name": "AC-6 Least Privilege",
                "passed": True,
                "assessed_at": "2026-09-29T05:00:00Z",
            }
        ]

    async def execute(self, query, *args):
        self.executions.append((query, args))
        return "UPDATE 1"

    def transaction(self):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False


class MockPool:
    def __init__(self):
        self.conn = MockConnection()

    def acquire(self):
        return self.conn


@pytest.fixture(autouse=True)
def mock_pool(monkeypatch):
    pool = MockPool()

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    return pool


@pytest.mark.asyncio
async def test_compliance_policy_scan_full_journey():
    """Test policy compliance scan end-to-end with real scan results."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.post(f"{policy_engine_url}/api/v1/compliance/scan").mock(
            return_value=httpx.Response(
                200,
                json=[
                    {
                        "framework": "nist-800-53",
                        "controlSet": "AC - Access Control",
                        "control": "AC-6 Least Privilege",
                        "check": "check-least-privilege",
                        "passed": True,
                        "policyVersion": "v2.1.0",
                        "ale": 0.0,
                        "var95": 0.0,
                        "tvar": 0.0,
                        "carriedGbp": 0.0,
                        "scanTimestamp": "2026-09-29T05:10:00Z",
                        "calibrationSource": "industry-indicative",
                    }
                ],
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            scan_request = {
                "namespace": "default",
                "policyVersion": "v2.1.0",
                "frameworks": ["nist-800-53"],
            }
            resp = await client.post("/api/compliance/policy/scan", json=scan_request, headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 200
            data = resp.json()
            assert "checks" in data
            assert len(data["checks"]) == 1
            assert data["checks"][0]["framework"] == "nist-800-53"
            assert data["checks"][0]["passed"] is True
            assert "summary" in data
            assert data["summary"]["passed"] == 1


@pytest.mark.asyncio
async def test_compliance_policy_scan_fallback():
    """Test policy compliance scan falls back gracefully when policy engine is offline."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.post(f"{policy_engine_url}/api/v1/compliance/scan").mock(
            side_effect=httpx.ConnectError("Connection refused")
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            scan_request = {
                "namespace": "default",
                "policyVersion": "v1.0.0",
                "frameworks": ["eu-ai-act"],
            }
            resp = await client.post("/api/compliance/policy/scan", json=scan_request, headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 200
            data = resp.json()
            assert "checks" in data
            assert "summary" in data
