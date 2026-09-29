"""Quantitative Risk (OpenFAIR) API routes.

Proxies OpenFAIR risk queries to the Go signal-ingest service, which owns
the canonical OpenFAIR risk engine (pkg/fair).
"""
from __future__ import annotations

import logging
import os
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse

from api_compat import APIError, authenticated_tenant

logger = logging.getLogger(__name__)

router = APIRouter(tags=["risk"])

_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 10.0


async def _proxy(method: str, path: str, tenant_id: str | None = None, **kwargs: Any) -> JSONResponse:
    """Forward a request to the signal-ingest service."""
    headers = kwargs.pop("headers", {}) or {}
    if tenant_id:
        headers["X-Tenant-ID"] = tenant_id
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(method, path, headers=headers, **kwargs)
            try:
                content = resp.json()
            except Exception:
                content = {"raw": resp.text}
            return JSONResponse(status_code=resp.status_code, content=content)
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
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    request: Request,
    trials: int | None = Query(default=None),
    seed: int | None = Query(default=None),
    model: str | None = Query(default=None),
) -> JSONResponse:
    """Get quantitative OpenFAIR risk assessment for a specific agent."""
    params: dict[str, Any] = {}
    if trials is not None:
        params["trials"] = trials
    if seed is not None:
        params["seed"] = seed
    if model is not None:
        params["model"] = model
    return await _proxy("GET", f"/api/v1/risk/agents/{agent_id}", tenant_id=tenant_id, params=params)


@router.get("/api/v1/risk/fleet")
@router.get("/v1/risk/fleet")
async def get_fleet_risk(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    request: Request,
) -> JSONResponse:
    """Get quantitative OpenFAIR risk rollup across the agent fleet."""
    return await _proxy("GET", "/api/v1/risk/fleet", tenant_id=tenant_id)


def install_risk_api(app: Any) -> None:
    """Mount the risk API router on the FastAPI app."""
    app.include_router(router)
