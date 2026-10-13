"""Quantitative Risk (OpenFAIR) API routes.

Proxies OpenFAIR risk queries to the Go signal-ingest service, which owns
the canonical OpenFAIR risk engine (pkg/fair).
"""
from __future__ import annotations

import json
import logging
import os
import urllib.parse
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Query, Request, Response
from fastapi.responses import JSONResponse

from api_compat import APIError, Principal, authenticated_principal, authenticated_tenant
from cross_tenant_audit import audit_cross_tenant_read
from ingest_client import ingest_headers

logger = logging.getLogger(__name__)

router = APIRouter(tags=["risk"])

_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 10.0


async def _proxy(method: str, path: str, principal: Principal, **kwargs: Any) -> Response:
    """Forward a request to signal-ingest as the gateway, acting for ``principal``'s tenant.

    X-Tenant-ID is not sent: signal-ingest never trusted it. The tenant travels as the gateway's
    acting tenant, which signal-ingest honours only for the gateway key.
    """
    headers = ingest_headers(principal)
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(method, path, headers=headers, **kwargs)
    except httpx.ConnectError as exc:
        logger.warning("signal-ingest service unreachable at %s", _SIGNAL_INGEST_URL)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest service unreachable"
        ) from exc
    except httpx.TimeoutException as exc:
        logger.warning("signal-ingest request timed out: %s %s", method, path)
        raise APIError(
            504, "upstream_timeout", "signal-ingest request timed out"
        ) from exc
    except Exception as exc:
        logger.exception("signal-ingest proxy error: %s %s", method, path)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest proxy error"
        ) from exc

    # Collect upstream headers to propagate
    from collections.abc import Mapping

    forwarded_headers: dict[str, str] = {}
    resp_headers_map: dict[str, str] = {}
    headers_obj = getattr(resp, "headers", None)
    if isinstance(headers_obj, Mapping):
        resp_headers_map = {str(k).lower(): str(v) for k, v in headers_obj.items()}
    for header_key in ("allow", "etag", "location", "x-tenant-id", "retry-after"):
        if header_key in resp_headers_map:
            forwarded_headers[header_key] = resp_headers_map[header_key]

    # For 204 No Content, empty bodies, or HEAD requests, return Response directly without JSON parsing
    if resp.status_code == 204 or not resp.content or method == "HEAD":
        if "content-type" in resp_headers_map and resp.status_code != 204:
            forwarded_headers["content-type"] = resp_headers_map["content-type"]
        return Response(
            status_code=resp.status_code,
            content=b"",
            headers=forwarded_headers,
        )

    try:
        content = resp.json()
    except Exception:
        content = {"raw": resp.text}

    outbound_headers = {"Content-Type": "application/json"}
    outbound_headers.update(forwarded_headers)
    return JSONResponse(status_code=resp.status_code, content=content, headers=outbound_headers)


DEFAULT_FRAMEWORK_VERSIONS: list[dict[str, Any]] = [
    {
        "framework_id": "eu-ai-act",
        "name": "EU AI Act",
        "version": "v2.1",
        "status": "active",
        "is_default": True,
        "description": "High-Risk AI Governance and Risk Assessment (Art. 9/14)",
    },
    {
        "framework_id": "eu-ai-act",
        "name": "EU AI Act",
        "version": "v2.0",
        "status": "retired",
        "is_default": False,
        "description": "Initial Provisional EU AI Act Baseline",
    },
    {
        "framework_id": "eu-ai-act",
        "name": "EU AI Act",
        "version": "v1.0",
        "status": "retired",
        "is_default": False,
        "description": "EU AI Act Concept Framework Draft",
    },
    {
        "framework_id": "nist-800-53",
        "name": "NIST SP 800-53",
        "version": "v2.1",
        "status": "active",
        "is_default": True,
        "description": "Security and Privacy Controls for Information Systems Rev 5",
    },
    {
        "framework_id": "nist-800-53",
        "name": "NIST SP 800-53",
        "version": "v2.0",
        "status": "retired",
        "is_default": False,
        "description": "NIST SP 800-53 Rev 4 Legacy Baseline",
    },
    {
        "framework_id": "soc2-type-ii",
        "name": "SOC 2 Type II",
        "version": "v2.1",
        "status": "active",
        "is_default": False,
        "description": "AICPA Trust Services Criteria (2017/2022)",
    },
    {
        "framework_id": "iso-42001",
        "name": "ISO/IEC 42001",
        "version": "v1.0-draft",
        "status": "draft",
        "is_default": False,
        "description": "Artificial Intelligence Management System (Draft Standard)",
    },
]


@router.get("/api/v1/fair/versions")
@router.get("/v1/fair/versions")
async def get_framework_versions(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    request: Request,
) -> JSONResponse:
    """Get dynamic list of regulatory framework and scenario versions with status metadata."""
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=2.0
        ) as client:
            resp = await client.get("/api/v1/fair/versions", headers={"X-Tenant-ID": tenant_id})
            if resp.status_code == 200:
                return JSONResponse(status_code=200, content=resp.json())
    except Exception:
        pass

    return JSONResponse(status_code=200, content=DEFAULT_FRAMEWORK_VERSIONS)


@router.get("/api/v1/risk/agents/{agent_id:path}")
@router.get("/v1/risk/agents/{agent_id:path}")
async def get_agent_risk(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    request: Request,
    trials: int | None = Query(default=None),
    seed: int | None = Query(default=None),
    model: str | None = Query(default=None),
) -> Response:
    """Get quantitative OpenFAIR risk assessment for a specific agent.

    signal-ingest's own ``requireCrossTenantRead`` (api/handlers.go handleGetAgentRisk) means
    every caller that is not acting "*" gets 403 before this ever sees a 2xx, so a successful
    call here is a cross-tenant read by construction -- audited unconditionally, not only when
    the response happens to name another tenant. The response names only an ``agentId``, never
    a tenant (agent-to-tenant ownership lives in fe-signalloom's own EAP registry, a different
    system from signal-ingest's FAIR engine), so the tenant is recorded as the sentinel
    ``"unattributed"`` rather than guessed at, with the agent id folded into the event itself.
    """
    params: dict[str, Any] = {}
    if trials is not None:
        params["trials"] = trials
    if seed is not None:
        params["seed"] = seed
    if model is not None:
        params["model"] = model
    quoted = urllib.parse.quote(agent_id, safe="")
    resp = await _proxy("GET", f"/api/v1/risk/agents/{quoted}", principal, params=params)
    if 200 <= resp.status_code < 300:
        await audit_cross_tenant_read(
            principal, f"GET /api/v1/risk/agents/{agent_id}", [{"tenant_id": "unattributed"}],
            what="Reading agent risk cross-tenant", extra={"agent_ids": [agent_id]},
        )
    return resp


@router.get("/api/v1/risk/fleet")
@router.get("/v1/risk/fleet")
async def get_fleet_risk(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    request: Request,
) -> Response:
    """Get quantitative OpenFAIR risk rollup across the agent fleet.

    Same construction as ``get_agent_risk``: gated cross-tenant-only by signal-ingest, so always
    audited on success, always "unattributed" since the fleet rollup carries no tenant either.
    The agent ids named in the event are whichever ones the response itself names (``topAgents``)
    -- the rollup does not enumerate the whole fleet, so this is honest about what the response
    actually disclosed, not a claim about the full agent catalogue.
    """
    resp = await _proxy("GET", "/api/v1/risk/fleet", principal)
    if 200 <= resp.status_code < 300:
        try:
            content = json.loads(resp.body)
        except (ValueError, TypeError):
            content = {}
        agent_ids = sorted({
            item["agentId"] for item in content.get("topAgents", [])
            if isinstance(item, dict) and isinstance(item.get("agentId"), str)
        })
        await audit_cross_tenant_read(
            principal, "GET /api/v1/risk/fleet", [{"tenant_id": "unattributed"}],
            what="Reading fleet risk cross-tenant", extra={"agent_ids": agent_ids},
        )
    return resp


def install_risk_api(app: Any) -> None:
    """Mount the risk API router on the FastAPI app."""
    app.include_router(router)
