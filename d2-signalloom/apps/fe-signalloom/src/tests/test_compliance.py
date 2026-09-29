"""Adversarial tests for compliance, regulatory frameworks, and posture scoring.

Tests:
1. Regulatory framework query: non-existent framework ID returns 404 with structured error envelope.
2. Posture score calculation edge cases:
   - Empty controls (returns None / Not assessed)
   - 100% failing controls (returns strictly 0.0)
   - 100% passing controls (returns strictly 100.0)
   - Missing evidence handling (penalizes score when required evidence is missing)
   - Strict [0.0, 100.0] bounding (clamps negative and overflow scores, handles NaN/Inf)
   - Double-scaling prevention (guards against 85 -> 8500 double multiplication)
3. Endpoints: /api/v1/compliance/frameworks/{id}, /api/v1/compliance/posture/calculate.
"""
import pytest
from httpx import ASGITransport, AsyncClient

from conftest import EAP_ALICE, EAP_TENANT_A, eap_bearer
from main import app
from policy_evaluation import calculate_posture_score

EAP_AUTHENTICATED = True


def test_posture_score_empty_controls():
    """Verify posture score calculation with 0 controls returns None (Not assessed)."""
    assert calculate_posture_score(passing=0, total=0) is None
    assert calculate_posture_score(passing=0, total=-1) is None
    assert calculate_posture_score(passing=0, total=0, raw_score=None) is None


def test_posture_score_100_percent_failing():
    """Verify 100% failing controls returns strictly 0.0."""
    score = calculate_posture_score(passing=0, total=10, failing=10)
    assert score == 0.0
    assert isinstance(score, float)

    # Edge case: raw score 0.0
    assert calculate_posture_score(passing=0, total=5, raw_score=0.0) == 0.0


def test_posture_score_100_percent_passing():
    """Verify 100% passing controls returns strictly 100.0."""
    score = calculate_posture_score(passing=10, total=10, failing=0)
    assert score == 100.0

    # With decimal ratio raw_score = 1.0
    assert calculate_posture_score(passing=5, total=5, raw_score=1.0) == 100.0
    # With already scaled raw_score = 100.0
    assert calculate_posture_score(passing=5, total=5, raw_score=100.0) == 100.0


def test_posture_score_missing_evidence():
    """Verify missing evidence penalizes posture score when evidence is required."""
    # 100% passing controls, but required evidence is missing (None)
    score_missing_none = calculate_posture_score(
        passing=10, total=10, evidence=None, require_evidence=True
    )
    assert score_missing_none == 0.0

    # 100% passing controls, but required evidence is empty list
    score_missing_empty = calculate_posture_score(
        passing=10, total=10, evidence=[], require_evidence=True
    )
    assert score_missing_empty == 0.0

    # Valid evidence provided
    score_with_evidence = calculate_posture_score(
        passing=10,
        total=10,
        evidence=["sha256:abc123evidencehash"],
        require_evidence=True,
    )
    assert score_with_evidence == 100.0


def test_posture_score_strict_bounding():
    """Verify posture scores are strictly bounded within [0.0, 100.0]."""
    # Negative values clamped to 0.0
    assert calculate_posture_score(passing=0, total=10, raw_score=-25.0) == 0.0
    assert calculate_posture_score(passing=0, total=10, raw_score=-0.01) == 0.0

    # Overflow values clamped to 100.0
    assert calculate_posture_score(passing=10, total=10, raw_score=125.0) == 100.0
    assert calculate_posture_score(passing=10, total=10, raw_score=999999.0) == 100.0

    # NaN and Inf handled safely without crashing
    assert calculate_posture_score(passing=0, total=10, raw_score=float("nan")) == 0.0
    assert calculate_posture_score(passing=0, total=10, raw_score=float("inf")) == 0.0
    assert calculate_posture_score(passing=0, total=10, raw_score=float("-inf")) == 0.0


def test_posture_score_double_scaling_prevention():
    """Verify double-scaling is prevented when score is already scaled."""
    # 1. Ratio 0.85 -> scaled to 85.0
    score_ratio = calculate_posture_score(passing=8, total=10, raw_score=0.85)
    assert score_ratio == 85.0

    # 2. Already percentage 85.0 -> preserved as 85.0, NOT scaled to 8500.0
    score_pct = calculate_posture_score(passing=8, total=10, raw_score=85.0)
    assert score_pct == 85.0
    assert score_pct != 8500.0

    # 3. Latent double-scaled value (8500.0) -> restored to 85.0
    score_repaired = calculate_posture_score(passing=8, total=10, raw_score=8500.0)
    assert score_repaired == 85.0


@pytest.mark.asyncio
async def test_regulatory_framework_query_not_found_returns_404():
    """Verify querying non-existent framework ID returns 404 with structured error envelope."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Query non-existent framework ID
        resp = await client.get(
            "/api/v1/compliance/frameworks/non-existent-framework-xyz",
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp.status_code == 404
        data = resp.json()
        assert data["error"] == "framework_not_found"
        assert "non-existent-framework-xyz" in data["message"]
        assert data["framework_id"] == "non-existent-framework-xyz"
        assert isinstance(data["available_frameworks"], list)
        assert "eu-ai-act" in data["available_frameworks"]
        assert "nist-800-53" in data["available_frameworks"]
        assert "Traceback" not in resp.text


@pytest.mark.asyncio
async def test_regulatory_framework_query_existing_returns_200():
    """Verify querying valid framework ID returns 200 with framework details."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get(
            "/api/v1/compliance/frameworks/eu-ai-act",
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["id"] == "eu-ai-act"
        assert data["name"] == "EU AI Act"
        assert "controls_count" in data


@pytest.mark.asyncio
async def test_api_compliance_posture_calculate_endpoint():
    """Verify POST /api/v1/compliance/posture/calculate handles all edge cases."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. Empty controls -> posture_score: null, status: not_assessed
        resp_empty = await client.post(
            "/api/v1/compliance/posture/calculate",
            json={"total_controls": 0, "passing_controls": 0},
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp_empty.status_code == 200
        assert resp_empty.json()["posture_score"] is None
        assert resp_empty.json()["status"] == "not_assessed"

        # 2. 100% failing -> posture_score: 0.0
        resp_fail = await client.post(
            "/api/v1/compliance/posture/calculate",
            json={"total_controls": 5, "passing_controls": 0, "failing_controls": 5},
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp_fail.status_code == 200
        assert resp_fail.json()["posture_score"] == 0.0

        # 3. 100% passing -> posture_score: 100.0
        resp_pass = await client.post(
            "/api/v1/compliance/posture/calculate",
            json={"total_controls": 5, "passing_controls": 5, "failing_controls": 0},
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp_pass.status_code == 200
        assert resp_pass.json()["posture_score"] == 100.0

        # 4. Double-scaling prevention on API
        resp_scale = await client.post(
            "/api/v1/compliance/posture/calculate",
            json={"total_controls": 5, "raw_score": 85.0},
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp_scale.status_code == 200
        assert resp_scale.json()["posture_score"] == 85.0
