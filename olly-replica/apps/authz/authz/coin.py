"""COIN JWT Issuer (:8001). Runs the OAuth2 grant (H2M to M2M-enhanced), calls
the PlainID PDP synchronously, mints the enhanced token, and records the
decision to the Jarvis audit. The human ACME id is preserved as `username`
through this and every later hop, and a fresh authz_ctx_id anchors the chain.

Routes:
    POST /token                  mint an M2M-enhanced token (OBO supported)
    GET  /audit?authz_ctx_id=..  every audit record for one chain (single query)
    GET  /healthz
"""

import json
import urllib.request
import uuid
from datetime import datetime, timezone

from . import audit, config, httputil, jwtutil


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _pdp_evaluate(username: str, requested: list) -> dict:
    data = json.dumps({"username": username, "requested_actions": requested}).encode()
    req = urllib.request.Request(
        f"{config.url(config.PDP_PORT)}/evaluate",
        data=data, headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def _token(handler) -> None:
    body = httputil.read_json(handler)
    acme_id = body.get("acme_id", "")
    grant_type = body.get("grant_type", "client_credentials")
    # OBO: when a human delegates to the agent, on_behalf_of carries the human id
    # while the agent is the actor. Absent it, this is a plain M2M grant.
    on_behalf_of = body.get("on_behalf_of", "")
    agent = body.get("agent", "olly-sentinel")
    requested = body.get("requested_actions") or list(config.ACTIONS)

    subject = on_behalf_of or acme_id
    pdp = _pdp_evaluate(subject, requested)
    authz_ctx_id = "actx-" + uuid.uuid4().hex[:16]
    permitted = pdp.get("permitted_actions", [])

    claims = {
        "iss": "acme-coin",
        "sub": subject,               # the human internal id, preserved through every hop
        "username": subject,
        "actor": "agent" if on_behalf_of else "service",
        "on_behalf_of": on_behalf_of or None,
        "agent": agent,
        "token_type": "m2m_enhanced",
        "grant_type": grant_type,
        "policy_id": pdp.get("policy_id", ""),
        "permitted_actions": permitted,
        "authz_ctx_id": authz_ctx_id,
    }
    token = jwtutil.encode(claims, config.JWT_SECRET, config.JWT_TTL)
    audit.record(
        authz_ctx_id=authz_ctx_id, acme_id=subject, agent=agent, action="token_exchange",
        decision=pdp.get("decision", ""), policy_id=pdp.get("policy_id", ""),
        chain=[agent], reason=f"COIN mint OBO={bool(on_behalf_of)}", ts=_now(),
    )
    httputil.send_json(handler, 200, {
        "access_token": token,
        "token_type": "Bearer",
        "authz_ctx_id": authz_ctx_id,
        "username": subject,
        "permitted_actions": permitted,
        "decision": pdp.get("decision"),
    })


def _audit(handler) -> None:
    q = httputil.query(handler)
    ctx = q.get("authz_ctx_id", "")
    httputil.send_json(handler, 200, {"authz_ctx_id": ctx, "records": audit.read_for(ctx)})


def _healthz(handler) -> None:
    httputil.send_json(handler, 200, {"status": "alive", "service": "coin-issuer"})


def routes() -> dict:
    return {
        ("POST", "/token"): _token,
        ("GET", "/audit"): _audit,
        ("GET", "/healthz"): _healthz,
    }


def server():
    return httputil.build_server(config.COIN_PORT, routes())
