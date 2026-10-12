"""Measured federation state for the Federated Services screen.

Why this exists
---------------
``GET /v1/federation/{summary,zones,federations,services,policies,identities,
events}`` used to be answered from a hardcoded dataset: three zones, three
federations, four services, three policies, five SPIFFE IDs with fixed
expiries, five events with a literal bundle SHA, and a summary carrying
``attestation_success_rate: 99.8`` / ``active_alerts: 0`` whose other counts
were ``len()`` of those literal lists. None of it was a function of any input:
W9's perturbation showed all seven subpaths returning a byte-identical 200
across two different authenticated tenants. It was not a degraded-mode
fallback either - signal-ingest registers no ``/api/v1/federation`` handler
outside its own tests, so ``api/auth.go`` default-denies every such request
with ``403 {"error":"unregistered_route"}``, and the invented dataset is what
the dashboard got 100% of the time in live mode.

A sibling deleted the dataset, after which live mode showed nothing at all.
This module is the other half: show what IS measured, and refuse the rest
**per field**, naming the source that does not exist.

Where the implementation lives, and why here rather than in Go
-------------------------------------------------------------
In fe-signalloom, not signal-ingest. Three reasons, in order of weight:

1. The evidence vocabulary already lives here. ``api_compat._derived_topology``
   already labels every item ``evidence_state`` / ``assurance`` / ``freshness``
   / ``reason`` and reports its collector "unavailable" with a cause. A second
   implementation of that vocabulary in Go would drift from this one, and the
   whole value of the vocabulary is that one reader can trust it everywhere.
2. The only thing in this estate that actually OBSERVES SPIFFE state is the
   trust-topology collector, and fe-signalloom is the service that reads it
   (``TRUST_TOPOLOGY_URL``). signal-ingest is the telemetry ingest path; it
   holds no Kubernetes client, no SPIRE client and no RBAC for either, and
   giving it those to serve a read the portal already performs would be a new
   trust boundary bought for nothing.
3. signal-ingest's mux is a route registry that default-denies. A Go handler
   there has to be *registered*, not merely written - which is exactly the
   defect being replaced. Keeping the read local also stops every page load
   paying a round trip to collect a 403.

The write path is unchanged: anything that is not one of the seven read
subpaths still proxies to signal-ingest and still gets
``502 upstream_route_not_served`` when that route is not deployed.

What is measurable, and what is not
-----------------------------------
Measured, because it is a function of the collector's observations (or, when
the collector is unreachable, of the authenticated tenant's own registry - in
which case every item is labelled ``modeled``):

  identities[].uri   the SPIFFE ID observed on the workload
  identities[].ns    namespace observed on the workload
  identities[].sa    service account observed on the workload
  identities[].workload  the workload's own label/name
  zones[].domain     the trust domain parsed out of the observed SPIFFE IDs
  zones[].name       the same string; a zone's name IS its trust domain here
  zones[].identities how many observed identities sit in that trust domain
  counts.trust_zones, counts.spiffe_identities

Refused, because no source this service can reach reports them. Each carries
its own reason on the wire; see ``_REFUSALS``.

  zones[].clusters, zones[].servers, zones[].status
  identities[].svid, identities[].expiry
  the whole of federations, services, policies and events
  counts.attestation_success_rate, counts.active_alerts
"""
from __future__ import annotations

from typing import Any, Iterable, Mapping

#: Trust-domain-bearing SPIFFE prefix.
_SPIFFE_PREFIX = "spiffe://"

#: Node kinds that are platform-wide rather than tenant-owned, mirroring the
#: tenant filter in ``api_compat.trust_topology`` so the two views of the same
#: collector payload cannot disagree about who may see what.
_SHARED_KINDS = frozenset({"platform", "service", "external", "gap", "probe"})

#: Per-field refusals. The reason names the source that would have to exist.
_REFUSALS: dict[str, dict[str, str]] = {
    "zones.clusters": {
        "field": "clusters",
        "reason": (
            "the number of clusters in a trust domain is not collected: the topology "
            "collector reports workloads and their namespaces, and nothing in this "
            "deployment enumerates clusters per trust domain"
        ),
    },
    "zones.servers": {
        "field": "servers",
        "reason": (
            "counting the SPIRE servers that issue for a trust domain needs a read of "
            "the spire-system namespace or of the SPIRE server API; fe-signalloom holds "
            "neither a Kubernetes client for it nor RBAC to perform it"
        ),
    },
    "zones.status": {
        "field": "status",
        "reason": (
            "zone status is bundle-exchange state, readable only from the SPIRE bundle "
            "API (`spire-server bundle list`). No collector reads it, so 'active' would "
            "be an assertion that trust is established rather than an observation of it"
        ),
    },
    "identities.svid": {
        "field": "svid",
        "reason": (
            "the SVID type (X.509 vs JWT) is a property of the issued SVID document, and "
            "this service never handles a workload's SVID - only the SPIFFE ID the "
            "collector saw on the pod"
        ),
    },
    "identities.expiry": {
        "field": "expiry",
        "reason": (
            "SVID expiry is carried inside the SVID, which this service never sees; a "
            "lifetime inferred from a default TTL would be a guess presented as a clock"
        ),
    },
    "counts.attestation_success_rate": {
        "field": "attestation_success_rate",
        "reason": (
            "no attestation outcome stream is collected or stored anywhere in this "
            "estate, and a success rate over zero observations is not a number. This is "
            "the field that read 99.8 for every tenant on every request"
        ),
    },
    "counts.active_alerts": {
        "field": "active_alerts",
        "reason": (
            "there is no federation alert source, so zero alerts cannot be distinguished "
            "from no alerting. This field read 0 unconditionally"
        ),
    },
}

#: Panels with no source at all. Refused whole, with the source named.
_UNAVAILABLE_PANELS: dict[str, str] = {
    "federations": (
        "a federation is a ClusterFederatedTrustDomain object (or a "
        "`spire-server federation list` row). Nothing in this deployment reads either, "
        "so no federation relationship can be reported as observed. "
        "d2-agent-trust/spire-federation-config.yaml does DECLARE a trust-domain "
        "pair - read that file for the two domains - and a declaration in git is not "
        "an observation of a completed bundle exchange. Reporting it as one is how "
        "the deleted dataset came to show three federations as 'federated'. "
        "The domains are named by reference rather than quoted here on purpose: "
        "test_eap_identity.py asserts that no module in this package contains a "
        "stale trust-domain literal, and that guard is valuable precisely because "
        "it has no exemption list to rot. Prose is not worth the first exemption"
    ),
    "services": (
        "a federated service is an entry in the Cofide Connect / xDS fabric this panel "
        "describes. That fabric is not deployed in this estate at all: there is no agent, "
        "no xDS registry and no local endpoint to enumerate, so every row here would be "
        "invented wholesale"
    ),
    "policies": (
        "attestation policies are ClusterSPIFFEID custom resources. No collector reads "
        "them and fe-signalloom has no RBAC to list them, so the selectors that actually "
        "gate federation are unknown to this service"
    ),
    "events": (
        "no federation event stream is collected, published or stored - there is no "
        "bundle-rotation, attestation or federation audit feed for this screen to read. "
        "The deleted dataset's five events included a literal trust bundle SHA"
    ),
}


def refusals(*keys: str) -> list[dict[str, str]]:
    """The wire form of a set of per-field refusals."""
    return [dict(_REFUSALS[key]) for key in keys]


def trust_domain_of(spiffe_id: str | None) -> str | None:
    """The trust domain of a SPIFFE ID, or None if it is not one.

    Pure string derivation: ``spiffe://<domain>/<path>`` -> ``<domain>``. An ID
    with no path is still a trust domain; anything that is not a SPIFFE URI, or
    carries an empty authority, yields None rather than a guess.
    """
    if not isinstance(spiffe_id, str) or not spiffe_id.startswith(_SPIFFE_PREFIX):
        return None
    tail = spiffe_id[len(_SPIFFE_PREFIX):]
    domain = tail.split("/", 1)[0].strip()
    return domain or None


def _get(source: Any, name: str) -> Any:
    """Field access over either a mapping or an attribute-carrying object."""
    if isinstance(source, Mapping):
        return source.get(name)
    return getattr(source, name, None)


def _visible(node: Any, tenant_id: str) -> bool:
    kind = _get(node, "kind")
    tenant = _get(node, "tenant")
    if kind in _SHARED_KINDS:
        return True
    return tenant in (None, "", "shared", tenant_id)


def identities_from_topology(nodes: Iterable[Any], tenant_id: str) -> list[dict[str, Any]]:
    """One identity row per visible node that was observed to carry a SPIFFE ID.

    A node without a SPIFFE ID produces no row: an un-identified workload is not
    an identity, and inventing a probable SPIFFE ID for it from its namespace and
    service account would manufacture exactly the thing this screen is for.
    """
    rows: list[dict[str, Any]] = []
    for node in nodes:
        if not _visible(node, tenant_id):
            continue
        uri = _get(node, "spiffe_id")
        if not trust_domain_of(uri):
            continue
        rows.append({
            "uri": uri,
            "workload": _get(node, "label") or _get(node, "name") or _get(node, "id"),
            "ns": _get(node, "namespace"),
            "sa": _get(node, "service_account"),
            # refused: identities.svid / identities.expiry
            "svid": None,
            "expiry": None,
            "evidence_state": _get(node, "evidence_state") or "modeled",
            "observed_at": _get(node, "observed_at"),
            "evidence_source": _get(node, "evidence_source"),
        })
    rows.sort(key=lambda row: row["uri"])
    return rows


def identities_from_agents(agents: Iterable[Any], tenant_id: str) -> list[dict[str, Any]]:
    """Fallback rows from the tenant's own registry, used only when the collector is down.

    The registry records what was REGISTERED, not what SPIRE is currently
    issuing, so every row this produces is modeled and the caller labels the
    panel accordingly.
    """
    rows: list[dict[str, Any]] = []
    for agent in agents:
        if _get(agent, "tenant_id") not in (None, tenant_id):
            continue
        uri = _get(agent, "spiffe_id")
        if not trust_domain_of(uri):
            continue
        rows.append({
            "uri": uri,
            "workload": _get(agent, "name") or _get(agent, "id"),
            "ns": _get(agent, "namespace"),
            "sa": _get(agent, "service_account"),
            # refused: identities.svid / identities.expiry
            "svid": None,
            "expiry": None,
            "evidence_state": "modeled",
            "observed_at": _get(agent, "last_transition_at") or _get(agent, "created_at"),
            "evidence_source": "Derived from the authenticated tenant's agent registry",
        })
    rows.sort(key=lambda row: row["uri"])
    return rows


def zones_from_identities(identities: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Trust zones are the distinct trust domains of the identities actually seen.

    This is the whole of what can be said about a zone from here, and it is a
    strict function of the identity rows: remove the last identity in a domain
    and the zone goes with it. ``clusters`` / ``servers`` / ``status`` are
    emitted as None and refused by key.
    """
    counts: dict[str, int] = {}
    for item in identities:
        domain = trust_domain_of(item.get("uri"))
        if domain:
            counts[domain] = counts.get(domain, 0) + 1
    return [
        {
            "name": domain,
            "domain": domain,
            "identities": counts[domain],
            # refused: zones.clusters / zones.servers / zones.status
            "clusters": None,
            "servers": None,
            "status": None,
        }
        for domain in sorted(counts)
    ]


def _panel(
    items: list[dict[str, Any]],
    *,
    degraded: bool,
    observed_at: str | None,
    evidence_source: str,
    reason: str,
    unmeasured: list[dict[str, str]],
) -> dict[str, Any]:
    """A measured panel, labelled with the weakest evidence any of its items carries."""
    state = "modeled" if degraded else "observed"
    return {
        "available": True,
        "items": items,
        "evidence_state": state,
        "assurance": state,
        "freshness": "unavailable" if degraded else "fresh",
        "observed_at": observed_at,
        "evidence_source": evidence_source,
        "reason": reason,
        "unmeasured_fields": unmeasured,
    }


def _refused_panel(name: str, *, observed_at: str | None) -> dict[str, Any]:
    return {
        "available": False,
        "items": [],
        "evidence_state": "unavailable",
        "assurance": "unavailable",
        "freshness": "unavailable",
        "observed_at": observed_at,
        "evidence_source": None,
        "reason": _UNAVAILABLE_PANELS[name],
        "unmeasured_fields": [],
    }


def build_federation_state(
    *,
    tenant_id: str,
    now: str,
    topology: Mapping[str, Any] | None,
    topology_reason: str,
    agents: Iterable[Any] = (),
) -> dict[str, Any]:
    """Assemble the whole federation view from the sources that exist.

    ``topology`` is the trust-topology collector payload, or None when it could
    not be reached (``topology_reason`` then names the cause). Both inputs are
    injected rather than fetched so the derivation is testable without a
    collector, a cluster, or a network.
    """
    collector_ok = topology is not None
    if collector_ok:
        collector = (topology.get("collectors") or {}).get("kubernetes") or {}
        collector_status = collector.get("status") or "ok"
        collector_observed_at = collector.get("observed_at") or now
        collector_reason = collector.get("reason") or ""
        observed = collector_status == "ok"
        identities = identities_from_topology(topology.get("nodes") or [], tenant_id)
        source = "trust-topology collector (Kubernetes workload observation)"
        panel_reason = (
            "SPIFFE IDs as observed on in-cluster workloads by the topology collector"
            if observed
            else f"topology collector reported {collector_status}: {collector_reason}"
        )
    else:
        collector_status = "unavailable"
        collector_observed_at = now
        collector_reason = topology_reason
        observed = False
        identities = identities_from_agents(agents, tenant_id)
        source = "Derived from the authenticated tenant's agent registry"
        panel_reason = (
            "topology collector unreachable, so these rows come from the tenant's own "
            f"registry and record what was registered, not what SPIRE is issuing: {topology_reason}"
        )

    zones = zones_from_identities(identities)
    # One verdict for both panels: a zone is only as observed as the identities
    # it was derived from, so the weakest identity weakens the zone list too.
    degraded = not observed or any(
        item.get("evidence_state") not in (None, "observed") for item in identities
    )

    zones_panel = _panel(
        zones,
        degraded=degraded,
        observed_at=collector_observed_at,
        evidence_source=source,
        reason=panel_reason,
        unmeasured=refusals("zones.clusters", "zones.servers", "zones.status"),
    )
    identities_panel = _panel(
        identities,
        degraded=degraded,
        observed_at=collector_observed_at,
        evidence_source=source,
        reason=panel_reason,
        unmeasured=refusals("identities.svid", "identities.expiry"),
    )

    return {
        "generated_at": now,
        "tenant": tenant_id,
        "collectors": {
            "kubernetes": {
                "status": collector_status,
                "observed_at": collector_observed_at,
                "reason": collector_reason,
            }
        },
        "zones": zones_panel,
        "identities": identities_panel,
        "federations": _refused_panel("federations", observed_at=collector_observed_at),
        "services": _refused_panel("services", observed_at=collector_observed_at),
        "policies": _refused_panel("policies", observed_at=collector_observed_at),
        "events": _refused_panel("events", observed_at=collector_observed_at),
        "counts": {
            "trust_zones": len(zones),
            "spiffe_identities": len(identities),
            "federations": None,
            "federated_services": None,
            "attestation_policies": None,
            "attestation_success_rate": None,
            "active_alerts": None,
        },
        "unmeasured_fields": refusals(
            "counts.attestation_success_rate", "counts.active_alerts"
        ),
    }


#: Subpaths this service derives locally. Everything else keeps the proxy.
LOCAL_READ_SUBPATHS = frozenset({
    "", "summary", "zones", "federations", "services", "policies", "identities", "events",
})


def project_subpath(state: Mapping[str, Any], subpath: str) -> dict[str, Any]:
    """Project the whole state onto one subpath's response.

    ``summary`` is the whole thing. A named panel is returned as that panel,
    with the state's generated_at/collectors attached so a caller fetching one
    panel still learns how fresh it is and which collector produced it.
    """
    if subpath in ("", "summary"):
        return dict(state)
    panel = dict(state[subpath])
    panel["generated_at"] = state["generated_at"]
    panel["collectors"] = state["collectors"]
    return panel
