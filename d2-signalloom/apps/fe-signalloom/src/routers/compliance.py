"""Compliance and regulatory frameworks routes.

Handles:
- Regulatory frameworks querying (/api/v1/compliance/frameworks and /api/v1/compliance/frameworks/{framework_id})
  with structured 404 error envelope when framework ID does not exist.
- Compliance scan execution (/api/v1/compliance/scan)
- Compliance posture summary (/api/v1/compliance/summary)
- Posture score calculation with strict [0.0, 100.0] bounds and double-scaling prevention.
"""
from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse

from api_compat import (
    _error_response,
    authenticated_tenant,
)
from policy_evaluation import calculate_posture_score

logger = logging.getLogger(__name__)

router = APIRouter(tags=["compliance"])

# Standard available regulatory frameworks
KNOWN_FRAMEWORKS: dict[str, dict[str, Any]] = {
    "eu-ai-act": {
        "id": "eu-ai-act",
        "name": "EU AI Act",
        "version": "v2.1.0",
        "regulatory_body": "European Commission",
        "description": "High-risk AI governance, technical robustness, and human oversight requirements.",
        "controls_count": 4,
    },
    "nist-800-53": {
        "id": "nist-800-53",
        "name": "NIST SP 800-53",
        "version": "v2.1.0",
        "regulatory_body": "NIST",
        "description": "Security and Privacy Controls for Information Systems and Organizations.",
        "controls_count": 5,
    },
    "cra": {
        "id": "cra",
        "name": "Cyber Resilience Act",
        "version": "v1.0.0",
        "regulatory_body": "European Union",
        "description": "Cybersecurity requirements for products with digital elements.",
        "controls_count": 3,
    },
    "soc-2": {
        "id": "soc-2",
        "name": "SOC 2 Type II",
        "version": "v1.2.0",
        "regulatory_body": "AICPA",
        "description": "Trust Services Criteria for Security, Availability, and Confidentiality.",
        "controls_count": 4,
    },
}


@router.get("/api/v1/compliance/frameworks/{framework_id}")
@router.get("/v1/compliance/frameworks/{framework_id}")
async def get_framework_by_id(
    framework_id: str,
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Retrieve details for a specific regulatory framework, or 404 with structured error envelope."""
    clean_id = framework_id.strip().lower()
    if clean_id not in KNOWN_FRAMEWORKS:
        logger.warning("Compliance framework query not found: %r", framework_id)
        return JSONResponse(
            status_code=404,
            content={
                "error": "framework_not_found",
                "message": f"Regulatory framework '{framework_id}' not found",
                "framework_id": framework_id,
                "available_frameworks": sorted(list(KNOWN_FRAMEWORKS.keys())),
            },
        )

    return JSONResponse(
        status_code=200,
        content=KNOWN_FRAMEWORKS[clean_id],
    )


@router.get("/api/v1/compliance/frameworks")
@router.get("/v1/compliance/frameworks")
async def list_frameworks(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """List available regulatory frameworks."""
    # Proxy to upstream policy engine if available, fallback to KNOWN_FRAMEWORKS
    from routers.policy_engine import proxy_policy_engine
    resp = await proxy_policy_engine(request, "frameworks", "compliance", tenant_id=tenant_id)
    if resp.status_code == 200:
        return resp
    # Fallback to local catalog if upstream is unavailable
    return JSONResponse(
        status_code=200,
        content=list(KNOWN_FRAMEWORKS.values()),
    )


@router.post("/api/v1/compliance/scan")
@router.post("/v1/compliance/scan")
async def scan_compliance(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Execute compliance scan across requested frameworks."""
    from routers.policy_engine import proxy_policy_engine
    return await proxy_policy_engine(request, "scan", "compliance", tenant_id=tenant_id)


@router.get("/api/v1/compliance/summary")
@router.get("/v1/compliance/summary")
async def get_compliance_summary(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Retrieve aggregate compliance summary with bounded posture score [0.0, 100.0]."""
    from routers.policy_engine import proxy_policy_engine
    resp = await proxy_policy_engine(request, "summary", "compliance", tenant_id=tenant_id)
    if resp.status_code == 200:
        import json
        try:
            body = json.loads(resp.body)
            # Ensure posture score is strictly bounded and double-scaling prevented
            raw_score = body.get("posture_score") or body.get("postureScore")
            total = body.get("total_controls", body.get("totalControls", 0))
            passed = body.get("controls_passing", body.get("passed", 0))
            failing = body.get("controls_failing", body.get("failed", 0))
            bounded_score = calculate_posture_score(
                passing=passed,
                total=total,
                failing=failing,
                raw_score=raw_score,
            )
            body["posture_score"] = bounded_score
            body["postureScore"] = bounded_score
            return JSONResponse(status_code=200, content=body)
        except Exception:
            return resp
    return resp


@router.post("/api/v1/compliance/posture/calculate")
@router.post("/v1/compliance/posture/calculate")
async def calculate_posture(request: Request) -> Response:
    """Calculate posture score with strict [0.0, 100.0] bounds and double-scaling prevention."""
    try:
        body = await request.json()
    except Exception as exc:
        return _error_response(400, "invalid_json", f"Malformed JSON request body: {exc}")

    total = body.get("total_controls", 0)
    passing = body.get("passing_controls", 0)
    failing = body.get("failing_controls", 0)
    pending = body.get("pending_controls", 0)
    raw_score = body.get("raw_score")
    evidence = body.get("evidence")
    require_evidence = body.get("require_evidence", False)

    score = calculate_posture_score(
        passing=passing,
        total=total,
        failing=failing,
        pending=pending,
        raw_score=raw_score,
        evidence=evidence,
        require_evidence=require_evidence,
    )

    return JSONResponse(
        status_code=200,
        content={
            "posture_score": score,
            "total_controls": total,
            "passing_controls": passing,
            "failing_controls": failing,
            "status": "assessed" if score is not None else "not_assessed",
        },
    )


def install_compliance_api(app: Any) -> None:
    """Mount the compliance router on the FastAPI application."""
    app.include_router(router)
