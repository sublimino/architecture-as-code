"""Agent Governance and Lifecycle Router for fe-signalloom.

Provides:
1. POST /api/v1/agents/{agent_id}/transition: Validates agent lifecycle state
   transitions (discovered -> governed, governed -> suspended/stunned, suspended -> revoked)
   and strictly rejects illegal transitions (revoked -> governed) with 409 Conflict,
   unknown states with 400 Bad Request, and enforces SPIFFE ID validation.
2. GET /api/v1/agents: Inventory listing with Attention Required filtering
   (security findings/warnings, missing SBOM, expired SVID).
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse

import api_compat
from api_compat import (
    APIError,
    ERROR_RESPONSES,
    Principal,
    _AGENTS,
    _STORE_LOCK,
    _audit_log,
    _canonical_lifecycle_state,
    _get_pool,
    _now_iso,
    _record_memory_audit,
    _synth_agent,
    _write,
    authenticated_principal,
)
from models import (
    AgentTransitionRequest,
    AgentTransitionResponse,
    LIFECYCLE_TRANSITIONS,
    VALID_INTERNAL_STATES,
    evaluate_agent_attention,
    validate_lifecycle_transition,
    validate_spiffe_id,
)

logger = logging.getLogger("signalloom.agents")

router = APIRouter(tags=["agents"])


def _make_error(status_code: int, code: str, message: str) -> JSONResponse:
    """Format structured error envelope: {"error": {"code": ..., "message": ...}}."""
    return JSONResponse(
        status_code=status_code,
        content={"error": {"code": code, "message": message}},
    )


@router.post(
    "/api/v1/agents/{agent_id}/transition",
    response_model=AgentTransitionResponse,
    responses=ERROR_RESPONSES,
    status_code=200,
)
@router.post(
    "/v1/agents/{agent_id}/transition",
    response_model=AgentTransitionResponse,
    responses=ERROR_RESPONSES,
    status_code=200,
)
@router.post(
    "/agents/{agent_id}/transition",
    response_model=AgentTransitionResponse,
    responses=ERROR_RESPONSES,
    status_code=200,
)
async def transition_agent_state(
    agent_id: str,
    body: AgentTransitionRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Response:
    """Execute an agent lifecycle state transition with state-machine validation.

    Enforces:
    - Valid transitions:
      - discovered -> governed
      - governed -> suspended / stunned
      - suspended -> revoked
      - suspended -> governed (resume)
    - Illegal transitions:
      - revoked -> governed (terminal state -> 409 Conflict)
      - unknown state -> 400 Bad Request
    - SPIFFE ID validation:
      - malformed ID or non-spiffe scheme -> 400 Bad Request
      - cross-tenant forged ID -> 403 Forbidden
    """
    tenant_id = principal.tenant
    now = _now_iso()

    # 1. SPIFFE ID validation if present in body
    if body.spiffe_id:
        is_spiffe_valid, spiffe_err = validate_spiffe_id(body.spiffe_id, expected_tenant_id=tenant_id)
        if not is_spiffe_valid:
            code = "cross_tenant_forbidden" if "Cross-tenant" in (spiffe_err or "") else "invalid_spiffe_id"
            status = 403 if code == "cross_tenant_forbidden" else 400
            return _make_error(status, code, spiffe_err or "Invalid SPIFFE ID")

    # 2. Determine current state and validate transition
    pool = await _get_pool()
    if pool is not None:
        async with _write(pool) as conn:
            agent_uuid = api_compat._try_uuid(agent_id)
            if agent_uuid is not None:
                row = await conn.fetchrow(
                    "SELECT id, lifecycle_state, name FROM agent_registry WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
                    agent_uuid, tenant_id,
                )
            else:
                row = await conn.fetchrow(
                    "SELECT id, lifecycle_state, name FROM agent_registry WHERE name = $1 AND tenant_id = $2 FOR UPDATE",
                    agent_id, tenant_id,
                )

            from_state = "registered" if row is None else row["lifecycle_state"]
            agent_name = agent_id if row is None else row["name"]

            # Validate state transition rules
            try:
                validate_lifecycle_transition(from_state, body.to_state)
            except ValueError as ve:
                return _make_error(400, "invalid_state", str(ve))
            except RuntimeError as re:
                return _make_error(409, "invalid_transition", str(re))

            normalized_to_state = body.to_state.strip().lower()
            if row is not None:
                await conn.execute(
                    """UPDATE agent_registry SET lifecycle_state = $1, last_transition_at = now()
                       WHERE id = $2 AND tenant_id = $3""",
                    normalized_to_state, row["id"], tenant_id,
                )
                target_agent_id = str(row["id"])
            else:
                target_agent_id = agent_id

            await _audit_log(
                conn, tenant_id, "agent.transitioned", target_agent_id, agent_name, principal.actor,
                {
                    "from_state": from_state,
                    "to_state": normalized_to_state,
                    "reason": body.reason,
                    "agent_ref": agent_id,
                },
            )
    else:
        # Memory storage path
        api_compat._ensure_seeded(tenant_id)
        with _STORE_LOCK:
            agent = _AGENTS.get(tenant_id, {}).get(agent_id)
            from_state = "registered" if agent is None else str(agent.get("lifecycle_state", "registered"))

            # Validate state transition rules
            try:
                validate_lifecycle_transition(from_state, body.to_state)
            except ValueError as ve:
                return _make_error(400, "invalid_state", str(ve))
            except RuntimeError as re:
                return _make_error(409, "invalid_transition", str(re))

            if agent is None:
                agent = _synth_agent(tenant_id, agent_id)

            normalized_to_state = body.to_state.strip().lower()
            agent["lifecycle_state"] = normalized_to_state
            agent["last_transition_at"] = now
            agent["last_transition_by"] = principal.actor
            _AGENTS.setdefault(tenant_id, {})[agent_id] = agent

            _record_memory_audit(
                tenant_id=tenant_id,
                event_type="agent.transitioned",
                agent_id=agent_id,
                agent_name=agent.get("name", agent_id),
                actor=principal.actor,
                detail={
                    "from_state": from_state,
                    "to_state": normalized_to_state,
                    "reason": body.reason,
                    "agent_ref": agent_id,
                },
            )

    resp = AgentTransitionResponse(
        agent_id=agent_id,
        from_state=from_state,
        to_state=body.to_state,
        actor=principal.actor,
        reason=body.reason,
        timestamp=now,
    )
    return JSONResponse(status_code=200, content=resp.model_dump(mode="json"))


@router.get(
    "/api/v1/agents",
    responses=ERROR_RESPONSES,
)
@router.get(
    "/v1/agents",
    responses=ERROR_RESPONSES,
)
@router.get(
    "/agents",
    responses=ERROR_RESPONSES,
)
async def list_agents(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    state: str | None = None,
    lifecycle_state: str | None = None,
    attention_required: bool = Query(default=False),
    attention: bool = Query(default=False),
    search: str | None = None,
    record_class: str | None = None,
    sort_by: str | None = None,
    sort_dir: str = "asc",
    page: int = 1,
    limit: int = 50,
) -> Response:
    """List governed agents with optional Attention Required filtering.

    When attention_required=true or attention=true, filters results to return only:
    - Agents with security findings / warnings
    - Agents with missing SBOM attestation
    - Agents with expired SVID credentials
    - Agents in suspended / stunned / revoked lifecycle states
    """
    # Delegate to api_compat for base agent list retrieval
    base_response = await api_compat.agents(
        tenant_id=principal.tenant,
        search=search,
        state=state,
        lifecycle_state=lifecycle_state,
        record_class=record_class,
        page=page,
        limit=limit,
    )

    should_filter_attention = attention_required or attention
    if not should_filter_attention:
        if isinstance(base_response, JSONResponse):
            return base_response
        if hasattr(base_response, "model_dump"):
            return JSONResponse(status_code=200, content=base_response.model_dump(mode="json"))
        return base_response

    # Parse response content to apply attention evaluation
    try:
        if hasattr(base_response, "model_dump"):
            content = base_response.model_dump(mode="json")
        elif hasattr(base_response, "body"):
            content = json.loads(base_response.body)
        elif isinstance(base_response, dict):
            content = base_response
        else:
            content = {}
        agents_list = (content.get("agents") or content.get("data") or []) if isinstance(content, dict) else []

        flagged_agents: list[dict[str, Any]] = []
        for ag in agents_list:
            comp = ag.get("compliance_summary") or {}
            failing = comp.get("failing", 0)
            pending = comp.get("pending", 0)
            posture = comp.get("posture_score")
            att = ag.get("attention") or {}
            att_level = att.get("level", "none")

            # Missing SBOM check
            has_sbom = ag.get("has_sbom", True)
            if ag.get("sbom") is None and "sbom" in ag:
                has_sbom = False
            if "sbom" in (att.get("highest_issue") or "").lower():
                has_sbom = False

            # Expired SVID check
            cred_state = ag.get("credential_state") or {}
            svid_expired = ag.get("svid_expired", False)
            if cred_state.get("status") == "expired":
                svid_expired = True
            ident = ag.get("identity") or {}
            cert_until = ident.get("cert_valid_until")
            if cert_until:
                try:
                    exp_dt = datetime.fromisoformat(cert_until.replace("Z", "+00:00"))
                    if exp_dt.timestamp() <= datetime.now(timezone.utc).timestamp():
                        svid_expired = True
                except Exception:
                    pass

            state_val = ag.get("lifecycle_state", "Governed")

            level, issue, req_att = evaluate_agent_attention(
                compliance_failing=failing,
                compliance_pending=pending,
                findings_count=ag.get("findings_count", 0),
                has_sbom=has_sbom,
                svid_expired=svid_expired,
                lifecycle_state=state_val,
                posture_score=posture,
            )

            # Update agent record with derived attention details
            if req_att or att_level in {"critical", "warning"}:
                ag["attention"] = {
                    "level": "critical" if level == "critical" or att_level == "critical" else "warning",
                    "highest_issue": issue or att.get("highest_issue") or "Attention required",
                }
                ag["has_sbom"] = has_sbom
                ag["svid_expired"] = svid_expired
                flagged_agents.append(ag)

        content["agents"] = flagged_agents
        content["data"] = flagged_agents
        content["total"] = len(flagged_agents)
        return JSONResponse(status_code=200, content=content)
    except Exception as exc:
        logger.warning("Failed to filter agents for attention_required: %s", exc)
        return base_response


# ---------------------------------------------------------------------------
# App Installer Function
# ---------------------------------------------------------------------------

def install_agents_api(app: Any) -> None:
    """Mount the agents router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) in (
            transition_agent_state,
            list_agents,
        ):
            return
    app.include_router(router)
