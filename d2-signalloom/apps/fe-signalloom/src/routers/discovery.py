"""Discovery and Workload Claim Router for fe-signalloom.

Provides:
1. POST /api/v1/discovery/claim: Adversarially hardened workload claim endpoint
   with structured error envelopes (never unhandled 500), strict input validation
   for empty agent ID, missing/invalid namespace, malformed JSON, and SPIFFE ID checks.
2. GET /api/v1/discovery/workloads: Aggregated multi-source workload discovery.
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

import api_compat
from api_compat import (
    APIError,
    ERROR_RESPONSES,
    Principal,
    _AGENTS,
    _CLAIMS,
    _STORE_LOCK,
    _audit_log,
    _error_response,
    _get_pool,
    _now_iso,
    _record_memory_audit,
    _write,
    authenticated_principal,
)
from models import (
    DiscoveryClaimRequest,
    DiscoveryClaimResponse,
    format_spiffe_id,
    is_known_or_tenant_namespace,
    is_valid_namespace_format,
    validate_spiffe_id,
)

logger = logging.getLogger("signalloom.discovery")

router = APIRouter(tags=["discovery"])


def _make_error(status_code: int, code: str, message: str) -> JSONResponse:
    """Format structured error envelope: {"error": {"code": ..., "message": ...}}."""
    return JSONResponse(
        status_code=status_code,
        content={"error": {"code": code, "message": message}},
    )


@router.post(
    "/api/v1/discovery/claim",
    response_model=DiscoveryClaimResponse,
    responses=ERROR_RESPONSES,
    status_code=200,
)
@router.post(
    "/v1/discovery/claim",
    response_model=DiscoveryClaimResponse,
    responses=ERROR_RESPONSES,
    status_code=200,
)
@router.post(
    "/discovery/claim",
    response_model=DiscoveryClaimResponse,
    responses=ERROR_RESPONSES,
    status_code=200,
)
async def claim_discovered_workload(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Response:
    """Adversarially hardened claim endpoint for discovered workloads.

    Validates:
    - Content-Type must be application/json
    - Request body must be valid JSON
    - agent_id must be non-empty and non-whitespace
    - namespace must be non-empty, RFC 1123 compliant, and exist
    - spiffe_id (if supplied) must have 'spiffe://' scheme and match tenant
    - Never raises unhandled 500 error
    """
    tenant_id = principal.tenant
    content_type = request.headers.get("content-type", "")

    # 1. Content-Type check
    if content_type and not content_type.startswith("application/json"):
        return _make_error(400, "invalid_content_type", "Content-Type must be application/json")

    # 2. Raw body parsing with explicit JSON error capture
    try:
        raw_body = await request.body()
        if not raw_body:
            return _make_error(400, "malformed_request", "Request body cannot be empty")
        body_json = json.loads(raw_body)
        if not isinstance(body_json, dict):
            return _make_error(400, "malformed_request", "Request payload must be a JSON object")
    except json.JSONDecodeError as exc:
        return _make_error(400, "malformed_request", f"Invalid JSON body: {exc}")
    except Exception as exc:
        return _make_error(400, "malformed_request", f"Failed to parse request: {exc}")

    # 3. Pydantic contract validation
    try:
        req = DiscoveryClaimRequest.model_validate(body_json)
    except ValidationError as val_err:
        errors = val_err.errors()
        err_msg = errors[0]["msg"] if errors else "Validation failed"
        field_name = errors[0]["loc"][-1] if errors and errors[0]["loc"] else "payload"
        return _make_error(422, "validation_error", f"Field '{field_name}': {err_msg}")
    except Exception as exc:
        return _make_error(422, "validation_error", f"Contract validation failed: {exc}")

    # 4. Namespace validation (format and existence/allowlist)
    if not is_valid_namespace_format(req.namespace):
        return _make_error(
            422,
            "invalid_namespace",
            f"Namespace '{req.namespace}' is not a valid RFC 1123 DNS label",
        )

    if not is_known_or_tenant_namespace(req.namespace, tenant_id):
        return _make_error(
            400,
            "namespace_not_found",
            f"Namespace '{req.namespace}' does not exist or is not available for tenant '{tenant_id}'",
        )

    # 5. SPIFFE ID validation if client-asserted
    if req.spiffe_id:
        is_spiffe_valid, spiffe_err = validate_spiffe_id(req.spiffe_id, expected_tenant_id=tenant_id)
        if not is_spiffe_valid:
            code = "cross_tenant_forbidden" if "Cross-tenant" in (spiffe_err or "") else "invalid_spiffe_id"
            status = 403 if code == "cross_tenant_forbidden" else 400
            return _make_error(status, code, spiffe_err or "Invalid SPIFFE ID")

    # 6. Server-minted canonical SPIFFE ID
    server_spiffe_id = format_spiffe_id(tenant_id, req.agent_id)
    claim_id = f"claim-{uuid.uuid4().hex[:12]}"
    now = _now_iso()

    # 7. Persistence and state transition to Governed
    try:
        pool = await _get_pool()
        if pool is not None:
            async with _write(pool) as conn:
                # Check for cross-tenant conflict
                conflict = await conn.fetchrow(
                    """SELECT claim_id, tenant_id FROM public.agent_claims
                        WHERE (agent_id::text = $1 OR pod_name = $1)
                          AND tenant_id != $2
                          AND status = 'granted'
                          AND released_at IS NULL""",
                    req.agent_id, tenant_id,
                )
                if conflict is not None:
                    return _make_error(
                        409,
                        "claim_conflict",
                        f"Agent '{req.agent_id}' is already claimed by another tenant",
                    )

                # Insert/update registry
                agent_uuid = api_compat._try_uuid(req.agent_id)
                if agent_uuid is None:
                    agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{req.agent_id}")

                await conn.execute(
                    """INSERT INTO public.agent_registry (
                        id, tenant_id, name, display_name, description, status, lifecycle_state,
                        origin, compliance_posture, model_provider, model_name,
                        last_transition_at, created_at, updated_at
                    ) VALUES (
                        $1, $2, $3, $4, 'Discovered workload claimed via discovery portal', 'active', 'active',
                        'Discovered Workload', 83, 'anthropic', 'claude-3-5-sonnet',
                        NOW(), NOW(), NOW()
                    )
                    ON CONFLICT (tenant_id, name) DO UPDATE SET
                        lifecycle_state = 'active',
                        status = 'active',
                        compliance_posture = 83,
                        last_transition_at = NOW(),
                        updated_at = NOW()""",
                    agent_uuid, tenant_id, req.agent_id, req.agent_id.replace("-", " ").title(),
                )

                # Insert claim record
                await conn.execute(
                    """INSERT INTO public.agent_claims (
                        claim_id, tenant_id, agent_id, pod_name, namespace, spiffe_id,
                        harness, model, status, allocated_token_budget, claimed_at
                    ) VALUES (
                        $1, $2, $3, $4, $5, $6,
                        'discovered', 'claude-3-5-sonnet', 'granted', $7, NOW()
                    )
                    ON CONFLICT (claim_id) DO NOTHING""",
                    claim_id, tenant_id, agent_uuid, req.agent_id, req.namespace,
                    server_spiffe_id, req.token_budget_limit,
                )

                # Audit log
                await _audit_log(
                    conn, tenant_id, "agent.claimed", str(agent_uuid), req.agent_id, principal.actor,
                    {
                        "claim_id": claim_id,
                        "namespace": req.namespace,
                        "spiffe_id": server_spiffe_id,
                        "source": "discovery_claim",
                    },
                )
        else:
            # Memory state fallback
            with _STORE_LOCK:
                # Check cross-tenant conflict in memory
                for other_tenant, tclaims in _CLAIMS.items():
                    if other_tenant != tenant_id:
                        for cid, cdata in tclaims.items():
                            if cdata.get("agent_id") == req.agent_id or cdata.get("pod_name") == req.agent_id:
                                if cdata.get("status") == "granted":
                                    return _make_error(
                                        409,
                                        "claim_conflict",
                                        f"Agent '{req.agent_id}' is already claimed by another tenant",
                                    )

                _CLAIMS.setdefault(tenant_id, {})[claim_id] = {
                    "claim_id": claim_id,
                    "tenant_id": tenant_id,
                    "agent_id": req.agent_id,
                    "pod_name": req.agent_id,
                    "namespace": req.namespace,
                    "spiffe_id": server_spiffe_id,
                    "status": "granted",
                    "allocated_token_budget": req.token_budget_limit,
                    "claimed_at": now,
                }

                # Update memory agent record
                agents = _AGENTS.setdefault(tenant_id, {})
                agent_record = agents.get(req.agent_id, {})
                agent_record.update({
                    "id": req.agent_id,
                    "tenant_id": tenant_id,
                    "name": req.agent_id,
                    "lifecycle_state": "active",
                    "status": "active",
                    "namespace": req.namespace,
                    "record_class": "registered",
                    "is_registry_linked": True,
                    "last_transition_at": now,
                    "last_transition_by": principal.actor,
                })
                agents[req.agent_id] = agent_record

                _record_memory_audit(
                    tenant_id=tenant_id,
                    event_type="agent.claimed",
                    agent_id=req.agent_id,
                    agent_name=req.agent_id,
                    actor=principal.actor,
                    detail={
                        "claim_id": claim_id,
                        "namespace": req.namespace,
                        "spiffe_id": server_spiffe_id,
                        "source": "discovery_claim",
                    },
                )

        response_data = DiscoveryClaimResponse(
            claim_id=claim_id,
            tenant_id=tenant_id,
            agent_id=req.agent_id,
            namespace=req.namespace,
            spiffe_id=server_spiffe_id,
            status="granted",
            claimed_at=now,
            allocated_token_budget=req.token_budget_limit,
        )
        return JSONResponse(status_code=200, content=response_data.model_dump(mode="json"))

    except APIError as api_err:
        return _make_error(api_err.status_code, api_err.code, api_err.message)
    except Exception as exc:
        logger.exception("Unexpected error during discovery claim: %s", exc)
        return _make_error(500, "internal_error", f"An internal error occurred during claim processing: {exc}")


@router.get(
    "/api/v1/discovery/workloads",
    responses=ERROR_RESPONSES,
)
@router.get(
    "/v1/discovery/workloads",
    responses=ERROR_RESPONSES,
)
@router.get(
    "/discovery/workloads",
    responses=ERROR_RESPONSES,
)
async def list_discovery_workloads(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    status: str | None = None,
    source: str | None = None,
    namespace: str | None = None,
    search: str | None = None,
) -> Response:
    """Forward to api_compat list_discovery_workloads handler for complete fidelity."""
    return await api_compat.list_discovery_workloads(
        request=request,
        principal=principal,
        status=status,
        source=source,
        namespace=namespace,
        search=search,
    )


# ---------------------------------------------------------------------------
# App Installer Function
# ---------------------------------------------------------------------------

def install_discovery_api(app: Any) -> None:
    """Mount the discovery router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) in (
            claim_discovered_workload,
            list_discovery_workloads,
        ):
            return
    app.include_router(router)
