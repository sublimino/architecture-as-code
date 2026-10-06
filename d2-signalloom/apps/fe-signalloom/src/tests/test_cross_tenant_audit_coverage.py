"""Every GET route capable of a superadmin cross-tenant read is accounted for.

Mirrors test_audit_event_types.py's own rule for itself: "an extractor that
silently returns less than the truth turns this file into decoration". A
hand-maintained list of "the routes I audited" would have exactly that
failure mode -- it reads as coverage for as long as nobody adds a tenth
``is_superadmin``-gated GET route and forgets to update it. So the routes
are *discovered* by AST, from a fixed set of marker calls that only occur in
code reachable by a superadmin acting across every tenant (``is_superadmin``/
``require_superadmin``, the signal-ingest proxy's ``ingest_headers``/
``acting_tenant``, and ``_visible_pods``, cadvisor_poller's own one-hop
wrapper around ``is_superadmin``) -- then every discovered route must appear
in exactly one of cross_tenant_audit.py's two registries: ``AUDITED_ROUTES``
(and there must be a passing test exercising it -- see
test_cross_tenant_audit.py) or ``TENANT_AGNOSTIC_ROUTES`` (with a reason).

A route that is neither audited nor explicitly excused fails here, so a new
one cannot silently skip this.
"""
from __future__ import annotations

import ast
from pathlib import Path

import cross_tenant_audit

SRC_DIR = Path(__file__).resolve().parent.parent

#: Every module that can mount a GET route capable of a superadmin reading
#: across every tenant. Fixed, not discovered -- the same trade
#: test_audit_event_types.py makes for _source_modules vs. a general dataflow
#: engine: a short explicit list that is cheap to audit by eye, rather than a
#: second system (e.g. "every module importing superadmin or ingest_client")
#: that could itself go stale.
ROUTER_MODULES = {
    "signal_fusion.py": SRC_DIR / "signal_fusion.py",
    "signal_policy.py": SRC_DIR / "signal_policy.py",
    "risk.py": SRC_DIR / "risk.py",
    "federation.py": SRC_DIR / "routers" / "federation.py",
    "invites.py": SRC_DIR / "invites.py",
    "cadvisor_poller.py": SRC_DIR / "cadvisor_poller.py",
}

#: A call to any of these, anywhere in a GET route's own body, means the
#: route can act for a tenant other than the caller's own. ``_proxy`` and
#: ``proxy_federation_request`` cover every signal-ingest proxy (they are
#: themselves one hop from ``ingest_headers``/``acting_tenant``, pinned by
#: test_cross_tenant_audit_markers_still_indicate_cross_tenant_capability
#: below rather than re-resolved here); ``_visible_pods`` is
#: cadvisor_poller's own one-hop wrapper around ``is_superadmin``.
CROSS_TENANT_MARKERS = frozenset(
    {
        "is_superadmin",
        "require_superadmin",
        "ingest_headers",
        "acting_tenant",
        "_proxy",
        "proxy_federation_request",
        "_visible_pods",
    }
)


def _decorator_methods(decorator: ast.expr) -> set[str]:
    """The HTTP methods one ``@router.xxx(...)`` decorator registers for."""
    if not isinstance(decorator, ast.Call):
        return set()
    attr = decorator.func
    if not isinstance(attr, ast.Attribute):
        return set()
    if attr.attr in ("get", "post", "put", "delete", "patch"):
        return {attr.attr.upper()}
    if attr.attr == "api_route":
        for kw in decorator.keywords:
            if kw.arg == "methods" and isinstance(kw.value, ast.List):
                return {
                    elt.value for elt in kw.value.elts
                    if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
                }
    return set()


def _calls_a_marker(node: ast.AST) -> bool:
    """True if a marker name appears anywhere in the function -- as a call, or as a bare name.

    The bare-name case matters as much as the call: ``require_superadmin`` gates a route
    through ``Annotated[Principal, Depends(require_superadmin)]`` in the parameter list, where
    it is an *argument* to ``Depends(...)``, never itself the callee of a ``Call`` node. A
    Call-only check sees every ``_proxy(...)``/``is_superadmin(...)`` call but is blind to
    every dependency-injected gate, which is most of them (invites.list_invites was exactly
    this miss, caught by test_every_registry_entry_still_corresponds_to_a_discovered_route
    going red for the opposite reason -- a registry entry the discovery itself couldn't see).
    """
    for item in ast.walk(node):
        if isinstance(item, ast.Name) and item.id in CROSS_TENANT_MARKERS:
            return True
        if isinstance(item, ast.Attribute) and item.attr in CROSS_TENANT_MARKERS:
            return True
    return False


def discover_superadmin_capable_get_routes() -> dict[str, list[str]]:
    """``{"module.py:function_name": [...]}`` for every GET route whose body calls a marker.

    One entry per function, not per path: several of these are registered
    under more than one path alias (``/api/v1/...`` and ``/v1/...``, or a
    ``{subpath}`` catch-all) that all resolve to the same function, and a
    function audited once is audited on every alias.
    """
    found: dict[str, list[str]] = {}
    for module_name, path in ROUTER_MODULES.items():
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            methods: set[str] = set()
            for decorator in node.decorator_list:
                methods |= _decorator_methods(decorator)
            if "GET" not in methods:
                continue
            if not _calls_a_marker(node):
                continue
            found.setdefault(f"{module_name}:{node.name}", []).append(module_name)
    return found


def test_the_discovery_finds_more_than_a_handful() -> None:
    """Guards the guard: an extractor that finds nothing would pass vacuously."""
    discovered = discover_superadmin_capable_get_routes()
    assert len(discovered) >= 10, (
        f"only found {len(discovered)} superadmin-capable GET routes across "
        f"{sorted(ROUTER_MODULES)} -- the AST discovery is probably broken"
    )


def test_every_discovered_route_is_audited_or_explicitly_tenant_agnostic() -> None:
    """The regression guard this whole file exists for."""
    discovered = set(discover_superadmin_capable_get_routes())
    known = cross_tenant_audit.AUDITED_ROUTES | set(cross_tenant_audit.TENANT_AGNOSTIC_ROUTES)
    unaccounted = sorted(discovered - known)
    assert not unaccounted, (
        f"{len(unaccounted)} GET route(s) can act for a superadmin reading across every "
        f"tenant but are not listed in cross_tenant_audit.AUDITED_ROUTES or "
        f"TENANT_AGNOSTIC_ROUTES: {unaccounted}. Either wire in "
        "cross_tenant_audit.audit_cross_tenant_read and add the route to AUDITED_ROUTES "
        "(with a test in test_cross_tenant_audit.py), or add it to TENANT_AGNOSTIC_ROUTES "
        "with a reason the route's response carries no tenant attribution."
    )


def test_every_registry_entry_still_corresponds_to_a_discovered_route() -> None:
    """The exemption-staleness guard, on test_audit_event_types.py's
    test_the_actor_exemptions_are_all_still_needed pattern: a registry entry for a route that
    no longer exists, or no longer calls a marker, is dead weight that would hide a rename or a
    removal rather than surfacing it.
    """
    discovered = set(discover_superadmin_capable_get_routes())
    known = cross_tenant_audit.AUDITED_ROUTES | set(cross_tenant_audit.TENANT_AGNOSTIC_ROUTES)
    stale = sorted(known - discovered)
    assert not stale, (
        f"{len(stale)} registry entr{'y is' if len(stale) == 1 else 'ies are'} stale -- no "
        f"longer a discovered superadmin-capable GET route: {stale}. Remove them."
    )


def test_the_two_registries_do_not_overlap() -> None:
    overlap = sorted(cross_tenant_audit.AUDITED_ROUTES & set(cross_tenant_audit.TENANT_AGNOSTIC_ROUTES))
    assert not overlap, (
        f"{len(overlap)} route(s) listed in both registries, which is a contradiction -- a "
        f"route is either audited or explicitly excused, never both: {overlap}"
    )


def test_every_tenant_agnostic_reason_is_non_trivial() -> None:
    """A reason that is empty or a placeholder is the same failure as no reason at all."""
    short = sorted(
        route for route, reason in cross_tenant_audit.TENANT_AGNOSTIC_ROUTES.items()
        if len(reason.strip()) < 20
    )
    assert not short, f"suspiciously short (or empty) reason for: {short}"
