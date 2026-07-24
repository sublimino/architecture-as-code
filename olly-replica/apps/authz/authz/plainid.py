"""PlainID PDP (:8002). Evaluated synchronously at token issuance. For each
requested action it calls the EEMS PIP for attributes, applies a Rego-style
policy, and derives permitted_actions with limits. The real PDP runs Rego; this
stand-in encodes the same rule: permit an action only when EEMS reports access
and a positive limit."""

import json
import urllib.request

from . import config, httputil


def _eems(username: str, action: str) -> dict:
    url = f"{config.url(config.EEMS_PORT)}/attributes?username={username}&action={action}"
    with urllib.request.urlopen(url, timeout=5) as resp:
        return json.loads(resp.read())


def _evaluate(handler) -> None:
    body = httputil.read_json(handler)
    username = body.get("username", "")
    requested = body.get("requested_actions") or list(config.ACTIONS)

    permitted, considered = [], []
    for action in requested:
        attr = _eems(username, action)
        has = bool(attr.get(f"has_{action}_access", False))
        limit = int(attr.get(f"max_{action}_limit", 0))
        considered.append({"action": action, "has_access": has, "limit": limit})
        # Rego-style rule: permit when EEMS grants access and the limit is positive.
        if has and limit > 0:
            permitted.append({"action": action, "limit": limit})

    httputil.send_json(handler, 200, {
        "username": username,
        "policy_id": "acme.arc.agent_action.v1",
        "permitted_actions": permitted,
        "considered": considered,
        "decision": "PERMIT" if permitted else "DENY",
    })


def _healthz(handler) -> None:
    httputil.send_json(handler, 200, {"status": "alive", "service": "plainid-pdp"})


def routes() -> dict:
    return {("POST", "/evaluate"): _evaluate, ("GET", "/healthz"): _healthz}


def server():
    return httputil.build_server(config.PDP_PORT, routes())
