"""Signal Loom External Webhook Ingestion & Trigger Engine.

Provides HMAC-SHA256 cryptographic signature verification, replay attack
defense, GitHub and generic webhook event parsing, and event-driven dispatching
into the on-demand EAP environment routing engine.
"""
from __future__ import annotations

import hmac
import hashlib
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from fastapi import APIRouter, FastAPI, Header, HTTPException, Request, Response, status
from pydantic import BaseModel, Field

from environment_routing import (
    GLOBAL_ENVIRONMENT_REGISTRY,
    EnvironmentResponse,
    EnvironmentState,
    EnvironmentTier,
    ProvisionRequest,
    build_environment_urls,
    derive_customer_hash,
    normalize_company_name,
)

logger = logging.getLogger(__name__)

DEFAULT_WEBHOOK_SECRET = "signalloom-webhook-secret-2026-q3"
MAX_TIMESTAMP_DRIFT_SECONDS = 300  # 5 minutes


def get_webhook_secret(tenant_key: Optional[str] = None) -> str:
    """Retrieve tenant-specific or global webhook secret from environment."""
    if tenant_key:
        env_key = f"SIGNAL_LOOM_WEBHOOK_SECRET_{tenant_key.upper().replace('-', '_')}"
        val = os.getenv(env_key)
        if val:
            return val
    return os.getenv("SIGNAL_LOOM_WEBHOOK_SECRET", DEFAULT_WEBHOOK_SECRET)


def verify_github_signature(payload_bytes: bytes, secret: str, signature_header: Optional[str]) -> bool:
    """Verify GitHub X-Hub-Signature-256 header using constant-time comparison."""
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    received_hash = signature_header[len("sha256=") :].strip().lower()
    expected_hash = hmac.new(secret.encode("utf-8"), payload_bytes, hashlib.sha256).hexdigest()
    return hmac.compare_digest(received_hash, expected_hash)


def verify_generic_signature(
    payload_bytes: bytes,
    secret: str,
    signature_header: Optional[str],
    timestamp_header: Optional[str],
    max_drift: int = MAX_TIMESTAMP_DRIFT_SECONDS,
) -> bool:
    """Verify generic webhook signature with replay protection."""
    if not signature_header or not timestamp_header:
        return False
    try:
        ts = int(timestamp_header)
    except ValueError:
        return False

    current_ts = int(time.time())
    if abs(current_ts - ts) > max_drift:
        logger.warning("Webhook rejected: timestamp drift too large (drift=%d, max=%d)", abs(current_ts - ts), max_drift)
        return False

    to_sign = f"{timestamp_header}.".encode("utf-8") + payload_bytes
    expected_sig = hmac.new(secret.encode("utf-8"), to_sign, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature_header.strip().lower(), expected_sig)


# ── Webhook Models ─────────────────────────────────────────────────────────


class WebhookTriggerResponse(BaseModel):
    status: str
    action_taken: str
    company_name: str
    customer_hash: str
    hostname: str
    internal_mesh_url: str
    external_fqdn: str
    environment_id: Optional[str] = None
    state: Optional[str] = None
    detail: Optional[str] = None


# ── Webhook Router ─────────────────────────────────────────────────────────


router = APIRouter(prefix="/api/v1/webhooks", tags=["webhooks"])


@router.post(
    "/github",
    response_model=WebhookTriggerResponse,
    status_code=status.HTTP_200_OK,
    summary="GitHub Webhook Receiver for PR lifecycle preview environments",
)
async def github_webhook_receiver(
    request: Request,
    x_hub_signature_256: Optional[str] = Header(None, alias="X-Hub-Signature-256"),
    x_github_event: Optional[str] = Header(None, alias="X-GitHub-Event"),
    x_github_delivery: Optional[str] = Header(None, alias="X-GitHub-Delivery"),
) -> WebhookTriggerResponse:
    """Handle incoming GitHub PR webhook events to spin up, extend, or teardown preview environments."""
    raw_body = await request.body()
    secret = get_webhook_secret()

    if not verify_github_signature(raw_body, secret, x_hub_signature_256):
        logger.warning("Rejected GitHub webhook: signature verification failed")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing X-Hub-Signature-256.",
        )

    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Malformed JSON payload.") from exc

    # Determine company/tenant from repository name or organization
    repo_name = payload.get("repository", {}).get("name", "kurasi")
    # For kurasi demo, default to kurasi if repo matches
    company = "kurasi" if "kurasi" in repo_name.lower() else repo_name.split("-")[0]
    normalized_company = normalize_company_name(company)
    c_hash = derive_customer_hash(normalized_company)
    urls = build_environment_urls(c_hash)

    pr_action = payload.get("action", "")
    action_taken = "ignored"
    env_id: Optional[str] = None
    env_state: Optional[str] = None
    detail_msg = f"Processed GitHub event '{x_github_event}' (action: {pr_action})"

    if x_github_event == "pull_request":
        pr_number = payload.get("number")
        is_closed = pr_action == "closed"
        is_opened = pr_action in ("opened", "reopened")
        is_sync = pr_action == "synchronize"

        if is_opened:
            # Provision or find existing
            try:
                rec = GLOBAL_ENVIRONMENT_REGISTRY.create(
                    ProvisionRequest(
                        company_name=normalized_company,
                        tier=EnvironmentTier.DEMO,
                        ttl_minutes=120,
                        metadata={"github_pr": pr_number, "delivery": x_github_delivery},
                    )
                )
                action_taken = "provisioned"
                env_id = rec.id
                env_state = rec.state.value
            except HTTPException as e:
                if e.status_code == 409:
                    rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)
                    action_taken = "already_active"
                    env_id = rec.id if rec else None
                    env_state = rec.state.value if rec else None
                else:
                    raise

        elif is_sync:
            rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)
            if rec and rec.state != EnvironmentState.TERMINATED:
                extended = GLOBAL_ENVIRONMENT_REGISTRY.extend_ttl(rec.id, additional_minutes=60)
                action_taken = "extended_ttl"
                env_id = extended.id
                env_state = extended.state.value
            else:
                action_taken = "no_active_environment_to_extend"

        elif is_closed:
            rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)
            if rec and rec.state != EnvironmentState.TERMINATED:
                torn = GLOBAL_ENVIRONMENT_REGISTRY.teardown(rec.id, reason=f"PR #{pr_number} closed")
                action_taken = "torn_down"
                env_id = torn.id
                env_state = torn.state.value
            else:
                action_taken = "already_terminated"

    return WebhookTriggerResponse(
        status="ok",
        action_taken=action_taken,
        company_name=normalized_company,
        customer_hash=c_hash,
        hostname=urls["hostname"],
        internal_mesh_url=urls["internal_mesh_url"],
        external_fqdn=urls["external_fqdn"],
        environment_id=env_id,
        state=env_state,
        detail=detail_msg,
    )


@router.post(
    "/generic",
    response_model=WebhookTriggerResponse,
    status_code=status.HTTP_200_OK,
    summary="Generic Webhook Receiver with HMAC-SHA256 & timestamp replay protection",
)
async def generic_webhook_receiver(
    request: Request,
    x_signalloom_signature: Optional[str] = Header(None, alias="X-SignalLoom-Signature"),
    x_signalloom_timestamp: Optional[str] = Header(None, alias="X-SignalLoom-Timestamp"),
) -> WebhookTriggerResponse:
    """Handle generic external CI/CD webhook requests with timestamped HMAC verification."""
    raw_body = await request.body()
    secret = get_webhook_secret()

    if not verify_generic_signature(raw_body, secret, x_signalloom_signature, x_signalloom_timestamp):
        logger.warning("Rejected generic webhook: signature verification or timestamp validation failed")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired X-SignalLoom-Signature / X-SignalLoom-Timestamp.",
        )

    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Malformed JSON payload.") from exc

    company = payload.get("company_name", "kurasi")
    action = payload.get("action", "provision")
    ttl = int(payload.get("ttl_minutes", 120))

    normalized_company = normalize_company_name(company)
    c_hash = derive_customer_hash(normalized_company)
    urls = build_environment_urls(c_hash)

    action_taken = "ignored"
    env_id: Optional[str] = None
    env_state: Optional[str] = None

    if action == "provision":
        try:
            rec = GLOBAL_ENVIRONMENT_REGISTRY.create(
                ProvisionRequest(
                    company_name=normalized_company,
                    tier=EnvironmentTier.DEMO,
                    ttl_minutes=ttl,
                )
            )
            action_taken = "provisioned"
            env_id = rec.id
            env_state = rec.state.value
        except HTTPException as e:
            if e.status_code == 409:
                rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)
                action_taken = "already_active"
                env_id = rec.id if rec else None
                env_state = rec.state.value if rec else None
            else:
                raise
    elif action == "teardown":
        rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)
        if rec and rec.state != EnvironmentState.TERMINATED:
            torn = GLOBAL_ENVIRONMENT_REGISTRY.teardown(rec.id, reason="Generic webhook teardown trigger")
            action_taken = "torn_down"
            env_id = torn.id
            env_state = torn.state.value
        else:
            action_taken = "already_terminated"

    return WebhookTriggerResponse(
        status="ok",
        action_taken=action_taken,
        company_name=normalized_company,
        customer_hash=c_hash,
        hostname=urls["hostname"],
        internal_mesh_url=urls["internal_mesh_url"],
        external_fqdn=urls["external_fqdn"],
        environment_id=env_id,
        state=env_state,
        detail=f"Executed action '{action}' for customer '{normalized_company}'",
    )


def install_webhook_triggers_api(app: FastAPI) -> None:
    """Mount webhook triggers router on the FastAPI application."""
    app.include_router(router)
    logger.info("Installed Signal Loom external webhook trigger API at /api/v1/webhooks")
