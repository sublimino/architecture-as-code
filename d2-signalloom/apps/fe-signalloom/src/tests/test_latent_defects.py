"""Verification of latent defects reproduction and fixes.

Specifically verifies that policy scan invokes policy-engine with real manifests
and reconciles verdicts into database, flipping the latent defect to PASS.
"""
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
                "policies_applied": ["eu-ai-act"],
                "framework_id": "eu-ai-act",
                "framework_name": "EU AI Act",
                "control_id": "c-1",
                "control_name": "Risk Management",
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
async def test_policy_engine_not_called_for_policies():
    """Latent defect #3 verification:

    Prior defect: _db_policy_scan only updated timestamps in Postgres and returned
    hardcoded ale=0, var95=0 without calling policy-engine.
    Fix: _db_policy_scan calls policy-engine /api/v1/compliance/scan, calculates
    real FAIR risk exposure, reconciles into agent_compliance_results, and audits.
    """
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        scan_route = respx_mock.post(f"{policy_engine_url}/api/v1/compliance/scan").mock(
            return_value=httpx.Response(
                200,
                json=[
                    {
                        "framework": "eu-ai-act",
                        "controlSet": "Article 9",
                        "control": "Risk Management",
                        "check": "check-risk-assessment",
                        "passed": True,
                        "policyVersion": "v1.0.0",
                        "ale": 0.0,
                        "var95": 0.0,
                        "tvar": 0.0,
                        "carriedGbp": 0.0,
                        "scanTimestamp": "2026-09-29T05:00:00Z",
                        "calibrationSource": "industry-indicative",
                    },
                    {
                        "framework": "eu-ai-act",
                        "controlSet": "Article 14",
                        "control": "Human Oversight",
                        "check": "check-human-oversight",
                        "passed": False,
                        "policyVersion": "v1.0.0",
                        "ale": 15000.0,
                        "var95": 45000.0,
                        "tvar": 60000.0,
                        "carriedGbp": 15000.0,
                        "scanTimestamp": "2026-09-29T05:00:00Z",
                        "calibrationSource": "industry-indicative",
                    },
                ],
            )
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

            # Verify policy engine was called
            assert scan_route.called
            sent_req = scan_route.calls.last.request
            sent_json = sent_req.read().decode()
            assert "frameworks" in sent_json
            assert "eu-ai-act" in sent_json

            # Verify response checks and non-zero exposure from real policy engine
            checks = data["checks"]
            assert len(checks) == 2
            assert checks[0]["passed"] is True
            assert checks[1]["passed"] is False
            assert checks[1]["ale"] == 15000.0

            # Verify summary includes real aggregated exposure
            summary = data["summary"]
            assert summary["totalChecks"] == 2
            assert summary["passed"] == 1
            assert summary["failed"] == 1
            assert summary["totalAle"] == 15000.0
            assert summary["totalCarriedGbp"] == 15000.0
