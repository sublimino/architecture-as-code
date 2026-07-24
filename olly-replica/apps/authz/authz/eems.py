"""EEMS PIP REST (:8003). The Policy Information Point the PDP calls for
entitlement attributes. Returns has_<action>_access, max_<action>_limit,
gp_numbers, and approved_domains for a (username, action)."""

from . import config, httputil


def _attributes(handler) -> None:
    q = httputil.query(handler)
    username = q.get("username", "")
    action = q.get("action", "")
    ent = config.ENTITLEMENTS.get(username, {})
    limit = int(ent.get("grants", {}).get(action, 0))
    httputil.send_json(handler, 200, {
        "username": username,
        "action": action,
        f"has_{action}_access": limit > 0,
        f"max_{action}_limit": limit,
        "gp_numbers": ent.get("gp_numbers", []),
        "approved_domains": ent.get("approved_domains", []),
    })


def _healthz(handler) -> None:
    httputil.send_json(handler, 200, {"status": "alive", "service": "eems-pip"})


def routes() -> dict:
    return {("GET", "/attributes"): _attributes, ("GET", "/healthz"): _healthz}


def server():
    return httputil.build_server(config.EEMS_PORT, routes())
