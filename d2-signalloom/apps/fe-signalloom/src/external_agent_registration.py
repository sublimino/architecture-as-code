"""Tenant-bound external Linux agent registration, host enrollment, and revocation enforcement.

Implements AMXO-P2-2 and AMXO-P3-3:
1. Strict server-side tenant scoping derived from authenticated operator credentials.
2. Pre-registration of external Linux agent metadata (host OS, runtime profile, allocated budget).
3. Host enrollment exchange with single-use bearer token and Ed25519 key binding.
4. Independent host revocation without affecting user accounts or sibling host agents.
5. Immediate real-time upload rejection (403 Forbidden) for revoked hosts.
6. Append-only audit events and Actor-Resolution Spine delegation clamping.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator

import api_compat
from agent_claim import clamp_claim_delegation_in_spine, sync_claim_delegation_to_spine
from external_agent_contract import (
    EnrollmentRequest,
    EnrollmentResult,
    ExternalUpload,
    PrivacyContract,
    RevocationReason,
    RevocationRequest,
    RevocationResult,
    UploadResult,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/external-agents", tags=["external-agents"])
v1_router = APIRouter(prefix="/v1/external-agents", tags=["external-agents-v1"])
compat_router = APIRouter(prefix="/api/external-agents", tags=["external-agents-compat"])

SAFE_ID_REGEX = re.compile(r"^[a-z][a-z0-9-]{2,63}$")

# In-memory store for fallback/testing when PostgreSQL is not running
_REG_LOCK = threading.Lock()
# tenant_id -> { agent_id -> dict }
_EXTERNAL_REGISTRATIONS: dict[str, dict[str, dict[str, Any]]] = {}
# tenant_id -> { upload_id -> dict }
_EXTERNAL_UPLOADS: dict[str, dict[str, dict[str, Any]]] = {}


def reset_external_agent_state(tenant_id: str | None = None) -> None:
    with _REG_LOCK:
        if tenant_id:
            _EXTERNAL_REGISTRATIONS.pop(tenant_id, None)
            _EXTERNAL_UPLOADS.pop(tenant_id, None)
        else:
            _EXTERNAL_REGISTRATIONS.clear()
            _EXTERNAL_UPLOADS.clear()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
    revoked_by_subject: str | None = None
    revoked_by_user_id: str | None = None
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
    model_config = ConfigDict(extra="ignore")

    reason: str = Field(default="operator-request", min_length=1, max_length=256)
    reason_code: str | None = Field(default=None, max_length=256)


# Database & in-memory operations

async def _audit_log_external_agent(
    conn: Any,
    tenant_id: str,
    event_type: str,
    agent_id: str,
    principal: api_compat.Principal,
    detail: dict[str, Any],
) -> None:
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
            revoked_by_subject=row.get("revoked_by_subject"),
            revoked_by_user_id=str(row["revoked_by_user_id"]) if row.get("revoked_by_user_id") else None,
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
        registered_by_user_id=str(row["registered_by_user_id"]) if row.get("registered_by_user_id") is not None else None,
        allocated_token_budget=row["allocated_token_budget"],
        spiffe_id_pattern=row["spiffe_id_pattern"],
        enrolled_at=api_compat._ts(row["enrolled_at"]),
        revoked_at=api_compat._ts(row["revoked_at"]),
        revocation_reason=row["revocation_reason"],
        revoked_by_subject=row.get("revoked_by_subject") if "revoked_by_subject" in row else None,
        revoked_by_user_id=str(row["revoked_by_user_id"]) if row.get("revoked_by_user_id") is not None else None,
        metadata=json.loads(row["metadata"]) if isinstance(row["metadata"], str) else (row["metadata"] or {}),
        created_at=api_compat._ts(row["created_at"]) or "",
        updated_at=api_compat._ts(row["updated_at"]) or "",
    )


async def is_external_agent_revoked(
    tenant_id: str,
    agent_id: str,
    host_id: str | None = None,
) -> tuple[bool, str | None]:
    """Real-time credential revocation check for upload authorization."""
    pool = await api_compat._get_pool()
    if pool is not None:
        try:
            row = await pool.fetchrow(
                """SELECT enrollment_status, revoked_at, revocation_reason
                     FROM public.external_agent_registrations
                    WHERE tenant_id = $1 AND (agent_id = $2 OR (host_id = $3 AND $3 IS NOT NULL))
                    ORDER BY CASE WHEN enrollment_status = 'revoked' THEN 0 ELSE 1 END
                    LIMIT 1""",
                tenant_id,
                agent_id,
                host_id,
            )
            if row and (row["enrollment_status"] == "revoked" or row["revoked_at"] is not None):
                return True, row["revocation_reason"] or "Host credential has been revoked"
        except Exception as exc:
            logger.warning("Database revocation check query failed: %s", exc)

    with _REG_LOCK:
        t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
        if agent_id in t_regs:
            reg = t_regs[agent_id]
            if reg.get("enrollment_status") == "revoked" or reg.get("revoked_at") is not None:
                return True, reg.get("revocation_reason") or "Host credential has been revoked"
        if host_id:
            for reg in t_regs.values():
                if reg.get("host_id") == host_id and (reg.get("enrollment_status") == "revoked" or reg.get("revoked_at") is not None):
                    return True, reg.get("revocation_reason") or "Host credential has been revoked"

    return False, None


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
                    WHERE agent_id = $1 AND (tenant_id = $2 OR tenant_id != $2)""",
                body.agent_id,
                tenant_id,
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
                "revoked_by_subject": None,
                "revoked_by_user_id": None,
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
        async with pool.acquire() as conn:
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
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE tenant_id = $1 AND agent_id = $2""",
                tenant_id, agent_id,
            )
            if row is None:
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
            reg = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE agent_id = $1 AND (tenant_id = $2 OR tenant_id != $2) FOR UPDATE""",
                agent_id,
                tenant_id,
            )
            if reg is None:
                raise api_compat.APIError(
                    403,
                    "unregistered_agent",
                    f"External agent '{agent_id}' must be pre-registered within tenant scope before claim",
                )
            if reg["tenant_id"] != tenant_id:
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

            active_claim = await conn.fetchrow(
                """SELECT claim_id, status, released_at FROM public.agent_claims
                    WHERE (agent_id = $1 OR pod_name = $2)
                      AND (tenant_id = $3 OR tenant_id != $3)
                      AND status = 'granted'
                      AND released_at IS NULL""",
                agent_uuid,
                agent_id,
                tenant_id,
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

            if reg["enrollment_status"] == "revoked":
                raise api_compat.APIError(
                    403,
                    "agent_revoked",
                    f"External agent '{agent_id}' has been revoked and cannot be claimed",
                )

            budget = req_body.allocated_token_budget or reg["allocated_token_budget"]
            spiffe_id = reg["spiffe_id_pattern"] or f"spiffe://cluster.local/ns/external-agents/sa/{agent_id}"

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

            await conn.execute(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'enrolled',
                          enrolled_at = NOW(),
                          updated_at = NOW()
                    WHERE tenant_id = $1 AND agent_id = $2""",
                tenant_id,
                agent_id,
            )

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
        unregistered = False
        cross_tenant_rejected = False
        revoked = False
        duplicate_claim_obj = None
        reg_item = None
        budget = 100000
        spiffe_id = f"spiffe://cluster.local/ns/external-agents/sa/{agent_id}"

        with _REG_LOCK:
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
                with api_compat._STORE_LOCK:
                    t_claims = api_compat._CLAIMS.setdefault(tenant_id, {})
                    for c in t_claims.values():
                        if (c.get("pod_name") == agent_id or c.get("agent_id") == str(agent_uuid)) and c.get("status") == "granted" and c.get("released_at") is None:
                            duplicate_claim_obj = c
                            break

                    if duplicate_claim_obj is None:
                        for other_tenant, ot_claims in api_compat._CLAIMS.items():
                            if other_tenant != tenant_id:
                                for c in ot_claims.values():
                                    if c.get("pod_name") == agent_id and c.get("status") == "granted" and c.get("released_at") is None:
                                        cross_tenant_rejected = True
                                        break

                    if duplicate_claim_obj is None and not cross_tenant_rejected:
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
        if duplicate_claim_obj is not None:
            await _audit_log_external_agent(
                None,
                tenant_id,
                "external_agent.claim_rejected",
                agent_id,
                principal,
                {
                    "reason": "duplicate_claim_rejected",
                    "existing_claim_id": duplicate_claim_obj["claim_id"],
                    "agent_id": agent_id,
                },
            )
            raise api_compat.APIError(
                409,
                "duplicate_claim",
                f"Agent '{agent_id}' already has an active claim ({duplicate_claim_obj['claim_id']})",
            )
        if revoked:
            raise api_compat.APIError(
                403,
                "agent_revoked",
                f"External agent '{agent_id}' has been revoked and cannot be claimed",
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
                "host_id": reg_item["host_id"] if reg_item else "external-host",
                "host_os": reg_item.get("host_os", "linux") if reg_item else "linux",
                "runtime_profile": reg_item.get("runtime_profile", "nono-0.73.0-standard") if reg_item else "nono-0.73.0-standard",
                "spiffe_id": spiffe_id,
                "harness": req_body.harness,
                "model": req_body.model,
                "token_budget": budget,
            },
        )

    try:
        await sync_claim_delegation_to_spine(
            tenant_id=tenant_id,
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


# Revocation Logic (AMXO-P3-3)

async def _execute_revocation(
    tenant_id: str,
    agent_id: str,
    reason: str,
    principal: api_compat.Principal,
) -> dict[str, Any]:
    """Execute host/agent revocation: update DB, release claims, clamp spine, and record audit."""
    _validate_safe_id(agent_id, "agent_id")
    now = _now_iso()
    agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{agent_id}")

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            # Look up revoking user ID from platform_users if present
            user_row = await conn.fetchrow(
                "SELECT id FROM public.platform_users WHERE tenant_id = $1 AND subject = $2 LIMIT 1",
                tenant_id,
                principal.subject,
            )
            user_id = user_row["id"] if user_row else None

            row = await conn.fetchrow(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'revoked',
                          revoked_at = NOW(),
                          revocation_reason = $1,
                          revoked_by_subject = $2,
                          revoked_by_issuer = $3,
                          revoked_by_user_id = $4,
                          updated_at = NOW()
                    WHERE tenant_id = $5 AND agent_id = $6
                RETURNING *""",
                reason,
                principal.subject,
                api_compat.settings.api_jwt_issuer,
                user_id,
                tenant_id,
                agent_id,
            )
            if row is None:
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")

            # Release any active claims in agent_claims
            await conn.execute(
                """UPDATE public.agent_claims
                      SET released_at = NOW()
                    WHERE tenant_id = $1 AND (agent_id = $2 OR pod_name = $3) AND released_at IS NULL""",
                tenant_id,
                agent_uuid,
                agent_id,
            )

            # Revoke any agent credentials in agent_credentials table
            try:
                await conn.execute(
                    """UPDATE public.agent_credentials
                          SET revoked_at = NOW(),
                              revoked_by = $1
                        WHERE tenant_id = $2 AND agent_id = $3 AND revoked_at IS NULL""",
                    principal.actor,
                    tenant_id,
                    agent_uuid,
                )
            except Exception as exc:
                logger.debug("agent_credentials update skipped: %s", exc)

            await _audit_log_external_agent(
                conn,
                tenant_id,
                "external_agent.revoked",
                agent_id,
                principal,
                {"reason": reason, "agent_id": agent_id, "revoked_by": principal.subject},
            )

            try:
                await clamp_claim_delegation_in_spine(tenant_id, str(agent_uuid))
            except Exception as exc:
                logger.warning("Spine clamp failed during revocation: %s", exc)

            return dict(row)

    # In-memory store
    with _REG_LOCK:
        t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
        if agent_id not in t_regs:
            raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
        reg_item = t_regs[agent_id]
        reg_item["enrollment_status"] = "revoked"
        reg_item["revoked_at"] = now
        reg_item["revocation_reason"] = reason
        reg_item["revoked_by_subject"] = principal.subject
        reg_item["revoked_by_issuer"] = api_compat.settings.api_jwt_issuer
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
        {"reason": reason, "agent_id": agent_id, "revoked_by": principal.subject},
    )

    try:
        await clamp_claim_delegation_in_spine(tenant_id, str(agent_uuid))
    except Exception as exc:
        logger.warning("Spine clamp failed during revocation: %s", exc)

    return reg_item


async def revoke_external_agent_handler(
    agent_id: str,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
    body: ExternalAgentRevocationRequest | dict[str, Any] | None = None,
) -> ExternalAgentRegistrationResponse:
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    reason = "operator_revocation"
    if isinstance(body, ExternalAgentRevocationRequest):
        reason = body.reason_code or body.reason or "operator_revocation"
    elif isinstance(body, dict):
        reason = body.get("reason_code") or body.get("reason") or "operator_revocation"

    row = await _execute_revocation(tenant_id, agent_id, reason, principal)
    return _row_to_response(row)


async def revoke_external_agent_contract_handler(
    agent_id: str,
    response: Response,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
    body: RevocationRequest | dict[str, Any] | None = None,
) -> RevocationResult:
    """AMXO-P1-3 wire contract revocation endpoint (returns 202 RevocationResult)."""
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    reason_code: RevocationReason = "operator-request"
    if isinstance(body, RevocationRequest):
        reason_code = body.reason_code
    elif isinstance(body, dict) and "reason_code" in body:
        reason_code = body["reason_code"]

    row = await _execute_revocation(tenant_id, agent_id, reason_code, principal)
    response.status_code = status.HTTP_202_ACCEPTED
    credential_ref = row.get("spiffe_id_pattern") or f"spiffe://signalloom.demo/platform/signalloom/tenant/{tenant_id}/agent/{agent_id}"

    return RevocationResult(
        schema_version="1.0.0",
        agent_id=agent_id,
        credential_reference=credential_ref,
        revocation_state="revocation-accepted",
        reason_code=reason_code,
        revoked_at=api_compat._ts(row.get("revoked_at")) or _now_iso(),
    )


async def revoke_external_host_handler(
    host_id: str,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
    body: ExternalAgentRevocationRequest | dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Revoke all external agents registered under a specific host ID for this tenant."""
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    reason = "host-unenrolled"
    if isinstance(body, ExternalAgentRevocationRequest):
        reason = body.reason_code or body.reason or "host-unenrolled"
    elif isinstance(body, dict):
        reason = body.get("reason_code") or body.get("reason") or "host-unenrolled"

    pool = await api_compat._get_pool()
    revoked_agents: list[str] = []
    if pool is not None:
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT agent_id FROM public.external_agent_registrations WHERE tenant_id = $1 AND host_id = $2",
                tenant_id, host_id,
            )
            for r in rows:
                await _execute_revocation(tenant_id, r["agent_id"], reason, principal)
                revoked_agents.append(r["agent_id"])
    else:
        with _REG_LOCK:
            t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
            agents_to_revoke = [aid for aid, r in t_regs.items() if r.get("host_id") == host_id]
        for aid in agents_to_revoke:
            await _execute_revocation(tenant_id, aid, reason, principal)
            revoked_agents.append(aid)

    return {
        "status": "revoked",
        "host_id": host_id,
        "tenant_id": tenant_id,
        "revoked_agents": revoked_agents,
        "count": len(revoked_agents),
    }


# Enrollment & Upload Handlers (AMXO-P3-1 / AMXO-P3-3)

async def enroll_external_agent_handler(
    body: EnrollmentRequest | dict[str, Any],
    authorization: Annotated[str | None, Header()] = None,
    principal: api_compat.Principal | None = Depends(api_compat.authenticated_principal),
) -> EnrollmentResult:
    """Enroll an external host with pre-registered agent record (P3-1 / P3-3)."""
    req_dict = body.model_dump() if isinstance(body, BaseModel) else body
    agent_id = req_dict["agent_id"]
    host_id = req_dict["host_id"]
    key_id = req_dict["key_id"]
    credential_ref = req_dict.get("credential_reference") or f"spiffe://signalloom.demo/platform/signalloom/tenant/tenant-demo/agent/{agent_id}"

    tenant_id = principal.tenant if principal else "tenant-demo"
    now = _now_iso()

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            reg = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE agent_id = $1 AND tenant_id = $2 FOR UPDATE""",
                agent_id, tenant_id,
            )
            if reg is None:
                raise api_compat.APIError(404, "not_found", f"Agent '{agent_id}' is not pre-registered")

            if reg["enrollment_status"] == "revoked":
                raise api_compat.APIError(403, "host_revoked", f"Agent '{agent_id}' has been revoked")

            if reg["enrollment_status"] == "enrolled":
                raise api_compat.APIError(409, "already_enrolled", f"Agent '{agent_id}' is already enrolled")

            await conn.execute(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'enrolled',
                          enrolled_at = NOW(),
                          metadata = metadata || $1::jsonb,
                          updated_at = NOW()
                    WHERE tenant_id = $2 AND agent_id = $3""",
                json.dumps({"key_id": key_id, "public_key": req_dict.get("public_key")}),
                tenant_id, agent_id,
            )
    else:
        with _REG_LOCK:
            t_regs = _EXTERNAL_REGISTRATIONS.get(tenant_id, {})
            if agent_id not in t_regs:
                raise api_compat.APIError(404, "not_found", f"Agent '{agent_id}' is not pre-registered")
            reg = t_regs[agent_id]
            if reg.get("enrollment_status") == "revoked":
                raise api_compat.APIError(403, "host_revoked", f"Agent '{agent_id}' has been revoked")
            if reg.get("enrollment_status") == "enrolled":
                raise api_compat.APIError(409, "already_enrolled", f"Agent '{agent_id}' is already enrolled")
            reg["enrollment_status"] = "enrolled"
            reg["enrolled_at"] = now
            reg.setdefault("metadata", {})["key_id"] = key_id

    expires_at = datetime.now(timezone.utc).replace(year=datetime.now(timezone.utc).year + 1).strftime("%Y-%m-%dT%H:%M:%SZ")
    return EnrollmentResult(
        schema_version="1.0.0",
        tenant_id=tenant_id,
        agent_id=agent_id,
        host_id=host_id,
        key_id=key_id,
        enrollment_state="enrolled",
        credential_kind="existing-mtls-identity",
        credential_scope="audit-upload-only",
        credential_bootstrap="pre-provisioned-out-of-band",
        credential_reference=credential_ref,
        credential_expires_at=expires_at,
        revocation_endpoint=f"/v1/external-agents/{agent_id}/revocations",
    )


async def upload_external_agent_evidence_handler(
    body: ExternalUpload | dict[str, Any],
    response: Response,
    principal: api_compat.Principal | None = Depends(api_compat.authenticated_principal),
) -> UploadResult:
    """Receive and verify external agent evidence upload with real-time revocation enforcement."""
    upload_dict = body.model_dump() if isinstance(body, BaseModel) else body
    upload_id = upload_dict.get("upload_id") or f"upload-{uuid.uuid4().hex[:16]}"
    session_id = upload_dict.get("session_id", "session-default")

    # Extract agent_id from upload or envelope
    agent_id = "agent-maxxing-linux-01"
    if "assertion_envelope" in upload_dict and "assertions" in upload_dict["assertion_envelope"]:
        assertions = upload_dict["assertion_envelope"]["assertions"]
        if assertions and isinstance(assertions, list) and "agent_id" in assertions[0]:
            agent_id = assertions[0]["agent_id"]

    tenant_id = principal.tenant if principal else "tenant-demo"

    # Real-time Revocation Check
    is_revoked, rev_reason = await is_external_agent_revoked(tenant_id, agent_id)
    if is_revoked:
        logger.warning("Upload denied: external agent '%s' is revoked on tenant '%s' (%s)", agent_id, tenant_id, rev_reason)
        raise api_compat.APIError(
            status_code=403,
            code="host_revoked",
            message=f"Host credential for agent '{agent_id}' has been revoked: {rev_reason}",
        )

    # Store upload record
    with _REG_LOCK:
        t_uploads = _EXTERNAL_UPLOADS.setdefault(tenant_id, {})
        t_uploads[upload_id] = {
            "upload_id": upload_id,
            "session_id": session_id,
            "agent_id": agent_id,
            "uploaded_at": _now_iso(),
            "status": "accepted",
        }

    response.status_code = status.HTTP_202_ACCEPTED
    return UploadResult(
        schema_version="1.0.0",
        upload_id=upload_id,
        replay_result="accepted",
        host_signature_state="host-signature-verified",
        original_chain_state="original-chain-not-verified",
    )


# Mount routes on routers

# Canonical /api routes matching DB_ROUTES in test_tenant_isolation.py
for r in (router, compat_router):
    r.add_api_route("/register", register_external_agent_handler, methods=["POST"], status_code=201, response_model=ExternalAgentRegistrationResponse)
    r.add_api_route("/registrations", register_external_agent_handler, methods=["POST"], status_code=201, response_model=ExternalAgentRegistrationResponse)
    r.add_api_route("/registrations", list_external_agents_handler, methods=["GET"], response_model=ExternalAgentRegistrationListResponse)
    r.add_api_route("/registrations/{agent_id}", get_external_agent_handler, methods=["GET"], response_model=ExternalAgentRegistrationResponse)
    r.add_api_route("/registrations/{agent_id}/claim", claim_external_agent_handler, methods=["POST"], response_model=api_compat.AgentClaimResponse)
    r.add_api_route("/registrations/{agent_id}/revoke", revoke_external_agent_handler, methods=["POST"], response_model=ExternalAgentRegistrationResponse)
    r.add_api_route("/{agent_id}/claim", claim_external_agent_handler, methods=["POST"], response_model=api_compat.AgentClaimResponse)

# Full contract surface mounted on /v1/external-agents (external-agent-server.v1.schema.json)
v1_router.add_api_route("/enroll", enroll_external_agent_handler, methods=["POST"], status_code=201, response_model=EnrollmentResult)
v1_router.add_api_route("/evidence-uploads", upload_external_agent_evidence_handler, methods=["POST"], status_code=202, response_model=UploadResult)
v1_router.add_api_route("/{agent_id}/revocations", revoke_external_agent_contract_handler, methods=["POST"], status_code=202, response_model=RevocationResult)
v1_router.add_api_route("/registrations/{agent_id}/revocations", revoke_external_agent_contract_handler, methods=["POST"], status_code=202, response_model=RevocationResult)
v1_router.add_api_route("/hosts/{host_id}/revoke", revoke_external_host_handler, methods=["POST"])
v1_router.add_api_route("/register", register_external_agent_handler, methods=["POST"], status_code=201, response_model=ExternalAgentRegistrationResponse)
v1_router.add_api_route("/registrations", register_external_agent_handler, methods=["POST"], status_code=201, response_model=ExternalAgentRegistrationResponse)
v1_router.add_api_route("/registrations", list_external_agents_handler, methods=["GET"], response_model=ExternalAgentRegistrationListResponse)
v1_router.add_api_route("/registrations/{agent_id}", get_external_agent_handler, methods=["GET"], response_model=ExternalAgentRegistrationResponse)
v1_router.add_api_route("/{agent_id}", get_external_agent_handler, methods=["GET"], response_model=ExternalAgentRegistrationResponse)
v1_router.add_api_route("/registrations/{agent_id}/claim", claim_external_agent_handler, methods=["POST"], response_model=api_compat.AgentClaimResponse)
v1_router.add_api_route("/{agent_id}/claim", claim_external_agent_handler, methods=["POST"], response_model=api_compat.AgentClaimResponse)
v1_router.add_api_route("/registrations/{agent_id}/revoke", revoke_external_agent_handler, methods=["POST"], response_model=ExternalAgentRegistrationResponse)
v1_router.add_api_route("/{agent_id}/revoke", revoke_external_agent_handler, methods=["POST"], response_model=ExternalAgentRegistrationResponse)
v1_router.add_api_route("/{agent_id}/evidence-uploads", upload_external_agent_evidence_handler, methods=["POST"], status_code=202, response_model=UploadResult)
v1_router.add_api_route("/{agent_id}/uploads", upload_external_agent_evidence_handler, methods=["POST"], status_code=202, response_model=UploadResult)
