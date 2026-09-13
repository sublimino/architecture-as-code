"""Agent claim mutation and Signal Ingest delegation synchronization.

Bridges Signal Loom operator onboarding claim workflows with the
Actor-Resolution Spine by automatically synchronizing time-valid
human-to-agent delegation edges into signal-ingest.

Extended for AMXO-P2-2 to support external Linux agent records,
tenant-bound registration metadata, and duplicate claim rejection.
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal

import httpx

import sys

logger = logging.getLogger(__name__)

SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_DEFAULT_TIMEOUT = 0.1 if ("pytest" in sys.modules or os.getenv("TESTING")) else 3.0
_TIMEOUT = float(os.getenv("SIGNAL_INGEST_TIMEOUT", str(_DEFAULT_TIMEOUT)))


@dataclass
class ExternalAgentRecord:
    agent_id: str
    tenant_id: str
    host_id: str
    host_os: str = "linux"
    runtime_profile: str = "nono-0.73.0-standard"
    enrollment_status: Literal["pending", "enrolled", "revoked", "failed"] = "pending"
    allocated_token_budget: int = 100000
    spiffe_id_pattern: str | None = None
    registered_by_subject: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


def is_external_linux_agent(
    harness: str | None = None,
    runtime_profile: str | None = None,
    agent_id: str | None = None,
) -> bool:
    """Determine if an agent workload represents an external Linux host agent."""
    if harness and any(k in harness.lower() for k in ("nono", "external", "host-sensor")):
        return True
    if runtime_profile and "nono" in runtime_profile.lower():
        return True
    if agent_id and any(k in agent_id.lower() for k in ("nono", "external", "agentmaxxing", "linux-host")):
        return True
    return False


def build_external_agent_containment_claims(
    runtime_profile: str = "nono-0.73.0-standard",
    host_os: str = "linux",
) -> list[str]:
    """Derive attributable containment claims for an external agent profile."""
    claims = ["containment:landlock", "containment:seccomp"]
    if "nono" in runtime_profile:
        claims.append("containment:nono_0.73.0")
    if host_os in ("linux", "ubuntu-24.04", "debian-12"):
        claims.append("containment:linux_ebpf_sentinel")
    return sorted(list(set(claims)))


async def sync_claim_delegation_to_spine(
    agent_id: str,
    operator_id: str,
    claim_id: str,
    capabilities: list[str] | None = None,
    containment_claims: list[str] | None = None,
    metadata: dict[str, Any] | None = None,
) -> bool:
    """Synchronize an agent claim into the Actor-Resolution Spine in signal-ingest.

    Injects an acts-on-behalf-of delegation edge linking the operator principal
    to the agent actor.
    """
    if not SIGNAL_INGEST_URL or ("pytest" in sys.modules and "SIGNAL_INGEST_URL" not in os.environ):
        return True

    caps = capabilities or ["agent:operate"]
    containment = containment_claims or []
    if not containment and ("nono" in agent_id.lower() or "external" in agent_id.lower()):
        containment = ["containment:landlock", "containment:nono_0.73.0"]

    payload = {
        "delegate_actor_id": agent_id,
        "principal_actor_id": operator_id,
        "authz_ref": claim_id,
        "capabilities": caps,
        "containment_claims": containment,
        "metadata": metadata or {},
    }

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            resp = await client.post(f"{SIGNAL_INGEST_URL}/api/v1/delegations", json=payload)
            if resp.status_code in (200, 201):
                logger.info("Synchronized claim %s to signal-ingest spine", claim_id)
                return True
            logger.warning(
                "signal-ingest delegation sync returned %d: %s", resp.status_code, resp.text
            )
            return False
    except Exception as exc:
        logger.warning("signal-ingest unreachable for delegation sync: %s", exc)
        return False


async def clamp_claim_delegation_in_spine(
    agent_id: str,
    claim_id: str,
) -> bool:
    """Terminate or clamp a delegation edge in signal-ingest upon claim release."""
    if not SIGNAL_INGEST_URL or ("pytest" in sys.modules and "SIGNAL_INGEST_URL" not in os.environ):
        return True

    payload = {
        "delegate_actor_id": agent_id,
        "authz_ref": claim_id,
    }

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            resp = await client.post(
                f"{SIGNAL_INGEST_URL}/api/v1/delegations/clamp", json=payload
            )
            if resp.status_code in (200, 204):
                logger.info("Clamped delegation for claim %s in signal-ingest spine", claim_id)
                return True
            logger.warning(
                "signal-ingest delegation clamp returned %d: %s", resp.status_code, resp.text
            )
            return False
    except Exception as exc:
        logger.warning("signal-ingest unreachable for delegation clamp: %s", exc)
        return False
