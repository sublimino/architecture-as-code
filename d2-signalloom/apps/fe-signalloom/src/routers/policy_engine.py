"""Policy Engine reverse proxy routes for fe-signalloom.

Proxies /api/v1/compliance/* and /api/v1/policies/* requests
to the Go policy-engine service (http://policy-engine:8081).
Validates inbound and outbound JSON payloads, and handles upstream connection
failures with structured HTTP 502/504 errors instead of HTML fallbacks.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse

from api_compat import (
    APIError,
    Principal,
    _error_response,
    authenticated_principal,
    authenticated_tenant,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["policy-engine"])

POLICY_ENGINE_URL = os.getenv("POLICY_ENGINE_URL", "http://policy-engine:8081")
_TIMEOUT = float(os.getenv("POLICY_ENGINE_TIMEOUT", "10.0"))


async def proxy_policy_engine(
    request: Request,
    subpath: str,
    prefix: str,
    tenant_id: str | None = None,
) -> Response:
    """Forward a request to the policy-engine service with JSON validation."""
    clean_subpath = subpath.lstrip("/")
    target_path = f"/api/v1/{prefix}/{clean_subpath}" if clean_subpath else f"/api/v1/{prefix}"

    # Inbound content-type and body validation for mutating methods
    body_bytes: bytes | None = None
    if request.method in ("POST", "PUT", "PATCH"):
        raw_body = await request.body()
        if raw_body:
            content_type = request.headers.get("content-type", "")
            if not content_type.lower().startswith("application/json"):
                logger.warning(
                    "policy-engine proxy rejected request with non-JSON Content-Type: %r",
                    content_type,
                )
                return _error_response(
                    400,
                    "invalid_content_type",
                    "Content-Type must be application/json",
                )
            try:
                json.loads(raw_body)
            except Exception as exc:
                logger.warning("policy-engine proxy rejected malformed JSON body: %s", exc)
                return _error_response(
                    400,
                    "invalid_json",
                    f"Malformed JSON request body: {exc}",
                )
            body_bytes = raw_body

    headers: dict[str, str] = {
        "Accept": "application/json",
    }
    if body_bytes is not None:
        headers["Content-Type"] = "application/json"
    if tenant_id:
        headers["X-Tenant-ID"] = tenant_id

    # Forward any authorization headers if present
    auth_header = request.headers.get("authorization")
    if auth_header:
        headers["Authorization"] = auth_header

    params = dict(request.query_params)
    if tenant_id and "tenant" not in params:
        params["tenant"] = tenant_id

    try:
        async with httpx.AsyncClient(
            base_url=POLICY_ENGINE_URL,
            timeout=_TIMEOUT,
        ) as client:
            resp = await client.request(
                method=request.method,
                url=target_path,
                params=params,
                content=body_bytes,
                headers=headers,
            )
    except httpx.ConnectError as exc:
        logger.warning(
            "policy-engine service unreachable at %s: %s", POLICY_ENGINE_URL, exc
        )
        return _error_response(
            502,
            "upstream_unavailable",
            f"policy-engine service unreachable at {POLICY_ENGINE_URL}",
        )
    except httpx.TimeoutException as exc:
        logger.warning(
            "policy-engine request timed out: %s %s", request.method, target_path
        )
        return _error_response(
            504,
            "upstream_timeout",
            "policy-engine request timed out",
        )
    except Exception as exc:
        logger.exception(
            "policy-engine proxy error: %s %s (%s)", request.method, target_path, exc
        )
        return _error_response(
            502,
            "upstream_error",
            f"policy-engine proxy error: {exc}",
        )

    # Outbound content-type validation: reject HTML fallbacks or non-JSON payloads
    resp_content_type = resp.headers.get("content-type", "")
    resp_text_sample = resp.text[:100].lower() if resp.text else ""
    if (
        "text/html" in resp_content_type.lower()
        or "<!doctype" in resp_text_sample
        or "<html" in resp_text_sample
    ):
        logger.warning(
            "policy-engine returned HTML instead of JSON: status=%d content_type=%r",
            resp.status_code,
            resp_content_type,
        )
        return _error_response(
            502,
            "invalid_upstream_response",
            f"policy-engine returned non-JSON response (status {resp.status_code})",
        )

    try:
        data = resp.json()
    except Exception as exc:
        logger.warning(
            "policy-engine returned unparseable JSON: status=%d error=%s",
            resp.status_code,
            exc,
        )
        return _error_response(
            502,
            "invalid_upstream_response",
            f"policy-engine returned unparseable JSON (status {resp.status_code})",
        )

    return JSONResponse(
        status_code=resp.status_code,
        content=data,
        headers={"Content-Type": "application/json"},
    )


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Compliance Routes (/api/v1/compliance/* and /v1/compliance/*)
# ---------------------------------------------------------------------------


@router.api_route(
    "/api/v1/compliance/{subpath:path}",
    methods=["GET", "POST"],
)
@router.api_route(
    "/api/v1/compliance",
    methods=["GET", "POST"],
)
@router.api_route(
    "/v1/compliance/{subpath:path}",
    methods=["GET", "POST"],
)
@router.api_route(
    "/v1/compliance",
    methods=["GET", "POST"],
)
async def proxy_compliance_route(
    request: Request,
    subpath: str = "",
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Proxy compliance requests to upstream policy-engine or local handlers."""
    clean_subpath = subpath.lstrip("/")
    if clean_subpath.startswith("frameworks/"):
        fw_id = clean_subpath.split("/", 1)[1]
        from routers.compliance import get_framework_by_id
        return await get_framework_by_id(fw_id, request, tenant_id=tenant_id)
    if clean_subpath == "posture/calculate":
        from routers.compliance import calculate_posture
        return await calculate_posture(request)
    return await proxy_policy_engine(request, subpath, "compliance", tenant_id=tenant_id)


# ---------------------------------------------------------------------------
# Policies Routes (/api/v1/policies/* and /v1/policies/*)
# ---------------------------------------------------------------------------


@router.api_route(
    "/api/v1/policies/{subpath:path}",
    methods=["GET", "POST"],
)
@router.api_route(
    "/api/v1/policies",
    methods=["GET", "POST"],
)
@router.api_route(
    "/v1/policies/{subpath:path}",
    methods=["GET", "POST"],
)
@router.api_route(
    "/v1/policies",
    methods=["GET", "POST"],
)
@router.api_route(
    "/api/policies/{subpath:path}",
    methods=["GET", "POST"],
)
@router.api_route(
    "/api/policies",
    methods=["GET", "POST"],
)
@router.api_route(
    "/policies/{subpath:path}",
    methods=["GET", "POST"],
)
@router.api_route(
    "/policies",
    methods=["GET", "POST"],
)
async def proxy_policies_route(
    request: Request,
    subpath: str = "",
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Proxy policy evaluation and bundle requests to upstream policy-engine or local handlers."""
    clean_subpath = subpath.lstrip("/")
    if clean_subpath == "validate":
        from routers.policies import validate_policy_expression
        return await validate_policy_expression(request)
    if clean_subpath == "evaluate":
        from routers.policies import evaluate_policies
        return await evaluate_policies(request, tenant_id=tenant_id)
    if clean_subpath == "bundles" and request.method == "POST":
        from routers.policies import register_bundle
        return await register_bundle(request, tenant_id=tenant_id)
    if clean_subpath == "rollback" and request.method == "POST":
        from routers.policies import rollback_bundle
        return await rollback_bundle(request, tenant_id=tenant_id)
    return await proxy_policy_engine(request, subpath, "policies", tenant_id=tenant_id)


def install_policy_engine_api(app: Any) -> None:
    """Mount the policies, compliance, and reverse proxy routers on the FastAPI app."""
    from routers.compliance import router as compliance_router
    from routers.policies import router as policies_router

    # Avoid duplicate includes if already registered
    for route in app.routes:
        if getattr(route, "endpoint", None) in (
            proxy_compliance_route,
            proxy_policies_route,
        ):
            return
    app.include_router(policies_router)
    app.include_router(compliance_router)
    app.include_router(router)
