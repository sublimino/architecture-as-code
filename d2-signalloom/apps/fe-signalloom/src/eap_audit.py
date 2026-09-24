# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/eap_audit.py
# Signal Loom EAP Audit Decision Helper
#
# Provides durable audit decision logging for mutating EAP routes, recording
# events on the active database connection.
# ==============================================================================
from __future__ import annotations

import json
import logging
import uuid
from typing import Any, Optional

import api_compat

logger = logging.getLogger("signalloom.eap_audit")


async def _audit_eap_decision(
    conn: Any,
    principal: Any,
    action: str,
    target: str,
    verdict: str,
    detail: dict[str, Any],
) -> None:
    """Record an audit decision for an EAP route on the caller's connection.

    Matches the durable write shape from host_enrollment._audit_log_enrollment and api_compat._audit_log.
    """
    tenant_id = ""
    actor_str = "system:eap-router"
    actor_subject = "eap-operator"
    actor_issuer = getattr(api_compat.settings, "api_jwt_issuer", "https://auth.signalloom.demo")

    if principal is not None:
        if isinstance(principal, str):
            actor_str = principal
            actor_subject = principal
        else:
            tenant_id = getattr(principal, "tenant_id", "") or getattr(principal, "tenant", "") or ""
            actor_str = getattr(principal, "actor_id", "") or getattr(principal, "user_id", "") or str(principal)
            actor_subject = getattr(principal, "sub", "") or actor_str
            actor_issuer = getattr(principal, "iss", "") or actor_issuer

    if not tenant_id and "tenant_id" in detail:
        tenant_id = str(detail["tenant_id"])
    elif not tenant_id and target and target != "all":
        tenant_id = str(target)

    event_type = f"eap.{action}" if not action.startswith("eap.") else action
    agent_id = target
    clean_detail = dict(detail)
    clean_detail["action"] = action
    clean_detail["target"] = target
    clean_detail["verdict"] = verdict

    agent_uuid = (
        uuid.uuid5(uuid.NAMESPACE_DNS, f"{tenant_id}:{agent_id}")
        if tenant_id and agent_id
        else uuid.uuid4()
    )

    if conn is not None and hasattr(conn, "execute"):
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
                actor_issuer,
                actor_subject,
                json.dumps(clean_detail, default=str),
            )
            return
        except Exception as exc:
            logger.warning("DB audit log failed for EAP decision: %s", exc)
