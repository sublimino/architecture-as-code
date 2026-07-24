"""permitted_actions helpers. An action carries a limit; the A2A hop intersects
the inbound context with the receiving agent's local grant and can only narrow:
drop an action or lower a limit, never add either."""


def to_map(permitted_actions: list) -> dict:
    return {p["action"]: int(p.get("limit", 0)) for p in permitted_actions if p.get("action")}


def to_list(mapping: dict) -> list:
    return [{"action": a, "limit": mapping[a]} for a in sorted(mapping)]


def intersect(inbound: list, local_grants: dict) -> list:
    """Narrow-only intersection: keep actions present in both, take the lower
    limit. This is the property that makes an A2A chain safe: no hop can widen
    what an earlier hop was granted."""
    ctx = to_map(inbound)
    out = {}
    for action, limit in ctx.items():
        if action in local_grants:
            out[action] = min(limit, int(local_grants[action]))
    return to_list(out)


def allows(permitted_actions: list, action: str) -> bool:
    mapping = to_map(permitted_actions)
    return action in mapping and mapping[action] > 0
