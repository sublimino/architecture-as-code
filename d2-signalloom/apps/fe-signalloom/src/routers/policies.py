"""Policies and Policy-as-Code CEL evaluation routes.

Handles:
- CEL syntax and type validation (/api/v1/policies/validate)
- Policy evaluation with structured error diagnostics (/api/v1/policies/evaluate)
- Bundle lifecycle and version rollback (/api/v1/policies/bundles, /api/v1/policies/rollback)
- Listing active policy bundles (/api/v1/policies)
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
from policy_evaluation import (
    evaluate_cel_expression,
    validate_cel_expression,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["policies"])


@router.post("/api/v1/policies/validate")
@router.post("/v1/policies/validate")
async def validate_policy_expression(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Validate a CEL policy expression and return structured error diagnostics."""
    del tenant_id  # auth gate only; this computation reads no tenant-owned data
    content_type = request.headers.get("content-type", "")
    if content_type and not content_type.lower().startswith("application/json"):
        return _error_response(400, "invalid_content_type", "Content-Type must be application/json")
    try:
        body = await request.json()
    except Exception as exc:
        return _error_response(400, "invalid_json", f"Malformed JSON request body: {exc}")

    expression = body.get("expression") or body.get("cel_expression") or ""
    result = validate_cel_expression(expression)

    if not result.valid:
        diag = result.diagnostics
        return JSONResponse(
            status_code=422,
            content={
                "error": "cel_validation_error",
                "detail": diag.reason if diag else "CEL expression failed validation",
                "diagnostics": diag.to_dict() if diag else None,
            },
        )

    return JSONResponse(
        status_code=200,
        content={"valid": True, "diagnostics": None},
    )


@router.post("/api/v1/policies/evaluate")
@router.post("/v1/policies/evaluate")
async def evaluate_policies(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Evaluate CEL policies against agent and workload contexts with structured diagnostics."""
    content_type = request.headers.get("content-type", "")
    if content_type and not content_type.lower().startswith("application/json"):
        return _error_response(400, "invalid_content_type", "Content-Type must be application/json")
    try:
        body = await request.json()
    except Exception as exc:
        return _error_response(400, "invalid_json", f"Malformed JSON request body: {exc}")

    # If single expression provided directly in request
    single_expr = body.get("expression") or body.get("cel_expression")
    if single_expr:
        validation = validate_cel_expression(single_expr)
        if not validation.valid:
            diag = validation.diagnostics
            return JSONResponse(
                status_code=422,
                content={
                    "error": "cel_validation_error",
                    "detail": diag.reason if diag else "CEL expression failed validation",
                    "diagnostics": diag.to_dict() if diag else None,
                },
            )
        eval_res = evaluate_cel_expression(single_expr, body.get("context", body))
        return JSONResponse(status_code=200, content=eval_res.to_dict())

    # If rules list provided in request
    rules = body.get("rules", [])
    if isinstance(rules, list) and rules:
        for idx, rule in enumerate(rules):
            expr = rule.get("cel_expression") if isinstance(rule, dict) else None
            if expr:
                validation = validate_cel_expression(expr)
                if not validation.valid:
                    diag = validation.diagnostics
                    return JSONResponse(
                        status_code=422,
                        content={
                            "error": "cel_validation_error",
                            "detail": f"Rule {idx} ({rule.get('id', 'unknown')}): {diag.reason if diag else 'invalid'}",
                            "diagnostics": diag.to_dict() if diag else None,
                            "rule_index": idx,
                            "rule_id": rule.get("id"),
                        },
                    )

    # Proxy to upstream policy-engine if available
    from routers.policy_engine import proxy_policy_engine
    resp = await proxy_policy_engine(request, "evaluate", "policies", tenant_id=tenant_id)
    if resp.status_code != 502:
        return resp

    # Hermetic local fallback when upstream policy-engine is offline
    results = []
    compliant = True
    context = body.get("context", body)
    for idx, rule in enumerate(rules):
        expr = rule.get("cel_expression", "true")
        eval_res = evaluate_cel_expression(expr, context)
        if not eval_res.compliant:
            compliant = False
        results.append({
            "rule_id": rule.get("id", f"rule-{idx}"),
            "name": rule.get("name", "Rule"),
            "passed": eval_res.compliant,
            "status": "EVALUATED",
            "error": eval_res.error or "",
            "cost": eval_res.cost,
        })

    return JSONResponse(
        status_code=200,
        content={
            "compliant": compliant,
            "tenant_id": tenant_id,
            "total_rules": len(rules),
            "passed_rules": sum(1 for r in results if r["passed"]),
            "failed_rules": sum(1 for r in results if not r["passed"]),
            "results": results,
        },
    )


@router.get("/api/v1/policies")
@router.get("/v1/policies")
@router.get("/api/policies")
@router.get("/policies")
async def list_policies(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """List policy bundles with version history."""
    from routers.policy_engine import proxy_policy_engine
    return await proxy_policy_engine(request, "", "policies", tenant_id=tenant_id)


@router.post("/api/v1/policies/bundles")
@router.post("/v1/policies/bundles")
async def register_bundle(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Register a new policy bundle with upfront CEL validation."""
    content_type = request.headers.get("content-type", "")
    if content_type and not content_type.lower().startswith("application/json"):
        return _error_response(400, "invalid_content_type", "Content-Type must be application/json")
    try:
        body = await request.json()
    except Exception as exc:
        return _error_response(400, "invalid_json", f"Malformed JSON request body: {exc}")

    rules = body.get("rules", [])
    if not rules:
        return _error_response(400, "empty_bundle", "At least one policy rule is required in bundle")

    for idx, rule in enumerate(rules):
        expr = rule.get("cel_expression", "")
        validation = validate_cel_expression(expr)
        if not validation.valid:
            diag = validation.diagnostics
            return JSONResponse(
                status_code=422,
                content={
                    "error": "cel_validation_error",
                    "detail": f"Rule {idx} ({rule.get('id', 'unknown')}): {diag.reason if diag else 'invalid'}",
                    "diagnostics": diag.to_dict() if diag else None,
                    "rule_index": idx,
                    "rule_id": rule.get("id"),
                },
            )

    from routers.policy_engine import proxy_policy_engine
    resp = await proxy_policy_engine(request, "bundles", "policies", tenant_id=tenant_id)
    if resp.status_code != 502:
        return resp

    # Hermetic local fallback when upstream policy-engine is offline
    bundle_id = body.get("id") or f"{body.get('framework_id', 'custom')}-{body.get('version', 'v1.0.0')}"
    return JSONResponse(
        status_code=201,
        content={
            "id": bundle_id,
            "framework_id": body.get("framework_id"),
            "version": body.get("version"),
            "author": tenant_id or "system",
            "rules": rules,
        },
    )


@router.post("/api/v1/policies/rollback")
@router.post("/v1/policies/rollback")
async def rollback_bundle(
    request: Request,
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Rollback policy bundle to an earlier version."""
    content_type = request.headers.get("content-type", "")
    if content_type and not content_type.lower().startswith("application/json"):
        return _error_response(400, "invalid_content_type", "Content-Type must be application/json")
    from routers.policy_engine import proxy_policy_engine
    return await proxy_policy_engine(request, "rollback", "policies", tenant_id=tenant_id)


def install_policies_api(app: Any) -> None:
    """Mount the policies router on the FastAPI application."""
    app.include_router(router)
