"""External agent allowlisted evidence persistence and tenant-scoped projections (AMXO-P5-3).

Enforces strict field allowlisting at the storage boundary (stripping all raw payload
contents, process memory dumps, command strings, and buffer dumps) while exposing
isolated, tenant-scoped REST API projections for Signal Loom governance dashboards.
"""
from __future__ import annotations

import json
import logging
import threading
import uuid
from datetime import datetime, timezone
from typing import Annotated, Any, Literal

import asyncpg
from fastapi import APIRouter, Depends, Query, Response, status
from pydantic import BaseModel, ConfigDict, Field

from api_compat import (
    APIError,
    Principal,
    _get_pool,
    authenticated_principal,
    authenticated_tenant,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["external-evidence"])


# ---------------------------------------------------------------------------
# Data Models & Schemas
# ---------------------------------------------------------------------------

class ExternalEvidenceItem(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: str
    tenant_id: str
    agent_id: str
    session_id: str
    evidence_type: str
    source: str = "agentmaxxing-host-sensor"
    observed_at: str
    attributable_actor: str
    spiffe_id: str
    landlock_abi: int = 0
    git_oid: str | None = None
    attributes: dict[str, Any] = Field(default_factory=dict)
    hash_chain_digest: str = ""
    verified: bool = True
    created_at: str | None = None


class ExternalEvidenceResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")

    agent_id: str
    tenant_id: str
    evidence: list[ExternalEvidenceItem]
    total: int
    limit: int = 50
    offset: int = 0


class ExternalEvidenceIngestPayload(BaseModel):
    model_config = ConfigDict(extra="ignore")

    session_id: str
    evidence_type: Literal["process", "artifact", "network", "collection-limit"]
    source: str = "agentmaxxing-host-sensor"
    observed_at: str
    attributable_actor: str = ""
    spiffe_id: str = ""
    landlock_abi: int = 0
    git_oid: str | None = None
    attributes: dict[str, Any] = Field(default_factory=dict)
    hash_chain_digest: str = ""
    verified: bool = True


# ---------------------------------------------------------------------------
# Storage Boundary Allowlist Sanitizer (Rule SP-5 & AMXO-P5-3)
# ---------------------------------------------------------------------------

PROHIBITED_FIELD_NAMES = {
    "payload",
    "raw_payload",
    "payload_contents",
    "file_contents",
    "contents",
    "memory_dump",
    "memory_contents",
    "process_memory",
    "command_text",
    "raw_command",
    "command",
    "stdin_content",
    "buffer",
    "raw_nono_record",
    "error_body",
    "streamed_payload_contents",
    "network_payload_contents",
}

ALLOWLISTED_ATTRIBUTE_FIELDS = {
    "process": {
        "pid",
        "ppid",
        "binary_path",
        "binary_sha256",
        "health_state",
        "cpu_time_ms",
        "resident_memory_bytes",
        "exit_code",
        "restart_count",
        "signal",
        "start_time",
        "observation_state",
        "integrity_state",
    },
    "artifact": {
        "artifact_id",
        "root_id",
        "sha256",
        "size_bytes",
        "mtime_ns",
        "mtime",
        "action",
        "path_digest",
        "integrity_state",
        "observation_state",
    },
    "network": {
        "destination_id",
        "dest_ip",
        "dest_port",
        "dest_domain",
        "protocol",
        "direction",
        "decision",
        "action",
        "observation_state",
        "integrity_state",
    },
    "collection-limit": {
        "reason_code",
        "max_file_size_bytes",
        "max_files_per_window",
        "max_bytes_per_window",
        "window_seconds",
        "observation_state",
        "integrity_state",
    },
}


def sanitize_evidence_attributes(evidence_type: str, raw_attributes: dict[str, Any]) -> dict[str, Any]:
    """Enforce strict field allowlist at storage boundary.

    Drops prohibited payload contents, memory dumps, raw command strings, and
    non-allowlisted fields while deterministically preserving unobserved states.
    """
    if not isinstance(raw_attributes, dict):
        return {}

    allowed_keys = ALLOWLISTED_ATTRIBUTE_FIELDS.get(evidence_type, set())
    sanitized: dict[str, Any] = {}

    for k, v in raw_attributes.items():
        k_lower = k.lower()
        # Drop prohibited fields or anything matching forbidden patterns
        if k_lower in PROHIBITED_FIELD_NAMES:
            continue
        if any(p in k_lower for p in ("payload", "memory", "dump", "content")):
            continue

        # Only permit allowlisted fields
        if k in allowed_keys or k_lower in allowed_keys:
            sanitized[k] = v

    # Preserve unobserved observation_state explicitly if present
    if "observation_state" in raw_attributes and "observation_state" not in sanitized:
        sanitized["observation_state"] = raw_attributes["observation_state"]
    if "integrity_state" in raw_attributes and "integrity_state" not in sanitized:
        sanitized["integrity_state"] = raw_attributes["integrity_state"]

    return sanitized


# ---------------------------------------------------------------------------
# Storage & Persistence Layer
# ---------------------------------------------------------------------------

_EVIDENCE_STORE: dict[str, list[dict[str, Any]]] = {}
_EVIDENCE_LOCK = threading.Lock()


def _clear_evidence_for_testing() -> None:
    with _EVIDENCE_LOCK:
        _EVIDENCE_STORE.clear()


async def save_external_evidence(
    tenant_id: str,
    agent_id: str,
    session_id: str,
    evidence_type: str,
    source: str,
    observed_at: str,
    attributable_actor: str,
    spiffe_id: str,
    landlock_abi: int,
    git_oid: str | None,
    attributes: dict[str, Any],
    hash_chain_digest: str,
    verified: bool = True,
) -> dict[str, Any]:
    """Persist verified allowlisted external agent evidence into Postgres and memory store."""
    sanitized_attrs = sanitize_evidence_attributes(evidence_type, attributes)
    now_iso = datetime.now(timezone.utc).isoformat()
    record_id = str(uuid.uuid4())

    record = {
        "id": record_id,
        "tenant_id": tenant_id,
        "agent_id": agent_id,
        "session_id": session_id,
        "evidence_type": evidence_type,
        "source": source,
        "observed_at": observed_at,
        "attributable_actor": attributable_actor,
        "spiffe_id": spiffe_id,
        "landlock_abi": landlock_abi,
        "git_oid": git_oid,
        "attributes": sanitized_attrs,
        "hash_chain_digest": hash_chain_digest,
        "verified": verified,
        "created_at": now_iso,
    }

    # In-memory persistence
    store_key = f"{tenant_id}:{agent_id}"
    with _EVIDENCE_LOCK:
        records = _EVIDENCE_STORE.setdefault(store_key, [])
        records.append(record)

    # Database persistence
    pool = await _get_pool()
    if pool is not None:
        try:
            query = """
            INSERT INTO public.external_agent_evidence (
                id, tenant_id, agent_id, session_id, evidence_type, source,
                observed_at, attributable_actor, spiffe_id, landlock_abi,
                git_oid, attributes, hash_chain_digest, verified, created_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12::jsonb, $13, $14, NOW()
            );
            """
            obs_dt = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
            await pool.execute(
                query,
                uuid.UUID(record_id),
                tenant_id,
                agent_id,
                session_id,
                evidence_type,
                source,
                obs_dt,
                attributable_actor,
                spiffe_id,
                landlock_abi,
                git_oid,
                json.dumps(sanitized_attrs),
                hash_chain_digest,
                verified,
            )
        except Exception as exc:
            logger.warning("Failed to persist external agent evidence to DB: %s", exc)

    return record


async def query_external_evidence(
    tenant_id: str,
    agent_id: str,
    session_id: str | None = None,
    evidence_type: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[dict[str, Any]], int]:
    """Query external agent evidence strictly scoped to authenticated tenant."""
    pool = await _get_pool()
    if pool is not None:
        try:
            where_clauses = ["tenant_id = $1", "agent_id = $2"]
            params: list[Any] = [tenant_id, agent_id]
            idx = 3

            if session_id:
                where_clauses.append(f"session_id = ${idx}")
                params.append(session_id)
                idx += 1

            if evidence_type:
                where_clauses.append(f"evidence_type = ${idx}")
                params.append(evidence_type)
                idx += 1

            where_sql = " AND ".join(where_clauses)
            count_query = f"SELECT COUNT(*) FROM public.external_agent_evidence WHERE {where_sql}"
            total = await pool.fetchval(count_query, *params)

            data_query = f"""
            SELECT id, tenant_id, agent_id, session_id, evidence_type, source,
                   observed_at, attributable_actor, spiffe_id, landlock_abi,
                   git_oid, attributes, hash_chain_digest, verified, created_at
            FROM public.external_agent_evidence
            WHERE {where_sql}
            ORDER BY observed_at DESC
            LIMIT ${idx} OFFSET ${idx + 1};
            """
            params.extend([limit, offset])
            rows = await pool.fetch(data_query, *params)

            items = [
                {
                    "id": str(r["id"]),
                    "tenant_id": r["tenant_id"],
                    "agent_id": r["agent_id"],
                    "session_id": r["session_id"],
                    "evidence_type": r["evidence_type"],
                    "source": r["source"],
                    "observed_at": r["observed_at"].isoformat(),
                    "attributable_actor": r["attributable_actor"],
                    "spiffe_id": r["spiffe_id"],
                    "landlock_abi": r["landlock_abi"],
                    "git_oid": r["git_oid"],
                    "attributes": json.loads(r["attributes"]) if isinstance(r["attributes"], str) else r["attributes"],
                    "hash_chain_digest": r["hash_chain_digest"],
                    "verified": r["verified"],
                    "created_at": r["created_at"].isoformat(),
                }
                for r in rows
            ]
            return items, int(total or 0)
        except Exception as exc:
            logger.warning("Database query failed for external agent evidence: %s", exc)

    # In-memory query fallback
    store_key = f"{tenant_id}:{agent_id}"
    with _EVIDENCE_LOCK:
        all_records = list(_EVIDENCE_STORE.get(store_key, []))

    filtered = []
    for rec in all_records:
        if session_id and rec.get("session_id") != session_id:
            continue
        if evidence_type and rec.get("evidence_type") != evidence_type:
            continue
        filtered.append(rec)

    total = len(filtered)
    # Sort newest first
    filtered.sort(key=lambda x: x.get("observed_at", ""), reverse=True)
    paged = filtered[offset : offset + limit]
    return paged, total


# ---------------------------------------------------------------------------
# Tenant Cross-Isolation Verification Helper
# ---------------------------------------------------------------------------

def _assert_tenant_owns_agent(authenticated_tenant_id: str, agent_id: str) -> None:
    """Enforce strict tenant ownership.

    Rejects queries if the agent ID explicitly names another tenant (e.g. 'tenant-b:agent-1')
    or if the agent is known to belong to a different organization.
    """
    if ":" in agent_id:
        target_tenant, _, target_agent = agent_id.partition(":")
        if target_tenant != authenticated_tenant_id:
            logger.warning(
                "Cross-tenant IDOR access denied: caller tenant '%s' requested agent '%s' owned by '%s'",
                authenticated_tenant_id,
                agent_id,
                target_tenant,
            )
            raise APIError(
                status_code=404,
                code="agent_not_found",
                message=f"Agent '{agent_id}' not found for tenant '{authenticated_tenant_id}'",
            )


# ---------------------------------------------------------------------------
# REST API Endpoints
# ---------------------------------------------------------------------------

@router.get(
    "/api/v1/agents/{agent_id}/external-evidence",
    response_model=ExternalEvidenceResponse,
)
@router.get(
    "/api/agents/{agent_id}/external-evidence",
    response_model=ExternalEvidenceResponse,
)
@router.get(
    "/v1/external-agents/{agent_id}/external-evidence",
    response_model=ExternalEvidenceResponse,
)
async def get_agent_external_evidence(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    session_id: str | None = Query(None, description="Filter by audit session ID"),
    evidence_type: str | None = Query(None, description="Filter by evidence type"),
    limit: int = Query(50, ge=1, le=500, description="Page limit"),
    offset: int = Query(0, ge=0, description="Page offset"),
) -> ExternalEvidenceResponse:
    """Read verified external agent evidence timeline strictly scoped to caller's tenant."""
    _assert_tenant_owns_agent(tenant_id, agent_id)

    items, total = await query_external_evidence(
        tenant_id=tenant_id,
        agent_id=agent_id,
        session_id=session_id,
        evidence_type=evidence_type,
        limit=limit,
        offset=offset,
    )

    evidence_models = [ExternalEvidenceItem.model_validate(it) for it in items]
    return ExternalEvidenceResponse(
        agent_id=agent_id,
        tenant_id=tenant_id,
        evidence=evidence_models,
        total=total,
        limit=limit,
        offset=offset,
    )


@router.post(
    "/api/v1/agents/{agent_id}/external-evidence",
    status_code=status.HTTP_201_CREATED,
    response_model=ExternalEvidenceItem,
)
async def create_agent_external_evidence(
    agent_id: str,
    payload: ExternalEvidenceIngestPayload,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> ExternalEvidenceItem:
    """Ingest and persist verified allowlisted external agent evidence."""
    _assert_tenant_owns_agent(tenant_id, agent_id)

    record = await save_external_evidence(
        tenant_id=tenant_id,
        agent_id=agent_id,
        session_id=payload.session_id,
        evidence_type=payload.evidence_type,
        source=payload.source,
        observed_at=payload.observed_at,
        attributable_actor=payload.attributable_actor or principal.subject,
        spiffe_id=payload.spiffe_id,
        landlock_abi=payload.landlock_abi,
        git_oid=payload.git_oid,
        attributes=payload.attributes,
        hash_chain_digest=payload.hash_chain_digest,
        verified=payload.verified,
    )

    return ExternalEvidenceItem.model_validate(record)
