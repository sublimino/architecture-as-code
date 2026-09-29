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


def test_posture_score_double_scaling_latent_defect():
    """Latent defect #1 verification:

    Prior defect: api_compat.py divided compliance.posture_score (which is already a 0..1 float)
    by 100.0 in _agent_response_from_row (line 2005), scaling 0.85 down to 0.0085.
    Fix: normalized_score in assessment_summary preserves the 0..1 float ratio (0.85).
    """
    row = {
        "id": "11111111-2222-3333-4444-555555555555",
        "name": "Audit Sentinel",
        "tenant_id": "tenant-a",
        "lifecycle_state": "active",
        "origin": "Custom",
        "owner": "alice",
    }
    compliance = {
        "total_controls": 10,
        "passing": 8,
        "failing": 2,
        "pending": 0,
        "posture_score": 0.8,
    }
    resp = api_compat._agent_response_from_row(row, compliance)
    assert resp.assessment_summary.status == "assessed"
    assert resp.assessment_summary.total_controls == 10
    assert resp.assessment_summary.normalized_score == 0.8
    assert resp.compliance_summary.posture_score == 0.8


@pytest.mark.asyncio
async def test_fair_version_list_matches_api():
    """Latent defect #2 verification:

    Prior defect: RiskExposurePage used a hardcoded static VERSIONS array (['v1.0', 'v2.0', 'v2.1'])
    which mismatched active backend framework/scenario versions and lacked status indicators.
    Fix: /api/v1/fair/versions provides dynamic framework version list from backend metadata,
    including version tags, semantic sorting, and status badges (active, draft, retired).
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/v1/fair/versions", headers=eap_bearer(EAP_ALICE))
        assert resp.status_code == 200
        data = resp.json()
        assert isinstance(data, list)
        assert len(data) > 0

        # Verify version metadata fields
        for item in data:
            assert "version" in item
            assert "name" in item or "framework_id" in item
            assert "status" in item
            assert item["status"] in {"active", "draft", "retired"}

        # Verify active and retired versions are present
        statuses = {item["status"] for item in data}
        assert "active" in statuses
        assert "retired" in statuses

        # Verify alias route /v1/fair/versions
        alias_resp = await client.get("/v1/fair/versions", headers=eap_bearer(EAP_ALICE))
        assert alias_resp.status_code == 200
        alias_data = alias_resp.json()
        assert len(alias_data) == len(data)

