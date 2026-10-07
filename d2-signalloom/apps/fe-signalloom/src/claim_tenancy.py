"""Who may claim a workload, and with what model.

A claim binds a running workload into the claimant's tenant. The workload's
tenant is declared by the platform, as the ``signalloom.ai/tenant`` label that
GitOps puts on the pod template. It is never declared by the claimant. Discovery
(fake-integration-proxy ``GET /agents``) reports that label as ``tenant`` and
the ``signalloom.ai/model`` label as ``model``.

Every claim path resolves its target here first:

* 503 ``discovery_unavailable``  discovery cannot be read; the claim fails closed
* 404 ``workload_not_found``     no running workload of that name in that namespace
* 409 ``workload_ambiguous``     more than one workload answers to that name
* 403 ``agent_identity_mismatch`` the workload's agent_name label names a
  REGISTERED agent (agent_identity_map, the same map
  d2-signalloom/apps/fleet-manager/identity_map.go and the
  ValidatingAdmissionPolicy sl-agent-identity-binding read -- defined
  inline in the fleet's cluster-level ResourceSet at
  d2-osramp-fleet/tenants/base/policies.yaml, reconciled by flux-system)
  but its actual namespace and ServiceAccount do not BOTH match the pair
  registered for it -- a decoy claiming a known identity, not that agent.
  A ServiceAccount name alone is not enough: it is only unique within its
  namespace. An unregistered agent_name is unaffected.
* 403 ``workload_tenant_undeclared``  the workload carries no tenant label
* 403 ``cross_tenant_forbidden`` the workload belongs to another tenant (not named)
* 422 ``workload_model_undeclared``  the workload carries no model label
* 422 ``model_mismatch``         the claimant asserted a model the workload does not declare

The model a claim records is the workload's, so no claim path can write a model
the workload did not declare. Tenants compare as exact strings, so a homoglyph
(``kusarі`` with a Cyrillic ``і``) is a different tenant and is refused.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Awaitable, Callable

import httpx

import agent_identity_map


# agent_claims.model is NOT NULL; an agent that declares no model is recorded
# as exactly this, never as a guessed model. Nullable columns record NULL.
UNDECLARED_MODEL = "undeclared"


# Per-workload refusals. Batch claiming skips these; 503 is never skipped.
REFUSAL_CODES = frozenset({
    "workload_not_found", "workload_ambiguous", "workload_tenant_undeclared",
    "cross_tenant_forbidden", "workload_model_undeclared", "model_mismatch",
    "agent_identity_mismatch",
})

# The agent-name -> (namespace, ServiceAccount) map. Called fresh on every
# authorize(), same pattern as workload_source below, so a test can replace
# it with a fixture mapping with no filesystem involved. Production reads
# the ConfigMap volume mount (agent_identity_map.load's default directory).
identity_map_source: Callable[[], dict[str, agent_identity_map.AgentIdentity]] = agent_identity_map.load


@dataclass(frozen=True)
class ClaimTarget:
    name: str
    namespace: str
    tenant: str
    model: str


async def _discovery_workloads() -> list[dict[str, Any]]:
    import api_compat

    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            res = await client.get(api_compat.AGENT_DISCOVERY_URL)
            api_compat._check_response_status(res, api_compat.AGENT_DISCOVERY_URL)
            payload = res.json()
    except Exception:
        raise api_compat.APIError(
            503, "discovery_unavailable", "Workload discovery is unavailable; claims fail closed"
        ) from None
    agents = payload.get("agents") if isinstance(payload, dict) else None
    if not isinstance(agents, list):
        raise api_compat.APIError(
            503, "discovery_unavailable", "Workload discovery returned no agent list; claims fail closed"
        )
    return [a for a in agents if isinstance(a, dict)]


# The workload source. Tests replace it with a fixture list of workloads in the
# discovery contract's shape; production reads discovery.
workload_source: Callable[[], Awaitable[list[dict[str, Any]]]] = _discovery_workloads


def _label(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _answers_to(workload: dict[str, Any], name: str) -> bool:
    keys = ("agent_name", "id", "name")
    return any(isinstance(workload.get(k), str) and workload.get(k) == name for k in keys)


async def list_workloads() -> list[dict[str, Any]]:
    return await workload_source()


def authorize(
    workloads: list[dict[str, Any]],
    name: str,
    namespace: str,
    tenant: str,
    asserted_model: str | None = None,
) -> ClaimTarget:
    import api_compat

    matches = [w for w in workloads if w.get("namespace") == namespace and _answers_to(w, name)]
    if not matches:
        raise api_compat.APIError(
            404, "workload_not_found", f"No running workload '{name}' in namespace '{namespace}'"
        )
    if len(matches) > 1:
        raise api_compat.APIError(
            409, "workload_ambiguous", f"More than one workload answers to '{name}' in '{namespace}'"
        )
    workload = matches[0]

    # The agent_name field is sourced from signalloom.ai/agent-name, a label
    # its creator writes -- including hosted-daytona-coder, which holds
    # pod-create RBAC in this namespace. If that name is a REGISTERED agent
    # identity, the workload's actual namespace AND ServiceAccount (both read
    # live from the pod, never a label) must match the pair registered for
    # it, or this is a decoy claiming a known agent's identity, not that
    # agent. Namespace is required alongside ServiceAccount because a
    # ServiceAccount name is only unique within its namespace: a decoy in a
    # different namespace that names its own ServiceAccount after a
    # registered agent (e.g. hosted-daytona-coder's own namespace running a
    # ServiceAccount literally called "kusari-agent") would otherwise pass.
    # An unregistered agent_name is unaffected: this is never a second
    # allow-list for which agents may exist.
    claimed_identity = _label(workload.get("agent_name"))
    if claimed_identity and not agent_identity_map.matches(
        identity_map_source(), claimed_identity, workload.get("namespace"), workload.get("service_account")
    ):
        raise api_compat.APIError(
            403, "agent_identity_mismatch",
            f"Workload '{name}' is labelled as registered agent '{claimed_identity}' but runs in "
            f"namespace '{workload.get('namespace')}' as ServiceAccount '{workload.get('service_account')}', "
            "not the namespace/ServiceAccount registered for that agent",
        )

    declared = _label(workload.get("tenant"))
    if not declared:
        raise api_compat.APIError(
            403, "workload_tenant_undeclared",
            f"Workload '{name}' declares no signalloom.ai/tenant; it cannot be claimed",
        )
    if declared != tenant:
        # The owning tenant is not named: a refusal must not become a tenant oracle.
        # By design this also refuses every tenant for workloads GitOps labels
        # `controlplane` (agent-cardvault, swarm-governor, triage-ci-worker and the
        # other platform-owned agents). No subject maps to that tenant, because
        # those agents are the platform's own and not claimable by customers.
        raise api_compat.APIError(
            403, "cross_tenant_forbidden", f"Workload '{name}' belongs to another tenant"
        )
    model = _label(workload.get("model"))
    if not model:
        raise api_compat.APIError(
            422, "workload_model_undeclared",
            f"Workload '{name}' declares no signalloom.ai/model; refusing to record an invented model",
        )
    # An asserted model may name the workload's model or its bare
    # signalloom.ai/model label; the recorded model is always the workload's.
    accepted = {model, _label(workload.get("model_label"))} - {""}
    if asserted_model is not None and asserted_model not in accepted:
        raise api_compat.APIError(
            422, "model_mismatch", f"Workload '{name}' declares model '{model}', not '{asserted_model}'"
        )
    return ClaimTarget(name=name, namespace=namespace, tenant=declared, model=model)


async def resolve_claim(
    name: str, namespace: str, tenant: str, asserted_model: str | None = None
) -> ClaimTarget:
    return authorize(await list_workloads(), name, namespace, tenant, asserted_model)


def claimable(workloads: list[dict[str, Any]], tenant: str, namespace: str | None = None) -> list[dict[str, Any]]:
    """The workloads ``tenant`` may claim: its own tenant label and a declared model."""
    return [
        w for w in workloads
        if _label(w.get("tenant")) == tenant
        and _label(w.get("model"))
        and (namespace is None or w.get("namespace") == namespace)
    ]
