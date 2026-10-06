"""Remote-cluster workload discovery: fleet-manager's registry as agent records.

The portal's agent list has only ever read the central cluster, through
``fake-integration-proxy``'s pod lister (``AGENT_DISCOVERY_URL``). A pilot
cluster runs no discovery service and is not reachable from the hub, so its
workloads were invisible to every page. Per the remote contract
(``docs/EAP/remote-contract.md``) the warden on that cluster reports its pods to
fleet-manager, which keeps a registry keyed ``cluster_id/namespace/name`` and
serves it at ``GET /api/v1/fleet/workloads?cluster_id=`` behind caller-key scope
``read``. This module is the portal's reader for that registry.

Three deliberate choices:

* **Fail soft, and say so.** A remote cluster being unreachable is a normal
  state (it is somebody else's network), so an error here degrades the
  ``remote_registry`` source-health entry and returns no records. It never
  fails ``/api/agents``, because that would make the central cluster's agents
  disappear whenever the pilot's VPN dropped.

* **The response shape is read defensively.** fleet-manager owns the Go side
  and is adding the endpoint in parallel; the contract names the pod record
  fields but not the envelope key. ``workloads``, ``pods``, and a bare list are
  all accepted so neither side has to land first.

* **Tenancy is the reported tenant, never inferred.** The warden reports the
  pod's ``signalloom.ai/tenant`` label. A record with no tenant is attributed to
  ``__unattributed__`` and is therefore shown to no tenant user, which is the
  same rule ``/weave`` already applies to an unattributed observation. The
  portal does not guess a tenant for a remote pod.

Ids are ``cluster_id/namespace/name``: stable across a pod restart only to the
extent the name is (a Deployment-owned pod gets a new name), which is why the
owner is carried through as well. The id is prefixed ``remote:`` so it can never
collide with a central discovery id or a registry UUID.
"""
from __future__ import annotations

import logging
import os
from typing import Any, Literal

import httpx

logger = logging.getLogger(__name__)

#: Caller key for fleet-manager read scope. The stun key (scope ``stun``) cannot
#: read the registry, so this is its own Secret entry; unset means this
#: deployment does not read a remote registry and the source reports
#: "unavailable" rather than pretending the registry was empty.
FLEET_MANAGER_READ_KEY_ENV = "FLEET_MANAGER_READ_KEY"

#: Cluster ids whose registry the portal merges, comma-separated. Empty means
#: "every cluster fleet-manager knows", which is what an omitted ``cluster_id``
#: query parameter asks for.
FLEET_REMOTE_CLUSTERS_ENV = "FLEET_REMOTE_CLUSTERS"

#: The tenant a remote pod is attributed to when the warden reported none.
#: Matches signal-ingest's spelling so the two unattributed paths read alike.
UNATTRIBUTED_TENANT = "__unattributed__"

#: Marks an id as belonging to the remote registry rather than central
#: discovery or the Postgres registry. Also what ``origin`` reports.
REMOTE_ID_PREFIX = "remote:"
REMOTE_ORIGIN = "remote"

SourceStatus = Literal["healthy", "degraded", "error", "unavailable"]


def remote_clusters() -> list[str]:
    """Configured cluster ids, or ``[""]`` meaning "ask for all of them"."""
    raw = os.environ.get(FLEET_REMOTE_CLUSTERS_ENV, "")
    ids = [c.strip() for c in raw.split(",") if c.strip()]
    return ids or [""]


def _read_key() -> str:
    return os.environ.get(FLEET_MANAGER_READ_KEY_ENV, "").strip()


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _records(payload: Any) -> list[dict[str, Any]]:
    """Pull pod records out of whichever envelope fleet-manager used."""
    if isinstance(payload, list):
        candidates = payload
    elif isinstance(payload, dict):
        for key in ("workloads", "pods", "items"):
            value = payload.get(key)
            if isinstance(value, list):
                candidates = value
                break
        else:
            return []
    else:
        return []
    return [c for c in candidates if isinstance(c, dict)]


def remote_id(cluster_id: str, namespace: str, name: str) -> str:
    """The stable portal id of a remote pod: ``remote:cluster/namespace/name``."""
    return f"{REMOTE_ID_PREFIX}{cluster_id}/{namespace}/{name}"


def normalize(record: dict[str, Any], default_cluster_id: str = "") -> dict[str, Any] | None:
    """One registry pod record as a discovery-shaped dict, or None if unusable.

    The output speaks the same dialect as ``fake-integration-proxy``'s ``/agents``
    items (``id``, ``name``, ``namespace``, ``tenant``, ``model``, ``kernel_state``)
    so the existing ``_agent_response_from_discovered`` builder can consume it
    without a second code path, plus the three remote-only fields the contract
    names: ``cluster_id``, ``pod``, ``frozen``.

    A record with no name or no namespace is dropped: without both there is no
    stable id, and a record the portal cannot address again is worse than
    absent because it would appear and disappear between polls.
    """
    namespace = _text(record.get("namespace"))
    name = _text(record.get("name"))
    if not namespace or not name:
        return None

    cluster_id = _text(record.get("cluster_id")) or _text(default_cluster_id)
    if not cluster_id:
        return None

    owner = record.get("owner") if isinstance(record.get("owner"), dict) else {}
    labels = record.get("labels") if isinstance(record.get("labels"), dict) else {}
    frozen = record.get("frozen") is True
    tenant = _text(record.get("tenant")) or UNATTRIBUTED_TENANT

    # The warden reports the pod's labels verbatim, so the model label is read
    # from there. No model means no model: the claim path refuses a workload
    # that declares none, and inventing one here would defeat that.
    model = _text(labels.get("signalloom.ai/model")) or _text(record.get("model"))

    return {
        "id": remote_id(cluster_id, namespace, name),
        "name": name,
        "namespace": namespace,
        "tenant": tenant,
        "model": model or None,
        "origin": REMOTE_ORIGIN,
        "type": REMOTE_ORIGIN,
        # Remote-only fields (remote-contract.md "Discovery and tenancy").
        "cluster_id": cluster_id,
        "pod": name,
        "frozen": frozen,
        "pod_uid": _text(record.get("uid")) or None,
        "node": _text(record.get("node")) or None,
        "owner_kind": _text(owner.get("kind")) or None,
        "owner_name": _text(owner.get("name")) or None,
        # Kernel truth as the warden observed it, same vocabulary as the
        # central kernel_state annotation. "unknown" is never claimed as
        # "running": a registry that has not reported a freeze is not evidence
        # that the pod is thawed.
        "kernel_state": "frozen" if frozen else "unknown",
        "kernel_observed_at": _text(record.get("reported_at")) or None,
        "labels": dict(labels),
    }


async def fetch(
    base_url: str,
    *,
    timeout: float = 5.0,
) -> tuple[list[dict[str, Any]], SourceStatus, str | None]:
    """Read every configured cluster's registry.

    Returns ``(records, status, message)``. ``status`` is ``unavailable`` when
    there is no key or no fleet-manager, ``degraded`` when at least one cluster
    answered and at least one did not, and ``error`` when none answered.
    """
    if not base_url:
        return [], "unavailable", "no fleet-manager configured"

    key = _read_key()
    if not key:
        # Said plainly rather than reported as an empty registry: "no remote
        # workloads" and "the portal cannot read the registry" are different
        # facts and the pilot needs to tell them apart.
        return [], "unavailable", f"{FLEET_MANAGER_READ_KEY_ENV} is unset"

    clusters = remote_clusters()
    records: list[dict[str, Any]] = []
    failures: list[str] = []
    successes = 0

    headers = {"Authorization": f"Bearer {key}"}
    url = f"{base_url.rstrip('/')}/api/v1/fleet/workloads"

    async with httpx.AsyncClient(timeout=timeout) as client:
        for cluster_id in clusters:
            params = {"cluster_id": cluster_id} if cluster_id else None
            try:
                res = await client.get(url, params=params, headers=headers)
                if res.status_code >= 400:
                    # A plain ValueError, not httpx.HTTPStatusError: that
                    # exception reads ``response.request``, which is unset on a
                    # response the caller constructed rather than sent, so
                    # building it would raise RuntimeError and turn a handled
                    # 503 from fleet-manager into a 500 from the portal.
                    raise ValueError(f"status {res.status_code}")
                payload = res.json()
            except (httpx.HTTPError, ValueError) as exc:
                failures.append(f"{cluster_id or 'all'}: {exc}")
                continue
            successes += 1
            for record in _records(payload):
                normalized = normalize(record, default_cluster_id=cluster_id)
                if normalized is not None:
                    records.append(normalized)

    if failures and successes == 0:
        logger.warning("remote workload registry unreadable: %s", "; ".join(failures))
        return [], "error", "; ".join(failures)
    if failures:
        logger.warning("remote workload registry partially read: %s", "; ".join(failures))
        return records, "degraded", "; ".join(failures)
    return records, "healthy", None
