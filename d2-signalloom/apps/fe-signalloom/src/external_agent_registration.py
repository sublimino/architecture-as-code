"""Tenant-bound external Linux agent registration and duplicate claim rejection.

Implements AMXO-P2-2:
1. Strict server-side tenant scoping derived from authenticated operator credentials.
2. Pre-registration of external Linux agent metadata (host OS, runtime profile, allocated budget).
3. Global agent ID uniqueness preventing cross-tenant registration and claim hijacking.
4. Atomic duplicate-claim rejection for already-claimed agents.
5. Integration with Actor-Resolution Spine delegation and append-only audit events.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import uuid
from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, Depends, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

import api_compat
from agent_claim import sync_claim_delegation_to_spine, clamp_claim_delegation_in_spine

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/external-agents", tags=["external-agents"])
compat_router = APIRouter(prefix="/api/external-agents", tags=["external-agents-compat"])

SAFE_ID_REGEX = re.compile(r"^[a-z][a-z0-9-]{2,63}$")

# In-memory store for fallback/testing when PostgreSQL is not running
_REG_LOCK = threading.Lock()
# tenant_id -> { agent_id -> dict }
_EXTERNAL_REGISTRATIONS: dict[str, dict[str, dict[str, Any]]] = {}


def reset_external_agent_state(tenant_id: str | None = None) -> None:
    with _REG_LOCK:
        if tenant_id:
            _EXTERNAL_REGISTRATIONS.pop(tenant_id, None)
        else:
            _EXTERNAL_REGISTRATIONS.clear()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _validate_safe_id(value: str, field_name: str) -> str:
    trimmed = value.strip()
    if not SAFE_ID_REGEX.match(trimmed):
        raise ValueError(
            f"{field_name} must match SafeID pattern '^[a-z][a-z0-9-]{{2,63}}$'"
        )
    return trimmed


class ExternalAgentRegistrationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str = Field(min_length=3, max_length=64)
    host_id: str = Field(min_length=3, max_length=64)
    host_os: Literal["linux", "ubuntu-24.04", "debian-12", "rhel-9", "fedora-40", "arch"] = "linux"
    runtime_profile: str = Field(default="nono-0.73.0-standard", min_length=3, max_length=128)
    allocated_token_budget: int = Field(default=100000, gt=0, le=10000000)
    spiffe_id_pattern: str | None = Field(default=None, max_length=512)
    metadata: dict[str, Any] = Field(default_factory=dict)

    @field_validator("agent_id")
    @classmethod
    def validate_agent_id(cls, v: str) -> str:
        return _validate_safe_id(v, "agent_id")

    @field_validator("host_id")
    @classmethod
    def validate_host_id(cls, v: str) -> str:
        return _validate_safe_id(v, "host_id")

    @field_validator("runtime_profile")
    @classmethod
    def validate_profile(cls, v: str) -> str:
        trimmed = v.strip()
        if not trimmed:
            raise ValueError("runtime_profile must not be blank")
        return trimmed


class ExternalAgentRegistrationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    agent_id: str
    tenant_id: str
    host_id: str
    host_os: str
    runtime_profile: str
    enrollment_status: Literal["pending", "enrolled", "revoked", "failed"]
    registered_by_subject: str
    registered_by_user_id: str | None = None
    allocated_token_budget: int
    spiffe_id_pattern: str | None = None
    enrolled_at: str | None = None
    revoked_at: str | None = None
    revocation_reason: str | None = None
    metadata: dict[str, Any]
    created_at: str
    updated_at: str


class ExternalAgentRegistrationListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    registrations: list[ExternalAgentRegistrationResponse]
    total: int


class ExternalAgentClaimRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    harness: str = Field(default="nono-0.73.0", min_length=1, max_length=128)
    model: str = Field(default="claude-3-5-sonnet", min_length=1, max_length=128)
    declared_tools: list[str] = Field(default_factory=list)
    allocated_token_budget: int | None = Field(default=None, gt=0)
    metadata: dict[str, Any] = Field(default_factory=dict)


class ExternalAgentRevocationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason: str = Field(default="operator_revocation", min_length=3, max_length=256)


# Database & in-memory operations

async def _audit_log_external_agent(
    conn: Any,
    tenant_id: str,
    event_type: str,
    agent_id: str,
    principal: api_compat.Principal,
    detail: dict[str, Any],
) -> None:
    now = _now_iso()
    actor_str = principal.email or principal.subject or "operator@signalloom.test"
    agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{agent_id}")

    if conn is not None:
        try:
            await conn.execute(
                """INSERT INTO public.audit_events (
                    id, tenant_id, event_type, agent_id, agent_name, actor,
                    actor_issuer, actor_subject, detail, timestamp
                ) VALUES (
                    gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7, $8::jsonb, NOW()
                )""",
                tenant_id,
                event_type,
                agent_uuid,
                agent_id,
                actor_str,
                api_compat.settings.api_jwt_issuer,
                principal.subject,
                json.dumps(detail, default=str),
            )
            return
        except Exception as exc:
            logger.warning("DB audit log failed for external agent: %s", exc)

    # In-memory fallback
    api_compat._record_memory_audit(
        tenant_id=tenant_id,
        event_type=event_type,
        agent_id=str(agent_uuid),
        agent_name=agent_id,
        actor=actor_str,
        detail=detail,
    )


def _row_to_response(row: Any) -> ExternalAgentRegistrationResponse:
    if isinstance(row, dict):
        return ExternalAgentRegistrationResponse(
            id=str(row.get("id", "")),
            agent_id=row["agent_id"],
            tenant_id=row["tenant_id"],
            host_id=row["host_id"],
            host_os=row.get("host_os", "linux"),
            runtime_profile=row.get("runtime_profile", "nono-0.73.0-standard"),
            enrollment_status=row.get("enrollment_status", "pending"),
            registered_by_subject=row.get("registered_by_subject", ""),
            registered_by_user_id=str(row["registered_by_user_id"]) if row.get("registered_by_user_id") else None,
            allocated_token_budget=int(row.get("allocated_token_budget", 100000)),
            spiffe_id_pattern=row.get("spiffe_id_pattern"),
            enrolled_at=api_compat._ts(row.get("enrolled_at")),
            revoked_at=api_compat._ts(row.get("revoked_at")),
            revocation_reason=row.get("revocation_reason"),
            metadata=row.get("metadata") if isinstance(row.get("metadata"), dict) else json.loads(row.get("metadata", "{}") or "{}"),
            created_at=api_compat._ts(row.get("created_at")) or _now_iso(),
            updated_at=api_compat._ts(row.get("updated_at")) or _now_iso(),
        )
    return ExternalAgentRegistrationResponse(
        id=str(row["id"]),
        agent_id=row["agent_id"],
        tenant_id=row["tenant_id"],
        host_id=row["host_id"],
        host_os=row["host_os"],
        runtime_profile=row["runtime_profile"],
        enrollment_status=row["enrollment_status"],
        registered_by_subject=row["registered_by_subject"],
        registered_by_user_id=str(row["registered_by_user_id"]) if row["registered_by_user_id"] is not None else None,
        allocated_token_budget=row["allocated_token_budget"],
        spiffe_id_pattern=row["spiffe_id_pattern"],
        enrolled_at=api_compat._ts(row["enrolled_at"]),
        revoked_at=api_compat._ts(row["revoked_at"]),
        revocation_reason=row["revocation_reason"],
        metadata=json.loads(row["metadata"]) if isinstance(row["metadata"], str) else (row["metadata"] or {}),
        created_at=api_compat._ts(row["created_at"]) or "",
        updated_at=api_compat._ts(row["updated_at"]) or "",
    )


# Handlers

async def register_external_agent_handler(
    body: ExternalAgentRegistrationRequest,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
) -> ExternalAgentRegistrationResponse:
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    pool = await api_compat._get_pool()
    now = _now_iso()
    reg_id = str(uuid.uuid4())

    if pool is not None:
        async with api_compat._write(pool) as conn:
            # 1. Check if agent_id already exists in ANY tenant
            existing = await conn.fetchrow(
                """SELECT id, tenant_id, agent_id, enrollment_status
                     FROM public.external_agent_registrations
                    WHERE agent_id = $1""",
                body.agent_id,
            )
            if existing is not None:
                if existing["tenant_id"] != tenant_id:
                    # Cross-tenant conflict: DO NOT name the conflicting tenant
                    await _audit_log_external_agent(
                        conn,
                        tenant_id,
                        "external_agent.claim_rejected",
                        body.agent_id,
                        principal,
                        {
                            "reason": "cross_tenant_conflict",
                            "agent_id": body.agent_id,
                            "attempted_host_id": body.host_id,
                        },
                    )
                    raise api_compat.APIError(
                        409,
                        "claim_conflict",
                        f"Agent '{body.agent_id}' is already registered or claimed by another tenant",
                    )
                # Same tenant duplicate registration
                raise api_compat.APIError(
                    409,
                    "registration_conflict",
                    f"Agent '{body.agent_id}' is already registered in this tenant",
                )

            # 2. Check if agent is already in agent_claims under another tenant
            claim_conflict = await conn.fetchrow(
                """SELECT claim_id, tenant_id FROM public.agent_claims
                    WHERE pod_name = $1 AND tenant_id != $2 AND status = 'granted' AND released_at IS NULL""",
                body.agent_id,
                tenant_id,
            )
            if claim_conflict is not None:
                raise api_compat.APIError(
                    409,
                    "claim_conflict",
                    f"Agent '{body.agent_id}' is already registered or claimed by another tenant",
                )

            # Insert registration
            row = await conn.fetchrow(
                """INSERT INTO public.external_agent_registrations (
                    id, agent_id, tenant_id, host_id, host_os, runtime_profile,
                    enrollment_status, registered_by_subject, registered_by_issuer,
                    allocated_token_budget, spiffe_id_pattern, metadata,
                    created_at, updated_at
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, 'pending', $7, $8, $9, $10, $11::jsonb, NOW(), NOW()
                ) RETURNING *""",
                uuid.UUID(reg_id),
                body.agent_id,
                tenant_id,
                body.host_id,
                body.host_os,
                body.runtime_profile,
                principal.subject,
                api_compat.settings.api_jwt_issuer,
                body.allocated_token_budget,
                body.spiffe_id_pattern,
                json.dumps(body.metadata),
            )

            await _audit_log_external_agent(
                conn,
                tenant_id,
                "external_agent.registered",
                body.agent_id,
                principal,
                {
                    "registration_id": reg_id,
                    "agent_id": body.agent_id,
                    "host_id": body.host_id,
                    "host_os": body.host_os,
                    "runtime_profile": body.runtime_profile,
                    "allocated_token_budget": body.allocated_token_budget,
                },
            )
            return _row_to_response(row)

    # In-memory fallback
    conflict_type = None
    with _REG_LOCK:
        # Cross-tenant and duplicate check
        for other_tenant, regs in _EXTERNAL_REGISTRATIONS.items():
            if body.agent_id in regs:
                if other_tenant != tenant_id:
                    conflict_type = "cross_tenant"
                else:
                    conflict_type = "same_tenant"
                break

        if conflict_type is None:
            # Cross-tenant claim check in _CLAIMS
            with api_compat._STORE_LOCK:
                for other_tenant, tclaims in api_compat._CLAIMS.items():
                    if other_tenant != tenant_id:
                        for c in tclaims.values():
                            if c.get("pod_name") == body.agent_id and c.get("status") == "granted" and c.get("released_at") is None:
                                conflict_type = "cross_tenant_claim"
                                break

        if conflict_type is None:
            t_regs = _EXTERNAL_REGISTRATIONS.setdefault(tenant_id, {})
            reg_record = {
                "id": reg_id,
                "agent_id": body.agent_id,
                "tenant_id": tenant_id,
                "host_id": body.host_id,
                "host_os": body.host_os,
                "runtime_profile": body.runtime_profile,
                "enrollment_status": "pending",
                "registered_by_subject": principal.subject,
                "registered_by_user_id": None,
                "allocated_token_budget": body.allocated_token_budget,
                "spiffe_id_pattern": body.spiffe_id_pattern,
                "enrolled_at": None,
                "revoked_at": None,
                "revocation_reason": None,
                "metadata": body.metadata,
                "created_at": now,
                "updated_at": now,
            }
            t_regs[body.agent_id] = reg_record

    if conflict_type == "cross_tenant" or conflict_type == "cross_tenant_claim":
        await _audit_log_external_agent(
            None,
            tenant_id,
            "external_agent.claim_rejected",
            body.agent_id,
            principal,
            {
                "reason": "cross_tenant_conflict",
                "agent_id": body.agent_id,
                "attempted_host_id": body.host_id,
            },
        )
        raise api_compat.APIError(
            409,
            "claim_conflict",
            f"Agent '{body.agent_id}' is already registered or claimed by another tenant",
        )
    if conflict_type == "same_tenant":
        raise api_compat.APIError(
            409,
            "registration_conflict",
            f"Agent '{body.agent_id}' is already registered in this tenant",
        )

    await _audit_log_external_agent(
        None,
        tenant_id,
        "external_agent.registered",
        body.agent_id,
        principal,
        {
            "registration_id": reg_id,
            "agent_id": body.agent_id,
            "host_id": body.host_id,
            "host_os": body.host_os,
            "runtime_profile": body.runtime_profile,
            "allocated_token_budget": body.allocated_token_budget,
        },
    )
    return _row_to_response(reg_record)


async def list_external_agents_handler(
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
    status: str | None = Query(None, description="Filter by enrollment status"),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> ExternalAgentRegistrationListResponse:
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._read(pool) as conn:
            if status:
                rows = await conn.fetch(
                    """SELECT * FROM public.external_agent_registrations
                        WHERE tenant_id = $1 AND enrollment_status = $2
                        ORDER BY created_at DESC LIMIT $3 OFFSET $4""",
                    tenant_id, status, limit, offset,
                )
                total_row = await conn.fetchval(
                    "SELECT COUNT(*) FROM public.external_agent_registrations WHERE tenant_id = $1 AND enrollment_status = $2",
                    tenant_id, status,
                )
            else:
                rows = await conn.fetch(
                    """SELECT * FROM public.external_agent_registrations
                        WHERE tenant_id = $1
                        ORDER BY created_at DESC LIMIT $2 OFFSET $3""",
                    tenant_id, limit, offset,
                )
                total_row = await conn.fetchval(
                    "SELECT COUNT(*) FROM public.external_agent_registrations WHERE tenant_id = $1",
                    tenant_id,
                )
            return ExternalAgentRegistrationListResponse(
                registrations=[_row_to_response(r) for r in rows],
                total=int(total_row or 0),
            )

    with _REG_LOCK:
        t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
        items = list(t_regs.values())
        if status:
            items = [r for r in items if r.get("enrollment_status") == status]
        total = len(items)
        paginated = items[offset : offset + limit]
        return ExternalAgentRegistrationListResponse(
            registrations=[_row_to_response(r) for r in paginated],
            total=total,
        )


async def get_external_agent_handler(
    agent_id: str,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
) -> ExternalAgentRegistrationResponse:
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    _validate_safe_id(agent_id, "agent_id")

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._read(pool) as conn:
            row = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE tenant_id = $1 AND agent_id = $2""",
                tenant_id, agent_id,
            )
            if row is None:
                # Check if it exists in another tenant to ensure zero IDOR leak
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
            return _row_to_response(row)

    with _REG_LOCK:
        t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
        if agent_id not in t_regs:
            raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
        return _row_to_response(t_regs[agent_id])


async def claim_external_agent_handler(
    agent_id: str,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
    body: ExternalAgentClaimRequest | None = None,
) -> api_compat.AgentClaimResponse:
    """Atomic tenant-bound claim for pre-registered external agents with duplicate claim rejection."""
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    _validate_safe_id(agent_id, "agent_id")
    req_body = body or ExternalAgentClaimRequest()
    now = _now_iso()
    claim_id = f"claim-{uuid.uuid4().hex[:12]}"
    agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{agent_id}")

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            # 1. Verify pre-registration within authenticated tenant scope
            reg = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE agent_id = $1 FOR UPDATE""",
                agent_id,
            )
            if reg is None:
                # Not registered anywhere or registered in another tenant?
                # Check other tenant to prevent cross-tenant claim
                raise api_compat.APIError(
                    403,
                    "unregistered_agent",
                    f"External agent '{agent_id}' must be pre-registered within tenant scope before claim",
                )
            if reg["tenant_id"] != tenant_id:
                # Cross-tenant claim attempt!
                await _audit_log_external_agent(
                    conn,
                    tenant_id,
                    "external_agent.claim_rejected",
                    agent_id,
                    principal,
                    {
                        "reason": "cross_tenant_claim_rejected",
                        "agent_id": agent_id,
                    },
                )
                raise api_compat.APIError(
                    409,
                    "claim_conflict",
                    f"Agent '{agent_id}' is already registered or claimed by another tenant",
                )

            # 2. Check duplicate active claim in agent_claims
            active_claim = await conn.fetchrow(
                """SELECT claim_id, status, released_at FROM public.agent_claims
                    WHERE (agent_id = $1 OR pod_name = $2)
                      AND status = 'granted'
                      AND released_at IS NULL""",
                agent_uuid,
                agent_id,
            )
            if active_claim is not None:
                await _audit_log_external_agent(
                    conn,
                    tenant_id,
                    "external_agent.claim_rejected",
                    agent_id,
                    principal,
                    {
                        "reason": "duplicate_claim_rejected",
                        "existing_claim_id": active_claim["claim_id"],
                        "agent_id": agent_id,
                    },
                )
                raise api_compat.APIError(
                    409,
                    "duplicate_claim",
                    f"Agent '{agent_id}' already has an active claim ({active_claim['claim_id']})",
                )

            # 3. Check revocation status
            if reg["enrollment_status"] == "revoked":
                raise api_compat.APIError(
                    403,
                    "agent_revoked",
                    f"External agent '{agent_id}' has been revoked and cannot be claimed",
                )

            budget = req_body.allocated_token_budget or reg["allocated_token_budget"]
            spiffe_id = reg["spiffe_id_pattern"] or f"spiffe://cluster.local/ns/external-agents/sa/{agent_id}"

            # 4. Create/update agent registry
            await conn.execute(
                """INSERT INTO public.agent_registry (
                    id, tenant_id, name, display_name, description, status, lifecycle_state,
                    origin, compliance_posture, model_provider, model_name,
                    last_transition_at, created_at, updated_at
                ) VALUES (
                    $1, $2, $3, $4, $5, 'active', 'active',
                    'External Linux Workload', 83, 'anthropic', $6,
                    NOW(), NOW(), NOW()
                ) ON CONFLICT (tenant_id, name) DO UPDATE SET
                    lifecycle_state = 'active',
                    status = 'active',
                    compliance_posture = 83,
                    last_transition_at = NOW(),
                    updated_at = NOW()""",
                agent_uuid,
                tenant_id,
                agent_id,
                agent_id.replace("-", " ").title(),
                f"Pre-registered external Linux agent on host {reg['host_id']}",
                req_body.model,
            )

            # 5. Insert claim record
            await conn.execute(
                """INSERT INTO public.agent_claims (
                    claim_id, tenant_id, agent_id, pod_name, namespace, spiffe_id,
                    harness, model, status, allocated_token_budget, claimed_at
                ) VALUES (
                    $1, $2, $3, $4, 'external-agents', $5, $6, $7, 'granted', $8, NOW()
                )""",
                claim_id,
                tenant_id,
                agent_uuid,
                agent_id,
                spiffe_id,
                req_body.harness,
                req_body.model,
                budget,
            )

            # 6. Update registration state to enrolled
            await conn.execute(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'enrolled',
                          enrolled_at = NOW(),
                          updated_at = NOW()
                    WHERE tenant_id = $1 AND agent_id = $2""",
                tenant_id,
                agent_id,
            )

            # 7. Audit log
            audit_detail = {
                "action": "claimed",
                "source": "external_agent_claim",
                "claim_id": claim_id,
                "agent_id": agent_id,
                "host_id": reg["host_id"],
                "host_os": reg["host_os"],
                "runtime_profile": reg["runtime_profile"],
                "spiffe_id": spiffe_id,
                "harness": req_body.harness,
                "model": req_body.model,
                "token_budget": budget,
            }
            await _audit_log_external_agent(
                conn,
                tenant_id,
                "external_agent.claimed",
                agent_id,
                principal,
                audit_detail,
            )

    else:
        # In-memory execution
        unregistered = False
        cross_tenant_rejected = False
        revoked = False
        duplicate_claim_obj = None
        reg_item = None
        budget = 100000
        spiffe_id = f"spiffe://cluster.local/ns/external-agents/sa/{agent_id}"

        with _REG_LOCK:
            # Find in all tenants
            found_tenant = None
            for t_id, regs in _EXTERNAL_REGISTRATIONS.items():
                if agent_id in regs:
                    found_tenant = t_id
                    reg_item = regs[agent_id]
                    break

            if reg_item is None:
                unregistered = True
            elif found_tenant != tenant_id:
                cross_tenant_rejected = True
            elif reg_item.get("enrollment_status") == "revoked":
                revoked = True
            else:
                # Check duplicate active claim in _CLAIMS
                with api_compat._STORE_LOCK:
                    t_claims = api_compat._CLAIMS.setdefault(tenant_id, {})
                    for c in t_claims.values():
                        if (c.get("pod_name") == agent_id or c.get("agent_id") == str(agent_uuid)) and c.get("status") == "granted" and c.get("released_at") is None:
                            duplicate_claim_obj = c
                            break

                    if duplicate_claim_obj is None:
                        budget = req_body.allocated_token_budget or reg_item.get("allocated_token_budget", 100000)
                        spiffe_id = reg_item.get("spiffe_id_pattern") or f"spiffe://cluster.local/ns/external-agents/sa/{agent_id}"

                        claim_record = {
                            "claim_id": claim_id,
                            "tenant_id": tenant_id,
                            "agent_id": str(agent_uuid),
                            "pod_name": agent_id,
                            "namespace": "external-agents",
                            "spiffe_id": spiffe_id,
                            "harness": req_body.harness,
                            "model": req_body.model,
                            "status": "granted",
                            "allocated_token_budget": budget,
                            "claimed_at": now,
                            "released_at": None,
                        }
                        t_claims[claim_id] = claim_record

                        reg_item["enrollment_status"] = "enrolled"
                        reg_item["enrolled_at"] = now
                        reg_item["updated_at"] = now

        if unregistered:
            raise api_compat.APIError(
                403,
                "unregistered_agent",
                f"External agent '{agent_id}' must be pre-registered within tenant scope before claim",
            )

        if cross_tenant_rejected:
            await _audit_log_external_agent(
                None,
                tenant_id,
                "external_agent.claim_rejected",
                agent_id,
                principal,
                {"reason": "cross_tenant_claim_rejected", "agent_id": agent_id},
            )
            raise api_compat.APIError(
                409,
                "claim_conflict",
                f"Agent '{agent_id}' is already registered or claimed by another tenant",
            )

        if revoked:
            raise api_compat.APIError(
                403,
                "agent_revoked",
                f"External agent '{agent_id}' has been revoked and cannot be claimed",
            )

        if duplicate_claim_obj is not None:
            await _audit_log_external_agent(
                None,
                tenant_id,
                "external_agent.claim_rejected",
                agent_id,
                principal,
                {
                    "reason": "duplicate_claim_rejected",
                    "existing_claim_id": duplicate_claim_obj.get("claim_id"),
                    "agent_id": agent_id,
                },
            )
            raise api_compat.APIError(
                409,
                "duplicate_claim",
                f"Agent '{agent_id}' already has an active claim ({duplicate_claim_obj.get('claim_id')})",
            )

        await _audit_log_external_agent(
            None,
            tenant_id,
            "external_agent.claimed",
            agent_id,
            principal,
            {
                "action": "claimed",
                "source": "external_agent_claim",
                "claim_id": claim_id,
                "agent_id": agent_id,
                "host_id": reg_item["host_id"],
                "host_os": reg_item["host_os"],
                "runtime_profile": reg_item["runtime_profile"],
                "spiffe_id": spiffe_id,
                "harness": req_body.harness,
                "model": req_body.model,
                "token_budget": budget,
            },
        )

    # Synchronize delegation to signal-ingest Actor-Resolution Spine asynchronously
    try:
        await sync_claim_delegation_to_spine(
            agent_id=str(agent_uuid),
            operator_id=principal.subject,
            claim_id=claim_id,
            capabilities=["agent:operate", "external_linux_agent"],
            containment_claims=["containment:nono_0.73.0", "containment:landlock"],
            metadata={"host_id": reg_item["host_id"] if reg_item else "external-host", "agent_id": agent_id},
        )
    except Exception as exc:
        logger.warning("Spine sync failed for external agent claim: %s", exc)

    return api_compat.AgentClaimResponse(
        claim_id=claim_id,
        status="granted",
        spiffe_svid_verified=True,
        allocated_token_budget=budget,
        signal_session_url=f"/api/v1/sessions?agent_id={agent_uuid}",
        ebpf_sentinel_bound=True,
        agent_id=str(agent_uuid),
    )


async def revoke_external_agent_handler(
    agent_id: str,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
    body: ExternalAgentRevocationRequest | None = None,
) -> ExternalAgentRegistrationResponse:
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    _validate_safe_id(agent_id, "agent_id")
    req_body = body or ExternalAgentRevocationRequest()
    now = _now_iso()
    agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{agent_id}")

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            row = await conn.fetchrow(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'revoked',
                          revoked_at = NOW(),
                          revocation_reason = $1,
                          updated_at = NOW()
                    WHERE tenant_id = $2 AND agent_id = $3
                RETURNING *""",
                req_body.reason,
                tenant_id,
                agent_id,
            )
            if row is None:
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")

            # Release any active claims
            await conn.execute(
                """UPDATE public.agent_claims
                      SET released_at = NOW()
                    WHERE tenant_id = $1 AND (agent_id = $2 OR pod_name = $3) AND released_at IS NULL""",
                tenant_id,
                agent_uuid,
                agent_id,
            )

            await _audit_log_external_agent(
                conn,
                tenant_id,
                "external_agent.revoked",
                agent_id,
                principal,
                {"reason": req_body.reason, "agent_id": agent_id},
            )
            return _row_to_response(row)

    with _REG_LOCK:
        t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
        if agent_id not in t_regs:
            raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
        reg_item = t_regs[agent_id]
        reg_item["enrollment_status"] = "revoked"
        reg_item["revoked_at"] = now
        reg_item["revocation_reason"] = req_body.reason
        reg_item["updated_at"] = now

        # Release active in-memory claims
        with api_compat._STORE_LOCK:
            t_claims = api_compat._CLAIMS.get(tenant_id, {})
            for c in t_claims.values():
                if (c.get("pod_name") == agent_id or c.get("agent_id") == str(agent_uuid)) and c.get("released_at") is None:
                    c["released_at"] = now

    await _audit_log_external_agent(
        None,
        tenant_id,
        "external_agent.revoked",
        agent_id,
        principal,
        {"reason": req_body.reason, "agent_id": agent_id},
    )
    return _row_to_response(reg_item)


# Mount router endpoints
router.add_api_route(
    "/register",
    register_external_agent_handler,
    methods=["POST"],
    status_code=201,
    response_model=ExternalAgentRegistrationResponse,
    summary="Pre-register external Linux agent",
)
router.add_api_route(
    "/registrations",
    register_external_agent_handler,
    methods=["POST"],
    status_code=201,
    response_model=ExternalAgentRegistrationResponse,
    summary="Pre-register external Linux agent (alias)",
)
router.add_api_route(
    "/registrations",
    list_external_agents_handler,
    methods=["GET"],
    response_model=ExternalAgentRegistrationListResponse,
    summary="List external agent registrations",
)
router.add_api_route(
    "/registrations/{agent_id}",
    get_external_agent_handler,
    methods=["GET"],
    response_model=ExternalAgentRegistrationResponse,
    summary="Get external agent registration details",
)
router.add_api_route(
    "/registrations/{agent_id}/claim",
    claim_external_agent_handler,
    methods=["POST"],
    response_model=api_compat.AgentClaimResponse,
    summary="Claim pre-registered external agent",
)
router.add_api_route(
    "/{agent_id}/claim",
    claim_external_agent_handler,
    methods=["POST"],
    response_model=api_compat.AgentClaimResponse,
    summary="Claim external agent (alias)",
)
router.add_api_route(
    "/registrations/{agent_id}/revoke",
    revoke_external_agent_handler,
    methods=["POST"],
    response_model=ExternalAgentRegistrationResponse,
    summary="Revoke external agent registration",
)

# Compatibility router
compat_router.add_api_route(
    "/register",
    register_external_agent_handler,
    methods=["POST"],
    status_code=201,
    response_model=ExternalAgentRegistrationResponse,
)
compat_router.add_api_route(
    "/registrations",
    register_external_agent_handler,
    methods=["POST"],
    status_code=201,
    response_model=ExternalAgentRegistrationResponse,
)
compat_router.add_api_route(
    "/registrations",
    list_external_agents_handler,
    methods=["GET"],
    response_model=ExternalAgentRegistrationListResponse,
)
compat_router.add_api_route(
    "/registrations/{agent_id}",
    get_external_agent_handler,
    methods=["GET"],
    response_model=ExternalAgentRegistrationResponse,
)
compat_router.add_api_route(
    "/registrations/{agent_id}/claim",
    claim_external_agent_handler,
    methods=["POST"],
    response_model=api_compat.AgentClaimResponse,
)
compat_router.add_api_route(
    "/{agent_id}/claim",
    claim_external_agent_handler,
    methods=["POST"],
    response_model=api_compat.AgentClaimResponse,
)
compat_router.add_api_route(
    "/registrations/{agent_id}/revoke",
    revoke_external_agent_handler,
    methods=["POST"],
    response_model=ExternalAgentRegistrationResponse,
)
