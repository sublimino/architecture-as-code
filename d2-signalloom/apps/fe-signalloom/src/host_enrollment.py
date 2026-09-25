"""Atomic one-time external host enrollment token exchange service and router.

Implements AMXO-P3-1 and EAPR-P3-4:
1. Operator token issuance with CSPRNG entropy and SHA-256 hashed storage.
2. Single-use atomic compare-and-set redemption with immediate token invalidation.
3. Strict constant-time hash comparison preventing timing attacks.
4. Concurrency-safe replay protection rejecting duplicate and expired redemption attempts.
5. Audit event emission on successful, rejected, and revoked enrollment attempts with SPIFFE ID.
6. Server-minted SPIFFE IDs and SPIRE registration entries under spiffe://signalloom.demo.
7. Explicit refusal (HTTP 422) if client supplies credential_reference.
8. Authenticated, tenant-bound revocation endpoint with SPIRE entry deletion.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import re
import secrets
import threading
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Literal, Optional

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

import api_compat
from agent_claim import sync_claim_delegation_to_spine
from environment_routing import derive_customer_hash
from external_agent_contract import (
    ContractError,
    EnrollmentRequest,
    EnrollmentResult,
)
import external_agent_registration
from tenant_isolation import generate_spire_registration_entry, get_tenant_spiffe_id

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/external-agents", tags=["host-enrollment"])
api_router = APIRouter(prefix="/api/v1/external-agents", tags=["host-enrollment-api"])
compat_router = APIRouter(prefix="/api/external-agents", tags=["host-enrollment-compat"])

BEARER_AUTH_REGEX = re.compile(r"^Bearer\s+([A-Za-z0-9_.-]{16,2048})$", re.IGNORECASE)

# In-memory store for fallback/testing
_HOST_ENROLL_LOCK = threading.Lock()
# token_hash -> dict
_HOST_ENROLLMENT_TOKENS: dict[str, dict[str, Any]] = {}
# agent_id / entry_id -> dict
_SPIRE_REGISTRATION_ENTRIES: dict[str, dict[str, Any]] = {}


def reset_host_enrollment_state() -> None:
    with _HOST_ENROLL_LOCK:
        _HOST_ENROLLMENT_TOKENS.clear()
        _SPIRE_REGISTRATION_ENTRIES.clear()


def get_spire_registration_entry_for_agent(agent_id: str) -> dict[str, Any] | None:
    with _HOST_ENROLL_LOCK:
        return _SPIRE_REGISTRATION_ENTRIES.get(agent_id)


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _format_rfc3339(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def hash_enrollment_token(token: str) -> str:
    """Compute canonical SHA-256 hash of plaintext enrollment token."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_secure_token() -> str:
    """Generate cryptographically secure enrollment token with 256 bits entropy."""
    return secrets.token_urlsafe(32)


def _compute_spiffe_id(tenant_id: str, agent_id: str) -> str:
    """Compute server-minted SPIFFE ID under signalloom.demo trust domain."""
    tenant_hash = tenant_id if re.match(r"^[0-9a-f]{8}$", tenant_id) else derive_customer_hash(tenant_id)
    return f"spiffe://signalloom.demo/ns/eap-{tenant_hash.lower()}/sa/agent-{agent_id}"


class TokenIssueRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    ttl_seconds: int = Field(default=3600, ge=60, le=86400 * 30)


class TokenIssueResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    tenant_id: str
    enrollment_token: str
    token_type: Literal["Bearer"] = "Bearer"
    expires_at: str
    created_at: str


def _make_error_response(status_code: int, error_code: str, message: str) -> JSONResponse:
    request_id = f"req-{uuid.uuid4().hex[:16]}"
    err = ContractError(
        schema_version="1.0.0",
        error_code=error_code,  # type: ignore[arg-type]
        message=message[:256],
        request_id=request_id,
    )
    return JSONResponse(status_code=status_code, content=err.model_dump(mode="json"))


async def _audit_log_enrollment(
    conn: Any,
    tenant_id: str,
    event_type: str,
    agent_id: str,
    actor_str: str,
    actor_subject: str,
    detail: dict[str, Any],
) -> None:
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
                actor_subject,
                json.dumps(detail, default=str),
            )
            return
        except Exception as exc:
            logger.warning("DB audit log failed for host enrollment: %s", exc)

    api_compat._record_memory_audit(
        tenant_id=tenant_id,
        event_type=event_type,
        agent_id=str(agent_uuid),
        agent_name=agent_id,
        actor=actor_str,
        detail=detail,
    )


# --- Service Functions ---

async def issue_enrollment_token_for_agent(
    agent_id: str,
    tenant_id: str,
    principal: api_compat.Principal,
    ttl_seconds: int = 3600,
) -> TokenIssueResponse:
    """Issue a new one-time enrollment token for a pre-registered external agent."""
    token = generate_secure_token()
    token_hash = hash_enrollment_token(token)
    now = _now_utc()
    expires_at = now + timedelta(seconds=ttl_seconds)
    now_str = _format_rfc3339(now)
    expires_at_str = _format_rfc3339(expires_at)
    token_id = str(uuid.uuid4())

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            reg = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE tenant_id = $1 AND agent_id = $2 FOR UPDATE""",
                tenant_id,
                agent_id,
            )
            if reg is None:
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
            if reg["enrollment_status"] == "revoked":
                raise api_compat.APIError(403, "agent_revoked", f"External agent '{agent_id}' is revoked")

            # Update registration record
            await conn.execute(
                """UPDATE public.external_agent_registrations
                      SET enrollment_token_hash = $1,
                          enrollment_token_expires_at = $2,
                          enrollment_status = 'pending',
                          updated_at = NOW()
                    WHERE tenant_id = $3 AND agent_id = $4""",
                token_hash,
                expires_at,
                tenant_id,
                agent_id,
            )

            # Insert into host_enrollment_tokens
            await conn.execute(
                """INSERT INTO public.host_enrollment_tokens (
                    id, tenant_id, agent_id, host_id, token_hash,
                    created_by_subject, created_by_issuer, expires_at, status, created_at, updated_at
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7, $8, 'pending', NOW(), NOW()
                ) ON CONFLICT (token_hash) DO UPDATE SET
                    expires_at = $8, status = 'pending', updated_at = NOW()""",
                uuid.UUID(token_id),
                tenant_id,
                agent_id,
                reg["host_id"],
                token_hash,
                principal.subject,
                api_compat.settings.api_jwt_issuer,
                expires_at,
            )

            await _audit_log_enrollment(
                conn,
                tenant_id,
                "external_agent.token_issued",
                agent_id,
                principal.email or principal.subject,
                principal.subject,
                {
                    "action": "token_issued",
                    "agent_id": agent_id,
                    "host_id": reg["host_id"],
                    "expires_at": expires_at_str,
                },
            )
    else:
        # In-memory store
        with external_agent_registration._REG_LOCK:
            t_regs = external_agent_registration._EXTERNAL_REGISTRATIONS.get(tenant_id, {})
            if agent_id not in t_regs:
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
            reg = t_regs[agent_id]
            if reg.get("enrollment_status") == "revoked":
                raise api_compat.APIError(403, "agent_revoked", f"External agent '{agent_id}' is revoked")

            reg["enrollment_token_hash"] = token_hash
            reg["enrollment_token_expires_at"] = expires_at_str
            reg["enrollment_status"] = "pending"
            reg["updated_at"] = now_str

        with _HOST_ENROLL_LOCK:
            _HOST_ENROLLMENT_TOKENS[token_hash] = {
                "id": token_id,
                "tenant_id": tenant_id,
                "agent_id": agent_id,
                "host_id": reg["host_id"],
                "token_hash": token_hash,
                "created_by_subject": principal.subject,
                "created_by_issuer": api_compat.settings.api_jwt_issuer,
                "expires_at": expires_at_str,
                "status": "pending",
                "created_at": now_str,
                "updated_at": now_str,
            }

        await _audit_log_enrollment(
            None,
            tenant_id,
            "external_agent.token_issued",
            agent_id,
            principal.email or principal.subject,
            principal.subject,
            {
                "action": "token_issued",
                "agent_id": agent_id,
                "host_id": reg["host_id"],
                "expires_at": expires_at_str,
            },
        )

    return TokenIssueResponse(
        agent_id=agent_id,
        tenant_id=tenant_id,
        enrollment_token=token,
        token_type="Bearer",
        expires_at=expires_at_str,
        created_at=now_str,
    )


async def revoke_external_agent_for_host(
    agent_id: str,
    tenant_id: str,
    principal: api_compat.Principal,
    reason: str = "operator_revocation",
) -> dict[str, Any]:
    """Revoke an enrolled external agent registration and clear its SPIRE entry."""
    now = _now_utc()
    now_str = _format_rfc3339(now)
    spiffe_id = _compute_spiffe_id(tenant_id, agent_id)

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            reg = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE agent_id = $1 AND tenant_id = $2 FOR UPDATE""",
                agent_id,
                tenant_id,
            )
            if reg is None:
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")

            await conn.execute(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'revoked',
                          revoked_at = NOW(),
                          revoked_by_subject = $2,
                          revocation_reason = $3,
                          enrollment_token_hash = NULL,
                          enrollment_token_expires_at = NULL,
                          updated_at = NOW()
                    WHERE agent_id = $1 AND tenant_id = $4""",
                agent_id,
                principal.subject,
                reason,
                tenant_id,
            )
            with _HOST_ENROLL_LOCK:
                _SPIRE_REGISTRATION_ENTRIES.pop(agent_id, None)

            await _audit_log_enrollment(
                conn,
                tenant_id,
                "external_agent.revoked",
                agent_id,
                principal.email or principal.subject,
                principal.subject,
                {
                    "action": "revoked",
                    "agent_id": agent_id,
                    "spiffe_id": spiffe_id,
                    "reason": reason,
                    "revoked_by": principal.subject,
                },
            )
    else:
        with external_agent_registration._REG_LOCK:
            t_regs = external_agent_registration._EXTERNAL_REGISTRATIONS.get(tenant_id, {})
            if agent_id not in t_regs:
                raise api_compat.APIError(404, "not_found", f"External agent '{agent_id}' not found")
            reg = t_regs[agent_id]
            reg["enrollment_status"] = "revoked"
            reg["revoked_at"] = now_str
            reg["revoked_by_subject"] = principal.subject
            reg["revocation_reason"] = reason
            reg["enrollment_token_hash"] = None
            reg["enrollment_token_expires_at"] = None
            reg["updated_at"] = now_str

        with _HOST_ENROLL_LOCK:
            _SPIRE_REGISTRATION_ENTRIES.pop(agent_id, None)

        await _audit_log_enrollment(
            None,
            tenant_id,
            "external_agent.revoked",
            agent_id,
            principal.email or principal.subject,
            principal.subject,
            {
                "action": "revoked",
                "agent_id": agent_id,
                "spiffe_id": spiffe_id,
                "reason": reason,
                "revoked_by": principal.subject,
            },
        )

    return {
        "schema_version": "1.0.0",
        "status": "revoked",
        "enrollment_status": "revoked",
        "revocation_state": "revocation-accepted",
        "agent_id": agent_id,
        "tenant_id": tenant_id,
        "credential_reference": spiffe_id,
        "spiffe_id": spiffe_id,
        "revoked_at": now_str,
        "revocation_reason": reason,
    }


async def revoke_all_agents_for_tenant(
    tenant_id: str,
    principal: api_compat.Principal,
    reason: str = "environment_reaped",
) -> list[dict[str, Any]]:
    """Revoke every registered agent under a tenant (invoked during environment reap / teardown)."""
    results: list[dict[str, Any]] = []
    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._read(pool) as conn:
            rows = await conn.fetch(
                """SELECT agent_id FROM public.external_agent_registrations
                    WHERE tenant_id = $1 AND enrollment_status != 'revoked'""",
                tenant_id,
            )
            for row in rows:
                rev = await revoke_external_agent_for_host(row["agent_id"], tenant_id, principal, reason)
                results.append(rev)
    else:
        with external_agent_registration._REG_LOCK:
            t_regs = list(external_agent_registration._EXTERNAL_REGISTRATIONS.get(tenant_id, {}).keys())
        for agent_id in t_regs:
            try:
                rev = await revoke_external_agent_for_host(agent_id, tenant_id, principal, reason)
                results.append(rev)
            except Exception:
                pass
    return results


# --- Handlers ---

async def issue_token_handler(
    agent_id: str,
    body: TokenIssueRequest | None = None,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
) -> TokenIssueResponse:
    """Operator endpoint to generate / rotate a one-time enrollment token."""
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    req_body = body or TokenIssueRequest()
    return await issue_enrollment_token_for_agent(
        agent_id=agent_id,
        tenant_id=tenant_id,
        principal=principal,
        ttl_seconds=req_body.ttl_seconds,
    )


async def revoke_agent_handler(
    agent_id: str,
    body: dict[str, Any] | None = None,
    principal: api_compat.Principal = Depends(api_compat.authenticated_principal),
) -> JSONResponse:
    """Revoke external agent registration, deleting SPIRE entry and setting revoked status."""
    tenant_id = principal.tenant
    if not tenant_id:
        raise api_compat.APIError(401, "unauthenticated", "Authentication required")

    reason = "operator_revocation"
    if body and isinstance(body, dict):
        reason = body.get("reason") or body.get("reason_code") or "operator_revocation"

    result = await revoke_external_agent_for_host(
        agent_id=agent_id,
        tenant_id=tenant_id,
        principal=principal,
        reason=reason,
    )
    return JSONResponse(status_code=200, content=result)


async def enroll_host_handler(
    request: Request,
    authorization: str | None = Header(None),
) -> Response:
    """Atomic one-time external host enrollment token exchange endpoint.

    Validates Bearer enrollment token, verifies agent pre-registration,
    executes atomic compare-and-set state transition, mints server-issued SPIFFE ID
    and SPIRE registration entry, and invalidates the token.
    """
    # 1. Content-Type check (must be application/json)
    content_type = request.headers.get("content-type", "")
    if content_type and not content_type.startswith("application/json"):
        return _make_error_response(415, "unsupported-media-type", "Content-Type must be application/json")

    # 2. Extract Bearer token
    if not authorization:
        return _make_error_response(401, "unauthenticated", "Missing Authorization header")

    match = BEARER_AUTH_REGEX.match(authorization.strip())
    if not match:
        return _make_error_response(401, "unauthenticated", "Invalid Authorization header format; Bearer token required")

    plaintext_token = match.group(1)
    token_hash = hash_enrollment_token(plaintext_token)

    # 3. Parse and validate request body against frozen EnrollmentRequest contract
    try:
        raw_body = await request.body()
        if not raw_body:
            return _make_error_response(400, "malformed-request", "Empty request body")
        body_json = json.loads(raw_body)
    except json.JSONDecodeError:
        return _make_error_response(400, "malformed-request", "Invalid JSON body")

    # Step 7: Refuse client-supplied credential_reference with 422
    if "credential_reference" in body_json and body_json["credential_reference"] is not None:
        return _make_error_response(422, "validation-failed", "credential_reference is server-issued")

    try:
        body = EnrollmentRequest.model_validate(body_json)
    except Exception as exc:
        return _make_error_response(422, "validation-failed", f"Contract validation failed: {exc}")

    now = _now_utc()
    now_str = _format_rfc3339(now)
    cred_expires = now + timedelta(days=90)
    cred_expires_str = _format_rfc3339(cred_expires)

    # Step 6: Timestamp 300s window check
    raw_ts = body.timestamp or body_json.get("timestamp") or request.headers.get("x-timestamp") or request.headers.get("x-auth-timestamp")
    if raw_ts:
        try:
            ts_clean = str(raw_ts).replace("Z", "+00:00")
            ts_dt = datetime.fromisoformat(ts_clean)
            if abs((now - ts_dt).total_seconds()) > 300:
                return _make_error_response(401, "unauthenticated", "Request timestamp outside 300-second validity window")
        except Exception:
            return _make_error_response(401, "unauthenticated", "Invalid request timestamp")

    pool = await api_compat._get_pool()
    if pool is not None:
        async with api_compat._write(pool) as conn:
            # 1. Find agent registration with row lock
            reg = await conn.fetchrow(
                """SELECT * FROM public.external_agent_registrations
                    WHERE agent_id = $1 FOR UPDATE""",
                body.agent_id,
            )
            if reg is None:
                return _make_error_response(403, "forbidden", f"External agent '{body.agent_id}' is not pre-registered")

            tenant_id = reg["tenant_id"]

            # 2. Check revocation
            if reg["enrollment_status"] == "revoked":
                await _audit_log_enrollment(
                    conn,
                    tenant_id,
                    "external_agent.claim_rejected",
                    body.agent_id,
                    f"host:{body.host_id}",
                    body.host_id,
                    {"reason": "agent_revoked", "agent_id": body.agent_id, "host_id": body.host_id},
                )
                return _make_error_response(403, "forbidden", f"External agent '{body.agent_id}' has been revoked")

            # 3. Check host_id match
            if reg["host_id"] != body.host_id:
                await _audit_log_enrollment(
                    conn,
                    tenant_id,
                    "external_agent.claim_rejected",
                    body.agent_id,
                    f"host:{body.host_id}",
                    body.host_id,
                    {"reason": "host_id_mismatch", "expected": reg["host_id"], "provided": body.host_id},
                )
                return _make_error_response(409, "conflict", f"Host ID mismatch: expected '{reg['host_id']}', got '{body.host_id}'")

            # Step 6: Refuse body naming a tenant other than the token's tenant with 403
            req_tenant = body.tenant_id or body_json.get("tenant_id")
            if req_tenant and req_tenant != tenant_id:
                await _audit_log_enrollment(
                    conn,
                    tenant_id,
                    "external_agent.cross_tenant_rejected",
                    body.agent_id,
                    f"host:{body.host_id}",
                    body.host_id,
                    {
                        "reason": "cross_tenant_mismatch",
                        "token_tenant": tenant_id,
                        "provided_tenant": req_tenant,
                        "agent_id": body.agent_id,
                    },
                )
                return _make_error_response(403, "forbidden", f"Tenant mismatch: token is bound to '{tenant_id}', request specified '{req_tenant}'")

            # Step 6: Client nonce idempotency (return original result, no second SPIRE entry)
            if reg["enrollment_status"] == "enrolled" and reg["enrolled_client_nonce"] == body.client_nonce:
                spiffe_id = reg["enrolled_credential_reference"] or _compute_spiffe_id(tenant_id, body.agent_id)
                result = EnrollmentResult(
                    schema_version="1.0.0",
                    tenant_id=tenant_id,
                    agent_id=body.agent_id,
                    host_id=body.host_id,
                    key_id=body.key_id,
                    enrollment_state="enrolled",
                    credential_kind=body.credential_kind,
                    credential_scope=body.credential_scope,
                    credential_bootstrap=body.credential_bootstrap,
                    credential_reference=spiffe_id,
                    credential_expires_at=reg["enrolled_credential_expires_at"] or cred_expires_str,
                    revocation_endpoint=f"/v1/external-agents/{body.agent_id}/revocations",
                    svid_path="jwt-svid-fetch",
                )
                return JSONResponse(status_code=201, content=result.model_dump(mode="json"))

            # 4. Check token presence and constant-time match
            stored_hash = reg["enrollment_token_hash"]
            token_valid = bool(stored_hash and hmac.compare_digest(stored_hash, token_hash))

            if not token_valid:
                # Token already consumed or invalid
                is_already_enrolled = reg["enrollment_status"] == "enrolled"
                await _audit_log_enrollment(
                    conn,
                    tenant_id,
                    "external_agent.claim_rejected",
                    body.agent_id,
                    f"host:{body.host_id}",
                    body.host_id,
                    {
                        "reason": "token_already_consumed" if is_already_enrolled else "invalid_token",
                        "agent_id": body.agent_id,
                    },
                )
                if is_already_enrolled:
                    return _make_error_response(409, "conflict", "Enrollment token has already been consumed")
                return _make_error_response(401, "unauthenticated", "Invalid enrollment token")

            # 5. Check token expiration
            expires_at = reg["enrollment_token_expires_at"]
            if expires_at is not None and expires_at <= now:
                await _audit_log_enrollment(
                    conn,
                    tenant_id,
                    "external_agent.claim_rejected",
                    body.agent_id,
                    f"host:{body.host_id}",
                    body.host_id,
                    {"reason": "token_expired", "agent_id": body.agent_id},
                )
                return _make_error_response(401, "unauthenticated", "Enrollment token has expired")

            # Step 7: Server-minted SPIFFE ID
            claim_id = f"claim-{uuid.uuid4().hex[:12]}"
            agent_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{body.agent_id}")
            spiffe_id = _compute_spiffe_id(tenant_id, body.agent_id)

            # Step 8: SPIRE registration entry creation
            tenant_hash = tenant_id if re.match(r"^[0-9a-f]{8}$", tenant_id) else derive_customer_hash(tenant_id)
            spire_entry = generate_spire_registration_entry(tenant_hash, service_account=f"agent-{body.agent_id}")
            spire_entry["spiffe_id"] = spiffe_id
            spire_entry_id = f"spire-entry-{uuid.uuid4().hex[:12]}"
            spire_entry["entry_id"] = spire_entry_id

            with _HOST_ENROLL_LOCK:
                _SPIRE_REGISTRATION_ENTRIES[body.agent_id] = spire_entry
                _SPIRE_REGISTRATION_ENTRIES[spire_entry_id] = spire_entry

            # 6. Execute atomic compare-and-set UPDATE
            updated = await conn.fetchrow(
                """UPDATE public.external_agent_registrations
                      SET enrollment_status = 'enrolled',
                          enrolled_at = NOW(),
                          enrollment_token_hash = NULL,
                          enrollment_token_expires_at = NULL,
                          enrolled_key_id = $2,
                          enrolled_public_key = $3,
                          enrolled_client_nonce = $4,
                          enrolled_credential_reference = $5,
                          enrolled_credential_expires_at = $6,
                          token_consumed_at = NOW(),
                          updated_at = NOW()
                    WHERE agent_id = $1
                      AND enrollment_status = 'pending'
                      AND enrollment_token_hash = $7
                      AND (enrollment_token_expires_at IS NULL OR enrollment_token_expires_at > NOW())
                RETURNING id, agent_id, tenant_id, host_id, enrollment_status, enrolled_at""",
                body.agent_id,
                body.key_id,
                body.public_key,
                body.client_nonce,
                spiffe_id,
                cred_expires,
                token_hash,
            )

            if updated is None:
                # Concurrent race won by another contender
                return _make_error_response(409, "conflict", "Enrollment token was consumed by a concurrent request")

            # Update host_enrollment_tokens ledger
            await conn.execute(
                """UPDATE public.host_enrollment_tokens
                      SET status = 'consumed',
                          consumed_at = NOW(),
                          consumed_by_host_id = $1,
                          consumed_by_key_id = $2,
                          consumed_by_public_key = $3,
                          consumed_by_client_nonce = $4,
                          updated_at = NOW()
                    WHERE token_hash = $5""",
                body.host_id,
                body.key_id,
                body.public_key,
                body.client_nonce,
                token_hash,
            )

            # Ensure agent_registry and agent_claims are synchronized
            await conn.execute(
                """INSERT INTO public.agent_registry (
                    id, tenant_id, name, display_name, description, status, lifecycle_state,
                    origin, compliance_posture, model_provider, model_name,
                    last_transition_at, created_at, updated_at
                ) VALUES (
                    $1, $2, $3, $4, $5, 'active', 'active',
                    'External Linux Workload', 83, 'anthropic', 'claude-3-5-sonnet',
                    NOW(), NOW(), NOW()
                ) ON CONFLICT (tenant_id, name) DO UPDATE SET
                    lifecycle_state = 'active',
                    status = 'active',
                    compliance_posture = 83,
                    last_transition_at = NOW(),
                    updated_at = NOW()""",
                agent_uuid,
                tenant_id,
                body.agent_id,
                body.agent_id.replace("-", " ").title(),
                f"Enrolled external Linux agent on host {body.host_id}",
            )

            await conn.execute(
                """INSERT INTO public.agent_claims (
                    claim_id, tenant_id, agent_id, pod_name, namespace, spiffe_id,
                    harness, model, status, allocated_token_budget, claimed_at
                ) VALUES (
                    $1, $2, $3, $4, 'external-agents', $5, 'nono-0.73.0', 'claude-3-5-sonnet', 'granted', $6, NOW()
                ) ON CONFLICT (claim_id) DO NOTHING""",
                claim_id,
                tenant_id,
                agent_uuid,
                body.agent_id,
                spiffe_id,
                reg["allocated_token_budget"],
            )

            # Step 10: Audit log on register with server-minted SPIFFE ID
            await _audit_log_enrollment(
                conn,
                tenant_id,
                "external_agent.claimed",
                body.agent_id,
                f"host:{body.host_id}",
                body.host_id,
                {
                    "action": "enrolled",
                    "agent_id": body.agent_id,
                    "host_id": body.host_id,
                    "key_id": body.key_id,
                    "public_key": body.public_key,
                    "client_nonce": body.client_nonce,
                    "spiffe_id": spiffe_id,
                    "spire_entry_id": spire_entry_id,
                    "credential_kind": body.credential_kind,
                    "credential_scope": body.credential_scope,
                },
            )

            result = EnrollmentResult(
                schema_version="1.0.0",
                tenant_id=tenant_id,
                agent_id=body.agent_id,
                host_id=body.host_id,
                key_id=body.key_id,
                enrollment_state="enrolled",
                credential_kind=body.credential_kind,
                credential_scope=body.credential_scope,
                credential_bootstrap=body.credential_bootstrap,
                credential_reference=spiffe_id,
                credential_expires_at=cred_expires_str,  # type: ignore[arg-type]
                revocation_endpoint=f"/v1/external-agents/{body.agent_id}/revocations",
                svid_path="jwt-svid-fetch",
            )
            return JSONResponse(status_code=201, content=result.model_dump(mode="json"))

    # In-memory execution (fallback/tests)
    with _HOST_ENROLL_LOCK:
        # 1. Search in-memory registrations
        reg_item: dict[str, Any] | None = None
        found_tenant: str | None = None

        with external_agent_registration._REG_LOCK:
            for t_id, regs in external_agent_registration._EXTERNAL_REGISTRATIONS.items():
                if body.agent_id in regs:
                    found_tenant = t_id
                    reg_item = regs[body.agent_id]
                    break

        if reg_item is None:
            return _make_error_response(403, "forbidden", f"External agent '{body.agent_id}' is not pre-registered")

        tenant_id = found_tenant or "tenant-a"

        # 2. Check revocation
        if reg_item.get("enrollment_status") == "revoked":
            return _make_error_response(403, "forbidden", f"External agent '{body.agent_id}' has been revoked")

        # 3. Check host_id match
        if reg_item.get("host_id") != body.host_id:
            return _make_error_response(409, "conflict", f"Host ID mismatch: expected '{reg_item.get('host_id')}', got '{body.host_id}'")

        # Step 6: Refuse body naming a tenant other than the token's tenant with 403
        req_tenant = body.tenant_id or body_json.get("tenant_id")
        if req_tenant and req_tenant != tenant_id:
            await _audit_log_enrollment(
                None,
                tenant_id,
                "external_agent.cross_tenant_rejected",
                body.agent_id,
                f"host:{body.host_id}",
                body.host_id,
                {
                    "reason": "cross_tenant_mismatch",
                    "token_tenant": tenant_id,
                    "provided_tenant": req_tenant,
                    "agent_id": body.agent_id,
                },
            )
            return _make_error_response(403, "forbidden", f"Tenant mismatch: token is bound to '{tenant_id}', request specified '{req_tenant}'")

        # Step 6: Client nonce idempotency (return original result, no second SPIRE entry)
        if reg_item.get("enrollment_status") == "enrolled" and reg_item.get("enrolled_client_nonce") == body.client_nonce:
            spiffe_id = reg_item.get("enrolled_credential_reference") or _compute_spiffe_id(tenant_id, body.agent_id)
            result = EnrollmentResult(
                schema_version="1.0.0",
                tenant_id=tenant_id,
                agent_id=body.agent_id,
                host_id=body.host_id,
                key_id=body.key_id,
                enrollment_state="enrolled",
                credential_kind=body.credential_kind,
                credential_scope=body.credential_scope,
                credential_bootstrap=body.credential_bootstrap,
                credential_reference=spiffe_id,
                credential_expires_at=reg_item.get("enrolled_credential_expires_at") or cred_expires_str,
                revocation_endpoint=f"/v1/external-agents/{body.agent_id}/revocations",
                svid_path="jwt-svid-fetch",
            )
            return JSONResponse(status_code=201, content=result.model_dump(mode="json"))

        # 4. Check token match
        stored_hash = reg_item.get("enrollment_token_hash")
        token_valid = bool(stored_hash and hmac.compare_digest(stored_hash, token_hash))

        if not token_valid:
            is_already_enrolled = reg_item.get("enrollment_status") == "enrolled"
            if is_already_enrolled:
                return _make_error_response(409, "conflict", "Enrollment token has already been consumed")
            return _make_error_response(401, "unauthenticated", "Invalid enrollment token")

        # 5. Check token expiration
        exp_str = reg_item.get("enrollment_token_expires_at")
        if exp_str:
            try:
                # Handle ISO format
                exp_dt = datetime.fromisoformat(exp_str.replace("Z", "+00:00"))
                if exp_dt <= now:
                    return _make_error_response(401, "unauthenticated", "Enrollment token has expired")
            except Exception:
                pass

        # 6. Atomic compare-and-set transition
        if reg_item.get("enrollment_status") != "pending":
            return _make_error_response(409, "conflict", "Enrollment token was consumed by a concurrent request")

        # Step 7: Server-minted SPIFFE ID
        spiffe_id = _compute_spiffe_id(tenant_id, body.agent_id)

        # Step 8: SPIRE registration entry creation
        tenant_hash = tenant_id if re.match(r"^[0-9a-f]{8}$", tenant_id) else derive_customer_hash(tenant_id)
        spire_entry = generate_spire_registration_entry(tenant_hash, service_account=f"agent-{body.agent_id}")
        spire_entry["spiffe_id"] = spiffe_id
        spire_entry_id = f"spire-entry-{uuid.uuid4().hex[:12]}"
        spire_entry["entry_id"] = spire_entry_id

        _SPIRE_REGISTRATION_ENTRIES[body.agent_id] = spire_entry
        _SPIRE_REGISTRATION_ENTRIES[spire_entry_id] = spire_entry

        reg_item["enrollment_status"] = "enrolled"
        reg_item["enrolled_at"] = now_str
        reg_item["enrollment_token_hash"] = None
        reg_item["enrollment_token_expires_at"] = None
        reg_item["enrolled_key_id"] = body.key_id
        reg_item["enrolled_public_key"] = body.public_key
        reg_item["enrolled_client_nonce"] = body.client_nonce
        reg_item["enrolled_credential_reference"] = spiffe_id
        reg_item["enrolled_credential_expires_at"] = cred_expires_str
        reg_item["spire_entry_id"] = spire_entry_id
        reg_item["token_consumed_at"] = now_str
        reg_item["updated_at"] = now_str

        # Update _HOST_ENROLLMENT_TOKENS
        token_entry = _HOST_ENROLLMENT_TOKENS.get(token_hash)
        if token_entry:
            token_entry["status"] = "consumed"
            token_entry["consumed_at"] = now_str
            token_entry["consumed_by_host_id"] = body.host_id
            token_entry["consumed_by_key_id"] = body.key_id
            token_entry["consumed_by_public_key"] = body.public_key
            token_entry["consumed_by_client_nonce"] = body.client_nonce
            token_entry["updated_at"] = now_str

    # Step 10: In-memory audit with server-minted SPIFFE ID
    await _audit_log_enrollment(
        None,
        tenant_id,
        "external_agent.claimed",
        body.agent_id,
        f"host:{body.host_id}",
        body.host_id,
        {
            "action": "enrolled",
            "agent_id": body.agent_id,
            "host_id": body.host_id,
            "key_id": body.key_id,
            "public_key": body.public_key,
            "client_nonce": body.client_nonce,
            "spiffe_id": spiffe_id,
            "spire_entry_id": spire_entry_id,
            "credential_kind": body.credential_kind,
            "credential_scope": body.credential_scope,
        },
    )

    result = EnrollmentResult(
        schema_version="1.0.0",
        tenant_id=tenant_id,
        agent_id=body.agent_id,
        host_id=body.host_id,
        key_id=body.key_id,
        enrollment_state="enrolled",
        credential_kind=body.credential_kind,
        credential_scope=body.credential_scope,
        credential_bootstrap=body.credential_bootstrap,
        credential_reference=spiffe_id,
        credential_expires_at=cred_expires_str,  # type: ignore[arg-type]
        revocation_endpoint=f"/v1/external-agents/{body.agent_id}/revocations",
        svid_path="jwt-svid-fetch",
    )
    return JSONResponse(status_code=201, content=result.model_dump(mode="json"))


# Mount router endpoints
for r in (router, api_router, compat_router):
    r.add_api_route(
        "/enroll",
        enroll_host_handler,
        methods=["POST"],
        status_code=201,
        summary="Enroll external Linux host and exchange one-time token",
    )
    r.add_api_route(
        "/registrations/{agent_id}/token",
        issue_token_handler,
        methods=["POST"],
        response_model=TokenIssueResponse,
        summary="Issue or rotate host enrollment token",
    )
    r.add_api_route(
        "/{agent_id}/token",
        issue_token_handler,
        methods=["POST"],
        response_model=TokenIssueResponse,
        summary="Issue or rotate host enrollment token (alias)",
    )
    r.add_api_route(
        "/registrations/{agent_id}/revoke",
        revoke_agent_handler,
        methods=["POST"],
        summary="Revoke external agent registration and SPIRE entry",
    )
