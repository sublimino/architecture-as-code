# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/cross_tenant_audit.py
# Signal Loom — audit a superadmin's cross-tenant reads
#
# Some fe-signalloom routes proxy signal-ingest as the gateway
# (``ingest_client.ingest_headers``), and some read fe-signalloom's own stores
# directly. Either way, a superadmin can see data belonging to a tenant other
# than its own: ``ingest_client.acting_tenant`` names a GET "*" for a
# superadmin, and a handful of ``require_superadmin``/``is_superadmin`` gated
# routes query across every tenant by construction (``invites.list_invites``,
# ``cadvisor_poller``'s telemetry routes with ``visible is None``).
#
# Andy's decision (2026-10-06): superadmin keeps its cross-tenant view for the
# pilot, but every cross-tenant read must write an audit event naming the
# tenant(s) whose data was read. This module is the one place that decides
# whether a given response actually disclosed another tenant's data, and if
# so records it through the existing durable audit path
# (``api_compat._audit_outbound_request``) -- never a new store.
#
# Fail-closed, deliberately: ``_audit_outbound_request`` calls
# ``_require_pool``, which raises 503 ``database_unavailable`` when the audit
# database is configured but unreachable. That exception is left to propagate
# here, so a cross-tenant read whose disclosure cannot be recorded is refused
# rather than served -- the same convention every audited mutation already
# follows (api_compat.py's audited handlers, eap_audit-style decision logs).
# ==============================================================================
from __future__ import annotations

from typing import Any

from api_compat import Principal, _audit_outbound_request
from superadmin import is_superadmin

#: Dotted per the vocabulary convention test_audit_event_types.py enforces
#: (test_emitted_event_types_use_the_dotted_convention). Permitted by
#: db/migrations/056_cross_tenant_read_event_type.sql.
EVENT_TYPE = "audit.cross_tenant_read"

#: Keys, anywhere in a response body, that name the tenant owning that node.
#: ``tenant_id`` is signal-ingest's convention (api/auth.go, api/policy_routes.go,
#: api/tenancy_grants.go's ObservationTenantLabel); ``tenant`` is
#: fe-signalloom's own local convention (invites.InviteSummary.tenant).
_TENANT_KEYS = ("tenant_id", "tenant")

#: Bounds the recursive walk below so a huge or deeply-nested response body
#: cannot turn an audit check into a hang. Generous relative to any real
#: response (observations/policy pages cap at 500-1000 rows); exists only to
#: make the walk's cost provably bounded.
_MAX_NODES = 50_000


def _walk_tenant_ids(node: Any, found: set[str], budget: list[int]) -> None:
    if budget[0] <= 0:
        return
    budget[0] -= 1
    if isinstance(node, dict):
        for key in _TENANT_KEYS:
            value = node.get(key)
            if isinstance(value, str) and value:
                found.add(value)
        for value in node.values():
            _walk_tenant_ids(value, found, budget)
    elif isinstance(node, list):
        for item in node:
            _walk_tenant_ids(item, found, budget)


def tenant_ids_in_response(content: Any) -> set[str]:
    """Every distinct tenant id found anywhere in a JSON-shaped response body.

    A plain recursive walk rather than per-route field paths: signal-ingest
    nests its tenant label inside ``Labels`` on observations but puts it at
    the top level on policy findings/decisions, and fe-signalloom's own
    ``InviteSummary`` puts it at the top level under a different key. Walking
    everything and matching on key name handles all three shapes (and any
    future one that reuses the same key names) without per-route logic.
    """
    found: set[str] = set()
    _walk_tenant_ids(content, found, [_MAX_NODES])
    return found


def _result_count(content: Any) -> int:
    if isinstance(content, list):
        return len(content)
    return 1 if content else 0


async def audit_cross_tenant_read(
    principal: Principal,
    route: str,
    content: Any,
    *,
    what: str,
    reason: str | None = None,
    result_count: int | None = None,
    extra: dict[str, Any] | None = None,
) -> None:
    """Audit one read if, and only if, it actually surfaced another tenant's data.

    Does nothing for a non-superadmin, whose reads are scoped to their own
    tenant by construction, and nothing when a superadmin's read happens to
    carry only its own tenant's data -- recording that would be noise, not
    evidence, and the ideal state is explicit that same-tenant reads must stay
    silent.

    ``content`` may be pre-shaped by the caller into a minimal
    tenant-attribution structure (see ``cadvisor_poller``'s telemetry routes,
    which have no ``tenant_id`` of their own and build one via a namespace/pod
    lookup, or ``risk.py``'s routes, which carry none at all) rather than the
    literal response body; either way this function only cares which tenant
    ids the structure contains. The sentinel values ``"unresolved"``
    (``cadvisor_poller``: the lookup itself failed) and ``"unattributed"``
    (``risk.py``: there is nothing to look up) are deliberately never equal to
    a real ``principal.tenant``, so passing one here always counts as "another
    tenant's data" and always emits -- a cross-tenant-capable read must never
    go unrecorded just because its tenant could not be named (Andy's review,
    2026-10-06).

    ``reason`` is folded into ``detail`` when given, for exactly that case:
    recording *why* attribution was impossible, not just that it was.
    ``result_count`` overrides the count derived from ``content`` for a
    caller whose ``content`` is a synthetic placeholder rather than the real
    result set (e.g. the single-element ``["unresolved"]`` placeholder
    standing in for an arbitrarily large telemetry response). ``extra`` folds
    additional caller-specific fields into ``detail`` (e.g. the agent id(s) a
    risk read named).
    """
    if not is_superadmin(principal):
        return
    tenant_ids = tenant_ids_in_response(content)
    others = {t for t in tenant_ids if t != principal.tenant}
    if not others:
        return
    detail: dict[str, Any] = {
        "action": "cross_tenant_read",
        "route": route,
        "tenant_ids": sorted(tenant_ids),
        "result_count": result_count if result_count is not None else _result_count(content),
    }
    if reason is not None:
        detail["reason"] = reason
    if extra:
        detail.update(extra)
    # The literal sits at the call site, not behind the EVENT_TYPE constant
    # above, so that test_audit_event_types.py's AST extractor (which resolves
    # a bare name only through a one-hop caller, never through an imported
    # module constant) can see it directly. EVENT_TYPE exists for tests of
    # this module to assert against without duplicating the string.
    #
    # Propagates APIError(503, "database_unavailable", ...) when the audit
    # database is configured but unreachable -- the request fails closed
    # rather than disclosing cross-tenant data with no record of it.
    assert EVENT_TYPE == "audit.cross_tenant_read"
    await _audit_outbound_request(principal, "audit.cross_tenant_read", detail, what)


#: GET routes whose response is scanned by ``audit_cross_tenant_read`` and,
#: when a superadmin's read surfaces another tenant's data, write a
#: ``cross_tenant_read`` audit event. Keyed on "module:function" rather than
#: path, because several of these are registered under more than one path
#: alias (``/api/v1/...`` and ``/v1/...``, or a ``{subpath}`` catch-all) that
#: all resolve to the one function.
#:
#: Checked against by test_cross_tenant_audit_coverage.py, which discovers
#: every GET route capable of a superadmin "read across every tenant" by
#: AST, so a new one can't land without appearing in one of these two
#: registries.
AUDITED_ROUTES: frozenset[str] = frozenset(
    {
        "signal_fusion.py:get_observations",
        "signal_fusion.py:get_actors",
        "signal_fusion.py:get_actor",
        "signal_fusion.py:get_actor_authorization",
        "signal_fusion.py:query_authorization",
        "signal_fusion.py:get_coverage",
        "signal_fusion.py:get_store_stats",
        "signal_fusion.py:stream_observations",
        "signal_policy.py:get_policy_findings",
        "signal_policy.py:get_policy_decisions",
        "invites.py:list_invites",
        "cadvisor_poller.py:get_agent_telemetry",
        "cadvisor_poller.py:list_agent_telemetry",
        "risk.py:get_agent_risk",
        "risk.py:get_fleet_risk",
    }
)

#: GET routes capable of a superadmin "*"/cross-tenant read whose upstream
#: response carries no tenant attribution fe-signalloom can extract, with why.
#: Each reason names where the gap actually is, not just "not implemented" --
#: see the module docstring for the audit obligation this documents against.
#:
#: Andy's review (2026-10-06) narrowed this considerably: "no tenant in the
#: response" is not by itself a reason to stay silent -- stream_observations
#: and both risk.py routes moved to AUDITED_ROUTES, recording a sentinel
#: tenant ("stream"/"unattributed") rather than excusing the gap. Only
#: get_policy_rates and the federation proxy remain here, because their gap
#: is different in kind: rates truly carries no per-request disclosure to
#: name at all (a bucketed count has no identity), and federation's data is
#: either universally-identical demo fixture or an upstream registry that
#: names no tenant anywhere in its vocabulary -- not merely one this gateway
#: declines to attribute.
TENANT_AGNOSTIC_ROUTES: dict[str, str] = {
    "signal_policy.py:get_policy_rates": (
        "Bucketed observation counts per layer/source (api/policy_routes.go rateBucketView) "
        "carry no tenant_id field by design -- confirmed against the Go struct, which has only "
        "BucketStart/Layer/Source/Count. There is no per-request disclosure to name, unlike "
        "stream_observations or the risk.py routes, which do name something (observations, "
        "agent ids) even without a tenant."
    ),
    "federation.py:proxy_federation_route": (
        "Generic reverse proxy; the federation demo dataset is either a hardcoded fallback "
        "(DEFAULT_ZONES/DEFAULT_FEDERATIONS/DEFAULT_SERVICES, identical for every tenant) or "
        "whatever signal-ingest's /api/v1/federation/* registry answers, which attributes no "
        "tenant to a federation record today."
    ),
}
