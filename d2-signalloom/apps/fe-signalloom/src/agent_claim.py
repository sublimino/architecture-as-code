"""Agent claim mutation and Signal Ingest delegation synchronization.

Bridges Signal Loom operator onboarding claim workflows with the
Actor-Resolution Spine by automatically synchronizing time-valid
human-to-agent delegation edges into signal-ingest.
"""
from __future__ import annotations

import logging
import os
from typing import Any

import httpx

logger = logging.getLogger(__name__)

SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 3.0


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
    caps = capabilities or ["agent:operate"]
    containment = containment_claims or []
    if not containment and "nono" in agent_id.lower():
        containment = ["containment:landlock"]

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
